import Foundation

public enum WidgetPeriod: String, Codable, CaseIterable, Sendable {
    case today, sevenDays, thirtyDays
    public var title: String {
        switch self { case .today: return "今日"; case .sevenDays: return "近 7 天"; case .thirtyDays: return "近 30 天" }
    }
    public var tokenPeriod: TokenPeriod {
        switch self { case .today: return .today; case .sevenDays: return .sevenDays; case .thirtyDays: return .thirtyDays }
    }
}

public struct WidgetDaySample: Codable, Equatable, Sendable, Identifiable {
    public var date: Date
    public var tokens: Int64
    public var id: Date { date }
}

public struct WidgetTokenSplit: Codable, Equatable, Sendable {
    public var input: Int64
    public var output: Int64
    public init(_ counts: TokenCounts) { input = counts.totalInput; output = counts.output }
    public func tokens(for direction: TokenDirection) -> Int64 { direction == .input ? input : output }
}

public struct WidgetProviderSnapshot: Codable, Equatable, Sendable {
    public var provider: Provider
    public var today: Int64?
    public var sevenDays: Int64?
    public var thirtyDays: Int64?
    public var daily: [WidgetDaySample]
    public var quota: QuotaProgress?
    public var quotaWindows: [QuotaProgress]
    public var partial: Bool
    public var todayCost: TokenCostEstimate?
    public var sevenDaysCost: TokenCostEstimate?
    public var thirtyDaysCost: TokenCostEstimate?
    public var todaySplit: WidgetTokenSplit?
    public var sevenDaysSplit: WidgetTokenSplit?
    public var thirtyDaysSplit: WidgetTokenSplit?
    public func total(for period: WidgetPeriod) -> Int64? {
        switch period { case .today: return today; case .sevenDays: return sevenDays; case .thirtyDays: return thirtyDays }
    }
    public func quotaRemaining(at now: Date) -> Int? {
        guard let quota, quota.isCurrent(at: now) else { return nil }
        return quota.remainingPercent
    }
    public func cost(for period: WidgetPeriod) -> TokenCostEstimate? {
        switch period { case .today: return todayCost; case .sevenDays: return sevenDaysCost; case .thirtyDays: return thirtyDaysCost }
    }
    public func split(for period: WidgetPeriod) -> WidgetTokenSplit? {
        switch period { case .today: return todaySplit; case .sevenDays: return sevenDaysSplit; case .thirtyDays: return thirtyDaysSplit }
    }
}

/// Aggregate usage and quota-window metadata only: no credentials, request IDs,
/// log model details, file paths or conversation content are included.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    public var version = currentVersion
    public var generatedAt: Date
    public var dayStart: Date
    public var timeZoneIdentifier: String
    public var providers: [WidgetProviderSnapshot]
    public var priceDate = TokenPriceCatalog.verifiedDate

    public init(report: TokenReport, quotas: [UsageSnapshot] = [], now: Date = Date(), calendar: Calendar = .current) {
        generatedAt = now
        dayStart = calendar.startOfDay(for: now)
        timeZoneIdentifier = calendar.timeZone.identifier
        let trend = report.trend(period: .sevenDays, now: now, calendar: calendar)
        providers = Provider.allCases.map { provider in
            let coverage = report.coverage[provider] ?? TokenCoverage()
            let available = coverage.directoryFound && !(coverage.files == 0 && coverage.unreadableFiles > 0)
            func total(_ period: TokenPeriod) -> Int64? {
                available ? report.totals(provider: provider, period: period, now: now, calendar: calendar).total : nil
            }
            func cost(_ period: TokenPeriod) -> TokenCostEstimate? {
                available ? report.cost(provider: provider, period: period, now: now, calendar: calendar) : nil
            }
            func split(_ period: TokenPeriod) -> WidgetTokenSplit? {
                available ? WidgetTokenSplit(report.totals(provider: provider, period: period, now: now, calendar: calendar)) : nil
            }
            let quota = quotas.first { $0.provider == provider }
            return WidgetProviderSnapshot(provider: provider, today: total(.today), sevenDays: total(.sevenDays),
                thirtyDays: total(.thirtyDays), daily: available ? trend.buckets.map { WidgetDaySample(date: $0.start, tokens: $0.counts(for: provider).total) } : [],
                quota: QuotaProgress(snapshot: quota, now: now),
                quotaWindows: QuotaProgress.primaryWindows(snapshot: quota, now: now), partial: coverage.isPartial,
                todayCost: cost(.today), sevenDaysCost: cost(.sevenDays), thirtyDaysCost: cost(.thirtyDays),
                todaySplit: split(.today), sevenDaysSplit: split(.sevenDays), thirtyDaysSplit: split(.thirtyDays))
        }
    }
    public func matchesCurrentDay(at now: Date, calendar: Calendar = .current) -> Bool {
        timeZoneIdentifier == calendar.timeZone.identifier && abs(calendar.startOfDay(for: now).timeIntervalSince(dayStart)) < 1
    }
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(generatedAt) > 20 * 60 }
}

public enum WidgetSnapshotFile {
    public enum ReadError: Error { case unsupportedVersion }
    public static let name = "widget-summary.json"
    public static func write(_ snapshot: WidgetSnapshot, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(directory: URL) -> WidgetSnapshot? {
        try? load(directory: directory)
    }
    public static func load(directory: URL) throws -> WidgetSnapshot {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.version == WidgetSnapshot.currentVersion else { throw ReadError.unsupportedVersion }
        return snapshot
    }
}
