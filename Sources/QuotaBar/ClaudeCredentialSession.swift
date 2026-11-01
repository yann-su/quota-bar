import Foundation
import Security
import QuotaCore

/// Keep an authorized credential only in this process, not in a second keychain
/// item or file. Serial isolation also prevents concurrent authorization reads.
actor ClaudeCredentialSession {
    typealias Reader = (Bool, String?) throws -> ClaudeCredential
    private let reader: Reader
    private var cached: ClaudeCredential?
    private var rejectedToken: String?

    init(reader: @escaping Reader = { try ClaudeCredential.read(allowPrompt: $0, excludingToken: $1) }) {
        self.reader = reader
    }

    func credential(allowPrompt: Bool) throws -> ClaudeCredential {
        if let cached { return cached }
        let credential = try reader(allowPrompt, rejectedToken)
        guard credential.accessToken != rejectedToken else { throw UsageError.expiredCredential }
        cached = credential
        return credential
    }

    func invalidate(rejected credential: ClaudeCredential) {
        // A late response from an old request must not discard a newer login.
        guard cached == nil || cached?.accessToken == credential.accessToken else { return }
        cached = nil
        rejectedToken = credential.accessToken
    }

    func clear() {
        cached = nil
        rejectedToken = nil
    }
}

/// LAContext controls the modern keychain. Claude Code's macOS credentials can
/// reside in the legacy file-based keychain, which has a separate UI policy.
/// The caller serializes this short synchronous scope; it never changes an ACL,
/// unlocks a keychain, or leaves user interaction disabled after the read.
struct KeychainInteractionGate {
    var getAllowed: () throws -> Bool
    var setAllowed: (Bool) throws -> Void

    static var system: Self {
        Self(getAllowed: {
            var allowed = DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess else { throw UsageError.keychainDenied }
            return allowed.boolValue
        }, setAllowed: { allowed in
            guard SecKeychainSetUserInteractionAllowed(allowed) == errSecSuccess else { throw UsageError.keychainDenied }
        })
    }

    func read<T>(allowPrompt: Bool, operation: () throws -> T) throws -> T {
        if allowPrompt { return try operation() }
        let previous = try getAllowed()
        try setAllowed(false)
        defer { try? setAllowed(previous) }
        return try operation()
    }
}
