import Foundation

/// 国务院办公厅发布的年度法定节假日 + 调休表,内嵌硬编码,覆盖 2024-2026。
/// 数据源:
///   - 2024: 国办发明电〔2023〕7 号
///   - 2025: 国办发明电〔2024〕号
///   - 2026: 国办发明电〔2025〕7 号
public enum WorkdayKind {
    /// 法定节假日(休息)
    case legalHoliday
    /// 调休工作日(原本是周末但要上班)
    case makeupWorkday
}

/// 简单的中国法定工作日查询。
/// 已知局限:本表只覆盖 2024-2026,超过 `lastUpdatedYear` 后 `isTableExpired` 返回 true,
/// 方便上层提示用户升级。
public enum ChineseWorkdayCalendar {
    /// 表最后覆盖到哪一年
    public static let lastUpdatedYear: Int = 2026

    private static let table: [String: WorkdayKind] = {
        var t: [String: WorkdayKind] = [:]
        // ===== 2024 =====
        t["2024-01-01"] = .legalHoliday
        t["2024-02-04"] = .makeupWorkday
        t["2024-02-10"] = .legalHoliday
        t["2024-02-11"] = .legalHoliday
        t["2024-02-12"] = .legalHoliday
        t["2024-02-13"] = .legalHoliday
        t["2024-02-14"] = .legalHoliday
        t["2024-02-15"] = .legalHoliday
        t["2024-02-16"] = .legalHoliday
        t["2024-02-17"] = .legalHoliday
        t["2024-02-18"] = .makeupWorkday
        t["2024-04-04"] = .legalHoliday
        t["2024-04-05"] = .legalHoliday
        t["2024-04-06"] = .legalHoliday
        t["2024-04-07"] = .makeupWorkday
        t["2024-04-28"] = .makeupWorkday
        t["2024-05-01"] = .legalHoliday
        t["2024-05-02"] = .legalHoliday
        t["2024-05-03"] = .legalHoliday
        t["2024-05-04"] = .legalHoliday
        t["2024-05-05"] = .legalHoliday
        t["2024-05-11"] = .makeupWorkday
        t["2024-06-10"] = .legalHoliday
        t["2024-09-14"] = .makeupWorkday
        t["2024-09-15"] = .legalHoliday
        t["2024-09-16"] = .legalHoliday
        t["2024-09-17"] = .legalHoliday
        t["2024-09-29"] = .makeupWorkday
        t["2024-10-01"] = .legalHoliday
        t["2024-10-02"] = .legalHoliday
        t["2024-10-03"] = .legalHoliday
        t["2024-10-04"] = .legalHoliday
        t["2024-10-05"] = .legalHoliday
        t["2024-10-06"] = .legalHoliday
        t["2024-10-07"] = .legalHoliday
        t["2024-10-12"] = .makeupWorkday
        // ===== 2025 =====
        t["2025-01-01"] = .legalHoliday
        t["2025-01-26"] = .makeupWorkday
        t["2025-01-28"] = .legalHoliday
        t["2025-01-29"] = .legalHoliday
        t["2025-01-30"] = .legalHoliday
        t["2025-01-31"] = .legalHoliday
        t["2025-02-01"] = .legalHoliday
        t["2025-02-02"] = .legalHoliday
        t["2025-02-03"] = .legalHoliday
        t["2025-02-04"] = .legalHoliday
        t["2025-02-08"] = .makeupWorkday
        t["2025-04-04"] = .legalHoliday
        t["2025-04-05"] = .legalHoliday
        t["2025-04-06"] = .legalHoliday
        t["2025-04-27"] = .makeupWorkday
        t["2025-05-01"] = .legalHoliday
        t["2025-05-02"] = .legalHoliday
        t["2025-05-03"] = .legalHoliday
        t["2025-05-04"] = .legalHoliday
        t["2025-05-05"] = .legalHoliday
        t["2025-05-31"] = .legalHoliday
        t["2025-06-01"] = .legalHoliday
        t["2025-06-02"] = .legalHoliday
        t["2025-09-28"] = .makeupWorkday
        t["2025-10-01"] = .legalHoliday
        t["2025-10-02"] = .legalHoliday
        t["2025-10-03"] = .legalHoliday
        t["2025-10-04"] = .legalHoliday
        t["2025-10-05"] = .legalHoliday
        t["2025-10-06"] = .legalHoliday
        t["2025-10-07"] = .legalHoliday
        t["2025-10-08"] = .legalHoliday
        t["2025-10-11"] = .makeupWorkday
        // ===== 2026 =====
        t["2026-01-01"] = .legalHoliday
        t["2026-01-02"] = .legalHoliday
        t["2026-01-03"] = .legalHoliday
        t["2026-01-04"] = .makeupWorkday
        t["2026-02-14"] = .makeupWorkday
        t["2026-02-15"] = .legalHoliday
        t["2026-02-16"] = .legalHoliday
        t["2026-02-17"] = .legalHoliday
        t["2026-02-18"] = .legalHoliday
        t["2026-02-19"] = .legalHoliday
        t["2026-02-20"] = .legalHoliday
        t["2026-02-21"] = .legalHoliday
        t["2026-02-22"] = .legalHoliday
        t["2026-02-23"] = .legalHoliday
        t["2026-02-28"] = .makeupWorkday
        t["2026-04-04"] = .legalHoliday
        t["2026-04-05"] = .legalHoliday
        t["2026-04-06"] = .legalHoliday
        t["2026-05-01"] = .legalHoliday
        t["2026-05-02"] = .legalHoliday
        t["2026-05-03"] = .legalHoliday
        t["2026-05-04"] = .legalHoliday
        t["2026-05-05"] = .legalHoliday
        t["2026-05-09"] = .makeupWorkday
        t["2026-06-19"] = .legalHoliday
        t["2026-06-20"] = .legalHoliday
        t["2026-06-21"] = .legalHoliday
        t["2026-09-20"] = .makeupWorkday
        t["2026-09-25"] = .legalHoliday
        t["2026-09-26"] = .legalHoliday
        t["2026-09-27"] = .legalHoliday
        t["2026-10-01"] = .legalHoliday
        t["2026-10-02"] = .legalHoliday
        t["2026-10-03"] = .legalHoliday
        t["2026-10-04"] = .legalHoliday
        t["2026-10-05"] = .legalHoliday
        t["2026-10-06"] = .legalHoliday
        t["2026-10-07"] = .legalHoliday
        t["2026-10-10"] = .makeupWorkday
        return t
    }()

    /// 共享 Calendar(中国本地时区)
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = Locale(identifier: "zh_CN")
        return c
    }()

    private static func dateKey(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// 是否工作日:
    /// - 表里标 `.makeupWorkday` → 是
    /// - 表里标 `.legalHoliday`  → 否
    /// - 不在表里                → 默认周一~五是、周六日否
    public static func isWorkday(_ date: Date) -> Bool {
        let key = dateKey(date)
        if let kind = table[key] {
            return kind == .makeupWorkday
        }
        let weekday = calendar.component(.weekday, from: date)  // 1=Sun, 7=Sat
        return weekday != 1 && weekday != 7
    }

    /// 统计 [from, to) 之间(不含尾)的工作日数
    public static func workdaysBetween(from: Date, to: Date) -> Int {
        var count = 0
        var d = from
        while d < to {
            if isWorkday(d) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return count
    }

    /// 某年某月(1-based month)的工作日数
    public static func monthWorkdays(year: Int, month: Int) -> Int {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return 0 }
        return workdaysBetween(from: start, to: end)
    }

    /// 节假日表是否已过期(now 年份 > lastUpdatedYear)
    public static func isTableExpired(_ now: Date) -> Bool {
        let nowYear = calendar.component(.year, from: now)
        return nowYear > lastUpdatedYear
    }
}
