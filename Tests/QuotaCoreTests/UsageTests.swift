import XCTest
@testable import QuotaCore

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexPrefersMultiBucketWithoutDuplicatingLegacyBucket() throws {
        let json = #"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":12.5,"windowDurationMins":300,"resetsAt":1800003600},"secondary":{"usedPercent":81,"windowDurationMins":10080}},"review":{"limitName":"Code review","primary":{"usedPercent":4,"windowDurationMins":10080}}}}"#
        let snapshot = try UsageDecoder.codex(Data(json.utf8), now: now)
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].title, "5 小时")
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 87.5)
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.availablePercent(at: now, maxAge: 600), 19)
    }

    func testCodexLegacyResponseAndMissingDurations() throws {
        let snapshot = try UsageDecoder.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":0},"secondary":null}}"#.utf8), now: now)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.title, "当前窗口")
        XCTAssertNil(snapshot.windows.first?.resetsAt)
        XCTAssertEqual(snapshot.availablePercent(at: now, maxAge: 600), 100)
    }

    func testUnavailableOrMalformedUsageNeverBecomesZeroPercent() {
        for json in [#"{}"#, #"{"rateLimits":null}"#, #"{"rateLimits":{"primary":{"usedPercent":-1}}}"#,
                     #"{"rateLimits":{"primary":{"usedPercent":101}}}"#, #"{"error":"unauthorized"}"#] {
            XCTAssertThrowsError(try UsageDecoder.codex(Data(json.utf8)))
        }
        for json in [#"{}"#, #"{"five_hour":null}"#, #"{"five_hour":{"utilization":101}}"#,
                     #"{"five_hour":{"utilization":"12"}}"#, #"{"five_hour":{"utilization":10,"resets_at":"tomorrow"}}"#] {
            XCTAssertThrowsError(try UsageDecoder.claude(Data(json.utf8)))
        }
    }

    func testClaudeIncludesDynamicModelWindowsAndIgnoresCreditBilling() throws {
        let json = #"{"five_hour":{"utilization":36,"resets_at":"2027-01-15T08:00:00.123+00:00"},"seven_day":{"utilization":42,"resets_at":"2027-01-17T08:00:00Z"},"seven_day_opus":{"utilization":75,"resets_at":null},"seven_day_sonnet":null,"extra_usage":{"is_enabled":true,"used_credits":1500}}"#
        let snapshot = try UsageDecoder.claude(Data(json.utf8), now: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus"])
        XCTAssertEqual(snapshot.windows[2].title, "每周 · Opus")
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 64)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertNotNil(snapshot.windows[1].resetsAt)
        XCTAssertNil(snapshot.windows[2].resetsAt)
    }

    func testClaudeBreakdownMetadataDoesNotInvalidateRealQuotaWindows() throws {
        let json = #"{"five_hour":{"utilization":1,"resets_at":"2027-01-15T09:00:00Z"},"seven_day":{"utilization":12,"resets_at":"2027-01-17T08:00:00Z"},"seven_day_breakdown":{"by_product":{"claude_code":{}},"total":{}},"seven_day_opus":null,"seven_day_oauth_apps":null}"#
        let snapshot = try UsageDecoder.claude(Data(json.utf8), now: now)
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(snapshot.windows.map(\.usedPercent), [1, 12])
        XCTAssertEqual(snapshot.availablePercent(at: now, maxAge: 600), 88)
    }

    func testExpiredWindowCannotAdvertiseRemainingQuota() {
        let window = QuotaWindow(id: "a", title: "5 小时", usedPercent: 25, resetsAt: now.addingTimeInterval(60))
        let snapshot = UsageSnapshot(provider: .codex, fetchedAt: now, windows: [window], source: "test")
        XCTAssertEqual(snapshot.availablePercent(at: now, maxAge: 600), 75)
        XCTAssertNil(snapshot.availablePercent(at: now.addingTimeInterval(60), maxAge: 600))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25) // Reset is fetched, never guessed locally.
    }

    func testOldCacheCannotAdvertiseRemainingQuota() {
        let snapshot = UsageSnapshot(provider: .claude, fetchedAt: now, windows: [
            QuotaWindow(id: "a", title: "每周", usedPercent: 10, resetsAt: nil)
        ], source: "test")
        XCTAssertNil(snapshot.availablePercent(at: now.addingTimeInterval(601), maxAge: 600))
    }

    func testRetryAfterRespectsBothFormatsAndNeverRetriesInPast() {
        XCTAssertEqual(UsageDecoder.retryDate("120", now: now), now.addingTimeInterval(120))
        XCTAssertEqual(UsageDecoder.retryDate(nil, now: now), now.addingTimeInterval(300))
        XCTAssertEqual(UsageDecoder.retryDate("invalid", now: now), now.addingTimeInterval(300))
        XCTAssertEqual(UsageDecoder.retryDate("-5", now: now), now.addingTimeInterval(1))
        let date = UsageDecoder.retryDate("Wed, 21 Oct 2037 07:28:00 GMT", now: now)
        XCTAssertGreaterThan(date, now)
    }

    func testArchiveBoundsRetentionAndCoalescesOnlySameProvider() throws {
        var archive = SnapshotArchive()
        func sample(_ provider: Provider, _ date: Date) -> UsageSnapshot {
            UsageSnapshot(provider: provider, fetchedAt: date, windows: [], source: "test")
        }
        archive.append(sample(.claude, now.addingTimeInterval(-31 * 86400)), now: now.addingTimeInterval(-31 * 86400))
        archive.append(sample(.codex, now), now: now)
        archive.append(sample(.claude, now), now: now)
        archive.append(sample(.claude, now.addingTimeInterval(20)), now: now.addingTimeInterval(20))
        XCTAssertEqual(archive.snapshots.count, 2)
        XCTAssertEqual(archive.latest(.claude)?.fetchedAt, now.addingTimeInterval(20))
        let encoded = try JSONEncoder().encode(archive)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("accessToken"))
        XCTAssertEqual(try JSONDecoder().decode(SnapshotArchive.self, from: encoded).snapshots.count, 2)
    }
}
