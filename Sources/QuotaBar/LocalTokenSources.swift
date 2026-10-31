import Foundation
import QuotaCore

enum LocalTokenSources {
    static var roots: [Provider: [URL]] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let claude = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? home.appendingPathComponent(".claude")
        let codex = environment["CODEX_HOME"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? home.appendingPathComponent(".codex")
        return [.claude: [claude.appendingPathComponent("projects")],
                .codex: [codex.appendingPathComponent("sessions"), codex.appendingPathComponent("archived_sessions")]]
    }
}
