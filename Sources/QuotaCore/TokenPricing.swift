import Foundation

/// USD per million tokens, Standard / short-context reference rates. Kept
/// offline and dated: selected history is revalued at this table, not billed.
public struct TokenPrice: Sendable, Identifiable {
    public var provider: Provider
    public var model: String
    public var input: Decimal
    public var output: Decimal
    public var cacheRead: Decimal
    public var cacheWrite: Decimal?
    public var cacheWriteLong: Decimal?
    public var id: String { "\(provider.rawValue):\(model)" }
    public var sourceURL: URL {
        if provider == .codex && ["gpt-5.4", "gpt-5.2", "gpt-5.1-codex"].contains(model) {
            return URL(string: "https://developers.openai.com/api/docs/models/\(model)")!
        }
        return provider == .claude ? TokenPriceCatalog.claudeSource : TokenPriceCatalog.openAISource
    }
}

public enum TokenPriceCatalog {
    public static let verifiedDate = "2026-10-31"
    public static let openAISource = URL(string: "https://developers.openai.com/api/docs/pricing")!
    public static let claudeSource = URL(string: "https://platform.claude.com/docs/en/about-claude/pricing")!
    public static let assumptions = "按当前标准短上下文 API 单价重估历史用量；不含加速、长上下文溢价、工具及税费，不代表订阅实付。缺失缓存时长时，Claude 写入按 5 分钟、Codex 按 30 分钟计算。"

    public static let prices: [TokenPrice] = {
        var result: [TokenPrice] = []
        func add(_ provider: Provider, _ models: [String], _ input: String, _ output: String, _ read: String, _ write: String? = nil, _ long: String? = nil) {
            for model in models {
                result.append(TokenPrice(provider: provider, model: model, input: decimal(input), output: decimal(output),
                    cacheRead: decimal(read), cacheWrite: write.map(decimal), cacheWriteLong: long.map(decimal)))
            }
        }
        add(.claude, ["claude-opus-5-5"], "4", "20", "0.20", "5", "8")
        add(.claude, ["claude-sonnet-5-5"], "2", "10", "0.10", "2.5", "4")
        add(.claude, ["claude-haiku-5-5"], "0.10", "0.50", "0.01", "0.125", "0.20")
        add(.claude, ["claude-fable-5-1", "claude-mythos-5-1"], "10", "50", "0.25", "12.5", "20")
        add(.claude, ["claude-fable-5", "claude-mythos-5"], "10", "50", "1", "12.5", "20")
        add(.claude, ["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], "5", "25", "0.50", "6.25", "10")
        add(.claude, ["claude-opus-4-1", "claude-opus-4"], "15", "75", "1.5", "18.75", "30")
        add(.claude, ["claude-sonnet-5"], "2", "10", "0.20", "2.5", "4")
        add(.claude, ["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4"], "3", "15", "0.30", "3.75", "6")
        add(.claude, ["claude-haiku-4-5"], "1", "5", "0.10", "1.25", "2")
        add(.claude, ["claude-3-5-haiku"], "0.8", "4", "0.08", "1", "1.6")
        add(.codex, ["gpt-6-astra"], "10", "50", "1", "12.5", "25")
        add(.codex, ["gpt-6.1-sol"], "2", "10", "0.10", "2.5", "5")
        add(.codex, ["gpt-6.1-terra"], "1", "5", "0.05", "1.25", "2.5")
        add(.codex, ["gpt-6-sol"], "2", "10", "0.20", "2.5", "5")
        add(.codex, ["gpt-6-luna"], "0.10", "0.50", "0.01", "0.125", "0.25")
        add(.codex, ["gpt-5.6-sol"], "4", "20", "0.40", "5", "10")
        add(.codex, ["gpt-5.3-codex", "gpt-5.2"], "1.75", "14", "0.175")
        add(.codex, ["gpt-5.4"], "2.5", "15", "0.25")
        add(.codex, ["gpt-5.1-codex"], "1.25", "10", "0.125")
        return result
    }()

    private static func decimal(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }
    public static func price(provider: Provider, model: String) -> TokenPrice? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = prices.first(where: { $0.provider == provider && $0.model == name }) { return exact }
        // Only a complete dated snapshot suffix is accepted. Never infer prices
        // for "latest", renamed families, third-party or arbitrary model IDs.
        return prices.first { price in
            guard price.provider == provider, name.hasPrefix(price.model + "-") else { return false }
            let suffix = String(name.dropFirst(price.model.count + 1))
            return suffix.range(of: "^(?:[0-9]{8}|[0-9]{4}-[0-9]{2}-[0-9]{2})$", options: .regularExpression) != nil
        }
    }
}

public struct TokenCostEstimate: Codable, Equatable, Sendable {
    public var inputUSD: Decimal = 0
    public var outputUSD: Decimal = 0
    public var cacheReadUSD: Decimal = 0
    public var cacheWriteUSD: Decimal = 0
    public var pricedTokens: Int64 = 0
    public var unpricedTokens: Int64 = 0
    public var assumedCacheLifetime = false
    public var totalUSD: Decimal { inputUSD + outputUSD + cacheReadUSD + cacheWriteUSD }
    public var isComplete: Bool { unpricedTokens == 0 }
    public var hasKnownCost: Bool { pricedTokens > 0 || unpricedTokens == 0 }
    public var displayUSD: String { hasKnownCost ? Self.money(totalUSD) : "未定价" }
    public var referenceText: String {
        guard hasKnownCost else { return "未定价" }
        return displayUSD.hasPrefix("<") ? displayUSD : "≈ \(displayUSD)"
    }
    public var coverageText: String {
        if isComplete { return "已覆盖全部已记录 Token" }
        return "未定价 \(TokenDisplayValue.format(unpricedTokens).text) Token，金额仅含已定价部分"
    }
    public static func money(_ value: Decimal) -> String {
        if value > 0 && value < Decimal(string: "0.01")! { return "< US$0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "US$"
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }
    private mutating func addPriced(_ value: Int64) { pricedTokens = Self.sum(pricedTokens, value) }
    private mutating func addUnpriced(_ value: Int64) { unpricedTokens = Self.sum(unpricedTokens, value) }
    private static func sum(_ a: Int64, _ b: Int64) -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b); return overflow ? Int64.max : value
    }
    public static func estimate(_ records: [TokenRecord]) -> Self {
        var result = Self()
        for record in records {
            let counts = record.counts
            guard let rate = TokenPriceCatalog.price(provider: record.provider, model: record.model) else {
                result.addUnpriced(counts.total); continue
            }
            let million: Decimal = 1_000_000
            result.inputUSD += Decimal(counts.input) * rate.input / million
            result.outputUSD += Decimal(counts.output) * rate.output / million
            result.cacheReadUSD += Decimal(counts.cacheRead) * rate.cacheRead / million
            result.addPriced(TokenCounts(input: counts.input, output: counts.output, cacheRead: counts.cacheRead).total)
            guard counts.cacheWrite > 0 else { continue }
            guard let shortRate = rate.cacheWrite else { result.addUnpriced(counts.cacheWrite); continue }
            let long = min(counts.cacheWrite, max(0, record.longCacheWriteTokens ?? 0))
            if long > 0 && rate.cacheWriteLong == nil { result.addUnpriced(long) }
            else {
                result.cacheWriteUSD += Decimal(long) * (rate.cacheWriteLong ?? shortRate) / million
                result.addPriced(long)
            }
            let short = counts.cacheWrite - long
            result.cacheWriteUSD += Decimal(short) * shortRate / million
            result.addPriced(short)
            if record.longCacheWriteTokens == nil { result.assumedCacheLifetime = true }
        }
        return result
    }
}

public extension TokenReport {
    func cost(provider: Provider, period: TokenPeriod, now: Date, calendar: Calendar = .current) -> TokenCostEstimate {
        TokenCostEstimate.estimate(filtered(provider: provider, period: period, now: now, calendar: calendar))
    }
}
