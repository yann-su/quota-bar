import SwiftUI
import QuotaCore

/// Side-by-side windows keep both five-hour and weekly limits visible without
/// adding another row of height to a native widget.
struct QuotaWindowsView: View {
    let provider: Provider
    let progresses: [QuotaProgress]
    let date: Date
    var compact = false
    private struct Slot: Identifiable {
        let id: String
        let title: String
        let progress: QuotaProgress?
    }
    private var slots: [Slot] {
        if provider == .claude {
            return [("five_hour", "5 小时"), ("seven_day", "每周")].map { id, title in
                Slot(id: id, title: title, progress: progresses.first { $0.windowID == id })
            }
        }
        if progresses.isEmpty { return [Slot(id: "unknown", title: "订阅额度", progress: nil)] }
        return progresses.map { Slot(id: $0.windowID, title: $0.shortTitle, progress: $0) }
    }
    var body: some View {
        HStack(alignment: .top, spacing: compact ? 8 : 12) {
            ForEach(slots) { slot in
                window(slot).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    private func window(_ slot: Slot) -> some View {
        let progress = slot.progress.flatMap { $0.isCurrent(at: date) ? $0 : nil }
        let tint: Color = progress.map { $0.remainingPercent <= 10 ? .red : $0.remainingPercent <= 25 ? .orange : Color(red: 0.25, green: 0.64, blue: 0.53) } ?? .secondary
        return VStack(alignment: .leading, spacing: compact ? 2 : 3) {
            HStack(spacing: 2) {
                Text(slot.title).fontWeight(.medium).lineLimit(1).minimumScaleFactor(0.8)
                if compact {
                    Spacer(minLength: 0)
                    Text("用/余").font(.system(size: 7))
                }
            }.font(.system(size: compact ? 8 : 10)).foregroundStyle(.secondary)
            if let progress {
                Text(compact ? "\(progress.displayedUsedPercent)% / \(progress.remainingPercent)%" : "用\(progress.displayedUsedPercent)% · 余\(progress.remainingPercent)%")
                    .font(.system(size: compact ? 8 : 10)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Text("待同步").font(.system(size: compact ? 8 : 10)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.13))
                    if let progress { Capsule().fill(tint).frame(width: geometry.size.width * progress.usedFraction) }
                }
            }.frame(height: compact ? 3 : 4)
            Text(progress.map { $0.resetDescription(at: date) } ?? "暂无额度数据")
                .font(.system(size: compact ? 7 : 8)).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(progress.map { "\(slot.title)额度，已用百分之\($0.displayedUsedPercent)，剩余百分之\($0.remainingPercent)，\($0.resetDescription(at: date))" } ?? "\(slot.title)额度待同步")
    }
}
