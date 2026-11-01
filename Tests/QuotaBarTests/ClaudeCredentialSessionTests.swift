import XCTest
import QuotaCore
@testable import QuotaBar

final class ClaudeCredentialSessionTests: XCTestCase {
    private func credential(_ token: String) -> ClaudeCredential {
        ClaudeCredential(accessToken: token, expiresAt: .distantPast)
    }

    func testRefreshesReuseAuthorizationDespiteStaleLocalExpiryMetadata() async throws {
        let spy = ReaderSpy([.success(credential("placeholder"))])
        let session = ClaudeCredentialSession(reader: spy.read)
        _ = try await session.credential(allowPrompt: true)
        _ = try await session.credential(allowPrompt: false)
        _ = try await session.credential(allowPrompt: false)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertTrue(spy.calls[0].prompt)
    }

    func testConcurrentRefreshesReadCredentialOnlyOnce() async throws {
        let spy = ReaderSpy([.success(credential("placeholder"))])
        let session = ClaudeCredentialSession(reader: spy.read)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await session.credential(allowPrompt: false) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertFalse(spy.calls[0].prompt)
    }

    func testServerRejectionExcludesOldTokenAndLateFailureKeepsRenewedLogin() async throws {
        let old = credential("old-placeholder")
        let fresh = credential("fresh-placeholder")
        let spy = ReaderSpy([.success(old), .success(fresh)])
        let session = ClaudeCredentialSession(reader: spy.read)
        _ = try await session.credential(allowPrompt: true)
        await session.invalidate(rejected: old)
        let renewed = try await session.credential(allowPrompt: false)
        XCTAssertEqual(renewed.accessToken, fresh.accessToken)
        XCTAssertEqual(spy.calls[1].excluded, old.accessToken)
        XCTAssertFalse(spy.calls[1].prompt)
        await session.invalidate(rejected: old)
        let retained = try await session.credential(allowPrompt: false)
        XCTAssertEqual(retained.accessToken, fresh.accessToken)
        XCTAssertEqual(spy.calls.count, 2)
    }

    func testRejectedCredentialIsNotReusedEvenIfReaderReturnsItAgain() async throws {
        let old = credential("old-placeholder")
        let spy = ReaderSpy([.success(old), .success(old)])
        let session = ClaudeCredentialSession(reader: spy.read)
        _ = try await session.credential(allowPrompt: true)
        await session.invalidate(rejected: old)
        do {
            _ = try await session.credential(allowPrompt: false)
            XCTFail("A rejected token must not be sent again")
        } catch { XCTAssertEqual(error as? UsageError, .expiredCredential) }
        XCTAssertFalse(spy.calls[1].prompt)
    }

    func testDisconnectClearsMemoryCredential() async throws {
        let spy = ReaderSpy([.success(credential("first-placeholder")), .success(credential("second-placeholder"))])
        let session = ClaudeCredentialSession(reader: spy.read)
        _ = try await session.credential(allowPrompt: true)
        await session.clear()
        let next = try await session.credential(allowPrompt: false)
        XCTAssertEqual(next.accessToken, "second-placeholder")
        XCTAssertEqual(spy.calls.count, 2)
        XCTAssertNil(spy.calls[1].excluded)
    }

    func testRejectedTokenDoesNotMaskAnotherCredential() {
        let keychain = Data(#"{"claudeAiOauth":{"accessToken":"fresh-placeholder","expiresAt":2000000000000}}"#.utf8)
        let file = Data(#"{"claudeAiOauth":{"accessToken":"rejected-placeholder","expiresAt":2000000000000}}"#.utf8)
        let chosen = ClaudeCredential.select(keychainData: keychain, fileData: file,
            excludingToken: "rejected-placeholder", now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(chosen?.accessToken, "fresh-placeholder")
        XCTAssertNil(ClaudeCredential.select(keychainData: nil, fileData: file, excludingToken: "rejected-placeholder"))
    }

    func testSilentKeychainScopeRestoresPolicyWhenReadThrows() {
        var allowed = true
        var changes: [Bool] = []
        let gate = KeychainInteractionGate(getAllowed: { allowed }, setAllowed: { allowed = $0; changes.append($0) })
        XCTAssertThrowsError(try gate.read(allowPrompt: false) {
            XCTAssertFalse(allowed)
            throw UsageError.keychainDenied
        })
        XCTAssertTrue(allowed)
        XCTAssertEqual(changes, [false, true])
    }

    func testSilentKeychainScopePreservesPreviouslyDisabledInteraction() throws {
        var allowed = false
        let gate = KeychainInteractionGate(getAllowed: { allowed }, setAllowed: { allowed = $0 })
        try gate.read(allowPrompt: false) { XCTAssertFalse(allowed) }
        XCTAssertFalse(allowed)
    }

    func testKeychainReadDoesNotRunIfSilencingFails() {
        var didRead = false
        let gate = KeychainInteractionGate(getAllowed: { true }, setAllowed: { _ in throw UsageError.keychainDenied })
        XCTAssertThrowsError(try gate.read(allowPrompt: false) { didRead = true })
        XCTAssertFalse(didRead)
    }

    func testManualConnectionDoesNotAlterKeychainInteractionPolicy() throws {
        let gate = KeychainInteractionGate(getAllowed: { XCTFail("Unexpected read"); return false },
            setAllowed: { _ in XCTFail("Unexpected policy change") })
        var didRead = false
        try gate.read(allowPrompt: true) { didRead = true }
        XCTAssertTrue(didRead)
    }

    func testDeniedAuthorizationRequiresManualConnectionWithoutRetryDeadline() {
        let state = ProviderState(error: "denied", failure: .keychainDenied)
        XCTAssertTrue(state.requiresManualConnection)
        XCTAssertNil(state.retryAfter)
        XCTAssertFalse(ProviderState(failure: .serviceUnavailable).requiresManualConnection)
    }

    private final class ReaderSpy: @unchecked Sendable {
        private let lock = NSLock()
        private let responses: [Result<ClaudeCredential, UsageError>]
        private var recorded: [(prompt: Bool, excluded: String?)] = []
        init(_ responses: [Result<ClaudeCredential, UsageError>]) { self.responses = responses }
        var calls: [(prompt: Bool, excluded: String?)] {
            lock.lock(); defer { lock.unlock() }; return recorded
        }
        func read(_ prompt: Bool, _ excluded: String?) throws -> ClaudeCredential {
            lock.lock(); defer { lock.unlock() }
            let index = recorded.count
            recorded.append((prompt, excluded))
            guard index < responses.count else { throw UsageError.missingCredential }
            return try responses[index].get()
        }
    }
}
