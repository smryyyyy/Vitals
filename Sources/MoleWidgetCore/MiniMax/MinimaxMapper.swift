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
        guard let limit, let remains = limit.remainsTime else { return nil }
        let total = max(0, Int(remains))
        if total < 60 { return "即将重置" }
        let m = (total % 3600) / 60
        let h = (total % 86400) / 3600
        let d = total / 86400
        if d > 0 { return "\(d)d \(h)h 后重置" }
        if h > 0 { return "\(h)h \(m)m 后重置" }
        return "\(m)m 后重置"
    }
}
