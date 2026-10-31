import SwiftUI
import WidgetKit
import QuotaCore

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let period: WidgetPeriod
    var issue: WidgetLoadIssue?
}

struct UsageWidgetProvider: TimelineProvider {
    let period: WidgetPeriod
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: Date(), snapshot: nil, period: period)
    }
    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        Task {
            let result = await WidgetLocalClient.load()
            completion(UsageWidgetEntry(date: Date(), snapshot: result.snapshot, period: period, issue: result.issue))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        Task {
            let result = await WidgetLocalClient.load()
            let now = Date()
            func entry(_ date: Date) -> UsageWidgetEntry {
                UsageWidgetEntry(date: date, snapshot: result.snapshot, period: period, issue: result.issue)
            }
            let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime)!
            var entries = [entry(now)]
            if let expiry = result.snapshot?.generatedAt.addingTimeInterval(20 * 60 + 1), expiry > now, expiry < midnight {
                entries.append(entry(expiry))
            }
            entries.append(entry(midnight))
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry
    var body: some View {
        Group {
            if family == .systemLarge || family == .systemExtraLarge {
                WidgetLargeContentView(snapshot: entry.snapshot, period: entry.period, date: entry.date,
                                       wide: family == .systemExtraLarge, issue: entry.issue)
            } else {
                WidgetContentView(snapshot: entry.snapshot, period: entry.period, date: entry.date,
                                  isSmall: family == .systemSmall, issue: entry.issue, showsInputOutput: true)
            }
        }
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "quotabar://open?period=\(entry.period.rawValue)"))
    }
}

@MainActor
private func configuration(kind: String, period: WidgetPeriod) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: UsageWidgetProvider(period: period)) { entry in UsageWidgetView(entry: entry) }
        .description("本机 Token、输入／输出与美元参考费用。中号、大号及超大号显示近 7 天趋势。保持 QuotaBar 运行以同步。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
}

struct SevenDaysWidget: Widget {
    var body: some WidgetConfiguration { configuration(kind: WidgetKinds.sevenDays, period: .sevenDays).configurationDisplayName("近 7 天 · Claude & Codex") }
}
struct TodayWidget: Widget {
    var body: some WidgetConfiguration { configuration(kind: WidgetKinds.today, period: .today).configurationDisplayName("今日 · Claude & Codex") }
}
struct ThirtyDaysWidget: Widget {
    var body: some WidgetConfiguration { configuration(kind: WidgetKinds.thirtyDays, period: .thirtyDays).configurationDisplayName("近 30 天 · Claude & Codex") }
}

@main
struct QuotaBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        SevenDaysWidget()
        TodayWidget()
        ThirtyDaysWidget()
    }
}
