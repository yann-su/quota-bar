import Foundation

/// Compact presentation only. Stored counts and CSV exports remain exact.
public struct TokenDisplayValue: Equatable, Sendable {
    public var number: String
    public var unit: String
    public var text: String { unit.isEmpty ? number : "\(number) \(unit)" }

    public static func format(_ amount: Int64) -> Self {
        let value = max(0, amount)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        if value < 10_000 {
            formatter.maximumFractionDigits = 0
            return Self(number: formatter.string(from: NSNumber(value: value)) ?? String(value), unit: "")
        }
        let units: [(Int64, String)] = [(10_000, "万"), (100_000_000, "亿"), (1_000_000_000_000, "万亿")]
        var index = units.lastIndex(where: { value >= $0.0 }) ?? 0
        var scaled = Decimal(value) / Decimal(units[index].0)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 2, .plain)
        if rounded >= 10_000, index + 1 < units.count {
            index += 1
            scaled = Decimal(value) / Decimal(units[index].0)
            NSDecimalRound(&rounded, &scaled, 2, .plain)
        }
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return Self(number: formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "0.00", unit: units[index].1)
    }
}
