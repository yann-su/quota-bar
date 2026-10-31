import Foundation
import WidgetKit
import QuotaCore

@MainActor
final class WidgetPublisher {
    private var server: WidgetLocalServer?
    private var lastReload = Date.distantPast
    private var lastDay: Date?
    private var lastQuotaWindows: [String: QuotaProgress] = [:]
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
        let quotaWindows = Dictionary(uniqueKeysWithValues: snapshot.providers.flatMap { item in
            item.quotaWindows.map { ("\(item.provider.rawValue):\($0.windowID)", $0) }
        })
        // Refresh promptly when a quota first connects, expires, or enters a new
        // window; ordinary percentage updates still use the normal reload budget.
        let quotaWindowChanged = Set(quotaWindows.keys) != Set(lastQuotaWindows.keys) || quotaWindows.contains { provider, quota in
            lastQuotaWindows[provider]?.title != quota.title || lastQuotaWindows[provider]?.resetsAt != quota.resetsAt
        }
        lastQuotaWindows = quotaWindows
        let elapsed = Date().timeIntervalSince(lastReload)
        if elapsed >= 15 * 60 || (forceReload && elapsed >= 5) || lastDay != snapshot.dayStart || quotaWindowChanged {
            for kind in WidgetKinds.all { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            lastReload = Date(); lastDay = snapshot.dayStart
        }
        return true
    }
}
