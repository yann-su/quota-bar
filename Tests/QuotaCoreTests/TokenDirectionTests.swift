import XCTest
@testable import QuotaCore

final class TokenDirectionTests: XCTestCase {
    private let now = UsageDecoder.parseDate("2026-10-31T10:00:00Z")!
    private func row(_ model: String = "claude-opus-5-5", _ counts: TokenCounts, daysAgo: Int = 0) -> TokenRecord {
        TokenRecord(id: UUID().uuidString, provider: .claude, timestamp: now.addingTimeInterval(Double(-daysAgo) * 86400), model: model, counts: counts)
    }

    func testInputIncludesBothCachesAndPartitionsTheExistingTotal() {
        let counts = TokenCounts(input: 10, output: 20, cacheRead: 100, cacheWrite: 50)
        XCTAssertEqual(counts.totalInput, 160)
        XCTAssertEqual(counts.totalInput + counts.output, counts.total)
        XCTAssertEqual(TokenDirection.input.tokens(in: counts), 160)
        XCTAssertEqual(TokenDirection.output.tokens(in: counts), 20)
        XCTAssertEqual(TokenCounts(input: Int64.max, cacheRead: 100, cacheWrite: 100).totalInput, Int64.max)
    }

    func testInputFeesIncludeCacheFeesAndExactDirectionalAmountsSumToTotal() {
        var record = row("claude-opus-5-5", TokenCounts(input: 1_000_000, output: 2_000_000, cacheRead: 3_000_000, cacheWrite: 4_000_000))
        record.longCacheWriteTokens = 1_000_000
        let cost = TokenCostEstimate.estimate([record])
        XCTAssertEqual(cost.amountUSD(for: .input), Decimal(string: "27.6"))
        XCTAssertEqual(cost.amountUSD(for: .output), 40)
        XCTAssertEqual(cost.amountUSD(for: .input) + cost.amountUSD(for: .output), cost.totalUSD)
        XCTAssertEqual(cost.pricedInputTokens, 8_000_000)
        XCTAssertEqual(cost.pricedOutputTokens, 2_000_000)
        XCTAssertEqual(cost.pricedTokens, 10_000_000)
    }

    func testUnknownInputDoesNotInvalidateKnownOutputOrBecomeZeroCost() {
        let cost = TokenCostEstimate.estimate([
            row("unknown-model", TokenCounts(input: 100, cacheRead: 200, cacheWrite: 300)),
            row("claude-opus-5-5", TokenCounts(output: 1_000_000))
        ])
        XCTAssertEqual(cost.unpricedInputTokens, 600)
        XCTAssertFalse(cost.hasKnownCost(for: .input))
        XCTAssertEqual(cost.referenceText(for: .input), "未定价")
        XCTAssertTrue(cost.isComplete(for: .output))
        XCTAssertEqual(cost.amountUSD(for: .output), 20)
        XCTAssertEqual(cost.pricedOutputTokens, 1_000_000)
        XCTAssertEqual(cost.unpricedTokens, 600)
    }

    func testUnknownOutputDoesNotInvalidateKnownInputOrCacheFees() {
        let cost = TokenCostEstimate.estimate([
            row("unknown-model", TokenCounts(output: 500)),
            row("claude-opus-5-5", TokenCounts(input: 1_000_000, cacheRead: 1_000_000))
        ])
        XCTAssertTrue(cost.isComplete(for: .input))
        XCTAssertEqual(cost.amountUSD(for: .input), Decimal(string: "4.2"))
        XCTAssertFalse(cost.hasKnownCost(for: .output))
        XCTAssertEqual(cost.referenceText(for: .output), "未定价")
        XCTAssertEqual(cost.unpricedOutputTokens, 500)
    }

    func testUnsupportedWriteRateOnlyMarksInputAsPartial() {
        let record = TokenRecord(id: "fixture", provider: .codex, timestamp: now, model: "gpt-5.4",
            counts: TokenCounts(input: 1_000_000, output: 1_000_000, cacheWrite: 20))
        let cost = TokenCostEstimate.estimate([record])
        XCTAssertTrue(cost.hasKnownCost(for: .input))
        XCTAssertFalse(cost.isComplete(for: .input))
        XCTAssertEqual(cost.unpricedTokens(for: .input), 20)
        XCTAssertTrue(cost.isComplete(for: .output))
        XCTAssertEqual(cost.amountUSD(for: .output), 15)
    }

    func testInputTrendAggregatesCachesAndChoosesPeakByTotalInput() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let report = TokenReport(records: [
            row("claude-opus-5-5", TokenCounts(input: 10, output: 5, cacheRead: 100, cacheWrite: 50)),
            row("claude-opus-5-5", TokenCounts(input: 100, output: 500), daysAgo: 1)
        ])
        let trend = report.trend(period: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(TokenTrendMetric.input.value(trend.totals(for: .claude)), 260)
        XCTAssertEqual(trend.average(metric: .input), 260 / 7)
        XCTAssertEqual(trend.peak(metric: .input)?.start, calendar.startOfDay(for: now))
        XCTAssertEqual(trend.peak(metric: .output)?.start, calendar.startOfDay(for: now.addingTimeInterval(-86400)))
        for bucket in trend.buckets {
            XCTAssertEqual(bucket.combined.totalInput + bucket.combined.output, bucket.combined.total)
        }
    }

    func testWidgetSplitsAndDirectionalCostsMatchOverviewForEveryPeriod() throws {
        var found = TokenCoverage(); found.directoryFound = true; found.files = 1
        let report = TokenReport(records: [
            row("claude-opus-5-5", TokenCounts(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)),
            row("unknown-model", TokenCounts(input: 50, output: 60), daysAgo: 10)
        ], coverage: [.claude: found])
        let snapshot = WidgetSnapshot(report: report, now: now)
        for period in WidgetPeriod.allCases {
            let counts = report.totals(provider: .claude, period: period.tokenPeriod, now: now)
            let value = snapshot.providers[0]
            XCTAssertEqual(value.split(for: period)?.input, counts.totalInput)
            XCTAssertEqual(value.split(for: period)?.output, counts.output)
            XCTAssertEqual(value.cost(for: period), report.cost(provider: .claude, period: period.tokenPeriod, now: now))
        }
        XCTAssertNil(snapshot.providers[1].sevenDaysSplit)
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded), snapshot)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("unknown-model"))
    }
}
