import XCTest
@testable import QuotaCore

final class WidgetSnapshotTests: XCTestCase {
    private let now = UsageDecoder.parseDate("2026-10-31T10:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }
    private func report() -> TokenReport {
        var found = TokenCoverage(); found.directoryFound = true; found.files = 1
        return TokenReport(records: [
            TokenRecord(id: "private-request-id", provider: .claude, timestamp: now, model: "private-model",
                counts: TokenCounts(input: 12, output: 34, cacheRead: 56, cacheWrite: 78)),
            TokenRecord(id: "earlier", provider: .claude, timestamp: now.addingTimeInterval(-86400 * 10), model: "private-model",
                counts: TokenCounts(input: 100))
        ], coverage: [.claude: found])
    }
    func testAggregateSnapshotMatchesOverviewAndExcludesPrivateMetadata() throws {
        let report = report()
        let snapshot = WidgetSnapshot(report: report, now: now, calendar: calendar)
        for period in WidgetPeriod.allCases {
            XCTAssertEqual(snapshot.providers[0].total(for: period), report.totals(provider: .claude, period: period.tokenPeriod, now: now, calendar: calendar).total)
        }
        XCTAssertEqual(snapshot.providers[0].daily.count, 7)
        XCTAssertEqual(snapshot.providers[0].daily.reduce(0) { $0 + $1.tokens }, snapshot.providers[0].sevenDays)
        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private-request-id"))
        XCTAssertFalse(json.contains("private-model"))
        XCTAssertFalse(json.contains("model"))
        XCTAssertEqual(try JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot)
    }
    func testMissingLogsRemainUnavailableWhileEmptyDirectoryMeansRecordedZero() {
        var partial = TokenCoverage(); partial.directoryFound = true; partial.files = 1; partial.unreadableFiles = 1
        let report = TokenReport(coverage: [.claude: partial])
        let snapshot = WidgetSnapshot(report: report, now: now, calendar: calendar)
        XCTAssertEqual(snapshot.providers[0].today, 0)
        XCTAssertTrue(snapshot.providers[0].partial)
        XCTAssertNil(snapshot.providers[1].today)
        XCTAssertTrue(snapshot.providers[1].daily.isEmpty)
        partial.files = 0
        let unreadable = WidgetSnapshot(report: TokenReport(coverage: [.claude: partial]), now: now, calendar: calendar)
        XCTAssertNil(unreadable.providers[0].today)
    }
    func testDateRolloverTimeZoneAndStaleSnapshotAreDetected() {
        let snapshot = WidgetSnapshot(report: report(), now: now, calendar: calendar)
        XCTAssertTrue(snapshot.matchesCurrentDay(at: now, calendar: calendar))
        XCTAssertFalse(snapshot.matchesCurrentDay(at: now.addingTimeInterval(86400), calendar: calendar))
        var other = calendar; other.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(snapshot.matchesCurrentDay(at: now, calendar: other))
        XCTAssertFalse(snapshot.isStale(at: now.addingTimeInterval(1199)))
        XCTAssertTrue(snapshot.isStale(at: now.addingTimeInterval(1201)))
    }
    func testQuotaExpiresIndependentlyAndNeverInventsRemainingPercentage() {
        let quota = UsageSnapshot(provider: .claude, fetchedAt: now, windows: [
            QuotaWindow(id: "test", title: "测试", usedPercent: 25, resetsAt: now.addingTimeInterval(600))
        ], source: "test")
        let snapshot = WidgetSnapshot(report: report(), quotas: [quota], now: now, calendar: calendar)
        XCTAssertEqual(snapshot.providers[0].quotaRemaining(at: now), 75)
        XCTAssertNil(snapshot.providers[0].quotaRemaining(at: now.addingTimeInterval(601)))
        XCTAssertNil(snapshot.providers[1].quotaRemaining(at: now))
        var value = snapshot.providers[0]; value.quotaResetsAt = nil
        XCTAssertNil(value.quotaRemaining(at: now.addingTimeInterval(901)))
    }
    func testAtomicStoragePermissionsAndUnknownSchema() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(WidgetSnapshotFile.read(directory: directory))
        let snapshot = WidgetSnapshot(report: report(), now: now, calendar: calendar)
        try WidgetSnapshotFile.write(snapshot, directory: directory)
        XCTAssertEqual(WidgetSnapshotFile.read(directory: directory), snapshot)
        let url = directory.appendingPathComponent(WidgetSnapshotFile.name)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var future = snapshot; future.version = 999
        try WidgetSnapshotFile.write(future, directory: directory)
        XCTAssertNil(WidgetSnapshotFile.read(directory: directory))
        try Data("bad JSON".utf8).write(to: url)
        XCTAssertNil(WidgetSnapshotFile.read(directory: directory))
    }
}
