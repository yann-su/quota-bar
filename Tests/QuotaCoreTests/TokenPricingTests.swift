import XCTest
@testable import QuotaCore

final class TokenPricingTests: XCTestCase {
    private let now = UsageDecoder.parseDate("2026-10-31T10:00:00Z")!
    private func row(_ model: String = "claude-opus-5-5", provider: Provider = .claude,
        counts: TokenCounts, long: Int64? = nil) -> TokenRecord {
        TokenRecord(id: UUID().uuidString, provider: provider, timestamp: now, model: model, counts: counts, longCacheWriteTokens: long)
    }
    private func decimal(_ string: String) -> Decimal { Decimal(string: string)! }

    func testEachDisjointCategoryUsesItsOwnPriceAndLongWritesAreOnlyASubset() {
        let estimate = TokenCostEstimate.estimate([row(counts: TokenCounts(input: 1_000_000, output: 2_000_000,
            cacheRead: 3_000_000, cacheWrite: 4_000_000), long: 1_000_000)])
        XCTAssertEqual(estimate.inputUSD, 4)
        XCTAssertEqual(estimate.outputUSD, 40)
        XCTAssertEqual(estimate.cacheReadUSD, decimal("0.6"))
        XCTAssertEqual(estimate.cacheWriteUSD, 23) // 3M * $5 + 1M * $8
        XCTAssertEqual(estimate.totalUSD, decimal("67.6"))
        XCTAssertEqual(estimate.pricedTokens, 10_000_000)
        XCTAssertTrue(estimate.isComplete)
        XCTAssertFalse(estimate.assumedCacheLifetime)
    }

    func testCodexCachedInputIsNotChargedAsOrdinaryInputAgain() throws {
        var parser = TokenLogParser(provider: .codex, fileIdentity: "fixture")
        _ = parser.parse(Data(#"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#.utf8))
        let data = Data(#"{"type":"event_msg","timestamp":"2026-10-31T10:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":20,"reasoning_output_tokens":10}}}}"#.utf8)
        let record = try XCTUnwrap(parser.parse(data))
        let estimate = TokenCostEstimate.estimate([record])
        XCTAssertEqual(estimate.totalUSD, decimal("0.00049"))
        XCTAssertEqual(estimate.pricedTokens, 1020)
        XCTAssertEqual(estimate.displayUSD, "< US$0.01")
    }

    func testUnknownModelsDoNotBecomeZeroDollarUsageAndPartialSumIsExplicit() {
        let unknown = row("claude-opus-5-6", counts: TokenCounts(input: 1_000_000))
        let allUnknown = TokenCostEstimate.estimate([unknown])
        XCTAssertFalse(allUnknown.hasKnownCost)
        XCTAssertFalse(allUnknown.isComplete)
        XCTAssertEqual(allUnknown.displayUSD, "未定价")
        let partial = TokenCostEstimate.estimate([unknown, row("gpt-6.1-sol", provider: .codex, counts: TokenCounts(input: 1_000_000))])
        XCTAssertEqual(partial.totalUSD, 2)
        XCTAssertEqual(partial.pricedTokens, 1_000_000)
        XCTAssertEqual(partial.unpricedTokens, 1_000_000)
        XCTAssertTrue(partial.hasKnownCost)
        XCTAssertTrue(partial.coverageText.contains("仅含已定价部分"))
    }

    func testOnlyExactNamesOrDatedSnapshotsMatchWithinTheirProvider() {
        XCTAssertNotNil(TokenPriceCatalog.price(provider: .claude, model: "claude-opus-4-5-20251101"))
        XCTAssertNotNil(TokenPriceCatalog.price(provider: .codex, model: "gpt-5.2-2025-12-11"))
        XCTAssertNil(TokenPriceCatalog.price(provider: .claude, model: "claude-opus-4-5-custom"))
        XCTAssertNil(TokenPriceCatalog.price(provider: .codex, model: "gpt-6.1-sol-latest"))
        XCTAssertNil(TokenPriceCatalog.price(provider: .claude, model: "gpt-6.1-sol"))
        XCTAssertEqual(TokenPriceCatalog.price(provider: .claude, model: "claude-opus-4-1")?.input, 15)
        XCTAssertEqual(TokenPriceCatalog.price(provider: .claude, model: "claude-opus-4-5")?.input, 5)
        XCTAssertEqual(Set(TokenPriceCatalog.prices.map(\.id)).count, TokenPriceCatalog.prices.count)
    }

    func testMissingCacheLifetimeUsesDisclosedShortRateAndKnownLongUsesLongRate() {
        let counts = TokenCounts(cacheWrite: 1_000_000)
        let assumed = TokenCostEstimate.estimate([row(counts: counts)])
        let known = TokenCostEstimate.estimate([row(counts: counts, long: 1_000_000)])
        XCTAssertEqual(assumed.totalUSD, 5)
        XCTAssertTrue(assumed.assumedCacheLifetime)
        XCTAssertEqual(known.totalUSD, 8)
        XCTAssertFalse(known.assumedCacheLifetime)
    }

    func testClaudeCacheLifetimeParsingAndStreamingDedupPreserveTokenTotals() throws {
        var parser = TokenLogParser(provider: .claude, fileIdentity: "fixture")
        let data = Data(#"{"type":"assistant","timestamp":"2026-10-31T10:00:00Z","requestId":"private","message":{"id":"private","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":40,"ephemeral_1h_input_tokens":60}}}}"#.utf8)
        var record = try XCTUnwrap(parser.parse(data))
        record.merge(try XCTUnwrap(parser.parse(data)))
        XCTAssertEqual(record.counts.total, 130)
        XCTAssertEqual(record.longCacheWriteTokens, 60)
        XCTAssertEqual(TokenCostEstimate.estimate([record]).cacheWriteUSD, decimal("0.00068"))
    }

    func testUnsupportedCacheWritePriceKeepsOtherKnownCategoriesAndMarksGap() {
        let estimate = TokenCostEstimate.estimate([row("gpt-5.4", provider: .codex, counts: TokenCounts(input: 1_000_000, cacheWrite: 20))])
        XCTAssertEqual(estimate.inputUSD, decimal("2.5"))
        XCTAssertEqual(estimate.pricedTokens, 1_000_000)
        XCTAssertEqual(estimate.unpricedTokens, 20)
        XCTAssertFalse(estimate.isComplete)
    }

    func testGrowingStreamingCountersInvalidateIncompleteLifetimeBreakdown() {
        var record = row(counts: TokenCounts(cacheWrite: 100), long: 100)
        record.merge(row(counts: TokenCounts(cacheWrite: 200)))
        XCTAssertEqual(record.counts.cacheWrite, 200)
        XCTAssertNil(record.longCacheWriteTokens)
        XCTAssertTrue(TokenCostEstimate.estimate([record]).assumedCacheLifetime)
        record.merge(row(counts: TokenCounts(cacheWrite: 100), long: 100))
        XCTAssertNil(record.longCacheWriteTokens) // Older partial metadata cannot classify all 200 tokens.
        record.merge(row(counts: TokenCounts(cacheWrite: 200), long: 150))
        XCTAssertEqual(record.longCacheWriteTokens, 150)
        XCTAssertFalse(TokenCostEstimate.estimate([record]).assumedCacheLifetime)
    }

    func testMalformedOptionalCacheBreakdownDoesNotDiscardValidTokenUsage() throws {
        var parser = TokenLogParser(provider: .claude, fileIdentity: "fixture")
        let data = Data(#"{"type":"assistant","timestamp":"2026-10-31T10:00:00Z","message":{"id":"fixture","model":"claude-opus-5-5","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_creation":"unrecognized-format"}}}"#.utf8)
        let record = try XCTUnwrap(parser.parse(data))
        XCTAssertEqual(record.counts.total, 110)
        XCTAssertNil(record.longCacheWriteTokens)
        XCTAssertTrue(TokenCostEstimate.estimate([record]).assumedCacheLifetime)
        XCTAssertEqual(parser.malformedUsageRows, 0)
    }

    func testNoPerRecordRoundingAndLargeCountsDoNotOverflow() {
        let records = (0..<100).map { _ in row("gpt-6.1-sol", provider: .codex, counts: TokenCounts(input: 1)) }
        XCTAssertEqual(TokenCostEstimate.estimate(records).totalUSD, decimal("0.0002"))
        let huge = row(counts: TokenCounts(input: Int64.max))
        let result = TokenCostEstimate.estimate([huge, huge])
        XCTAssertEqual(result.pricedTokens, Int64.max)
        XCTAssertEqual(result.totalUSD, Decimal(Int64.max) * 8 / 1_000_000)
    }

    func testCostAndWidgetRespectTheSameCalendarScopeAndMissingLogCoverage() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        var found = TokenCoverage(); found.directoryFound = true; found.files = 1
        var old = row(counts: TokenCounts(input: 1_000_000)); old.timestamp = now.addingTimeInterval(-10 * 86400)
        var future = row(counts: TokenCounts(input: 8_000_000)); future.timestamp = now.addingTimeInterval(3600)
        let report = TokenReport(records: [old, future, row(counts: TokenCounts(input: 1_000_000))], coverage: [.claude: found])
        let snapshot = WidgetSnapshot(report: report, now: now, calendar: calendar)
        for period in WidgetPeriod.allCases {
            XCTAssertEqual(snapshot.providers[0].cost(for: period), report.cost(provider: .claude, period: period.tokenPeriod, now: now, calendar: calendar))
        }
        XCTAssertEqual(snapshot.providers[0].todayCost?.totalUSD, 4)
        XCTAssertEqual(snapshot.providers[0].thirtyDaysCost?.totalUSD, 8)
        XCTAssertNil(snapshot.providers[1].todayCost)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot)
    }
}
