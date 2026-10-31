import Foundation

/// A current subscription limit, independent of the selected token-log period.
public struct QuotaProgress: Codable, Equatable, Sendable {
    public var windowID: String
    public var title: String
    public var usedPercent: Double
    public var fetchedAt: Date
    public var resetsAt: Date?

    public init?(snapshot: UsageSnapshot?, now: Date, maxAge: TimeInterval = 15 * 60) {
        guard let snapshot, snapshot.fetchedAt.timeIntervalSince(now) <= 60,
              !snapshot.isStale(at: now, maxAge: maxAge),
              snapshot.windows.allSatisfy({ $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) }),
              let window = snapshot.windows.max(by: { $0.usedPercent < $1.usedPercent }),
              window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return nil }
        self.init(window: window, fetchedAt: snapshot.fetchedAt)
    }
    private init(window: QuotaWindow, fetchedAt: Date) {
        windowID = window.id; title = window.title; usedPercent = window.usedPercent
        self.fetchedAt = fetchedAt; resetsAt = window.resetsAt
    }
    /// Keep the two base subscription windows, regardless of which is tighter.
    /// An expired short window must not hide a still-current weekly window.
    public static func primaryWindows(snapshot: UsageSnapshot?, now: Date, maxAge: TimeInterval = 15 * 60) -> [Self] {
        guard let snapshot, snapshot.fetchedAt.timeIntervalSince(now) <= 60,
              now.timeIntervalSince(snapshot.fetchedAt) <= maxAge else { return [] }
        let ids = snapshot.provider == .claude ? ["five_hour", "seven_day"] : ["codex.primary", "codex.secondary"]
        let base = ids.compactMap { id in snapshot.windows.first { $0.id == id } }
        let selected = snapshot.provider == .claude || !base.isEmpty ? base : Array(snapshot.windows.prefix(2))
        return selected.compactMap { window in
            let progress = Self(window: window, fetchedAt: snapshot.fetchedAt)
            return progress.isCurrent(at: now) ? progress : nil
        }
    }
    public var shortTitle: String { title.hasPrefix("每周") ? "每周" : title.replacingOccurrences(of: " ", with: "") }
    public var validUntil: Date {
        let expiry = fetchedAt.addingTimeInterval(15 * 60)
        guard let resetsAt else { return expiry }
        return resetsAt.timeIntervalSince(expiry) < 0 ? resetsAt : expiry
    }
    public func isCurrent(at now: Date) -> Bool {
        usedPercent.isFinite && (0...100).contains(usedPercent) && fetchedAt.timeIntervalSince(now) <= 60 && now.timeIntervalSince(validUntil) < 0
    }
    public var remainingPercent: Int {
        guard usedPercent.isFinite else { return 0 }
        return Int((100 - min(100, max(0, usedPercent))).rounded(.down))
    }
    public var displayedUsedPercent: Int { 100 - remainingPercent }
    public var usedFraction: Double { usedPercent.isFinite ? min(1, max(0, usedPercent / 100)) : 0 }
    public func resetDescription(at now: Date) -> String {
        guard let resetsAt else { return "未提供重置时间" }
        guard resetsAt.timeIntervalSince(now) > 0 else { return "等待刷新" }
        let minutes = max(1, Int(ceil(resetsAt.timeIntervalSince(now) / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)天\((minutes % 1440) / 60)小时后重置" }
        if minutes >= 60 { return "\(minutes / 60)小时\(minutes % 60)分后重置" }
        return "\(minutes)分钟后重置"
    }
}
