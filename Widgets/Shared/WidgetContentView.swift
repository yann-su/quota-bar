import SwiftUI
import Charts
import QuotaCore

/// Shared by the extension and the app's local preview. The extension receives
/// only aggregate snapshots; it never scans logs or accesses login credentials.
struct WidgetContentView: View {
    let snapshot: WidgetSnapshot?
    let period: WidgetPeriod
    let date: Date
    let isSmall: Bool
    var isPreview = false
    var issue: WidgetLoadIssue?
    var showsInputOutput = false

    private var currentDay: Bool { snapshot?.matchesCurrentDay(at: date) == true }
    private var outdated: Bool { snapshot?.isStale(at: date) != false || !currentDay }
    private func tint(_ provider: Provider) -> Color {
        provider == .claude ? Color(red: 0.83, green: 0.47, blue: 0.34) : Color(red: 0.25, green: 0.64, blue: 0.53)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 6 : 8) {
            HStack(spacing: 4) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
                Text("QuotaBar").fontWeight(.semibold)
                Spacer(minLength: 2)
                Text(period.title).foregroundStyle(.secondary)
            }.font(.system(size: 11))

            if snapshot == nil {
                Spacer(minLength: 0)
                Label(issue?.title ?? "先打开 QuotaBar", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 14, weight: .semibold))
                Text(issue?.detail ?? "读取本机 Token 用量后，小组件会显示统计。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if isSmall {
                ForEach(Provider.allCases) { provider in providerValue(provider) }
                Spacer(minLength: 0)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Provider.allCases) { provider in providerValue(provider) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    trend.frame(maxWidth: .infinity)
                }.frame(maxHeight: .infinity)
            }
            HStack(spacing: 3) {
                Circle().fill(outdated ? Color.orange : Color.secondary.opacity(0.6)).frame(width: 4, height: 4)
                Text(isPreview ? "示例 · API 折合" : showsInputOutput ? "输入含缓存 · API 折合" : "本机 · API 折合")
                Spacer(minLength: 2)
                if let snapshot {
                    if !currentDay { Text("待更新") }
                    else if outdated { Text("上次 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))") }
                    else { Text(snapshot.generatedAt, style: .time) }
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func providerValue(_ provider: Provider) -> some View {
        let value = snapshot?.providers.first { $0.provider == provider }
        let count = currentDay ? value?.total(for: period) : nil
        let display = count.map(TokenDisplayValue.format)
        let cost = currentDay ? value?.cost(for: period) : nil
        let split = currentDay ? value?.split(for: period) : nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(tint(provider)).frame(width: 5, height: 5)
                Text(provider == .claude ? "Claude" : "Codex")
                if value?.partial == true { Image(systemName: "exclamationmark.circle") }
                Spacer(minLength: 2)
                if let cost {
                    Text("\(cost.hasKnownCost && !cost.isComplete ? "部分 " : "")\(cost.referenceText)")
                        .font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.6)
                }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            if showsInputOutput {
                HStack(alignment: .top, spacing: 7) {
                    ioValue(.input, split: split, cost: cost)
                    ioValue(.output, split: split, cost: cost)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(display?.number ?? "—").font(.system(size: isSmall ? 21 : 23, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    if let display, !display.unit.isEmpty {
                        Text(display.unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
            }
        }.accessibilityElement(children: .combine)
    }

    private func ioValue(_ direction: TokenDirection, split: WidgetTokenSplit?, cost: TokenCostEstimate?) -> some View {
        let count = split?.tokens(for: direction)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(direction == .input ? "入" : "出").font(.system(size: 8)).foregroundStyle(.secondary)
                Text(count.map { TokenDisplayValue.format($0).text } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
            }
            if let cost {
                Text("\(cost.hasKnownCost(for: direction) && !cost.isComplete(for: direction) ? "部分 " : "")\(cost.referenceText(for: direction))")
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(direction.title)\(count.map { "\($0)个 Token" } ?? "待更新")，参考折合\(cost?.referenceText(for: direction) ?? "未知")")
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每日总量 · 近 7 天").font(.system(size: 9)).foregroundStyle(.secondary)
            Chart {
                ForEach(snapshot?.providers ?? [], id: \.provider) { item in
                    ForEach(item.daily) { sample in
                        LineMark(x: .value("日期", sample.date), y: .value("Token", sample.tokens),
                                 series: .value("服务", item.provider.rawValue))
                            .foregroundStyle(tint(item.provider)).lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 61)
            HStack {
                if let first = snapshot?.providers.first?.daily.first {
                    Text(first.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                }
                Spacer()
                if let last = snapshot?.providers.first?.daily.last {
                    Text(last.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                }
            }.font(.system(size: 8)).foregroundStyle(.tertiary)
        }.accessibilityLabel("近七天 Claude 与 Codex 每日 Token 趋势；没有本机记录的日期显示为零。")
    }
}
