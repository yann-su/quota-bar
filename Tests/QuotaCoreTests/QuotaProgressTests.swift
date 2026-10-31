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
}
