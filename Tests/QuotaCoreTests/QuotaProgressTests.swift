import XCTest
@testable import QuotaCore

final class QuotaProgressTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_400_000)
    private func usage(_ used: Double = 12.5, reset: TimeInterval = 600) -> UsageSnapshot {
        UsageSnapshot(provider: .codex, fetchedAt: now, windows: [
            QuotaWindow(id: "five_hour", title: "5 小时", usedPercent: used, resetsAt: now.addingTimeInterval(reset))
        ], source: "test")
    }
    func testMostRestrictedWindowKeepsItsOwnResetTime() throws {
        var usage = usage(10, reset: 60)
        usage.windows.append(QuotaWindow(id: "week", title: "每周", usedPercent: 80, resetsAt: now.addingTimeInterval(6000)))
        let snapshot = WidgetSnapshot(report: TokenReport(), quotas: [usage], now: now)
        let item = try XCTUnwrap(snapshot.providers.first { $0.provider == .codex })
        let progress = try XCTUnwrap(item.quota)
        XCTAssertEqual(progress.title, "每周")
        XCTAssertEqual(progress.remainingPercent, 20)
        XCTAssertEqual(progress.resetsAt, now.addingTimeInterval(6000))
        XCTAssertNil(item.today) // Quota does not depend on finding token logs.
        XCTAssertEqual(item.quotaRemaining(at: now), 20)
    }
    func testFractionalUsageLabelsAreComplementaryWithoutChangingBarFraction() throws {
        let progress = try XCTUnwrap(QuotaProgress(snapshot: usage(), now: now))
        XCTAssertEqual(progress.remainingPercent, 87)
        XCTAssertEqual(progress.displayedUsedPercent, 13)
        XCTAssertEqual(progress.usedFraction, 0.125, accuracy: 0.000001)
        for value in [0.0, 0.1, 25.0, 99.9, 100.0] {
            let progress = try XCTUnwrap(QuotaProgress(snapshot: usage(value), now: now))
            XCTAssertEqual(progress.remainingPercent + progress.displayedUsedPercent, 100)
            XCTAssertTrue((0...1).contains(progress.usedFraction))
        }
    }
    func testResetAndFreshnessExpiryHidePreviouslyValidQuota() throws {
        let progress = try XCTUnwrap(QuotaProgress(snapshot: usage(reset: 30), now: now))
        XCTAssertTrue(progress.isCurrent(at: now.addingTimeInterval(29)))
        XCTAssertFalse(progress.isCurrent(at: now.addingTimeInterval(30)))
        let weekly = try XCTUnwrap(QuotaProgress(snapshot: usage(reset: 6000), now: now))
        XCTAssertTrue(weekly.isCurrent(at: now.addingTimeInterval(899)))
        XCTAssertFalse(weekly.isCurrent(at: now.addingTimeInterval(900)))
        XCTAssertNil(QuotaProgress(snapshot: usage(), now: now.addingTimeInterval(901)))
        XCTAssertNil(QuotaProgress(snapshot: usage(), now: now.addingTimeInterval(-61)))
        XCTAssertNil(QuotaProgress(snapshot: nil, now: now))
    }
    func testUnknownAndInvalidQuotaNeverBecomeDisplayedZeroUsage() throws {
        var noWindows = usage(); noWindows.windows = []
        XCTAssertNil(QuotaProgress(snapshot: noWindows, now: now))
        var malformed = try XCTUnwrap(QuotaProgress(snapshot: usage(), now: now))
        for value in [-1.0, 101, .nan, .infinity] {
            malformed.usedPercent = value
            XCTAssertFalse(malformed.isCurrent(at: now))
        }
        var invalidWindow = usage(); invalidWindow.windows[0].usedPercent = .nan
        XCTAssertNil(QuotaProgress(snapshot: invalidWindow, now: now))
    }
    func testPrimaryWindowsKeepWeeklyVisibleWhenFiveHourIsMoreRestricted() {
        let snapshot = UsageSnapshot(provider: .claude, fetchedAt: now, windows: [
            QuotaWindow(id: "seven_day", title: "每周 · 全部模型", usedPercent: 10, resetsAt: now.addingTimeInterval(5000)),
            QuotaWindow(id: "five_hour", title: "5 小时", usedPercent: 71, resetsAt: now.addingTimeInterval(600)),
            QuotaWindow(id: "seven_day_sonnet", title: "每周 · Sonnet", usedPercent: 99, resetsAt: now.addingTimeInterval(5000))
        ], source: "test")
        let windows = QuotaProgress.primaryWindows(snapshot: snapshot, now: now)
        XCTAssertEqual(windows.map(\.windowID), ["five_hour", "seven_day"])
        XCTAssertEqual(windows.map(\.usedPercent), [71, 10])
        let widget = WidgetSnapshot(report: TokenReport(), quotas: [snapshot], now: now)
        XCTAssertEqual(widget.providers[0].quotaWindows, windows)
    }
    func testShortWindowExpiryDoesNotHideCurrentWeeklyWindow() {
        let snapshot = UsageSnapshot(provider: .claude, fetchedAt: now, windows: [
            QuotaWindow(id: "five_hour", title: "5 小时", usedPercent: 80, resetsAt: now.addingTimeInterval(30)),
            QuotaWindow(id: "seven_day", title: "每周", usedPercent: 10, resetsAt: now.addingTimeInterval(5000))
        ], source: "test")
        let windows = QuotaProgress.primaryWindows(snapshot: snapshot, now: now.addingTimeInterval(31))
        XCTAssertEqual(windows.map(\.windowID), ["seven_day"])
        XCTAssertEqual(windows.first?.remainingPercent, 90)
    }
    func testMissingGlobalWeeklyQuotaIsNotReplacedByModelQuota() {
        var snapshot = usage(71)
        snapshot.provider = .claude
        snapshot.windows.append(QuotaWindow(id: "seven_day_opus", title: "每周 · Opus", usedPercent: 10, resetsAt: nil))
        XCTAssertEqual(QuotaProgress.primaryWindows(snapshot: snapshot, now: now).map(\.windowID), ["five_hour"])
        XCTAssertTrue(QuotaProgress.primaryWindows(snapshot: snapshot, now: now.addingTimeInterval(901)).isEmpty)
    }
    func testCodexUsesOnlyReportedBaseWindows() {
        let snapshot = UsageSnapshot(provider: .codex, fetchedAt: now, windows: [
            QuotaWindow(id: "review.primary", title: "Code review", usedPercent: 95, resetsAt: nil),
            QuotaWindow(id: "codex.primary", title: "每周", usedPercent: 16, resetsAt: nil)
        ], source: "test")
        let windows = QuotaProgress.primaryWindows(snapshot: snapshot, now: now)
        XCTAssertEqual(windows.map(\.windowID), ["codex.primary"])
        XCTAssertEqual(windows.first?.shortTitle, "每周")
    }
}
