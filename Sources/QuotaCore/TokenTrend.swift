import Foundation

public enum TokenTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case total, output
    public var id: Self { self }
    public var title: String { self == .total ? "总计" : "仅输出" }
    public func value(_ counts: TokenCounts) -> Int64 { self == .total ? counts.total : counts.output }
}

public enum TokenTrendGranularity: Sendable {
    case hour, day, month
    public var title: String {
        switch self { case .hour: return "每小时"; case .day: return "每日"; case .month: return "每月" }
    }
    public var averageTitle: String {
        switch self { case .hour: return "小时均量"; case .day: return "日均用量"; case .month: return "月均用量" }
    }
    var component: Calendar.Component {
        switch self { case .hour: return .hour; case .day: return .day; case .month: return .month }
    }
}

public struct TokenTimeBucket: Identifiable, Equatable, Sendable {
    public var start: Date
    public var claude: TokenCounts = .zero
    public var codex: TokenCounts = .zero
    public var id: Date { start }
    public var combined: TokenCounts { claude + codex }
    public func counts(for provider: Provider) -> TokenCounts { provider == .claude ? claude : codex }
}

public struct TokenTrend: Sendable {
    public var granularity: TokenTrendGranularity
    public var buckets: [TokenTimeBucket]
    public func totals(for provider: Provider) -> TokenCounts { buckets.reduce(.zero) { $0 + $1.counts(for: provider) } }
    public func average(metric: TokenTrendMetric) -> Int64 {
        guard !buckets.isEmpty else { return 0 }
        let total = buckets.reduce(TokenCounts.zero) { $0 + $1.combined }
        return metric.value(total) / Int64(buckets.count)
    }
    public func peak(metric: TokenTrendMetric) -> TokenTimeBucket? {
        let peak = buckets.max { metric.value($0.combined) < metric.value($1.combined) }
        return peak.flatMap { metric.value($0.combined) > 0 ? $0 : nil }
    }
    public func nearest(to date: Date) -> TokenTimeBucket? {
        buckets.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }
}

public extension TokenReport {
    func trend(period: TokenPeriod, now: Date, calendar: Calendar = .current) -> TokenTrend {
        let start = period.start(now: now, calendar: calendar)
        let rows = records.filter { record in
            record.timestamp.timeIntervalSince(now) <= 0 && (start.map { record.timestamp.timeIntervalSince($0) >= 0 } ?? true)
        }
        let firstDate = start ?? rows.map(\.timestamp).min() ?? calendar.startOfDay(for: now)
        let granularity: TokenTrendGranularity
        if period == .today { granularity = .hour }
        else if period == .all && (calendar.dateComponents([.day], from: firstDate, to: now).day ?? 0) > 366 { granularity = .month }
        else { granularity = .day }
        var grouped: [Date: TokenTimeBucket] = [:]
        for record in rows {
            guard let date = calendar.dateInterval(of: granularity.component, for: record.timestamp)?.start else { continue }
            var bucket = grouped[date] ?? TokenTimeBucket(start: date)
            if record.provider == .claude { bucket.claude = bucket.claude + record.counts }
            else { bucket.codex = bucket.codex + record.counts }
            grouped[date] = bucket
        }
        var buckets: [TokenTimeBucket] = []
        var cursor = calendar.dateInterval(of: granularity.component, for: firstDate)?.start ?? firstDate
        while cursor.timeIntervalSince(now) <= 0 {
            buckets.append(grouped[cursor] ?? TokenTimeBucket(start: cursor))
            guard let next = calendar.dateInterval(of: granularity.component, for: cursor)?.end,
                  next.timeIntervalSince(cursor) > 0 else { break }
            cursor = next
        }
        return TokenTrend(granularity: granularity, buckets: buckets)
    }
}
