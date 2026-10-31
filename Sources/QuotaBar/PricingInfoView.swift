import SwiftUI
import QuotaCore

struct TokenCostLabel: View {
    let estimate: TokenCostEstimate
    var body: some View {
        Text("\(estimate.isComplete || !estimate.hasKnownCost ? "API 折合" : "部分折合") \(estimate.referenceText)")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.75)
            .help("已定价部分的 API 参考折合：\n输入 \(TokenCostEstimate.money(estimate.inputUSD))\n输出 \(TokenCostEstimate.money(estimate.outputUSD))\n缓存读取 \(TokenCostEstimate.money(estimate.cacheReadUSD))\n缓存写入 \(TokenCostEstimate.money(estimate.cacheWriteUSD))\n\(estimate.coverageText)\n\(TokenPriceCatalog.assumptions)\n价格核对：\(TokenPriceCatalog.verifiedDate)")
    }
}

struct PricingInfoView: View {
    private struct Model: Identifiable {
        var provider: Provider
        var name: String
        var id: String { "\(provider.rawValue):\(name)" }
    }
    @ObservedObject var store: UsageStore
    private var models: [Model] {
        Provider.allCases.flatMap { provider in
            Set(store.tokenReport?.records.filter { $0.provider == provider }.map(\.model) ?? []).sorted().map { Model(provider: provider, name: $0) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API 参考折合 · USD").font(.system(size: 14, weight: .semibold))
            Text("按模型和四类 Token 分别计价，用于衡量使用量价值，不代表订阅扣款或余额。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(TokenPriceCatalog.assumptions).font(.system(size: 10)).foregroundStyle(.secondary)
            Text("价格核对：\(TokenPriceCatalog.verifiedDate) · 美元／百万 Token")
                .font(.system(size: 10, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(models) { model in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.name).font(.system(size: 10, weight: .medium)).textSelection(.enabled)
                            if let rate = TokenPriceCatalog.price(provider: model.provider, model: model.name) {
                                Text("输入 $\(number(rate.input)) · 输出 $\(number(rate.output)) · 缓存读 $\(number(rate.cacheRead))")
                                if let write = rate.cacheWrite {
                                    Text("缓存写 $\(number(write))／$\(number(rate.cacheWriteLong ?? write))（短／长时）")
                                }
                            } else { Text("未找到可靠单价，未计入金额。") }
                        }.font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
            HStack {
                Link("OpenAI 官方价格", destination: TokenPriceCatalog.openAISource)
                Link("Claude 官方价格", destination: TokenPriceCatalog.claudeSource)
            }.font(.system(size: 10))
        }.padding(15).frame(width: 310)
    }
    private func number(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
}
