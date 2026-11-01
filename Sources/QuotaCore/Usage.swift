import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "Codex" }
    public var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
}

public struct QuotaWindow: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?

    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?, durationMinutes: Int? = nil) {
        self.id = id
        self.title = title
        self.usedPercent = min(100, max(0, usedPercent.isFinite ? usedPercent : 0))
        self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
    public var remainingPercent: Double { 100 - usedPercent }
    public func hasReset(at now: Date) -> Bool { resetsAt.map { $0.timeIntervalSince(now) <= 0 } ?? false }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var fetchedAt: Date
    public var plan: String?
    public var windows: [QuotaWindow]
    public var source: String

    public init(provider: Provider, fetchedAt: Date = Date(), plan: String? = nil, windows: [QuotaWindow], source: String) {
        self.provider = provider; self.fetchedAt = fetchedAt; self.plan = plan
        self.windows = windows; self.source = source
    }
    public func isStale(at now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge || windows.contains { $0.hasReset(at: now) }
    }
    public func availablePercent(at now: Date, maxAge: TimeInterval) -> Int? {
        guard !isStale(at: now, maxAge: maxAge), let value = windows.map(\.remainingPercent).min() else { return nil }
        return Int(value.rounded(.down))
    }
}

public enum UsageError: Error, LocalizedError, Equatable {
    case missingCLI, notSignedIn, keychainDenied, expiredCredential, missingCredential
    case invalidResponse, timeout, serviceUnavailable, unsupportedAccount
    case rateLimited(Date)
    public var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex CLI。安装并登录后再刷新，或在设置中指定路径。"
        case .notSignedIn: return "请先在终端运行 codex login，再刷新额度。"
        case .keychainDenied: return "Claude 需要授权，已暂停后台读取。请手动点击「连接 Claude」；取消后不会自动再弹窗。"
        case .expiredCredential: return "Claude 登录需要更新。点击「修复 Claude 登录」让官方客户端续期，再回到这里刷新。"
        case .missingCredential: return "未找到 Claude Code 订阅登录。请先运行 claude 并登录。"
        case .invalidResponse: return "暂时无法解析额度响应，请刷新或更新 QuotaBar。"
        case .timeout: return "读取超时，请稍后刷新。"
        case .serviceUnavailable: return "服务暂时不可用，请检查网络后重试。"
        case .unsupportedAccount: return "当前账号未返回订阅额度；API key 账号不支持此视图。"
        case .rateLimited: return "查询过于频繁，稍后自动重试。"
        }
    }
}

public enum UsageDecoder {
    public static func codex(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        struct Response: Decodable {
            struct Bucket: Decodable {
                struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
                let limitName: String?; let primary: Window?; let secondary: Window?; let planType: String?
            }
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw UsageError.invalidResponse }
        var windows: [QuotaWindow] = []
        let buckets: [(String, Response.Bucket)]
        if let multiple = response.rateLimitsByLimitId, !multiple.isEmpty {
            buckets = multiple.sorted { a, b in
                if a.key == "codex" { return b.key != "codex" }
                if b.key == "codex" { return false }
                return a.key < b.key
            }
        } else if let single = response.rateLimits { buckets = [("codex", single)] }
        else { throw UsageError.unsupportedAccount }
        for (key, bucket) in buckets {
            for (name, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window, window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else {
                    if (name == "primary" ? bucket.primary : bucket.secondary) != nil { throw UsageError.invalidResponse }
                    continue
                }
                let title: String
                switch window.windowDurationMins {
                case 300: title = "5 小时"
                case 10080: title = "每周"
                case .some(let minutes) where minutes >= 1440: title = "\(minutes / 1440) 天"
                case .some(let minutes) where minutes >= 60 && minutes % 60 == 0: title = "\(minutes / 60) 小时"
                case .some(let minutes): title = "\(minutes) 分钟"
                case .none: title = name == "primary" ? "当前窗口" : "长期窗口"
                }
                windows.append(QuotaWindow(id: "\(key).\(name)", title: key == "codex" ? title : "\(bucket.limitName ?? key) · \(title)", usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }, durationMinutes: window.windowDurationMins))
            }
        }
        guard !windows.isEmpty else { throw UsageError.unsupportedAccount }
        return UsageSnapshot(provider: .codex, fetchedAt: now, plan: buckets.first?.1.planType, windows: windows, source: "Codex app-server")
    }

    public static func claude(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        struct Window: Decodable { let utilization: Double; let resets_at: String? }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.invalidResponse }
        var windows: [QuotaWindow] = []
        let preferred = ["five_hour", "seven_day"]
        // Breakdown is aggregate metadata, not an additional quota window.
        let keys = preferred + object.keys.filter { $0.hasPrefix("seven_day_") && $0 != "seven_day_breakdown" }.sorted()
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            guard JSONSerialization.isValidJSONObject(value), let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let window = try? JSONDecoder().decode(Window.self, from: encoded),
                  window.utilization.isFinite, (0...100).contains(window.utilization) else { throw UsageError.invalidResponse }
            let title = key == "five_hour" ? "5 小时" : key == "seven_day" ? "每周 · 全部模型" : "每周 · " + key.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
            let reset: Date?
            if let text = window.resets_at {
                guard let date = parseDate(text) else { throw UsageError.invalidResponse }
                reset = date
            } else { reset = nil }
            windows.append(QuotaWindow(id: key, title: title, usedPercent: window.utilization, resetsAt: reset, durationMinutes: key == "five_hour" ? 300 : 10080))
        }
        guard !windows.isEmpty else { throw UsageError.unsupportedAccount }
        return UsageSnapshot(provider: .claude, fetchedAt: now, windows: windows, source: "Claude Code 登录")
    }
    public static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    public static func retryDate(_ header: String?, now: Date = Date()) -> Date {
        guard let header else { return now.addingTimeInterval(300) }
        if let seconds = Double(header), seconds.isFinite { return now.addingTimeInterval(max(1, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let parsed = formatter.date(from: header) ?? now.addingTimeInterval(300)
        return now.addingTimeInterval(max(1, parsed.timeIntervalSince(now)))
    }
}

public struct SnapshotArchive: Codable, Sendable {
    public var snapshots: [UsageSnapshot] = []
    public init() {}
    public mutating func append(_ snapshot: UsageSnapshot, now: Date = Date()) {
        snapshots.removeAll { now.timeIntervalSince($0.fetchedAt) > 30 * 86400 }
        // Keep at most one sample per provider per minute, with a fixed disk bound.
        if let last = snapshots.lastIndex(where: { $0.provider == snapshot.provider }),
           abs(snapshot.fetchedAt.timeIntervalSince(snapshots[last].fetchedAt)) < 60 { snapshots.remove(at: last) }
        snapshots.append(snapshot)
        if snapshots.count > 20_000 { snapshots.removeFirst(snapshots.count - 20_000) }
    }
    public func latest(_ provider: Provider) -> UsageSnapshot? {
        snapshots.filter { $0.provider == provider }.max { $0.fetchedAt < $1.fetchedAt }
    }
}
