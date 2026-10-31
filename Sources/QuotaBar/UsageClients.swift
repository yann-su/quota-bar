import Foundation
import Security
import LocalAuthentication
import QuotaCore

enum ExecutableLocator {
    static func codex(customPath: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = customPath.isEmpty ? [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"
        ] : [NSString(string: customPath).expandingTildeInPath]
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        return (candidates + (customPath.isEmpty ? pathCandidates : [])).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }.map { URL(fileURLWithPath: $0) }
    }
}

/// A short-lived, read-only app-server connection. Never starts a model turn.
final class CodexRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 25) { self.timeout = timeout }

    func fetch(executable: URL) throws -> UsageSnapshot {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never log auth or config details.
        do { try process.run() } catch { throw UsageError.missingCLI }

        let deadline = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        try send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "quota_bar", "title": "QuotaBar", "version": "0.4.0"]]])
        _ = try readResponse(id: 1)
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 2])
        return try UsageDecoder.codex(readResponse(id: 2))
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw UsageError.serviceUnavailable }
    }

    private func readResponse(id: Int) throws -> Data {
        while true {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      object["id"] as? Int == id else { continue }
                if let error = object["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    if message.contains("auth") || message.contains("login") || message.contains("sign in") { throw UsageError.notSignedIn }
                    if message.contains("api key") || message.contains("chatgpt") { throw UsageError.unsupportedAccount }
                    throw UsageError.serviceUnavailable
                }
                guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else { throw UsageError.invalidResponse }
                return try JSONSerialization.data(withJSONObject: result)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw UsageError.timeout }
            buffer.append(chunk)
            guard buffer.count < 2_000_000 else { throw UsageError.invalidResponse }
        }
    }
}

struct ClaudeCredential {
    let accessToken: String
    let expiresAt: Date?

    static func read(allowPrompt: Bool) throws -> Self {
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        // Claude Code's documented fallback. Do not write or renew its credentials.
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let keychainData = status == errSecSuccess ? item as? Data : nil
        let fileData = try? Data(contentsOf: directory.appendingPathComponent(".credentials.json"))
        if let credential = select(keychainData: keychainData, fileData: fileData) { return credential }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw UsageError.keychainDenied
        }
        throw UsageError.missingCredential
    }

    static func select(keychainData: Data?, fileData: Data?, now: Date = Date()) -> Self? {
        let candidates = [keychainData, fileData].compactMap { data -> Self? in
            guard let data else { return nil }; return try? decode(data)
        }
        // A stale Keychain entry must not mask Claude Code's newer fallback file.
        return candidates.first { $0.expiresAt.map { $0.timeIntervalSince(now) > 0 } ?? false }
            ?? candidates.first { $0.expiresAt == nil }
            ?? candidates.first
    }

    static func decode(_ data: Data) throws -> Self {
        struct Container: Decodable {
            struct OAuth: Decodable { let accessToken: String; let expiresAt: Double? }
            let claudeAiOauth: OAuth?
        }
        guard let oauth = (try? JSONDecoder().decode(Container.self, from: data))?.claudeAiOauth,
              !oauth.accessToken.isEmpty else { throw UsageError.missingCredential }
        let expiry = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 > 100_000_000_000 ? $0 / 1000 : $0) }
        // The server is authoritative: local expiry metadata can lag behind a
        // renewed session. A 401 below reports an actually rejected credential.
        return ClaudeCredential(accessToken: oauth.accessToken, expiresAt: expiry)
    }
}

/// The token is only sent to this fixed Anthropic origin, with redirects rejected.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ClaudeClient {
    static func fetch(allowPrompt: Bool, diagnostics: ((String) -> Void)? = nil) async throws -> UsageSnapshot {
        let credential = try await Task.detached { try ClaudeCredential.read(allowPrompt: allowPrompt) }.value
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("QuotaBar/0.4.0", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw UsageError.timeout }
        catch { throw UsageError.serviceUnavailable }
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        if let diagnostics {
            diagnostics("Claude HTTP \(http.statusCode); content-type=\(http.mimeType ?? "unknown"); bytes=\(data.count)")
            diagnostics(responseShape(data))
        }
        switch http.statusCode {
        case 200: return try UsageDecoder.claude(data)
        case 401: throw UsageError.expiredCredential
        case 403: throw UsageError.unsupportedAccount
        case 429: throw UsageError.rateLimited(UsageDecoder.retryDate(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw UsageError.serviceUnavailable
        }
    }

    /// Only field names and validation results; never print credentials, body
    /// text, account identifiers, credit amounts, or raw timestamps.
    static func responseShape(_ data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Response is not a JSON object." }
        func kind(_ value: Any?) -> String {
            guard let value else { return "missing" }
            if value is NSNull { return "null" }
            if value is String { return "string" }
            if value is NSNumber { return "number" }
            if value is [String: Any] { return "object" }
            if value is [Any] { return "array" }
            return "other"
        }
        let keys = root.keys.filter { $0 == "five_hour" || $0.hasPrefix("seven_day") }.sorted()
        return keys.map { key in
            if key == "seven_day_breakdown" { return "seven_day_breakdown: aggregate metadata; not a quota window" }
            guard let window = root[key] as? [String: Any] else { return "\(key): \(kind(root[key]))" }
            let value = window["utilization"] as? NSNumber
            let valid = value.map { $0.doubleValue.isFinite && (0...100).contains($0.doubleValue) } ?? false
            let date = window["resets_at"] as? String
            return "\(key): utilization=\(kind(window["utilization"])) valid=\(valid); resets_at=\(kind(window["resets_at"])) parseable=\(date.flatMap(UsageDecoder.parseDate) != nil)"
        }.joined(separator: "\n")
    }
}
