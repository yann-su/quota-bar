import AppKit
import Combine
import SwiftUI
import QuotaCore

/// An ordinary, persistent AppKit panel. This is intentionally separate from
/// the WidgetKit extension: it can use live app data without an App Group.
@MainActor
final class DesktopWidgetController {
    let panel: NSPanel
    private let store: UsageStore
    private let suppressed: Bool
    private var subscription: AnyCancellable?

    init(store: UsageStore, suppressed: Bool, openDashboard: @escaping () -> Void) {
        self.store = store
        self.suppressed = suppressed
        let size = NSSize(width: store.desktopWidgetMedium ? 360 : 232, height: 210)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 80, width: size.width, height: size.height)
        panel = QuotaPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "QuotaBar 桌面浮窗"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DesktopWidgetView(store: store, openDashboard: openDashboard))
        if !store.isDemo {
            _ = panel.setFrameUsingName("QuotaBarDesktop")
            _ = panel.setFrameAutosaveName("QuotaBarDesktop")
        }
        update()
        subscription = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    private func update() {
        let size = NSSize(width: store.desktopWidgetMedium ? 360 : 232, height: 210)
        if panel.frame.size != size {
            let oldTop = panel.frame.maxY
            panel.setContentSize(size)
            if oldTop > 0 { panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: oldTop - size.height)) }
        }
        panel.level = store.desktopWidgetPinned ? .floating : .normal
        let screens = NSScreen.screens
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if !screens.contains(where: { $0.visibleFrame.intersection(panel.frame).width >= 60 && $0.visibleFrame.intersection(panel.frame).height >= 60 }) {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 80))
        } else {
            panel.setFrameOrigin(NSPoint(x: min(max(panel.frame.minX, visible.minX + 8), visible.maxX - size.width - 8),
                y: min(max(panel.frame.minY, visible.minY + 8), visible.maxY - size.height - 8)))
        }
        if store.desktopWidgetEnabled && !suppressed {
            if !panel.isVisible { panel.orderFrontRegardless() }
        } else { panel.orderOut(nil) }
    }

    func saveSnapshot(path: String) -> Data? {
        guard let view = panel.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        do { try png.write(to: URL(fileURLWithPath: path)); return png } catch { return nil }
    }
}

private struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    let openDashboard: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Button(action: openDashboard) {
                    Label("QuotaBar", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).help("打开用量明细；拖动空白处可移动浮窗")
                Spacer(minLength: 0)
                Menu {
                    Picker("统计范围", selection: $store.desktopWidgetPeriod) {
                        ForEach(WidgetPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: { Text(store.desktopWidgetPeriod.title).font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Toggle("保持置顶", isOn: $store.desktopWidgetPinned)
                    Toggle("显示输入／输出", isOn: $store.desktopWidgetShowsIO)
                    Toggle("中号趋势布局", isOn: $store.desktopWidgetMedium)
                    Divider()
                    Button("刷新本机统计") { store.refreshTokens(force: true) }.disabled(store.isDemo || store.tokensRefreshing)
                    Button("打开用量明细", action: openDashboard)
                    Divider()
                    Button("隐藏桌面浮窗") { store.desktopWidgetEnabled = false }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("浮窗设置")
            }.foregroundStyle(.secondary)
            if let snapshot = store.widgetSnapshot {
                WidgetContentView(snapshot: snapshot, period: store.desktopWidgetPeriod, date: store.now,
                    isSmall: !store.desktopWidgetMedium, isPreview: store.isDemo,
                    showsInputOutput: store.desktopWidgetShowsIO, showsHeader: false)
            } else {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在统计本机用量…").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(14)
            .frame(width: store.desktopWidgetMedium ? 360 : 232, height: 210)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.18)))
    }
}
