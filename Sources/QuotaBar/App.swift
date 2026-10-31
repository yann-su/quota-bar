import AppKit
import SwiftUI
import Combine
import QuotaCore

final class QuotaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
enum QuotaBarMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--running-instances") {
            for instance in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.quotabar.mac") {
                print("pid=\(instance.processIdentifier) path=\(instance.bundleURL?.path ?? "unknown") launched=\(instance.launchDate?.description ?? "unknown")")
            }
            return
        }
        if CommandLine.arguments.contains("--check-tokens") {
            Task {
                let start = Date()
                let report = await LocalTokenScanner(roots: LocalTokenSources.roots).scan()
                for provider in Provider.allCases {
                    let coverage = report.coverage[provider] ?? TokenCoverage()
                    print("\(provider.title): \(coverage.files) local log files; partial=\(coverage.isPartial)")
                    for period in TokenPeriod.allCases {
                        let counts = report.totals(provider: provider, period: period, now: report.scannedAt)
                        print("\(period.title): total=\(counts.total), input=\(counts.input), output=\(counts.output), cacheRead=\(counts.cacheRead), cacheWrite=\(counts.cacheWrite)")
                    }
                }
                print("Scan completed in \(String(format: "%.2f", Date().timeIntervalSince(start)))s; message contents not logged.")
                exit(0)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-widget") {
            Task { @MainActor in
                let report = await LocalTokenScanner(roots: LocalTokenSources.roots).scan()
                let published = WidgetPublisher().publish(report: report, quotas: []) && WidgetSharedContainer.read() != nil
                print("Host widget summary: \(published ? "written and read back" : "unavailable; check App Group and signing")")
                print("This checks host access only. Verify extension access in WidgetKit Simulator or on the desktop.")
                print("Payload: aggregate token counts and dates only; no credentials or conversations.")
                exit(published ? 0 : 1)
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-codex") {
            do {
                guard let executable = ExecutableLocator.codex(customPath: "") else { throw UsageError.missingCLI }
                let snapshot = try CodexRPC().fetch(executable: executable)
                print("Codex: connected; \(snapshot.windows.count) quota windows; no model turn started.")
                for window in snapshot.windows { print("\(window.title): \(Int(window.usedPercent))% used") }
            } catch { print("Codex: \(error.localizedDescription)"); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--check-claude") {
            Task {
                do {
                    let snapshot = try await ClaudeClient.fetch(allowPrompt: false)
                    print("Claude: connected; \(snapshot.windows.count) quota windows; credentials not logged.")
                    for window in snapshot.windows { print("\(window.title): \(Int(window.usedPercent))% used") }
                    exit(0)
                } catch { print("Claude: \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--replace") {
            for instance in NSRunningApplication.runningApplications(withBundleIdentifier: "dev.quotabar.mac")
                where instance.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                instance.terminate()
            }
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var store: UsageStore!
    private var cancellable: AnyCancellable?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pinned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        store = UsageStore(demo: demo)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "QuotaBar 额度")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Claude / Codex 剩余额度（取各窗口最低剩余）"
        }
        panel = QuotaPanel(contentRect: NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        updateContent()
        let widgetPreview = CommandLine.arguments.contains("--widget-preview-small") || CommandLine.arguments.contains("--widget-preview-medium")
        if widgetPreview {
            let small = CommandLine.arguments.contains("--widget-preview-small")
            let size = NSSize(width: small ? 170 : 360, height: 170)
            let view = WidgetPreviewView(store: store, small: small)
                .padding(16).frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 20))
            panel.setContentSize(size)
            panel.contentView = NSHostingView(rootView: view)
        }
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.statusItem.button?.title = self?.store.menuText ?? "" }
        }
        statusItem.button?.title = store.menuText
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.panel.orderOut(nil); return nil }
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.statusItem.button?.window && !self.pinned {
                self.panel.orderOut(nil)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.pinned else { return }; self.panel.orderOut(nil)
        }
        if demo || CommandLine.arguments.contains("--show") { showPanel() }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            // Render this app's own view, never capture another application's screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 1 : 3)) { [weak self] in
                self?.savePreview(path: path)
                NSApplication.shared.terminate(nil)
            }
        }
        if CommandLine.arguments.contains("--inspect-scroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.inspectScrollViews(afterScrolling: false)
            }
        }
    }

    private func updateContent() {
        let view = DashboardView(store: store, isPinned: pinned) { [weak self] in
            guard let self else { return }; self.pinned.toggle(); self.updateContent()
        }.clipShape(RoundedRectangle(cornerRadius: 18))
        panel.contentView = PanelHostingView(rootView: view)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "quotabar" && $0.host == "open" }) else { return }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "period" }?.value
        if let value, let period = WidgetPeriod(rawValue: value) { store.selectedTokenPeriod = period.tokenPeriod }
        store.widgetOpenRequest = UUID()
        showPanel()
        store.refreshTokens(force: true)
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "刷新额度", action: #selector(refresh), keyEquivalent: "r").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 QuotaBar", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }
    @objc private func refresh() { store.refreshAll(force: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.frame)
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(buttonFrame.midX - panel.frame.width / 2, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        let y = max(visible.minY + 8, buttonFrame.minY - panel.frame.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.makeKey()
        store.refreshAll()
    }

    private func savePreview(path: String) {
        guard let hosting = panel.contentView else { return }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
    }

    private func inspectScrollViews(afterScrolling: Bool) {
        var valid = true
        var count = 0
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView {
                count += 1
                print("scroll=\(type(of: scroll)) vertical=\(scroll.hasVerticalScroller) horizontal=\(scroll.hasHorizontalScroller) style=\(scroll.scrollerStyle.rawValue) viewport=\(scroll.contentView.bounds.size) document=\(scroll.documentView?.frame.size ?? .zero)")
                valid = valid && !scroll.hasVerticalScroller && !scroll.hasHorizontalScroller && scroll.verticalScroller == nil && scroll.horizontalScroller == nil
                if !afterScrolling {
                    let target = min(80, max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height))
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                    scroll.reflectScrolledClipView(scroll.contentView)
                } else { print("scrolledOffset=\(scroll.contentView.bounds.origin.y)") }
            }
            if let scroller = view as? NSScroller {
                print("scroller=\(type(of: scroller)) hidden=\(scroller.isHidden) frame=\(scroller.frame)")
            }
            view.subviews.forEach(visit)
        }
        if let view = panel.contentView { visit(view) }
        guard valid && count > 0 else { print("Native scroll inspection FAILED"); exit(1) }
        if afterScrolling {
            print("Native scroll inspection passed before and after scrolling.")
            NSApplication.shared.terminate(nil)
        } else {
            panel.contentView?.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.inspectScrollViews(afterScrolling: true) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }
}

private struct WidgetPreviewView: View {
    @ObservedObject var store: UsageStore
    var small: Bool
    var body: some View {
        WidgetContentView(snapshot: store.tokenReport.map { WidgetSnapshot(report: $0, now: store.now) },
            period: .sevenDays, date: store.now, isSmall: small, isPreview: store.isDemo)
    }
}
