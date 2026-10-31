import Foundation

public struct TokenCounts: Equatable, Sendable {
    /// Normalized categories are disjoint. Cached input is not added twice.
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public init(input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
    public static let zero = TokenCounts()
    private static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int64.max : value
    }
    public var total: Int64 { Self.add(Self.add(input, output), Self.add(cacheRead, cacheWrite)) }
    public var totalInput: Int64 { Self.add(Self.add(input, cacheRead), cacheWrite) }
    public static func + (a: Self, b: Self) -> Self {
        Self(input: add(a.input, b.input), output: add(a.output, b.output),
             cacheRead: add(a.cacheRead, b.cacheRead), cacheWrite: add(a.cacheWrite, b.cacheWrite))
    }
    public func mergedMaximum(_ other: Self) -> Self {
        Self(input: max(input, other.input), output: max(output, other.output),
             cacheRead: max(cacheRead, other.cacheRead), cacheWrite: max(cacheWrite, other.cacheWrite))
    }
    public func positiveDifference(from other: Self) -> Self {
        Self(input: max(0, input - other.input), output: max(0, output - other.output),
             cacheRead: max(0, cacheRead - other.cacheRead), cacheWrite: max(0, cacheWrite - other.cacheWrite))
    }
    var signature: String { "\(input):\(output):\(cacheRead):\(cacheWrite)" }
}

public struct TokenRecord: Equatable, Sendable {
    public var id: String
    public var provider: Provider
    public var timestamp: Date
    public var model: String
    public var counts: TokenCounts
    /// Known long-lived cache writes (Claude 1h). Nil means the lifetime was
    /// not present in the local metadata. This is a subset, never extra tokens.
    public var longCacheWriteTokens: Int64?
    public init(id: String, provider: Provider, timestamp: Date, model: String, counts: TokenCounts, longCacheWriteTokens: Int64? = nil) {
        self.id = id; self.provider = provider; self.timestamp = timestamp; self.model = model; self.counts = counts
        self.longCacheWriteTokens = longCacheWriteTokens
    }
    public mutating func merge(_ other: Self) {
        // Claude writes multiple content blocks for one API response. Preserve
        // the final counters once, even when blocks occur in copied transcripts.
        let oldWrite = counts.cacheWrite
        counts = counts.mergedMaximum(other.counts)
        if other.counts.cacheWrite > oldWrite {
            longCacheWriteTokens = other.longCacheWriteTokens
        } else if other.counts.cacheWrite == oldWrite, let value = other.longCacheWriteTokens {
            longCacheWriteTokens = min(counts.cacheWrite, max(longCacheWriteTokens ?? 0, value))
        }
        if other.timestamp.timeIntervalSince(timestamp) < 0 { timestamp = other.timestamp }
    }
}

public enum TokenPeriod: String, CaseIterable, Identifiable, Sendable {
    case today, sevenDays, thirtyDays, all
    public var id: Self { self }
    public var title: String {
        switch self { case .today: return "今日"; case .sevenDays: return "近 7 天"; case .thirtyDays: return "近 30 天"; case .all: return "全部" }
    }
    public func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .sevenDays: return calendar.date(byAdding: .day, value: -6, to: today)
        case .thirtyDays: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

public struct TokenCoverage: Sendable {
    public var files = 0
    public var unreadableFiles = 0
    public var malformedUsageRows = 0
    public var directoryFound = false
    public init() {}
    public var isPartial: Bool { unreadableFiles > 0 || malformedUsageRows > 0 }
}

public struct TokenReport: Sendable {
    public var records: [TokenRecord]
    public var coverage: [Provider: TokenCoverage]
    public var scannedAt: Date
    public init(records: [TokenRecord] = [], coverage: [Provider: TokenCoverage] = [:], scannedAt: Date = Date()) {
        self.records = records; self.coverage = coverage; self.scannedAt = scannedAt
    }
    public func filtered(provider: Provider, period: TokenPeriod, now: Date, calendar: Calendar = .current) -> [TokenRecord] {
        let start = period.start(now: now, calendar: calendar)
        return records.filter { record in
            record.provider == provider && record.timestamp.timeIntervalSince(now) <= 0 &&
            (start.map { record.timestamp.timeIntervalSince($0) >= 0 } ?? true)
        }
    }
    public func totals(provider: Provider, period: TokenPeriod, now: Date, calendar: Calendar = .current) -> TokenCounts {
        filtered(provider: provider, period: period, now: now, calendar: calendar).reduce(.zero) { $0 + $1.counts }
    }
    public var csv: String {
        let formatter = ISO8601DateFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let grouped = Dictionary(grouping: records) { record in
            "\(record.provider.rawValue)|\(calendar.startOfDay(for: record.timestamp).timeIntervalSince1970)|\(record.model)"
        }
        var lines = ["provider,day_local,timezone,model,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,total_tokens"]
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        for key in grouped.keys.sorted() {
            guard let entries = grouped[key], let first = entries.first else { continue }
            let counts = entries.reduce(TokenCounts.zero) { $0 + $1.counts }
            let cells = [first.provider.rawValue, formatter.string(from: first.timestamp), calendar.timeZone.identifier, first.model,
                String(counts.input), String(counts.output), String(counts.cacheRead), String(counts.cacheWrite), String(counts.total)]
            lines.append(cells.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
