import AppIntents
import SwiftUI
import WidgetKit
import QuotaCore

enum WidgetPeriodChoice: String, AppEnum {
    case today, sevenDays, thirtyDays
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "统计范围"
    static var caseDisplayRepresentations: [WidgetPeriodChoice: DisplayRepresentation] = [
        .today: "今日", .sevenDays: "近 7 天", .thirtyDays: "近 30 天"
    ]
    var period: WidgetPeriod { WidgetPeriod(rawValue: rawValue) ?? .sevenDays }
}

struct UsageWidgetConfiguration: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Token 用量"
    static var description = IntentDescription("选择要显示的本机 Token 统计范围。中号小组件附带近 7 天趋势。")
    @Parameter(title: "统计范围", default: .sevenDays) var period: WidgetPeriodChoice
    @Parameter(title: "显示输入／输出", default: false) var showsInputOutput: Bool
}

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let period: WidgetPeriod
    var issue: WidgetLoadIssue?
    var showsInputOutput = false
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        // No fabricated usage values: the gallery shows the empty state until
        // the host has written a real summary.
        UsageWidgetEntry(date: Date(), snapshot: nil, period: .sevenDays)
    }
    func snapshot(for configuration: UsageWidgetConfiguration, in context: Context) async -> UsageWidgetEntry {
        let result = WidgetSharedContainer.load()
        return UsageWidgetEntry(date: Date(), snapshot: result.snapshot, period: configuration.period.period, issue: result.issue, showsInputOutput: configuration.showsInputOutput)
    }
    func timeline(for configuration: UsageWidgetConfiguration, in context: Context) async -> Timeline<UsageWidgetEntry> {
        let now = Date()
        let result = WidgetSharedContainer.load()
        let snapshot = result.snapshot
        let entry = UsageWidgetEntry(date: now, snapshot: snapshot, period: configuration.period.period, issue: result.issue, showsInputOutput: configuration.showsInputOutput)
        // Midnight entries invalidate relative period totals even when the host
        // is closed and macOS delays the next provider execution.
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0), matchingPolicy: .nextTime)!
        var entries = [entry]
        if let expiry = snapshot?.generatedAt.addingTimeInterval(20 * 60 + 1), expiry > now, expiry < midnight {
            entries.append(UsageWidgetEntry(date: expiry, snapshot: snapshot, period: configuration.period.period, issue: result.issue, showsInputOutput: configuration.showsInputOutput))
        }
        entries.append(UsageWidgetEntry(date: midnight, snapshot: snapshot, period: configuration.period.period, issue: result.issue, showsInputOutput: configuration.showsInputOutput))
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60)))
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry
    var body: some View {
        WidgetContentView(snapshot: entry.snapshot, period: entry.period, date: entry.date, isSmall: family == .systemSmall, issue: entry.issue, showsInputOutput: entry.showsInputOutput)
            .containerBackground(.background, for: .widget)
            .widgetURL(URL(string: "quotabar://open?period=\(entry.period.rawValue)"))
    }
}

@main
struct QuotaBarWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSharedContainer.kind, intent: UsageWidgetConfiguration.self, provider: UsageWidgetProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude & Codex 用量")
        .description("本机 Token 用量，可切换输入／输出数量与参考费用。中号附带近 7 天总量趋势。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
