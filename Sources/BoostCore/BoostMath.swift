import Foundation

/// Conversions between the user-facing boost percentage and a linear gain.
public enum BoostMath {
    /// Allowed boost range in percent (100% = unchanged, 400% = 4× / ≈ +12 dB).
    public static let range: ClosedRange<Double> = 100...400

    /// Clamps a percentage into `range`. NaN maps to the lower bound.
    public static func clampPercent(_ p: Double) -> Double {
        guard !p.isNaN else { return range.lowerBound }
        return min(max(p, range.lowerBound), range.upperBound)
    }

    /// Linear gain for a boost percentage (clamped first).
    public static func gain(forPercent p: Double) -> Float {
        Float(clampPercent(p) / 100)
    }
}
