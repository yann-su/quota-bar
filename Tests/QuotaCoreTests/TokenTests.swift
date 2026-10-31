import XCTest
@testable import QuotaCore

final class TokenTests: XCTestCase {
    private let time = "2026-10-31T09:00:00.000Z"
    private func data(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func claude(id: String = "msg-1", output: Int = 20, timestamp: String = "2026-10-31T09:00:00.000Z") -> Data {
        data(["type": "assistant", "timestamp": timestamp, "requestId": "req-1", "message": [
            "id": id, "model": "claude-test", "content": [["type": "text", "text": "PRIVATE MESSAGE MUST NOT BE EXPORTED"]],
            "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50,
                      "cache_creation": ["ephemeral_1h_input_tokens": 50], "iterations": [["input_tokens": 10, "output_tokens": output]]]
        ]])
    }
    private func codex(input: Int, output: Int, cached: Int, last: [String: Int]? = nil) -> Data {
        var info: [String: Any] = ["total_token_usage": ["input_tokens": input, "output_tokens": output, "cached_input_tokens": cached,
            "total_tokens": input + output, "reasoning_output_tokens": output / 2]]
        if let last { info["last_token_usage"] = last }
        return data(["type": "event_msg", "timestamp": time, "payload": ["type": "token_count", "info": info]])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func writeLines(_ lines: [Data], to url: URL) throws {
        var result = Data()
        for line in lines { result.append(line); result.append(0x0A) }
        try result.write(to: url)
    }

    func testClaudeSeparatesCachesWithoutCountingNestedBreakdownsAgain() throws {
        var parser = TokenLogParser(provider: .claude, fileIdentity: "file")
        let record = try XCTUnwrap(parser.parse(claude()))
        XCTAssertEqual(record.counts, TokenCounts(input: 10, output: 20, cacheRead: 100, cacheWrite: 50))
        XCTAssertEqual(record.counts.total, 180)
        XCTAssertEqual(record.model, "claude-test")
    }

    func testClaudeStreamingBlocksReplaceCountersRatherThanSumThem() throws {
        var parser = TokenLogParser(provider: .claude, fileIdentity: "file")
        var record = try XCTUnwrap(parser.parse(claude(output: 5)))
        record.merge(try XCTUnwrap(parser.parse(claude(output: 20))))
        XCTAssertEqual(record.counts.total, 180)
        XCTAssertEqual(record.counts.output, 20)
    }

    func testCodexCachedInputAndReasoningAreAlreadyIncludedInParentTotals() throws {
        var parser = TokenLogParser(provider: .codex, fileIdentity: "file")
        let record = try XCTUnwrap(parser.parse(codex(input: 150, output: 20, cached: 100)))
        XCTAssertEqual(record.counts.input, 50)
        XCTAssertEqual(record.counts.cacheRead, 100)
        XCTAssertEqual(record.counts.total, 170)
        XCTAssertNil(parser.parse(codex(input: 150, output: 20, cached: 100)))
    }

    func testCodexCumulativeOnlyRecordsUseDeltas() throws {
        var parser = TokenLogParser(provider: .codex, fileIdentity: "file")
        let first = try XCTUnwrap(parser.parse(codex(input: 150, output: 20, cached: 100)))
        let second = try XCTUnwrap(parser.parse(codex(input: 350, output: 50, cached: 250)))
        XCTAssertEqual((first.counts + second.counts).total, 400)
        XCTAssertEqual(second.counts, TokenCounts(input: 50, output: 30, cacheRead: 150))
    }

    func testCodexLastUsageDoesNotChargeImportedSessionHistory() throws {
        var parser = TokenLogParser(provider: .codex, fileIdentity: "file")
        let record = try XCTUnwrap(parser.parse(codex(input: 100_000, output: 5000, cached: 90_000,
            last: ["input_tokens": 200, "output_tokens": 30, "cached_input_tokens": 150])))
        XCTAssertEqual(record.counts.total, 230)
    }

    func testInvalidOrUnrelatedRowsAreNotCharged() {
        var claudeParser = TokenLogParser(provider: .claude, fileIdentity: "file")
        XCTAssertNil(claudeParser.parse(data(["type": "user", "message": ["usage": ["input_tokens": 10]]])))
        XCTAssertNil(claudeParser.parse(claude(output: -1)))
        XCTAssertEqual(claudeParser.malformedUsageRows, 1)
        var codexParser = TokenLogParser(provider: .codex, fileIdentity: "file")
        XCTAssertNil(codexParser.parse(codex(input: 100, output: 5, cached: 200)))
        XCTAssertEqual(codexParser.malformedUsageRows, 1)
    }

    func testDuplicateFilesAndIncrementalAppendsAreDeduplicated() async throws {
        let root = try directory(), first = root.appendingPathComponent("one.jsonl"), second = root.appendingPathComponent("copy.jsonl")
        try writeLines([claude(output: 5)], to: first)
        try writeLines([claude(output: 20)], to: second)
        let scanner = LocalTokenScanner(roots: [.claude: [root]])
        let initial = await scanner.scan()
        XCTAssertEqual(initial.records.count, 1)
        XCTAssertEqual(initial.records.first?.counts.total, 180)
        let unchanged = await scanner.scan()
        XCTAssertEqual(unchanged.records, initial.records)
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        var extra = claude(id: "msg-2"); extra.append(0x0A)
        try handle.write(contentsOf: extra); try handle.close()
        let appended = await scanner.scan()
        XCTAssertEqual(appended.records.count, 2)
        XCTAssertEqual(appended.records.reduce(Int64(0)) { $0 + $1.counts.total }, 360)
    }

    func testForkedCodexLogsDoNotCountSharedTurnsTwice() async throws {
        let root = try directory()
        for (file, session) in [("one", "parent"), ("two", "fork")] {
            try writeLines([
                data(["type": "session_meta", "payload": ["id": session]]),
                data(["type": "turn_context", "payload": ["turn_id": "shared-turn", "model": "test-model"]]),
                codex(input: 150, output: 20, cached: 100)
            ], to: root.appendingPathComponent("\(file).jsonl"))
        }
        let report = await LocalTokenScanner(roots: [.codex: [root]]).scan()
        XCTAssertEqual(report.records.count, 1)
        XCTAssertEqual(report.records.first?.counts.total, 170)
    }

    func testIncompleteTrailingLineIsCountedOnlyAfterItIsComplete() async throws {
        let root = try directory(), url = root.appendingPathComponent("live.jsonl"), line = claude()
        try line.prefix(line.count / 2).write(to: url)
        let scanner = LocalTokenScanner(roots: [.claude: [root]])
        let initial = await scanner.scan()
        XCTAssertEqual(initial.records.count, 0)
        XCTAssertFalse(initial.coverage[.claude]!.isPartial)
        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
        var tail = Data(line.suffix(line.count - line.count / 2)); tail.append(0x0A)
        try handle.write(contentsOf: tail); try handle.close()
        let complete = await scanner.scan()
        XCTAssertEqual(complete.records.count, 1)
    }

    func testTruncatedLogsDiscardOldCachedUsage() async throws {
        let root = try directory(), url = root.appendingPathComponent("live.jsonl")
        try writeLines([claude(id: "old-1"), claude(id: "old-2")], to: url)
        let scanner = LocalTokenScanner(roots: [.claude: [root]])
        _ = await scanner.scan()
        try writeLines([claude(id: "new")], to: url)
        let replaced = await scanner.scan()
        XCTAssertEqual(replaced.records.count, 1)
        XCTAssertTrue(replaced.records[0].id.contains("new"))
    }

    func testCalendarRangesRespectLocalMidnightAndExcludeFutureRecords() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let now = try XCTUnwrap(UsageDecoder.parseDate("2026-10-31T10:00:00Z"))
        let dates = ["2026-10-30T15:59:59Z", "2026-10-30T16:00:00Z", "2026-10-31T11:00:00Z", "2026-10-24T16:00:00Z", "2026-10-24T15:59:59Z"]
        let rows = dates.enumerated().map { index, date in
            TokenRecord(id: "\(index)", provider: .claude, timestamp: UsageDecoder.parseDate(date)!, model: "test", counts: TokenCounts(input: 1))
        }
        let report = TokenReport(records: rows)
        XCTAssertEqual(report.totals(provider: .claude, period: .today, now: now, calendar: calendar).total, 1)
        XCTAssertEqual(report.totals(provider: .claude, period: .sevenDays, now: now, calendar: calendar).total, 3)
        XCTAssertEqual(report.totals(provider: .claude, period: .all, now: now, calendar: calendar).total, 4)
    }

    func testCSVContainsAggregatedUsageAndNoMessageTextOrRequestIDs() async throws {
        let root = try directory()
        try writeLines([claude(id: "PRIVATE_REQUEST_ID")], to: root.appendingPathComponent("one.jsonl"))
        let report = await LocalTokenScanner(roots: [.claude: [root]]).scan()
        XCTAssertTrue(report.csv.contains("\"10\",\"20\",\"100\",\"50\",\"180\""))
        XCTAssertFalse(report.csv.contains("PRIVATE MESSAGE"))
        XCTAssertFalse(report.csv.contains("PRIVATE_REQUEST_ID"))
    }

    func testMissingLogDirectoryIsNotPresentedAsKnownZeroUsage() async throws {
        let root = try directory().appendingPathComponent("missing")
        let report = await LocalTokenScanner(roots: [.claude: [root]]).scan()
        XCTAssertFalse(report.coverage[.claude]!.directoryFound)
        XCTAssertEqual(report.records.count, 0)
    }
}
