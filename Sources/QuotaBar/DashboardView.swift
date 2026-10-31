import SwiftUI
import Charts
import QuotaCore

private enum Palette {
    static let claude = Color(red: 0.78, green: 0.43, blue: 0.29)
    static let codex = Color(red: 0.24, green: 0.52, blue: 0.43)
    static func tint(_ provider: Provider) -> Color { provider == .claude ? claude : codex }
}

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    var isPinned: Bool
    var togglePin: () -> Void
    @State private var showingSettings = false
    @State private var showingTokens = true

    var body: some View {
        VStack(spacing: 0) {
            header
            if !showingSettings {
                Picker("查看内容", selection: $showingTokens) {
                    Text("Token 用量").tag(true)
                    Text("订阅额度").tag(false)
                }.pickerStyle(.segmented).controlSize(.small).labelsHidden().padding(.horizontal, 14)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.isDemo {
                        Label("演示模式 · 以下为示例数据", systemImage: "play.rectangle")
                            .font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity)
                    }
                    if showingSettings { settings }
                    else if showingTokens { TokenDashboard(store: store) }
                    else {
                        HStack {
                            Text("额度总览").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("百分比为当前窗口额度").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        ForEach(Provider.allCases) { provider in ProviderCard(provider: provider, store: store) }
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text("额度以服务商返回值为准。重置后会重新查询；本地趋势从首次连接开始记录。")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(.horizontal, 3)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.widgetOpenRequest) { _, _ in showingSettings = false; showingTokens = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 30, height: 30)
            Text("QuotaBar").font(.system(size: 15, weight: .bold, design: .rounded))
            Spacer()
            Button(action: togglePin) { Image(systemName: isPinned ? "pin.fill" : "pin") }
                .help(isPinned ? "取消固定" : "固定悬浮窗").tint(isPinned ? Palette.codex : .secondary)
            Button { showingSettings.toggle() } label: { Image(systemName: showingSettings ? "xmark" : "gearshape") }
                .help(showingSettings ? "返回总览" : "设置")
        }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 5) {
                Circle().fill(activeRefreshing ? Color.orange : Palette.codex).frame(width: 5, height: 5)
                Text(activeRefreshing ? "正在更新…" : showingTokens ? "Token 每分钟更新" : "每 \(store.refreshMinutes) 分钟刷新")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                if showingTokens { store.refreshTokens(force: true) } else { store.refreshAll(force: true) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise").font(.system(size: 10, weight: .medium))
            }.disabled(activeRefreshing || store.isDemo).keyboardShortcut("r", modifiers: .command)
            Menu {
                Button("查看 Claude 用量") { NSWorkspace.shared.open(Provider.claude.usageURL) }
                Button("查看 Codex 用量") { NSWorkspace.shared.open(Provider.codex.usageURL) }
                Divider()
                Button("导出历史 CSV…") { store.exportHistory() }
                Button("导出 Token CSV…") { store.exportTokens() }.disabled(store.tokenReport == nil)
                Divider()
                Button("退出 QuotaBar") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }.buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
            .background(.quaternary.opacity(0.4))
    }

    private var activeRefreshing: Bool { showingTokens ? store.tokensRefreshing : store.isRefreshing }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("偏好设置").font(.title3.bold())
            VStack(alignment: .leading, spacing: 12) {
                Picker("自动刷新", selection: $store.refreshMinutes) {
                    Text("1 分钟").tag(1); Text("5 分钟").tag(5); Text("15 分钟").tag(15)
                }
                Toggle("菜单栏显示剩余百分比", isOn: $store.showPercentInMenu)
                Toggle("登录时启动", isOn: Binding(get: { store.launchAtLogin }, set: store.toggleLaunchAtLogin))
                    .disabled(store.isDemo)
            }.font(.system(size: 12))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude 连接").font(.system(size: 12, weight: .semibold))
                Text("复用 Claude Code 的订阅登录。首次连接可能请求钥匙串权限。仅安装 Claude 桌面版时，请先安装 Claude Code 并登录。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Button(store.claudeEnabled ? "暂停 Claude 额度查询" : "连接 Claude") {
                    if store.claudeEnabled { store.disconnectClaude() } else { store.connectClaude() }
                }.disabled(store.isDemo)
                Button("修复 Claude 登录…") { store.repairClaudeLogin() }.disabled(store.isDemo)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Codex CLI 路径（可选）").font(.system(size: 12, weight: .semibold))
                TextField("自动查找，例如 /opt/homebrew/bin/codex", text: $store.codexPath)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                Text("复用 codex login。API key 账号没有订阅额度窗口。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("桌面小组件").font(.system(size: 12, weight: .semibold))
                Text("右键桌面 → 编辑小组件 → 搜索 QuotaBar。选择今日、近 7 天或近 30 天，支持小、中、大、超大四种尺寸；大号看板含总量、输入／输出、费用与趋势。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(store.widgetStatus ?? "正在准备统计摘要…")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button("同步统计摘要") { store.publishWidget(forceReload: true) }.disabled(store.isDemo || store.tokenReport == nil)
                Text("保持 QuotaBar 在菜单栏运行以更新统计。小组件仅显示本机记录，系统可能延后刷新。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("本地数据").font(.system(size: 12, weight: .semibold))
                Text("Token 来自本机会话日志，仅提取用量元数据，不保存或上传对话。额度快照保留 30 天。清除历史只删除额度快照，不删除原始会话日志。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button("导出 CSV…") { store.exportHistory() }
                    Button("导出 Token…") { store.exportTokens() }
                    Button("清除历史", role: .destructive) { store.clearHistory() }
                }
            }
            if let message = store.settingsMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("QuotaBar 0.12.2 · macOS 原生").font(.system(size: 10)).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderCard: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    @State private var expanded = false
    private var state: ProviderState { store.state(provider) }
    private var tint: Color { Palette.tint(provider) }
    private var stale: Bool { store.isStale(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 9) {
                Text(provider == .claude ? "✳" : ">_")
                    .font(.system(size: provider == .claude ? 24 : 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tint).frame(width: 33, height: 33)
                    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(.system(size: 16, weight: .semibold))
                    if let plan = state.snapshot?.plan { Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer()
                if state.isRefreshing { ProgressView().controlSize(.small) }
                else {
                    HStack(spacing: 4) {
                        Circle().fill(state.snapshot == nil || stale ? Color.orange : tint).frame(width: 5, height: 5)
                        Text(state.snapshot == nil ? "待连接" : stale ? "待更新" : "已同步")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Button { NSWorkspace.shared.open(provider.usageURL) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(.secondary).help("打开官方用量页面")
            }

            if let snapshot = state.snapshot {
                let visibleWindows = expanded ? snapshot.windows : Array(snapshot.windows.prefix(2))
                ForEach(visibleWindows) { window in
                    QuotaRow(window: window, now: store.now, tint: tint, stale: stale)
                }
                if snapshot.windows.count > 2 {
                    Button(expanded ? "收起模型额度" : "显示另外 \(snapshot.windows.count - 2) 项额度") { expanded.toggle() }
                        .font(.system(size: 10)).buttonStyle(.borderless)
                }
                if let error = state.error { errorMessage(error) }
                else if stale { Text("上次查询结果已过期，请刷新获取当前额度。")
                    .font(.system(size: 10)).foregroundStyle(.orange) }
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("更新于 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        Text(snapshot.source)
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    UsageSparkline(provider: provider, store: store, tint: tint)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(provider == .claude ? "连接一次，随时查看" : "读取本机 Codex 登录")
                        .font(.system(size: 13, weight: .medium))
                    Text(provider == .claude ? "使用 Claude Code 中已登录的订阅账号。" : "自动查找 Codex CLI，获取当前账号额度。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let error = state.error { errorMessage(error) }
                    Button(provider == .claude ? "连接 Claude" : "重新检测") {
                        if provider == .claude { store.connectClaude() } else { store.refresh(.codex, force: true) }
                    }.buttonStyle(.borderedProminent).tint(tint).controlSize(.small)
                        .disabled(state.isRefreshing || store.isDemo || state.mustWaitBeforeRetry(at: store.now, forced: true))
                }.padding(.vertical, 5)
            }
            if provider == .claude, state.failure == .expiredCredential || state.failure == .missingCredential {
                Button("修复 Claude 登录…") { store.repairClaudeLogin() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let retry = state.retryAfter, retry.timeIntervalSince(store.now) > 0 {
                Text("自动重试不早于 \(retry.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }.padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(tint.opacity(0.14), lineWidth: 1))
    }

    private func errorMessage(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow
    let now: Date
    let tint: Color
    let stale: Bool
    private var color: Color { window.usedPercent >= 95 ? .red : window.usedPercent >= 80 ? .orange : tint }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(window.remainingPercent.rounded(.down)))%")
                    .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(stale ? Color.secondary : color)
                Text(stale ? "上次剩余" : "剩余").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.10))
                    Capsule().fill(stale ? Color.gray.opacity(0.4) : color)
                        .frame(width: max(0, proxy.size.width * window.usedPercent / 100))
                }
            }.frame(height: 5)
            HStack {
                Text("已用 \(window.usedPercent, specifier: "%.0f")%")
                Spacer()
                Text(resetDescription)
                    .help(window.resetsAt.map { $0.formatted(date: .complete, time: .shortened) } ?? "服务商未返回重置时间")
            }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.title)，\(stale ? "上次" : "")剩余百分之\(Int(window.remainingPercent))，\(resetDescription)")
    }
    private var resetDescription: String {
        guard let reset = window.resetsAt else { return "未提供重置时间" }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "窗口已到期 · 等待刷新" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时后重置" }
        if minutes >= 60 { return "\(minutes / 60) 小时 \(minutes % 60) 分钟后重置" }
        return "\(minutes) 分钟后重置"
    }
}

private struct UsageSparkline: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    let tint: Color
    private var samples: [UsageSnapshot] {
        store.archive.snapshots.filter { $0.provider == provider && store.now.timeIntervalSince($0.fetchedAt) < 86400 }
            .sorted { $0.fetchedAt < $1.fetchedAt }
    }
    var body: some View {
        if samples.count >= 2 {
            VStack(alignment: .trailing, spacing: 3) {
                Chart(Array(samples.enumerated()), id: \.offset) { entry in
                    if let window = entry.element.windows.first {
                        // Separate cycles so reset boundaries aren't drawn as consumption.
                        LineMark(x: .value("时间", entry.element.fetchedAt), y: .value("已用", window.usedPercent),
                            series: .value("窗口", window.resetsAt?.timeIntervalSince1970 ?? 0))
                            .foregroundStyle(tint.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }.chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...100)
                    .frame(width: 80, height: 22)
                Text("24h · 首个窗口已用").font(.system(size: 8)).foregroundStyle(.tertiary)
            }.accessibilityLabel("最近二十四小时用量趋势")
        }
    }
}
