import Foundation

/// Decodes usage metadata only; message text, prompts and tool payloads are not
/// decoded into the application model, persisted, logged or uploaded.
public struct TokenLogParser {
    private struct Counters: Decodable {
        var input_tokens: Int64?
        var output_tokens: Int64?
        var cache_read_input_tokens: Int64?
        var cache_creation_input_tokens: Int64?
        var cached_input_tokens: Int64?
        var cache_write_input_tokens: Int64?
        var normalizedClaude: TokenCounts? {
            counts(input: input_tokens ?? 0, output: output_tokens ?? 0,
                   read: cache_read_input_tokens ?? 0, write: cache_creation_input_tokens ?? 0)
        }
        var normalizedCodex: TokenCounts? {
            let totalInput = input_tokens ?? 0
            let read = cached_input_tokens ?? 0
            let write = cache_write_input_tokens ?? 0
            guard read >= 0, write >= 0, read <= totalInput, write <= totalInput - read else { return nil }
            return counts(input: totalInput - read - write, output: output_tokens ?? 0, read: read, write: write)
        }
        private func counts(input: Int64, output: Int64, read: Int64, write: Int64) -> TokenCounts? {
            guard [input, output, read, write].allSatisfy({ (0...1_000_000_000_000).contains($0) }) else { return nil }
            return TokenCounts(input: input, output: output, cacheRead: read, cacheWrite: write)
        }
    }
    private struct ClaudeRow: Decodable {
        struct Message: Decodable { var id: String?; var model: String?; var usage: Counters? }
        var type: String?; var timestamp: String?; var uuid: String?; var requestId: String?; var message: Message?
    }
    private struct CodexRow: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable { var total_token_usage: Counters?; var last_token_usage: Counters? }
            var type: String?; var id: String?; var session_id: String?; var model: String?; var turn_id: String?; var info: Info?
        }
        var type: String?; var timestamp: String?; var payload: Payload?
    }
    public let provider: Provider
    private var session: String
    private var turn: String?
    private var model = "未知模型"
    private var previousCumulative: TokenCounts?
    private let fractional = ISO8601DateFormatter()
    private let plain = ISO8601DateFormatter()
    public private(set) var malformedUsageRows = 0

    public init(provider: Provider, fileIdentity: String) {
        self.provider = provider; self.session = fileIdentity
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    private func date(_ text: String?) -> Date? {
        guard let text else { return nil }; return fractional.date(from: text) ?? plain.date(from: text)
    }
    public mutating func parse(_ line: Data) -> TokenRecord? {
        let decoder = JSONDecoder()
        if provider == .claude {
            guard line.range(of: Data("\"usage\"".utf8)) != nil else { return nil }
            guard let row = try? decoder.decode(ClaudeRow.self, from: line) else { malformedUsageRows += 1; return nil }
            guard row.type == "assistant", let usage = row.message?.usage else { return nil }
            guard let counts = usage.normalizedClaude, let time = date(row.timestamp), let id = row.message?.id ?? row.uuid else {
                malformedUsageRows += 1; return nil
            }
            let key = "claude:\(id):\(row.requestId ?? "")"
            return TokenRecord(id: key, provider: provider, timestamp: time, model: row.message?.model ?? "未知模型", counts: counts)
        }
        guard ["\"token_count\"", "\"session_meta\"", "\"turn_context\""].contains(where: { line.range(of: Data($0.utf8)) != nil }) else { return nil }
        guard let row = try? decoder.decode(CodexRow.self, from: line) else { malformedUsageRows += 1; return nil }
        guard let payload = row.payload else { return nil }
        if row.type == "session_meta" {
            session = payload.id ?? payload.session_id ?? session
            return nil
        }
        if row.type == "turn_context" {
            model = payload.model ?? model; turn = payload.turn_id
            return nil
        }
        guard row.type == "event_msg", payload.type == "token_count", let info = payload.info else { return nil }
        guard let time = date(row.timestamp) else { malformedUsageRows += 1; return nil }
        let cumulative = info.total_token_usage?.normalizedCodex
        if info.total_token_usage != nil && cumulative == nil { malformedUsageRows += 1; return nil }
        // Repeated rate-limit updates carry the same cumulative counters.
        if let cumulative, cumulative == previousCumulative { return nil }
        let counts: TokenCounts
        if let last = info.last_token_usage {
            guard let value = last.normalizedCodex else { malformedUsageRows += 1; return nil }
            counts = value
        } else if let cumulative {
            counts = previousCumulative.map { cumulative.positiveDifference(from: $0) } ?? cumulative
        } else { malformedUsageRows += 1; return nil }
        previousCumulative = cumulative
        guard counts.total > 0 else { return nil }
        // Shared turn IDs also deduplicate transcript prefixes copied by forks.
        let fingerprint = cumulative?.signature ?? "\(time.timeIntervalSince1970):\(counts.signature)"
        return TokenRecord(id: "codex:\(turn ?? session):\(fingerprint)", provider: provider, timestamp: time, model: model, counts: counts)
    }
}

public actor LocalTokenScanner {
    private struct CachedFile {
        var size: UInt64 = 0
        var inode: UInt64 = 0
        var modified: Date = .distantPast
        var pending = Data()
        var droppingLongLine = false
        var oversizedRows = 0
        var parser: TokenLogParser
        var records: [String: TokenRecord] = [:]
    }
    private let roots: [Provider: [URL]]
    private var cache: [URL: CachedFile] = [:]
    public init(roots: [Provider: [URL]]) { self.roots = roots }

    public func scan(now: Date = Date()) -> TokenReport {
        let manager = FileManager.default
        var coverage: [Provider: TokenCoverage] = [:]
        var liveFiles: Set<URL> = []
        var combined: [String: TokenRecord] = [:]
        for provider in Provider.allCases {
            var status = TokenCoverage()
            for root in roots[provider] ?? [] {
                var isDirectory: ObjCBool = false
                guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                status.directoryFound = true
                guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles], errorHandler: { _, _ in
                    status.unreadableFiles += 1; return true
                }) else { status.unreadableFiles += 1; continue }
                for case let url as URL in walker where url.pathExtension == "jsonl" {
                    guard liveFiles.insert(url).inserted else { continue }
                    status.files += 1
                    do {
                        let attributes = try manager.attributesOfItem(atPath: url.path)
                        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                        let modified = attributes[.modificationDate] as? Date ?? .distantPast
                        var file = cache[url] ?? CachedFile(parser: TokenLogParser(provider: provider, fileIdentity: url.lastPathComponent))
                        if file.inode != inode || size < file.size || (size == file.size && modified != file.modified) {
                            file = CachedFile(parser: TokenLogParser(provider: provider, fileIdentity: url.lastPathComponent))
                        }
                        if size > file.size {
                            let handle = try FileHandle(forReadingFrom: url)
                            defer { try? handle.close() }
                            try handle.seek(toOffset: file.size)
                            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                                file.size += UInt64(chunk.count)
                                file.pending.append(chunk)
                                var start = file.pending.startIndex
                                while let newline = file.pending[start...].firstIndex(of: 0x0A) {
                                    if !file.droppingLongLine {
                                        let line = Data(file.pending[start..<newline])
                                        if let record = file.parser.parse(line) {
                                            if var old = file.records[record.id] { old.merge(record); file.records[record.id] = old }
                                            else { file.records[record.id] = record }
                                        }
                                    }
                                    file.droppingLongLine = false
                                    start = file.pending.index(after: newline)
                                }
                                file.pending = Data(file.pending[start...])
                                if file.pending.count > 32 * 1024 * 1024 {
                                    file.pending.removeAll(keepingCapacity: false)
                                    file.droppingLongLine = true; file.oversizedRows += 1
                                }
                            }
                        }
                        file.inode = inode; file.modified = modified
                        cache[url] = file
                        status.malformedUsageRows += file.parser.malformedUsageRows + file.oversizedRows
                        for record in file.records.values {
                            if var old = combined[record.id] { old.merge(record); combined[record.id] = old }
                            else { combined[record.id] = record }
                        }
                    } catch { status.unreadableFiles += 1 }
                }
            }
            coverage[provider] = status
        }
        cache = cache.filter { liveFiles.contains($0.key) }
        return TokenReport(records: combined.values.sorted { $0.timestamp.timeIntervalSince($1.timestamp) < 0 }, coverage: coverage, scannedAt: now)
    }
}
