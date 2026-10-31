import SwiftUI
import QuotaCore

struct TokenDashboard: View {
    @ObservedObject var store: UsageStore
    private var period: TokenPeriod { store.selectedTokenPeriod }
    @State private var showingTrends = CommandLine.arguments.contains("--show-trends")
    @State private var showingPrices = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("统计时间", selection: $store.selectedTokenPeriod) {
                ForEach(TokenPeriod.allCases) { period in Text(period.title).tag(period) }
            }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
            HStack {
                Text("本机 Token · 含缓存").font(.system(size: 10, weight: .medium))
                Spacer()
                Button { showingPrices.toggle() } label: { Image(systemName: "dollarsign.circle") }
                    .buttonStyle(.borderless).font(.system(size: 12)).help("查看 API 折合单价与计算说明")
                    .accessibilityLabel("查看 API 折合单价和说明")
                    .popover(isPresented: $showingPrices) { PricingInfoView(store: store) }
                Button { showingTrends.toggle() } label: {
                    Label(showingTrends ? "概览" : "趋势", systemImage: showingTrends ? "square.grid.2x2" : "chart.xyaxis.line")
                }.buttonStyle(.borderless).font(.system(size: 10))
                    .help(showingTrends ? "返回用量概览" : "展开用量趋势图")
                if let report = store.tokenReport {
                    Text("更新于 \(report.scannedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if let report = store.tokenReport {
                if showingTrends {
                    HStack {
                        ForEach(Provider.allCases) { provider in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.title).font(.system(size: 9)).foregroundStyle(.secondary)
                                let coverage = report.coverage[provider] ?? TokenCoverage()
                                if coverage.directoryFound && !(coverage.files == 0 && coverage.unreadableFiles > 0) {
                                    TokenCostLabel(estimate: report.cost(provider: provider, period: period, now: store.now))
                                } else {
                                    Text("记录不可用").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            if provider == .claude { Spacer() }
                        }
                    }.padding(.horizontal, 3)
                    TokenTrendPanel(trend: report.trend(period: period, now: store.now), period: period, now: store.now,
                                    isPartial: report.coverage.values.contains { $0.isPartial })
                }
                else {
                    ForEach(Provider.allCases) { provider in
                        TokenProviderCard(provider: provider, report: report, period: period, now: store.now)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在统计本机历史…").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            if !showingTrends {
                Text("本机记录 · API 折合仅供参考，非订阅扣款。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .help("总计 = 普通输入 + 输出 + 缓存读取 + 缓存写入。仅统计本机保存的记录，日期按 \(TimeZone.current.identifier) 划分。万／亿为四舍五入的显示值，导出 CSV 保留精确整数。")
            }
        }
    }
}

private struct TokenProviderCard: View {
    let provider: Provider
    let report: TokenReport
    let period: TokenPeriod
    let now: Date
    @State private var showDetails = false
    private var tint: Color { provider == .claude ? Color(red: 0.78, green: 0.43, blue: 0.29) : Color(red: 0.24, green: 0.52, blue: 0.43) }
    private var records: [TokenRecord] { report.filtered(provider: provider, period: period, now: now) }
    private var counts: TokenCounts { records.reduce(.zero) { $0 + $1.counts } }
    private var cost: TokenCostEstimate { TokenCostEstimate.estimate(records) }
    private var coverage: TokenCoverage { report.coverage[provider] ?? TokenCoverage() }
    private var available: Bool { coverage.directoryFound && !(coverage.files == 0 && coverage.unreadableFiles > 0) }
    private var models: [(name: String, counts: TokenCounts)] {
        Dictionary(grouping: records, by: \.model).map { name, values in (name, values.reduce(.zero) { $0 + $1.counts }) }
            .sorted { $0.counts.total > $1.counts.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider == .claude ? "Claude Code" : "Codex")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
                    if available { TokenCostLabel(estimate: cost) }
                }
                Spacer(minLength: 8)
                if available {
                    let amount = TokenDisplayValue.format(counts.total)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(amount.number).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        if !amount.unit.isEmpty { Text(amount.unit).font(.system(size: 13, weight: .medium)) }
                    }.lineLimit(1).minimumScaleFactor(0.7)
                        .help("\(exact(counts.total)) tokens")
                        .accessibilityLabel("\(period.title)共\(counts.total)个Token")
                } else { Text("—").font(.system(size: 24, weight: .semibold)) }
            }
            if available {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow { metric("普通输入", counts.input); metric("输出", counts.output) }
                    GridRow { metric("缓存读取", counts.cacheRead); metric("缓存写入", counts.cacheWrite) }
                }
                if records.isEmpty {
                    Text("该时段暂无已记录用量。")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack {
                    Button { showDetails.toggle() } label: {
                        HStack(spacing: 4) {
                            Text(showDetails ? "收起明细" : "查看明细")
                            Image(systemName: showDetails ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                    }.buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(tint)
                    Spacer()
                    Text("\(models.count) 个模型").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if showDetails { details }
            } else {
                Text(coverage.unreadableFiles > 0 ? "无法读取日志，请检查文件权限。" : "尚无本机记录，使用后会自动统计。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if coverage.isPartial {
                Label("部分记录无法读取，统计可能不完整。", systemImage: "exclamationmark.circle")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            if !cost.isComplete && available {
                Text(cost.coverageText).font(.system(size: 9)).foregroundStyle(.orange)
            }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.14)))
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.5)
            HStack {
                Text("精确合计").foregroundStyle(.secondary)
                Spacer()
                Text("\(exact(counts.total)) tokens").monospacedDigit().textSelection(.enabled)
            }.font(.system(size: 10))
            ForEach(models, id: \.name) { model in
                let estimate = TokenCostEstimate.estimate(records.filter { $0.model == model.name })
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(model.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        Text(TokenDisplayValue.format(model.counts.total).text).monospacedDigit()
                            .help("\(exact(model.counts.total)) tokens")
                    }.font(.system(size: 10))
                    TokenCostLabel(estimate: estimate)
                }
            }
            HStack {
                Text("\(coverage.files) 个本机日志")
                Spacer()
                if let last = report.records.filter({ $0.provider == provider }).max(by: { $0.timestamp.timeIntervalSince($1.timestamp) < 0 }) {
                    Text("最近 \(last.timestamp.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))")
                }
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }

    private func metric(_ title: String, _ value: Int64) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(TokenDisplayValue.format(value).text)
                .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title)：\(exact(value)) tokens\(title == "普通输入" ? "（不含缓存）" : "")")
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title)\(value)个Token")
    }
    private func exact(_ value: Int64) -> String { value.formatted(.number.grouping(.automatic)) }
}
