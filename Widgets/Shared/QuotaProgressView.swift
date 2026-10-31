import SwiftUI
import QuotaCore

struct QuotaProgressView: View {
    let progress: QuotaProgress?
    let date: Date
    var compact = false
    private var current: QuotaProgress? { progress.flatMap { $0.isCurrent(at: date) ? $0 : nil } }
    private var tint: Color {
        guard let current else { return .secondary }
        return current.remainingPercent <= 10 ? .red : current.remainingPercent <= 25 ? .orange : Color(red: 0.25, green: 0.64, blue: 0.53)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            HStack(spacing: 4) {
                Text(current.map { "额度 · \($0.title)" } ?? (progress == nil ? "额度待同步" : "额度已过期"))
                    .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                if let current { Text("已用 \(current.displayedUsedPercent)%").monospacedDigit() }
            }.font(.system(size: compact ? 8 : 10))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.13))
                    if let current {
                        Capsule().fill(tint).frame(width: geometry.size.width * current.usedFraction)
                    }
                }
            }.frame(height: compact ? 4 : 5)
            if let current {
                HStack(spacing: 3) {
                    Text("剩余 \(current.remainingPercent)%").foregroundStyle(tint)
                    Spacer(minLength: 0)
                    Text(current.resetDescription(at: date)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.65)
                }.font(.system(size: compact ? 8 : 9)).monospacedDigit()
            } else {
                Text("打开应用同步额度").font(.system(size: compact ? 8 : 9)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel(current.map { "当前\($0.title)额度，已用百分之\($0.displayedUsedPercent)，剩余百分之\($0.remainingPercent)，\($0.resetDescription(at: date))" } ?? "额度待同步，请打开 QuotaBar 刷新")
    }
}
