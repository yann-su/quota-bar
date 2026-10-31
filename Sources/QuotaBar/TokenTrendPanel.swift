import SwiftUI
import Charts
import QuotaCore

struct TokenTrendPanel: View {
    let trend: TokenTrend
    let period: TokenPeriod
    let now: Date
    let isPartial: Bool
    @State private var metric: TokenTrendMetric = CommandLine.arguments.contains("--trend-input") ? .input : .total
    @State private var selectedDate: Date?
    private var selected: TokenTimeBucket? { selectedDate.flatMap { trend.nearest(to: $0) } }
    private var displayedBucket: TokenTimeBucket? { selected ?? trend.buckets.last }

    var body: some View {
        let data = trend
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(data.granularity.title)趋势").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("折线指标", selection: $metric) {
                    ForEach(TokenTrendMetric.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(width: 152)
            }
            HStack {
                Text(displayedBucket.map { dateLabel($0.start, granularity: data.granularity) } ?? "暂无记录")
                Spacer()
                Text(selected == nil ? "当前时段累计" : "所选时段")
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            HStack {
                legend(.claude)
                Spacer()
                legend(.codex)
            }
            chart(data)
                .frame(height: 148)
                .accessibilityLabel("\(period.title)\(data.granularity.title)Token折线图")
            HStack {
                Text("悬停查看各时段 · 数量为 Token")
                Spacer()
                Text(metric == .output ? "仅输出 Token" : metric == .input ? "输入含缓存" : "含缓存")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(data.granularity.averageTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(TokenDisplayValue.format(data.average(metric: metric)).text).font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("合计峰值").font(.system(size: 10)).foregroundStyle(.secondary)
                    if let peak = data.peak(metric: metric) {
                        Text(TokenDisplayValue.format(metric.value(peak.combined)).text)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text(dateLabel(peak.start, granularity: data.granularity)).font(.system(size: 10)).foregroundStyle(.secondary)
                    } else { Text("暂无记录") }
                }
            }.monospacedDigit()
                .help("平均值包含没有本机记录的零值时段，以及尚未结束的当前时段。峰值为两家本机记录之和。")
            Divider().opacity(0.5)
            composition(data)
            Text(isPartial ? "部分日志无法读取，趋势统计可能不完整。" : "仅本机记录，不含网页／手机；无记录按零展示。")
                .font(.system(size: 10)).foregroundStyle(isPartial ? Color.orange : Color.secondary)
        }.padding(11)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.12)))
            .onChange(of: period) { _, _ in selectedDate = nil }
            .onChange(of: metric) { _, _ in selectedDate = nil }
    }

    @ViewBuilder private func chart(_ data: TokenTrend) -> some View {
        let maximum = data.buckets.flatMap { bucket in Provider.allCases.map { Double(metric.value(bucket.counts(for: $0))) } }.max() ?? 0
        Chart {
            ForEach(Provider.allCases) { provider in
                ForEach(data.buckets) { bucket in
                    LineMark(x: .value("时间", bucket.start), y: .value("Token", Double(metric.value(bucket.counts(for: provider)))),
                             series: .value("服务", provider.title))
                        .interpolationMethod(.linear)
                        .foregroundStyle(by: .value("服务", provider.title))
                        .lineStyle(TokenChartStyle.stroke(provider))
                    if data.buckets.count <= 31 || bucket.id == displayedBucket?.id {
                        PointMark(x: .value("时间", bucket.start), y: .value("Token", Double(metric.value(bucket.counts(for: provider)))))
                            .foregroundStyle(by: .value("服务", provider.title))
                            .symbol(provider == .claude ? .circle : .diamond)
                            .symbolSize(bucket.id == displayedBucket?.id ? 40 : 20)
                    }
                }
            }
            if let selected {
                RuleMark(x: .value("时间", selected.start)).foregroundStyle(TokenChartStyle.axisColor)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: ["Claude", "Codex"], range: [TokenChartStyle.color(.claude), TokenChartStyle.color(.codex)])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(1, maximum * 1.12))
        .chartXScale(domain: xDomain(data), range: .plotDimension(startPadding: 5, endPadding: 5))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(TokenChartStyle.gridColor)
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(TokenChartStyle.axisLabel(amount)).font(.system(size: 10, weight: .medium)).foregroundStyle(TokenChartStyle.axisColor) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates(data)) { value in
                AxisValueLabel(anchor: axisDates(data).count == 1 ? .top : value.index == 0 ? .topLeading : value.index == axisDates(data).count - 1 ? .topTrailing : .top,
                               collisionResolution: .disabled) {
                    if let date = value.as(Date.self) { Text(dateLabel(date, granularity: data.granularity)).font(.system(size: 10)).foregroundStyle(TokenChartStyle.axisColor) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame else { return }
                            let frame = geometry[anchor]
                            if frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) { selectedDate = date }
                            else { selectedDate = nil }
                        case .ended: selectedDate = nil
                        }
                    }
            }
        }
    }

    private func legend(_ provider: Provider) -> some View {
        let counts = displayedBucket?.counts(for: provider) ?? .zero
        let value = metric.value(counts)
        return HStack(spacing: 5) {
            TokenSeriesSwatch(provider: provider)
            Text(provider.title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(TokenChartStyle.label(value)).font(.system(size: 13, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.9)
        }.help("\(provider.title)：\(value.formatted(.number.grouping(.automatic))) tokens")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.title)，\(value)个 Token")
    }

    private func composition(_ data: TokenTrend) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("构成").fontWeight(.medium)
                Spacer(minLength: 2)
                ForEach(parts(.zero), id: \.name) { part in
                    HStack(spacing: 3) { Circle().fill(part.color).frame(width: 4, height: 4); Text(part.name) }
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
                .help("构成条始终展示所选时间范围的全部 Token，折线指标可单独切换为仅输出。")
            ForEach(Provider.allCases) { provider in
                let counts = data.totals(for: provider)
                HStack(spacing: 8) {
                    Text(provider.title).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(parts(counts), id: \.name) { part in
                                Rectangle().fill(part.color)
                                    .frame(width: counts.total > 0 ? geometry.size.width * Double(part.value) / Double(counts.total) : 0)
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 8).background(.quaternary, in: Capsule())
                }.help(parts(counts).map { "\($0.name)：\($0.value.formatted(.number.grouping(.automatic))) tokens" }.joined(separator: "\n"))
            }
        }
    }

    private func parts(_ counts: TokenCounts) -> [(name: String, value: Int64, color: Color)] {
        [("普通输入", counts.input, .blue), ("输出", counts.output, .purple),
         ("缓存读", counts.cacheRead, .teal), ("缓存写", counts.cacheWrite, .orange)]
    }
    private func dateLabel(_ date: Date, granularity: TokenTrendGranularity) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        switch granularity { case .hour: formatter.dateFormat = "HH:mm"; case .day: formatter.dateFormat = "MM/dd"; case .month: formatter.dateFormat = "yyyy/MM" }
        return formatter.string(from: date)
    }
    private func xDomain(_ data: TokenTrend) -> ClosedRange<Date> {
        let first = data.buckets.first?.start ?? now
        let last = data.buckets.last?.start ?? now
        if first == last { return first.addingTimeInterval(-1800)...last.addingTimeInterval(1800) }
        return first...last
    }
    private func axisDates(_ data: TokenTrend) -> [Date] {
        guard let first = data.buckets.first?.start, let last = data.buckets.last?.start else { return [] }
        if data.buckets.count <= 2 { return data.buckets.map(\.start) }
        return [first, data.buckets[data.buckets.count / 2].start, last]
    }
}
