import Foundation

/// 纯函数式的工资计算。无副作用,便于在测试中传任意 `now` 复现。
/// 工作日判定交给 `ChineseWorkdayCalendar`(国务院节假日 + 调休表)。
public enum SalaryEngine {

    // MARK: - 主入口

    /// 给定当前时间,产出完整快照。
    public static func compute(settings: SalarySettings, now: Date = Date()) -> SalarySnapshot {
        let tableExpired = ChineseWorkdayCalendar.isTableExpired(now)

        // 1) 未配置
        guard settings.monthlyNetSalary > 0 else {
            return SalarySnapshot(
                state: .unconfigured,
                tableExpired: tableExpired,
                now: now
            )
        }

        let cal = ChineseWorkdayCalendar.calendar
        let todayStart = cal.startOfDay(for: now)

        let d = dailySalary(settings: settings, now: now)
        let h = hourlyRate(settings: settings, now: now)
        let sr = secondRate(hourly: h)
        let yEarn = yearEarned(settings: settings, now: now)
        let mEarn = monthEarned(settings: settings, now: now)
        let tEarn = totalEarned(settings: settings, now: now)

        // 2) 休息日
        if !ChineseWorkdayCalendar.isWorkday(now) {
            return SalarySnapshot(
                state: .dayOff,
                todayDaily: d,
                hourlyRate: h,
                secondRate: sr,
                yearEarned: yEarn,
                monthEarned: mEarn,
                totalEarned: tEarn,
                tableExpired: tableExpired,
                now: now
            )
        }

        // 3) 构造今日的 4 个时间点
        let clockIn = todayAt(minute: settings.clockInMinute, on: todayStart)
        let lunchStart = todayAt(minute: settings.lunchStartMinute, on: todayStart)
        let lunchEnd = todayAt(minute: settings.lunchEndMinute, on: todayStart)
        let clockOut = todayAt(minute: settings.clockOutMinute, on: todayStart)

        // 4) 每日应工作秒数
        let totalWorkMinutes = max(0, settings.clockOutMinute - settings.clockInMinute)
        let lunchMinutes = settings.includeLunchInEarnings ? 0 : max(0, settings.lunchEndMinute - settings.lunchStartMinute)
        let todayTotalSeconds = max(0, totalWorkMinutes - lunchMinutes) * 60

        let nowSec = now.timeIntervalSinceReferenceDate
        let inSec = clockIn.timeIntervalSinceReferenceDate
        let lStartSec = lunchStart.timeIntervalSinceReferenceDate
        let lEndSec = lunchEnd.timeIntervalSinceReferenceDate
        let outSec = clockOut.timeIntervalSinceReferenceDate

        // 5) 上班前
        if nowSec < inSec {
            return SalarySnapshot(
                state: .beforeWork,
                todayDaily: d,
                todayTotalSeconds: Double(todayTotalSeconds),
                timeToWorkStart: inSec - nowSec,
                hourlyRate: h,
                secondRate: sr,
                yearEarned: yEarn,
                monthEarned: mEarn,
                totalEarned: tEarn,
                tableExpired: tableExpired,
                now: now
            )
        }

        // 6) 计算已工作秒数
        let worked = workedSeconds(
            now: nowSec,
            clockIn: inSec,
            lunchStart: lStartSec,
            lunchEnd: lEndSec,
            includeLunch: settings.includeLunchInEarnings
        )
        let progress = todayTotalSeconds > 0 ? min(1, max(0, worked / Double(todayTotalSeconds))) : 0
        let earned = h * worked / 3600.0

        // 7) includeLunch=false 时午休段 = .onLunch,进度冻结
        if !settings.includeLunchInEarnings && nowSec >= lStartSec && nowSec < lEndSec {
            return SalarySnapshot(
                state: .onLunch,
                todayEarned: earned,
                todayDaily: d,
                todayWorkedSeconds: worked,
                todayTotalSeconds: Double(todayTotalSeconds),
                progress: progress,
                timeToLunchEnd: lEndSec - nowSec,
                hourlyRate: h,
                secondRate: sr,
                yearEarned: yEarn,
                monthEarned: mEarn,
                totalEarned: tEarn,
                tableExpired: tableExpired,
                now: now
            )
        }

        // 8) 上班中(午休是否计入由 workedSeconds 决定,状态都是 .working)
        if nowSec < outSec {
            return SalarySnapshot(
                state: .working,
                todayEarned: earned,
                todayDaily: d,
                todayWorkedSeconds: worked,
                todayTotalSeconds: Double(todayTotalSeconds),
                progress: progress,
                timeToOffDuty: outSec - nowSec,
                hourlyRate: h,
                secondRate: sr,
                yearEarned: yEarn,
                monthEarned: mEarn,
                totalEarned: tEarn,
                tableExpired: tableExpired,
                now: now
            )
        }

        // 9) 下班后:今日已赚 = 日薪
        return SalarySnapshot(
            state: .afterWork,
            todayEarned: d,
            todayDaily: d,
            todayWorkedSeconds: Double(todayTotalSeconds),
            todayTotalSeconds: Double(todayTotalSeconds),
            progress: 1.0,
            hourlyRate: h,
            secondRate: sr,
            yearEarned: yEarn,
            monthEarned: mEarn,
            totalEarned: tEarn,
            tableExpired: tableExpired,
            now: now
        )
    }

    /// 已工作秒数:
    /// - includeLunch=true:已工作 = now - clockIn(午休也算)
    /// - includeLunch=false:已工作 = 上午 (lunchStart - clockIn) + max(0, now - lunchEnd)
    private static func workedSeconds(
        now: TimeInterval,
        clockIn: TimeInterval,
        lunchStart: TimeInterval,
        lunchEnd: TimeInterval,
        includeLunch: Bool
    ) -> Double {
        if includeLunch {
            return max(0, now - clockIn)
        }
        if now <= lunchStart { return max(0, now - clockIn) }
        if now <= lunchEnd   { return max(0, lunchStart - clockIn) }
        return max(0, (lunchStart - clockIn) + (now - lunchEnd))
    }

    // MARK: - 派生量

    /// 当月日薪 = 月薪 / 当月工作日
    public static func dailySalary(settings: SalarySettings, now: Date) -> Double {
        let cal = ChineseWorkdayCalendar.calendar
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        let total = ChineseWorkdayCalendar.monthWorkdays(year: y, month: m)
        guard total > 0 else { return 0 }
        return settings.monthlyNetSalary / Double(total)
    }

    /// 时薪 = 日薪 / 每日工作时数
    public static func hourlyRate(settings: SalarySettings, now: Date) -> Double {
        let hours = settings.dailyWorkHours
        guard hours > 0 else { return 0 }
        return dailySalary(settings: settings, now: now) / hours
    }

    /// 秒薪 = 时薪 / 3600
    public static func secondRate(settings: SalarySettings, now: Date) -> Double {
        hourlyRate(settings: settings, now: now) / 3600.0
    }

    private static func secondRate(hourly: Double) -> Double {
        hourly / 3600.0
    }

    // MARK: - 累计

    /// 今日已工作进度(0..1),跟 `compute()` 里的 progress 算法完全一致。
    /// 用于累计计算中"今天已经赚了多少"的部分,让累计按秒级增长,
    /// 跟 `todayEarned` 同步。不调 `compute()`(避免死循环)。
    private static func todayProgressFraction(settings: SalarySettings, now: Date) -> Double {
        let cal = ChineseWorkdayCalendar.calendar
        let todayStart = cal.startOfDay(for: now)
        let clockIn = todayAt(minute: settings.clockInMinute, on: todayStart)
        let lunchStart = todayAt(minute: settings.lunchStartMinute, on: todayStart)
        let lunchEnd = todayAt(minute: settings.lunchEndMinute, on: todayStart)

        let totalWorkMinutes = max(0, settings.clockOutMinute - settings.clockInMinute)
        let lunchMinutes = settings.includeLunchInEarnings ? 0 : max(0, settings.lunchEndMinute - settings.lunchStartMinute)
        let todayTotalSeconds = max(0, totalWorkMinutes - lunchMinutes) * 60
        guard todayTotalSeconds > 0 else { return 0 }

        let worked = workedSeconds(
            now: now.timeIntervalSinceReferenceDate,
            clockIn: clockIn.timeIntervalSinceReferenceDate,
            lunchStart: lunchStart.timeIntervalSinceReferenceDate,
            lunchEnd: lunchEnd.timeIntervalSinceReferenceDate,
            includeLunch: settings.includeLunchInEarnings
        )
        return min(1.0, max(0.0, worked / Double(todayTotalSeconds)))
    }

    /// 今年已赚:按月分段,每月用当月 workdays 算。
    /// 每个月 = 完整过去日 × 日薪,当前月额外加"今日 progress × 日薪",
    /// 让累计按秒级增长,跟 todayEarned 同步。
    /// 表外年份会回退到"周一~五"默认规则,UI 通过 snapshot.tableExpired 提示升级。
    public static func yearEarned(settings: SalarySettings, now: Date) -> Double {
        let cal = ChineseWorkdayCalendar.calendar
        let nowYear = cal.component(.year, from: now)
        let nowMonth = cal.component(.month, from: now)
        let todayStart = cal.startOfDay(for: now)

        var total: Double = 0
        for m in 1...nowMonth {
            guard let monthStart = cal.date(from: DateComponents(year: nowYear, month: m, day: 1)),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { continue }
            let totalWorkdays = ChineseWorkdayCalendar.monthWorkdays(year: nowYear, month: m)
            guard totalWorkdays > 0 else { continue }

            // periodEnd:完整过去月到月底,当前月到 todayStart(不含今天)
            let completePeriodEnd: Date
            if m < nowMonth {
                completePeriodEnd = monthEnd  // 完整过去月
            } else if m == nowMonth {
                completePeriodEnd = todayStart  // 当前月:月初到昨天
            } else {
                continue
            }

            let completeDaysWorked = ChineseWorkdayCalendar.workdaysBetween(from: monthStart, to: completePeriodEnd)
            total += settings.monthlyNetSalary * Double(completeDaysWorked) / Double(totalWorkdays)
        }

        // 当前月今日 progress(只在今天工作日时加,休息日不加)
        if ChineseWorkdayCalendar.isWorkday(now) {
            let todayDaily = dailySalary(settings: settings, now: now)
            total += todayDaily * todayProgressFraction(settings: settings, now: now)
        }

        return total
    }

    /// 本月已赚:月初到昨天(完整过去日) × 日薪 + 今日 progress × 日薪。
    /// 今日 progress 跟 todayEarned 同步,确保累计按秒增长。
    public static func monthEarned(settings: SalarySettings, now: Date) -> Double {
        let cal = ChineseWorkdayCalendar.calendar
        let y = cal.component(.year, from: now)
        let m = cal.component(.month, from: now)
        guard let monthStart = cal.date(from: DateComponents(year: y, month: m, day: 1)) else { return 0 }
        let todayStart = cal.startOfDay(for: now)

        let totalWorkdays = ChineseWorkdayCalendar.monthWorkdays(year: y, month: m)
        guard totalWorkdays > 0 else { return 0 }

        // 1) 完整过去日(月初到昨天,不含今天)
        let completeDaysWorked = ChineseWorkdayCalendar.workdaysBetween(from: monthStart, to: todayStart)
        let completeDaysEarn = settings.monthlyNetSalary * Double(completeDaysWorked) / Double(totalWorkdays)

        // 2) 今日 progress(只在今天工作日时加,休息日不加)
        let todayEarn: Double
        if ChineseWorkdayCalendar.isWorkday(now) {
            let todayDaily = dailySalary(settings: settings, now: now)
            todayEarn = todayDaily * todayProgressFraction(settings: settings, now: now)
        } else {
            todayEarn = 0
        }

        return completeDaysEarn + todayEarn
    }

    /// 在职累计:hireDate 到当前月昨天(完整过去日) × 各月日薪 + 当前月今日 progress × 日薪。
    /// hireDate 在月中:从 hireDate 起;完整过去月:整月;当前月:到 todayStart(完整过去日)。
    /// 表外年份的月份会回退到"周一~五"默认规则。
    public static func totalEarned(settings: SalarySettings, now: Date) -> Double {
        guard let hire = settings.hireDate, hire <= now else { return 0 }
        let cal = ChineseWorkdayCalendar.calendar

        let nowYear = cal.component(.year, from: now)
        let nowMonth = cal.component(.month, from: now)
        guard let monthNow = cal.date(from: DateComponents(year: nowYear, month: nowMonth, day: 1)) else { return 0 }
        let todayStart = cal.startOfDay(for: now)

        var total: Double = 0
        var cursor = firstDayOfMonth(hire, cal)

        while cursor <= now {
            let year = cal.component(.year, from: cursor)
            let month = cal.component(.month, from: cursor)
            guard let monthStart = cal.date(from: DateComponents(year: year, month: month, day: 1)),
                  let monthEnd = cal.date(byAdding: .month, value: 1, to: monthStart) else { break }

            let totalWorkdays = ChineseWorkdayCalendar.monthWorkdays(year: year, month: month)
            guard totalWorkdays > 0 else {
                guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
                continue
            }

            // periodStart:hireDate 所在月从 hireDate 起,其它月从月初
            let periodStart: Date
            if monthStart <= hire && hire < monthEnd {
                periodStart = hire
            } else {
                periodStart = monthStart
            }

            // periodEnd:完整过去月取 monthEnd,当前月取 todayStart(不含今天,只算完整过去日)
            let periodEnd: Date
            if monthEnd <= monthNow {
                periodEnd = monthEnd
            } else if monthStart == monthNow {
                periodEnd = todayStart
            } else {
                // 未来月,理论上 while 条件已排除,但保险起见退出
                break
            }

            if periodStart < periodEnd {
                let worked = ChineseWorkdayCalendar.workdaysBetween(from: periodStart, to: periodEnd)
                total += settings.monthlyNetSalary * Double(worked) / Double(totalWorkdays)
            }

            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }

        // 当前月今日 progress(只在今天工作日时加,休息日不加)
        if ChineseWorkdayCalendar.isWorkday(now) {
            let todayDaily = dailySalary(settings: settings, now: now)
            total += todayDaily * todayProgressFraction(settings: settings, now: now)
        }

        return total
    }

    private static func firstDayOfMonth(_ date: Date, _ cal: Calendar) -> Date {
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    // MARK: - 时间工具

    private static func todayAt(minute: Int, on dayStart: Date) -> Date {
        let h = minute / 60
        let m = minute % 60
        return ChineseWorkdayCalendar.calendar.date(bySettingHour: h, minute: m, second: 0, of: dayStart) ?? dayStart
    }

    // MARK: - 格式化

    /// "1234.56" → "¥1,234.56"
    public static func formatCNY(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        let str = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        return "¥\(str)"
    }

    /// 3725s → "1h 2m"; 95s → "1 分 35 秒"; 45s → "45 秒".
    public static func formatCountdown(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0 秒" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) 分 \(s) 秒" }
        return "\(s) 秒"
    }
}
