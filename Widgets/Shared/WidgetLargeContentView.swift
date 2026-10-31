import SwiftUI
import Charts
import QuotaCore

/// Dedicated dashboard layouts for the native large and extra-large families.
/// Uses the same aggregate snapshot and pricing coverage as the compact widget.
struct WidgetLargeContentView: View {
    let snapshot: WidgetSnapshot?
    let period: WidgetPeriod
    let date: Date
    var wide = false
    var issue: WidgetLoadIssue?
    var isPreview = false

    private var currentDay: Bool { snapshot?.matchesCurrentDay(at: date) == true }
    private var outdated: Bool { snapshot?.isStale(at: date) != false || !currentDay }
    private func tint(_ provider: Provider) -> Color {
        provider == .claude ? Color(red: 0.83, green: 0.47, blue: 0.34) : Color(red: 0.25, green: 0.64, blue: 0.53)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: wide ? 12 : 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").foregroundStyle(.secondary)
                Text("QuotaBar").fontWeight(.semibold)
                Spacer()
                Text("Token · \(period.title)").font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.primary.opacity(0.06), in: Capsule())
            }.font(.system(size: 14))

            if snapshot == nil {
                Spacer()
                Label(issue?.title ?? "先打开 QuotaBar", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 19, weight: .semibold))
                Text(issue?.detail ?? "读取本机 Token 用量后，小组件会显示统计。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else if wide {
                HStack(alignment: .top, spacing: 20) {
                    providerGrid.frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        trend.frame(maxHeight: .infinity)
                        Divider()
                        peakRows
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxHeight: .infinity)
            } else {
                providerGrid
                trend.frame(maxHeight: .infinity)
            }
            footer
        }
    }

    private var providerGrid: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(Provider.allCases) { provider in providerCard(provider) }
        }
    }

    private func providerCard(_ provider: Provider) -> some View {
        let item = snapshot?.providers.first { $0.provider == provider }
        let count = currentDay ? item?.total(for: period) : nil
        let cost = currentDay ? item?.cost(for: period) : nil
        let split = currentDay ? item?.split(for: period) : nil
        let display = count.map(TokenDisplayValue.format)
        return VStack(alignment: .leading, spacing: wide ? 7 : 5) {
            HStack(spacing: 5) {
                Circle().fill(tint(provider)).frame(width: 6, height: 6)
                Text(provider == .claude ? "Claude" : "Codex").fontWeight(.semibold)
                Spacer(minLength: 0)
                if item?.partial == true {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                        .accessibilityLabel("本机记录可能不完整")
                }
            }.font(.system(size: 12))

            VStack(alignment: .leading, spacing: wide ? 3 : 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(display?.number ?? "—")
                        .font(.system(size: wide ? 30 : 27, weight: .semibold, design: .rounded))
                        .monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                    if let display, !display.unit.isEmpty {
                        Text(display.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                if wide { Text("总 Token").font(.system(size: 9)).foregroundStyle(.secondary) }
                Text(cost.map { "\($0.hasKnownCost && !$0.isComplete ? "部分 " : "")\($0.referenceText)" } ?? "—")
                    .font(.system(size: wide ? 13 : 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("总计\(count.map { "\($0)个 Token" } ?? "待更新")，API参考\(cost?.referenceText ?? "未知")")

            Divider().overlay(tint(provider).opacity(0.15))
            directionRow(.input, split: split, cost: cost)
            directionRow(.output, split: split, cost: cost)
            Divider().opacity(0.4)
            QuotaWindowsView(provider: provider, progresses: item?.quotaWindows ?? [], date: date, compact: true)
            if wide { Spacer(minLength: 0) }
        }
        .padding(wide ? 12 : 10)
        .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil, alignment: .topLeading)
        .background(tint(provider).opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint(provider).opacity(0.16), lineWidth: 0.5))
        .fixedSize(horizontal: false, vertical: !wide)
    }

    private func directionRow(_ direction: TokenDirection, split: WidgetTokenSplit?, cost: TokenCostEstimate?) -> some View {
        let count = split?.tokens(for: direction)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(direction == .input ? "输入" : "输出")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(count.map { TokenDisplayValue.format($0).text } ?? "—")
                    .font(.system(size: wide ? 14 : 12, weight: .semibold, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            if let cost {
                Text("\(cost.hasKnownCost(for: direction) && !cost.isComplete(for: direction) ? "部分 " : "")\(cost.referenceText(for: direction))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(direction.title)\(count.map { "\($0)个 Token" } ?? "待更新")，参考折合\(cost?.referenceText(for: direction) ?? "未知")")
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每日总量 · 近 7 天").font(.system(size: 10, weight: .medium))
                Spacer()
                ForEach(Provider.allCases) { provider in
                    HStack(spacing: 3) {
                        Circle().fill(tint(provider)).frame(width: 4, height: 4)
                        Text(provider == .claude ? "Claude" : "Codex")
                    }.font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(snapshot?.providers ?? [], id: \.provider) { item in
                    ForEach(item.daily) { sample in
                        LineMark(x: .value("日期", sample.date), y: .value("Token", sample.tokens),
                                 series: .value("服务", item.provider.rawValue))
                            .foregroundStyle(tint(item.provider))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: trendDates) { value in
                    AxisValueLabel(format: .dateTime.month(.twoDigits).day(.twoDigits), centered: false,
                                   anchor: value.index == 0 ? .topLeading : value.index == 2 ? .topTrailing : .top,
                                   collisionResolution: .disabled)
                        .font(.system(size: 8))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.13))
                    AxisValueLabel {
                        if let count = value.as(Int64.self) {
                            Text(TokenDisplayValue.format(count).text).font(.system(size: 8))
                        }
                    }
                }
            }
            .frame(minHeight: wide ? 105 : 50)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("近七天 Claude 与 Codex 每日 Token 趋势；没有本机记录的日期显示为零。")
    }

    private var trendDates: [Date] {
        let dates = snapshot?.providers.first(where: { !$0.daily.isEmpty })?.daily.map(\.date) ?? []
        guard let first = dates.first, let last = dates.last else { return [] }
        return [first, dates[dates.count / 2], last]
    }

    private var peakRows: some View {
        HStack(spacing: 18) {
            ForEach(snapshot?.providers ?? [], id: \.provider) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.provider == .claude ? "Claude" : "Codex") · 7 日峰值")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(item.daily.map(\.tokens).max().map { TokenDisplayValue.format($0).text } ?? "—")
                        .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let peak = item.daily.max(by: { $0.tokens < $1.tokens }) {
                        Text(peak.date, format: .dateTime.month(.twoDigits).day(.twoDigits))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Circle().fill(outdated ? Color.orange : Color.secondary.opacity(0.6)).frame(width: 4, height: 4)
            Text(isPreview ? "示例 · API 参考" : "输入含缓存 · USD 参考")
            Spacer(minLength: 4)
            if let snapshot {
                if !currentDay { Text("待更新") }
                else if outdated { Text("上次 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))") }
                else { Text(snapshot.generatedAt, style: .time) }
            }
        }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
    }
}
