import AppKit
import Combine
import QuotaCore
import ServiceManagement
import UniformTypeIdentifiers

struct ProviderState {
    var snapshot: UsageSnapshot?
    var error: String?
    var isRefreshing = false
    var retryAfter: Date?
    var failure: UsageError?

    func mustWaitBeforeRetry(at now: Date, forced: Bool) -> Bool {
        guard let retryAfter, retryAfter.timeIntervalSince(now) > 0 else { return false }
        if case .rateLimited = failure { return true }
        return !forced
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var states: [Provider: ProviderState] = [:]
    @Published var archive = SnapshotArchive()
    @Published var now = Date()
    @Published var tokenReport: TokenReport?
    @Published var tokensRefreshing = false
    @Published var widgetStatus: String?
    @Published var selectedTokenPeriod: TokenPeriod = .sevenDays
    @Published var widgetOpenRequest = UUID()
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    @Published var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: "claudeEnabled") } }
    @Published var codexPath: String { didSet { defaults.set(codexPath, forKey: "codexPath") } }
    @Published var showPercentInMenu: Bool { didSet { defaults.set(showPercentInMenu, forKey: "showPercentInMenu") } }
    @Published var launchAtLogin = false
    @Published var settingsMessage: String?
    let isDemo: Bool
    private let defaults: UserDefaults
    private var timer: AnyCancellable?
    private var wakeObserver: AnyCancellable?
    private var lastAttempts: [Provider: Date] = [:]
    private var failures: [Provider: Int] = [:]
    private let tokenScanner = LocalTokenScanner(roots: LocalTokenSources.roots)
    private var lastTokenScan = Date.distantPast
    private lazy var widgetPublisher = WidgetPublisher()
    private let storageURL: URL

    init(demo: Bool = false) {
        isDemo = demo
        defaults = demo ? UserDefaults(suiteName: "dev.quotabar.demo")! : .standard
        let minutes = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = [1, 5, 15].contains(minutes) ? minutes : 5
        claudeEnabled = defaults.bool(forKey: "claudeEnabled")
        codexPath = defaults.string(forKey: "codexPath") ?? ""
        showPercentInMenu = defaults.object(forKey: "showPercentInMenu") as? Bool ?? true
        storageURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaBar/usage-history.json")
        if demo { seedDemo() }
        else {
            if let data = try? Data(contentsOf: storageURL), let saved = try? JSONDecoder().decode(SnapshotArchive.self, from: data) {
                archive = saved
                for provider in Provider.allCases { states[provider] = ProviderState(snapshot: saved.latest(provider)) }
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }; self.now = date
            self.refreshAll()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.refreshAll() }
        }
        if !demo { refreshAll() }
    }

    var maxAge: TimeInterval { TimeInterval(refreshMinutes * 120 + 30) }
    var menuText: String {
        guard showPercentInMenu else { return "" }
        return Provider.allCases.map { provider in
            let state = states[provider]
            let value = state?.error == nil && (provider != .claude || claudeEnabled || isDemo)
                ? state?.snapshot?.availablePercent(at: now, maxAge: maxAge) : nil
            return "\(provider == .claude ? "CL" : "CX") \(value.map { "\($0)%" } ?? "—")"
        }.joined(separator: "  ")
    }
    var isRefreshing: Bool { tokensRefreshing || states.values.contains { $0.isRefreshing } }
    func state(_ provider: Provider) -> ProviderState { states[provider] ?? ProviderState() }
    func isStale(_ provider: Provider) -> Bool {
        let state = state(provider)
        return state.error != nil || state.snapshot?.isStale(at: now, maxAge: maxAge) == true || (provider == .claude && !claudeEnabled && !isDemo)
    }
    func refreshAll(force: Bool = false) {
        guard !isDemo else { return }
        refreshTokens(force: force)
        for provider in Provider.allCases where provider != .claude || claudeEnabled { refresh(provider, force: force) }
    }
    func refreshTokens(force: Bool = false) {
        guard !isDemo, !tokensRefreshing, Date().timeIntervalSince(lastTokenScan) >= (force ? 2 : 60) else { return }
        lastTokenScan = Date()
        tokensRefreshing = true
        Task {
            tokenReport = await tokenScanner.scan()
            tokensRefreshing = false
            publishWidget()
        }
    }
    func publishWidget(forceReload: Bool = false) {
        guard !isDemo, let report = tokenReport else { return }
        let quotas = Provider.allCases.compactMap { provider -> UsageSnapshot? in
            guard !isStale(provider) else { return nil }; return state(provider).snapshot
        }
        let published = widgetPublisher.publish(report: report, quotas: quotas, forceReload: forceReload)
        widgetStatus = published ? widgetPublisher.status : "请安装包含原生小组件的版本。"
    }
    func exportTokens() {
        guard let tokenReport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QuotaBar-tokens.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try tokenReport.csv.write(to: url, atomically: true, encoding: .utf8) }
        catch { settingsMessage = "Token 导出失败，请选择可写入的位置。" }
    }
    func connectClaude() {
        claudeEnabled = true
        if case .rateLimited = state(.claude).failure {} else { lastAttempts[.claude] = nil }
        refresh(.claude, force: true, allowPrompt: true)
    }
    func repairClaudeLogin() {
        guard !isDemo, let script = Bundle.main.url(forResource: "RepairClaude", withExtension: "command") else {
            settingsMessage = "请在终端运行 claude --safe-mode /usage，等待额度出现后回到这里刷新。"
            return
        }
        NSWorkspace.shared.open(script)
        settingsMessage = "已打开 Claude 官方用量面板。等待额度出现后，回到这里点击「连接 Claude」或「刷新」。"
    }
    func disconnectClaude() {
        claudeEnabled = false
        states[.claude]?.error = "已暂停读取。点击连接可恢复。"
    }

    func refresh(_ provider: Provider, force: Bool = false, allowPrompt: Bool = false) {
        guard !isDemo, !state(provider).isRefreshing else { return }
        let current = Date()
        if state(provider).mustWaitBeforeRetry(at: current, forced: force) { return }
        let elapsed = current.timeIntervalSince(lastAttempts[provider] ?? .distantPast)
        guard elapsed >= (force ? 10 : TimeInterval(refreshMinutes * 60)) else { return }
        lastAttempts[provider] = current
        states[provider, default: ProviderState()].isRefreshing = true
        let customPath = codexPath
        Task {
            do {
                let snapshot: UsageSnapshot
                switch provider {
                case .codex:
                    snapshot = try await Task.detached {
                        guard let executable = ExecutableLocator.codex(customPath: customPath) else { throw UsageError.missingCLI }
                        return try CodexRPC().fetch(executable: executable)
                    }.value
                case .claude: snapshot = try await ClaudeClient.fetch(allowPrompt: allowPrompt)
                }
                // A disconnect while a request is in flight must take effect immediately.
                if provider == .claude && !claudeEnabled { states[provider]?.isRefreshing = false; return }
                states[provider] = ProviderState(snapshot: snapshot)
                failures[provider] = 0
                archive.append(snapshot)
                persist()
                publishWidget()
            } catch {
                states[provider, default: ProviderState()].isRefreshing = false
                states[provider]?.error = (error as? UsageError)?.localizedDescription ?? "无法读取额度，请稍后重试。"
                states[provider]?.failure = error as? UsageError
                let count = min(6, (failures[provider] ?? 0) + 1)
                failures[provider] = count
                if case UsageError.rateLimited(let date) = error { states[provider]?.retryAfter = date }
                else { states[provider]?.retryAfter = Date().addingTimeInterval(min(900, 15 * pow(2, Double(count - 1)))) }
            }
        }
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        guard !isDemo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 通用 → 登录项中允许 QuotaBar。" : nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            settingsMessage = "设置失败。请先将 QuotaBar 移到「应用程序」，再启用开机启动。"
        }
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "QuotaBar-usage.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let formatter = ISO8601DateFormatter()
        var lines = ["provider,fetched_at,window_id,used_percent,remaining_percent,resets_at"]
        for snapshot in archive.snapshots {
            for window in snapshot.windows {
                let values = [snapshot.provider.rawValue, formatter.string(from: snapshot.fetchedAt), window.id,
                    String(window.usedPercent), String(window.remainingPercent), window.resetsAt.map(formatter.string) ?? ""]
                lines.append(values.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ","))
            }
        }
        do { try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { settingsMessage = "导出失败，请选择可写入的位置。" }
    }

    func clearHistory() {
        archive = SnapshotArchive()
        // Keep live cards in memory; remove persisted history.
        guard !isDemo else { return }
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) { try FileManager.default.removeItem(at: storageURL) }
            settingsMessage = "已清除本地历史。之后成功刷新会重新记录。"
        } catch { settingsMessage = "未能清除本地历史，请检查文件权限。" }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(archive)
            try data.write(to: storageURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        } catch { settingsMessage = "本地快照保存失败，当前额度仍可查看。" }
    }

    private func seedDemo() {
        claudeEnabled = true
        let current = Date()
        now = current
        for index in 0..<25 {
            let time = current.addingTimeInterval(Double(index - 24) * 3600)
            let snapshots = [
                UsageSnapshot(provider: .claude, fetchedAt: time, plan: "Max", windows: [
                    QuotaWindow(id: "five_hour", title: "5 小时", usedPercent: index == 24 ? 36 : Double((index * 7) % 78), resetsAt: current.addingTimeInterval(7380), durationMinutes: 300),
                    QuotaWindow(id: "seven_day", title: "每周 · 全部模型", usedPercent: Double(18 + index), resetsAt: current.addingTimeInterval(258000), durationMinutes: 10080)
                ], source: "演示数据"),
                UsageSnapshot(provider: .codex, fetchedAt: time, plan: "Pro", windows: [
                    QuotaWindow(id: "codex.primary", title: "5 小时", usedPercent: Double(8 + index), resetsAt: current.addingTimeInterval(12540), durationMinutes: 300),
                    QuotaWindow(id: "codex.secondary", title: "每周", usedPercent: Double(54 + index), resetsAt: current.addingTimeInterval(154800), durationMinutes: 10080)
                ], source: "演示数据")
            ]
            for snapshot in snapshots { archive.append(snapshot); states[snapshot.provider] = ProviderState(snapshot: snapshot) }
        }
        var demoRecords: [TokenRecord] = []
        for day in 0..<7 {
            for provider in Provider.allCases {
                demoRecords.append(TokenRecord(id: "demo-\(provider)-\(day)", provider: provider,
                    timestamp: current.addingTimeInterval(Double(-day) * 86400),
                    model: provider == .claude ? "claude-opus-5-5" : "gpt-6.1-sol",
                    counts: TokenCounts(input: Int64(14000 + day * 1200), output: Int64(6300 + day * 400),
                        cacheRead: Int64(148000 + day * 4100), cacheWrite: provider == .claude ? 18500 : 0)))
            }
        }
        var found = TokenCoverage(); found.directoryFound = true; found.files = 12
        tokenReport = TokenReport(records: demoRecords, coverage: [.claude: found, .codex: found])
    }
}
