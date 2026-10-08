import Foundation

/// Translates the wire DTOs into a display-friendly `MinimaxSnapshot`.
/// Only the `general` bucket from `model_remains` carries the 5h + weekly
/// counters; the `video` bucket is ignored (per spec).
public enum MinimaxMapper {
    public static func snapshot(from response: MinimaxUsageResponse) -> MinimaxSnapshot {
        let general = response.modelRemains.first { $0.modelName == "general" }

        let fiveHour = general.map { model in
            MinimaxLimit(
                usedPercent: model.parsePercent(model.currentIntervalUsedPercent),
                remainsTime: model.remainsTime.map { TimeInterval($0) / 1000.0 },
                endTime: model.endTime.map { Self.date(ms: $0) }
            )
        }

        let weekly = general.map { model in
            MinimaxLimit(
                usedPercent: model.parsePercent(model.currentWeeklyUsedPercent),
                remainsTime: model.weeklyRemainsTime.map { TimeInterval($0) / 1000.0 },
                endTime: model.weeklyEndTime.map { Self.date(ms: $0) }
            )
        }

        return MinimaxSnapshot(
            fiveHour: fiveHour,
            weekly: weekly,
            fetchedAt: Date(),
            error: nil
        )
    }

    private static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    }

    /// Human-readable reset countdown for a single limit.
    /// - < 1 min        → "即将重置"
    /// - < 1 h          → "Xm 后重置"
    /// - < 24 h         → "Xh Ym 后重置"
    /// - ≥ 24 h         → "Xd Yh 后重置"
    public static func countdown(for limit: MinimaxLimit?, now: Date = Date()) -> String? {
        guard let limit, let remains = limit.remainsTime,
              let parts = split(remains) else { return nil }
        return parts.sentence
    }

    /// The same countdown without the "后重置" suffix, for the menu bar where
    /// the column is too narrow for it. Shares `split` with `countdown` so the
    /// two can never drift apart.
    /// - < 1 min → "--"
    /// - < 1 h   → "12m"
    /// - < 24 h  → "3h05"
    /// - ≥ 24 h  → "2d04"
    public static func compactCountdown(seconds: TimeInterval) -> String? {
        guard let parts = split(seconds) else { return nil }
        return parts.compact
    }

    /// Splits a remaining-seconds value into its display parts.
    /// `remainsTime` is **seconds**, not milliseconds.
    private static func split(_ seconds: TimeInterval) -> (sentence: String, compact: String)? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let total = Int(seconds)
        if total < 60 { return ("即将重置", "--") }
        let m = (total % 3600) / 60
        let h = (total % 86400) / 3600
        let d = total / 86400
        if d > 0 {
            return ("\(d)d \(h)h 后重置", "\(d)d\(padded(h))")
        }
        if h > 0 {
            return ("\(h)h \(m)m 后重置", "\(h)h\(padded(m))")
        }
        return ("\(m)m 后重置", "\(m)m")
    }

    /// Keeps the compact form's width stable so the menu bar does not resize
    /// once a minute.
    private static func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
