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

    // MARK: - 月度工作日缓存

    /// 节假日表是编译期常量,某个自然月的工作日集合也是常量,
    /// 所以按 (年, 月) 缓存成一张 32 位位图(bit 0 = 1 号,bit n = n+1 号)。
    ///
    /// 为什么需要:`isWorkday` 每次都要 `String(format:)` 拼 "yyyy-MM-dd" key,
    /// 而 `totalEarned` 会逐月调 `workdaysBetween` 逐日判断 —— 入职 10 年就是
    /// 120 个月 × 每月约 30 次格式化,而且每秒重算一次。改成按月缓存位图后,
    /// 整月查询一次位运算即可,格式化只发生在每个月的第一次访问。
    ///
    /// 用 `NSLock` 而不是 `@MainActor`:虽然现在只有 `SalaryEngine`(主线程)在用,
    /// 但表是纯数据 + 常量缓存,挪到后台队列时不需要改实现。
    private static let cacheLock = NSLock()
    private static var monthMaskCache: [Int: UInt32] = [:]

    /// 月份 key = year * 100 + month(1-based)。
    private static func monthKey(year: Int, month: Int) -> Int {
        year * 100 + month
    }

    /// 该月的工作日位图,首次访问时构建。
    private static func monthMask(year: Int, month: Int) -> UInt32 {
        let key = monthKey(year: year, month: month)
        cacheLock.lock()
        if let cached = monthMaskCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let mask = buildMonthMask(year: year, month: month)

        cacheLock.lock()
        monthMaskCache[key] = mask
        cacheLock.unlock()
        return mask
    }

    /// 逐日判定一次,把结果压进位图。只在每个月的第一次访问时执行。
    private static func buildMonthMask(year: Int, month: Int) -> UInt32 {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return 0 }
        var mask: UInt32 = 0
        var d = start
        var day = 1
        while d < end {
            if isWorkday(d) { mask |= (1 << UInt32(day - 1)) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
            day += 1
        }
        return mask
    }

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

    /// 统计 [from, to) 之间(不含尾)的工作日数。
    ///
    /// 两端先对齐到当天 0 点再按月走位图:调用方传入的 `from` 常常带时分
    /// (比如入职日期的当天 19:00),旧实现靠「每次 +1 天」把时分原样带着走,
    /// 对齐到 0 点后结果完全一致,但不用逐日拼 key。
    public static func workdaysBetween(from: Date, to: Date) -> Int {
        let fromDay = calendar.startOfDay(for: from)
        let toDay = calendar.startOfDay(for: to)
        guard fromDay < toDay else { return 0 }

        var count = 0
        var cursor = fromDay
        while cursor < toDay {
            let y = calendar.component(.year, from: cursor)
            let m = calendar.component(.month, from: cursor)
            let mask = monthMask(year: y, month: m)
            guard mask != 0 else {
                guard let next = calendar.date(byAdding: .month, value: 1,
                                               to: calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)) ?? cursor) else { break }
                cursor = next
                continue
            }

            let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)) ?? cursor
            let firstDay = calendar.component(.day, from: cursor)              // 起始日(可能是月中)
            let spanStart = firstDay - 1                                       // 位下标(0-based)
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 0
            // 月末必须从「月初」加一个月:5/31 + 1 month 会被 Foundation 截断成 6/30,
            // 那会让整月区间全部算错。
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart

            // 本月覆盖到哪天:
            // - monthEnd <= toDay:整个月都在区间内(注意 to 恰好是下个月 1 号时也走这里)
            // - 否则区间在月中结束,末尾当天不含 → 排他上界 = toDay 的日 - 1
            let spanEndExclusive = monthEnd <= toDay
                ? daysInMonth
                : calendar.component(.day, from: toDay) - 1
            if spanEndExclusive > spanStart {
                // 取出 [spanStart, spanEndExclusive) 这段位,数 1 的个数(月最多 31 天,不会溢出)
                let width = spanEndExclusive - spanStart
                let slice = mask >> UInt32(spanStart)
                count += (slice & ((1 << UInt32(width)) - 1)).nonzeroBitCount
            }

            guard monthEnd < toDay else { break }
            cursor = monthEnd
        }
        return count
    }

    /// 某年某月(1-based month)的工作日数
    public static func monthWorkdays(year: Int, month: Int) -> Int {
        monthMask(year: year, month: month).nonzeroBitCount
    }

    /// 节假日表是否已过期(now 年份 > lastUpdatedYear)
    public static func isTableExpired(_ now: Date) -> Bool {
        let nowYear = calendar.component(.year, from: now)
        return nowYear > lastUpdatedYear
    }
}
