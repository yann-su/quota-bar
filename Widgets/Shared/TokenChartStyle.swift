import AppKit
import SwiftUI
import QuotaCore

/// Shared chart presentation; stored counts and chart domains remain unchanged.
enum TokenChartStyle {
    static var axisColor: Color { Color(nsColor: .labelColor).opacity(0.75) }
    static var gridColor: Color { Color(nsColor: .labelColor).opacity(0.14) }

    static func color(_ provider: Provider) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if provider == .claude {
                return dark ? NSColor(srgbRed: 0.96, green: 0.59, blue: 0.40, alpha: 1)
                    : NSColor(srgbRed: 0.70, green: 0.28, blue: 0.13, alpha: 1)
            }
            return dark ? NSColor(srgbRed: 0.32, green: 0.81, blue: 0.70, alpha: 1)
                : NSColor(srgbRed: 0.03, green: 0.46, blue: 0.36, alpha: 1)
        })
    }

    static func stroke(_ provider: Provider, width: CGFloat = 2.5) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round,
                    dash: provider == .codex ? [5, 3] : [])
    }

    static func label(_ amount: Int64) -> String {
        let display = TokenDisplayValue.format(amount)
        var number = display.number
        if number.contains(".") {
            while number.hasSuffix("0") { number.removeLast() }
            if number.hasSuffix(".") { number.removeLast() }
        }
        return display.unit.isEmpty ? number : "\(number) \(display.unit)"
    }

    static func axisLabel(_ amount: Double) -> String {
        guard amount.isFinite else { return "—" }
        return label(amount >= Double(Int64.max) ? Int64.max : Int64(max(0, amount)))
    }
}

struct TokenSeriesSwatch: View {
    let provider: Provider
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 3))
            path.addLine(to: CGPoint(x: 17, y: 3))
        }.stroke(TokenChartStyle.color(provider), style: TokenChartStyle.stroke(provider, width: 2.5))
            .frame(width: 18, height: 6).accessibilityHidden(true)
    }
}
