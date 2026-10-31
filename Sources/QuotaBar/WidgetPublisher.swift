import Foundation
import WidgetKit
import QuotaCore

@MainActor
final class WidgetPublisher {
    private var server: WidgetLocalServer?
    private var lastReload = Date.distantPast
    private var lastDay: Date?
    var status: String { server?.status ?? "请安装包含原生小组件的版本。" }
    init() {
        guard let endpoint = WidgetLocalEndpoint.configured else { return }
        let server = WidgetLocalServer(endpoint: endpoint)
        do { try server.start(); self.server = server } catch { return }
    }
    func publish(report: TokenReport, quotas: [UsageSnapshot], forceReload: Bool = false) -> Bool {
        guard let server else { return false }
        let snapshot = WidgetSnapshot(report: report, quotas: quotas)
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        server.update(data)
        let elapsed = Date().timeIntervalSince(lastReload)
        if elapsed >= 15 * 60 || (forceReload && elapsed >= 5) || lastDay != snapshot.dayStart {
            for kind in WidgetKinds.all { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            lastReload = Date(); lastDay = snapshot.dayStart
        }
        return true
    }
}
