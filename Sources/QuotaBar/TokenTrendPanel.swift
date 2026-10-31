import SwiftUI
import Charts
import QuotaCore

struct TokenTrendPanel: View {
    let trend: TokenTrend
    let period: TokenPeriod
    let now: Date
    let isPartial: Bool
    @State private var metric: TokenTrendMetric = .total
    @State private var selectedDate: Date?
    private var selected: TokenTimeBucket? { selectedDate.flatMap { trend.nearest(to: $0) } }
    private let claudeColor = Color(red: 0.78, green: 0.43, blue: 0.29)
    private let codexColor = Color(red: 0.24, green: 0.62, blue: 0.49)

    var body: some View {
        let data = trend
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("\(data.granularity.title)趋势").font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("折线指标", selection: $metric) {
                    ForEach(TokenTrendMetric.allCases) { value in Text(value.title).tag(value) }
                }.pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(width: 112)
            }
            HStack {
                legend(.claude, data: data)
                Spacer()
                legend(.codex, data: data)
            }
            chart(data)
                .frame(height: 112)
                .accessibilityLabel("\(period.title)\(data.granularity.title)Token折线图")
            HStack {
                Text(selected.map { dateLabel($0.start, granularity: data.granularity) } ?? "移动鼠标查看各时段用量")
                Spacer()
                Text(metric == .total ? "含缓存" : "仅输出 Token")
            }.font(.system(size: 8)).foregroundStyle(.secondary)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(data.granularity.averageTitle).foregroundStyle(.secondary)
                    Text(TokenDisplayValue.format(data.average(metric: metric)).text).fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("合计峰值").foregroundStyle(.secondary)
                    if let peak = data.peak(metric: metric) {
                        Text("\(TokenDisplayValue.format(metric.value(peak.combined)).text) · \(dateLabel(peak.start, granularity: data.granularity))")
                            .fontWeight(.semibold)
                    } else { Text("暂无记录") }
                }
            }.font(.system(size: 10))
                .help("平均值包含没有本机记录的零值时段，以及尚未结束的当前时段。峰值为两家本机记录之和。")
            Divider().opacity(0.5)
            composition(data)
            Text(isPartial ? "部分日志无法读取，趋势统计可能不完整。" : "仅本机记录，不含网页／手机；无记录按零展示。")
                .font(.system(size: 8)).foregroundStyle(isPartial ? Color.orange : Color.secondary)
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
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    if data.buckets.count <= 31 {
                        PointMark(x: .value("时间", bucket.start), y: .value("Token", Double(metric.value(bucket.counts(for: provider)))))
                            .foregroundStyle(by: .value("服务", provider.title)).symbolSize(10)
                    }
                }
            }
            if let selected {
                RuleMark(x: .value("时间", selected.start)).foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartForegroundStyleScale(domain: ["Claude", "Codex"], range: [claudeColor, codexColor])
        .chartLegend(.hidden)
        .chartYScale(domain: 0...max(1, maximum * 1.12))
        .chartXScale(domain: xDomain(data))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(axisLabel(amount)).font(.system(size: 8)) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(dateLabel(date, granularity: data.granularity)).font(.system(size: 8)) }
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

    private func legend(_ provider: Provider, data: TokenTrend) -> some View {
        let counts = selected?.counts(for: provider) ?? data.totals(for: provider)
        let value = metric.value(counts)
        return HStack(spacing: 5) {
            Circle().fill(provider == .claude ? claudeColor : codexColor).frame(width: 5, height: 5)
            Text(provider.title).foregroundStyle(.secondary)
            Text(selected == nil ? TokenDisplayValue.format(value).text : value.formatted(.number.grouping(.automatic)))
                .fontWeight(.medium).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.font(.system(size: 10)).help("\(provider.title)：\(value.formatted(.number.grouping(.automatic))) tokens")
    }

    private func composition(_ data: TokenTrend) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("构成").fontWeight(.medium)
                Spacer(minLength: 2)
                ForEach(parts(.zero), id: \.name) { part in
                    HStack(spacing: 3) { Circle().fill(part.color).frame(width: 4, height: 4); Text(part.name) }
                }
            }.font(.system(size: 8)).foregroundStyle(.secondary)
                .help("构成条始终展示所选时间范围的全部 Token，折线指标可单独切换为仅输出。")
            ForEach(Provider.allCases) { provider in
                let counts = data.totals(for: provider)
                HStack(spacing: 8) {
                    Text(provider.title).font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(parts(counts), id: \.name) { part in
                                Rectangle().fill(part.color)
                                    .frame(width: counts.total > 0 ? geometry.size.width * Double(part.value) / Double(counts.total) : 0)
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 6).background(.quaternary, in: Capsule())
                }.help(parts(counts).map { "\($0.name)：\($0.value.formatted(.number.grouping(.automatic))) tokens" }.joined(separator: "\n"))
            }
        }
    }

    private func parts(_ counts: TokenCounts) -> [(name: String, value: Int64, color: Color)] {
        [("输入", counts.input, .blue), ("输出", counts.output, .purple),
         ("缓存读", counts.cacheRead, .teal), ("缓存写", counts.cacheWrite, .orange)]
    }
    private func dateLabel(_ date: Date, granularity: TokenTrendGranularity) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        switch granularity { case .hour: formatter.dateFormat = "HH:mm"; case .day: formatter.dateFormat = "MM/dd"; case .month: formatter.dateFormat = "yyyy/MM" }
        return formatter.string(from: date)
    }
    private func axisLabel(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let amount: Int64 = value >= Double(Int64.max) ? Int64.max : Int64(max(0, value))
        let display = TokenDisplayValue.format(amount)
        var number = display.number
        if number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        return display.unit.isEmpty ? number : "\(number) \(display.unit)"
    }
    private func xDomain(_ data: TokenTrend) -> ClosedRange<Date> {
        let first = data.buckets.first?.start ?? now
        let last = data.buckets.last?.start ?? now
        if first == last { return first.addingTimeInterval(-1800)...last.addingTimeInterval(1800) }
        return first...last
    }
}
