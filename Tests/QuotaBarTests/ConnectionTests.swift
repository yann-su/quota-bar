import XCTest
import QuotaCore
@testable import QuotaBar

final class ConnectionTests: XCTestCase {
    func testClaudeDiagnosticsOnlyLogResponseShape() {
        let json = #"{"accessToken":"PRIVATE-TOKEN","five_hour":{"utilization":21,"resets_at":"2027-01-15T08:00:00Z","account":"PRIVATE-ACCOUNT"},"seven_day_breakdown":{"private":"PRIVATE-METADATA"}}"#
        let result = ClaudeClient.responseShape(Data(json.utf8))
        XCTAssertTrue(result.contains("five_hour: utilization=number valid=true"))
        XCTAssertTrue(result.contains("aggregate metadata; not a quota window"))
        XCTAssertFalse(result.contains("PRIVATE"))
        XCTAssertFalse(result.contains("2027-01-15"))
    }
    func testLocalExpiryMetadataDoesNotPreventServerValidation() throws {
        let credential = try ClaudeCredential.decode(Data(#"{"claudeAiOauth":{"accessToken":"test-placeholder","expiresAt":1000000000000}}"#.utf8))
        XCTAssertEqual(credential.accessToken, "test-placeholder")
        XCTAssertEqual(credential.expiresAt?.timeIntervalSince1970, 1_000_000_000)
        let seconds = try ClaudeCredential.decode(Data(#"{"claudeAiOauth":{"accessToken":"test-placeholder","expiresAt":1800000000}}"#.utf8))
        XCTAssertEqual(seconds.expiresAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testStaleOrMalformedKeychainEntryDoesNotMaskNewFallbackCredential() {
        let old = Data(#"{"claudeAiOauth":{"accessToken":"old-placeholder","expiresAt":1000000000000}}"#.utf8)
        let fresh = Data(#"{"claudeAiOauth":{"accessToken":"new-placeholder","expiresAt":2000000000000}}"#.utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClaudeCredential.select(keychainData: old, fileData: fresh, now: now)?.accessToken, "new-placeholder")
        XCTAssertEqual(ClaudeCredential.select(keychainData: Data("invalid".utf8), fileData: fresh, now: now)?.accessToken, "new-placeholder")
    }

    func testManualRecoveryCanRetryImmediatelyAfterAuthenticationFailure() {
        let now = Date()
        let state = ProviderState(error: "authentication failed", retryAfter: now.addingTimeInterval(900), failure: .expiredCredential)
        XCTAssertFalse(state.mustWaitBeforeRetry(at: now, forced: true))
        XCTAssertTrue(state.mustWaitBeforeRetry(at: now, forced: false))
    }

    func testManualRecoveryStillRespectsServerRateLimit() {
        let now = Date()
        let deadline = now.addingTimeInterval(900)
        let state = ProviderState(retryAfter: deadline, failure: .rateLimited(deadline))
        XCTAssertTrue(state.mustWaitBeforeRetry(at: now, forced: true))
        XCTAssertFalse(state.mustWaitBeforeRetry(at: deadline, forced: true))
    }

    private func fixture(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-codex")
        try ("#!/usr/bin/python3\n" + source).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    func testRPCHandshakeDoesNotWaitForPipeEOFOrStartModelTurn() throws {
        let executable = try fixture("""
        import sys, json, time
        first = json.loads(sys.stdin.readline())
        assert first['method'] == 'initialize'
        print(json.dumps({'id': first['id'], 'result': {}}), flush=True)
        assert json.loads(sys.stdin.readline())['method'] == 'initialized'
        request = json.loads(sys.stdin.readline())
        assert request['method'] == 'account/rateLimits/read'
        print(json.dumps({'method': 'account/updated', 'params': {}}), flush=True)
        print(json.dumps({'id': request['id'], 'result': {'rateLimits': {'primary': {'usedPercent': 27, 'windowDurationMins': 300}}}}), flush=True)
        time.sleep(10)
        """)
        let start = Date()
        let snapshot = try CodexRPC(timeout: 4).fetch(executable: executable)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 27)
    }

    func testStalledRPCIsTerminatedAtDeadline() throws {
        let executable = try fixture("import time\ntime.sleep(30)\n")
        let start = Date()
        XCTAssertThrowsError(try CodexRPC(timeout: 0.4).fetch(executable: executable)) { error in
            XCTAssertEqual(error as? UsageError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testRPCAuthErrorBecomesActionableMessage() throws {
        let executable = try fixture("""
        import sys, json
        first = json.loads(sys.stdin.readline())
        print(json.dumps({'id': first['id'], 'result': {}}), flush=True)
        sys.stdin.readline()
        request = json.loads(sys.stdin.readline())
        print(json.dumps({'id': request['id'], 'error': {'code': -32000, 'message': 'Authentication required'}}), flush=True)
        """)
        XCTAssertThrowsError(try CodexRPC(timeout: 3).fetch(executable: executable)) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }
}
