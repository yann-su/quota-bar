import Foundation
import WidgetKit
import QuotaCore
import Security

@MainActor
final class WidgetPublisher {
    static var hasSigningTeam: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }
    private var lastReload = Date.distantPast
    private var lastDay: Date?
    func publish(report: TokenReport, quotas: [UsageSnapshot], forceReload: Bool = false) -> Bool {
        guard let directory = WidgetSharedContainer.directory else { return false }
        let snapshot = WidgetSnapshot(report: report, quotas: quotas)
        do { try WidgetSnapshotFile.write(snapshot, directory: directory) }
        catch { return false }
        // The system owns widget refresh scheduling. Keep fresh shared data, but
        // avoid spending the widget reload budget on every one-minute scan.
        let elapsed = Date().timeIntervalSince(lastReload)
        if elapsed >= 15 * 60 || (forceReload && elapsed >= 5) || lastDay != snapshot.dayStart {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedContainer.kind)
            lastReload = Date(); lastDay = snapshot.dayStart
        }
        return true
    }
}
