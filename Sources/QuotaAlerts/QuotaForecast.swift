import Foundation

/// Estimates how long a quota window will last from two remaining-% samples.
///
/// A reset (remaining went up), noise, or a window that is already empty produces `nil`.
public enum QuotaForecast {
    public static func minutesRemaining(from previous: Double, at previousAt: TimeInterval, to current: Double, at currentAt: TimeInterval) -> Int? {
        let dt = currentAt - previousAt
        guard dt >= 90, previous.isFinite, current.isFinite, current > 0.5 else { return nil }
        let burned = previous - current
        guard burned >= 0.5 else { return nil }
        let seconds = current / (burned / dt)
        guard seconds.isFinite, seconds >= 120, seconds <= 36 * 3600 else { return nil }
        return max(1, Int((seconds / 60.0).rounded()))
    }

    public static func phrase(_ minutes: Int) -> String {
        if minutes < 60 { return "хватит ~\(minutes) мин" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "хватит ~\(hours) ч" }
        return "хватит ~\(hours) ч \(rest) мин"
    }
}
