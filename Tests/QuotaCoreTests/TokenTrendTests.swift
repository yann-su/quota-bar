import XCTest
@testable import QuotaCore

final class TokenTrendTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return result
    }
    private func date(_ value: String) -> Date { UsageDecoder.parseDate(value)! }
    private func row(_ id: String, _ provider: Provider, _ time: String, _ counts: TokenCounts) -> TokenRecord {
        TokenRecord(id: id, provider: provider, timestamp: date(time), model: "test", counts: counts)
    }

    func testDailyBucketsRespectLocalMidnightAndFillMissingDays() {
        let now = date("2026-10-31T10:00:00Z")
        let report = TokenReport(records: [
            row("first", .claude, "2026-10-24T16:00:00Z", TokenCounts(input: 100)),
            row("today", .codex, "2026-10-30T16:00:00Z", TokenCounts(output: 40)),
            row("old", .codex, "2026-10-24T15:59:59Z", TokenCounts(output: 500)),
            row("future", .claude, "2026-10-31T11:00:00Z", TokenCounts(input: 900))
        ])
        let trend = report.trend(period: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(trend.granularity, .day)
        XCTAssertEqual(trend.buckets.count, 7)
        XCTAssertEqual(trend.buckets[0].start, date("2026-10-24T16:00:00Z"))
        XCTAssertEqual(trend.buckets[0].claude.total, 100)
        XCTAssertEqual(trend.buckets[1].combined.total, 0)
        XCTAssertEqual(trend.buckets[6].codex.output, 40)
        XCTAssertEqual(trend.totals(for: .claude).total, 100)
        XCTAssertEqual(trend.average(metric: .total), 20)
        XCTAssertEqual(trend.peak(metric: .output)?.codex.output, 40)
    }

    func testTodayUsesHoursAndDoesNotDrawFutureHoursAsZeros() {
        let now = date("2026-10-31T02:30:00Z") // 10:30 Taipei
        let report = TokenReport(records: [
            row("hour-0", .claude, "2026-10-30T16:15:00Z", TokenCounts(input: 5)),
            row("hour-10", .codex, "2026-10-31T02:10:00Z", TokenCounts(input: 30)),
            row("later", .codex, "2026-10-31T03:00:00Z", TokenCounts(input: 100))
        ])
        let trend = report.trend(period: .today, now: now, calendar: calendar)
        XCTAssertEqual(trend.granularity, .hour)
        XCTAssertEqual(trend.buckets.count, 11)
        XCTAssertEqual(trend.buckets[0].claude.total, 5)
        XCTAssertEqual(trend.buckets[10].codex.total, 30)
        XCTAssertEqual(trend.totals(for: .codex).total, 30)
    }

    func testTrendCategorySumsEqualOverviewAcrossPeriodsAndProviders() {
        let now = date("2026-10-31T10:00:00Z")
        let report = TokenReport(records: [
            row("a", .claude, "2026-10-31T09:00:00Z", TokenCounts(input: 10, output: 20, cacheRead: 100, cacheWrite: 50)),
            row("b", .codex, "2026-10-27T09:00:00Z", TokenCounts(input: 30, output: 5, cacheRead: 200)),
            row("c", .claude, "2026-10-10T09:00:00Z", TokenCounts(output: 70)),
            row("d", .codex, "2026-05-01T09:00:00Z", TokenCounts(input: 1))
        ])
        for period in TokenPeriod.allCases {
            let trend = report.trend(period: period, now: now, calendar: calendar)
            for provider in Provider.allCases {
                XCTAssertEqual(trend.totals(for: provider), report.totals(provider: provider, period: period, now: now, calendar: calendar))
            }
        }
    }

    func testLongHistoryUsesCalendarMonthsAndPreservesTotals() {
        let now = date("2026-10-31T10:00:00Z")
        let report = TokenReport(records: [
            row("old", .claude, "2024-10-12T08:00:00Z", TokenCounts(input: 123)),
            row("new", .claude, "2026-10-31T08:00:00Z", TokenCounts(input: 456))
        ])
        let trend = report.trend(period: .all, now: now, calendar: calendar)
        XCTAssertEqual(trend.granularity, .month)
        XCTAssertEqual(trend.buckets.count, 25)
        XCTAssertEqual(trend.buckets[0].claude.total, 123)
        XCTAssertEqual(trend.buckets[24].claude.total, 456)
        XCTAssertEqual(trend.totals(for: .claude).total, 579)
    }

    func testEmptyHistoryHasNoInventedPeakAndNearestPointIsStable() {
        let now = date("2026-10-31T10:00:00Z")
        let trend = TokenReport().trend(period: .sevenDays, now: now, calendar: calendar)
        XCTAssertEqual(trend.buckets.count, 7)
        XCTAssertEqual(trend.average(metric: .total), 0)
        XCTAssertNil(trend.peak(metric: .total))
        XCTAssertEqual(trend.nearest(to: date("2026-10-27T17:00:00Z"))?.start, date("2026-10-27T16:00:00Z"))
    }
}
