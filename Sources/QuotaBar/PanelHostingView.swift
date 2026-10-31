import AppKit
import SwiftUI

/// SwiftUI's HostingScrollView can recreate legacy scrollers when macOS is set
/// to Always show scroll bars. Enforce the panel's policy on the mounted native
/// hierarchy, after SwiftUI has finished each layout pass.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeScrollIndicators(in: self)
    }

    override func layout() {
        super.layout()
        removeScrollIndicators(in: self)
    }

    private func removeScrollIndicators(in view: NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
            if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
            if scroll.verticalScroller != nil { scroll.verticalScroller = nil }
            if scroll.horizontalScroller != nil { scroll.horizontalScroller = nil }
        }
        view.subviews.forEach { removeScrollIndicators(in: $0) }
    }
}
