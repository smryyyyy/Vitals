import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct SalaryEngineTests {

    // MARK: - Helpers

    /// 在系统时区构造指定 civil-date-time。测试用日期已全部避开表外年份,
    /// 确保节假日判断走真实数据。
    private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y
        c.month = m
        c.day = d
        c.hour = h
        c.minute = min
        c.second = s
        c.timeZone = TimeZone.current
        return Calendar.current.date(from: c)!
    }

    /// 默认测试设置:月薪 21000 元、9-18 含午休;
    /// 选择 21000 是因为 2025-06 有 18 个工作日(端午跨月)→ 日薪 = 1166.67;
    /// 测试用更常见的 2024-06(19 工作日)时 daily = 1105.26,留作 sanity。
    private static let defaultSettings = SalarySettings(
        monthlyNetSalary: 21000,
        clockInMinute: 9 * 60,
        clockOutMinute: 18 * 60,
        lunchStartMinute: 12 * 60,
        lunchEndMinute: 13 * 60,
        includeLunchInEarnings: true,
        hireDate: nil
    )

    // MARK: - ChineseWorkdayCalendar:isWorkday

    @Test func calendar_isWorkday_normalWeekday() {
        // 2024-01-15 = Monday
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 1, 15)))
    }

    @Test func calendar_isWorkday_normalWeekend() {
        // 2024-01-13 = Saturday, 2024-01-14 = Sunday
        #expect(!ChineseWorkdayCalendar.isWorkday(Self.date(2024, 1, 13)))
        #expect(!ChineseWorkdayCalendar.isWorkday(Self.date(2024, 1, 14)))
    }

    @Test func calendar_isWorkday_2024SpringFestival_allHoliday() {
        // 2/10-2/17 都是法定假日
        for d in 10...17 {
            #expect(!ChineseWorkdayCalendar.isWorkday(Self.date(2024, 2, d)),
                    "2024-02-\(d) 应该是法定假日")
        }
    }

    @Test func calendar_isWorkday_2024SpringFestival_makeupWorkday() {
        // 2/4 (Sun) 和 2/18 (Sun) 是调休上班
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 2, 4)))
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 2, 18)))
    }

    @Test func calendar_isWorkday_2024LaborDay_makeupWorkday() {
        // 4/28 (Sun) 和 5/11 (Sat) 是调休
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 4, 28)))
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 5, 11)))
    }

    @Test func calendar_isWorkday_2024NationalDay_makeupWorkday() {
        // 10/12 (Sat) 是调休;9/29 (Sun) 属于 9 月
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 10, 12)))
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2024, 9, 29)))
        // 10/1-7 是法定假日
        for d in 1...7 {
            #expect(!ChineseWorkdayCalendar.isWorkday(Self.date(2024, 10, d)))
        }
    }

    @Test func calendar_isWorkday_2026LongestSpringFestival() {
        // 2026 春节 9 天 (2/15-23)
        for d in 15...23 {
            #expect(!ChineseWorkdayCalendar.isWorkday(Self.date(2026, 2, d)))
        }
        // 调休:2/14 (Sat) 和 2/28 (Sat) 上班
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2026, 2, 14)))
        #expect(ChineseWorkdayCalendar.isWorkday(Self.date(2026, 2, 28)))
    }

    // MARK: - ChineseWorkdayCalendar:monthWorkdays

    @Test func calendar_monthWorkdays_2024_jan() {
        // 2024-01:31 天 - 4 周日 - 4 周六 - 1/1(元旦) = 22
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 1) == 22)
    }

    @Test func calendar_monthWorkdays_2024_feb_springFestival() {
        // 2024-02:29 天 - 4 周日(2/4,11,18,25) - 4 周六(2/3,10,17,24)
        //         - 8 假日(2/10-17) + 2 调休(2/4, 2/18) = 18
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 2) == 18)
    }

    @Test func calendar_monthWorkdays_2024_april_qingming() {
        // 4/4-6 清明 3 天假,4/7 (Sun) + 4/28 (Sun) 调休
        // = 30 - 4 周日 - 4 周六 - 3 假日 + 2 调休 = 21?
        // 实际:4/1,2,3 + 4/7,8,9,10,11,12 + 4/15-19 + 4/22-26 + 4/28,29,30 = 3+6+5+5+3 = 22
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 4) == 22)
    }

    @Test func calendar_monthWorkdays_2024_may_laborDay() {
        // 5/1-5 劳动节 5 天假,5/11 (Sat) 调休
        // = 21 workdays
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 5) == 21)
    }

    @Test func calendar_monthWorkdays_2024_june_dragonBoat() {
        // 6/10 端午 1 天假,无调休
        // 5+4+5+5 = 19
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 6) == 19)
    }

    @Test func calendar_monthWorkdays_2024_september_midAutumn() {
        // 9/15-17 中秋 3 天假,9/14 (Sat) 调休,9/29 (Sun) 调休(为国庆)
        // 21
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 9) == 21)
    }

    @Test func calendar_monthWorkdays_2024_october_nationalDay() {
        // 10/1-7 国庆 7 天假,10/12 (Sat) 调休
        // 19 个工作日(用户 spec 写的 8 是笔误,真实计算见下)
        // 10/8,9,10,11,12,14,15,16,17,18,21,22,23,24,25,28,29,30,31 = 19
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2024, month: 10) == 19)
    }

    @Test func calendar_monthWorkdays_2025_jan_newYearAndSpring() {
        // 1/1 元旦 + 1/28-31 春节(4 天,2/1-4 算 2 月)
        // 1/26 (Sun) 调休
        // = 19
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2025, month: 1) == 19)
    }

    @Test func calendar_monthWorkdays_2025_october_mergedHoliday() {
        // 10/1-8 国庆+中秋合并 8 天假
        // 9/28 (Sun) 调休(在 9 月),10/11 (Sat) 调休
        // = 18
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2025, month: 10) == 18)
    }

    @Test func calendar_monthWorkdays_2026_feb_longestSpring() {
        // 2026 史上最长春节 9 天 (2/15-23) + 2/14 + 2/28 调休
        // 2/2-6 + 2/9-14 + 2/24-28 = 5+6+5 = 16
        #expect(ChineseWorkdayCalendar.monthWorkdays(year: 2026, month: 2) == 16)
    }

    // MARK: - ChineseWorkdayCalendar:过期判断

    @Test func calendar_tableExpired_2026_9_returnsFalse() {
        #expect(!ChineseWorkdayCalendar.isTableExpired(Self.date(2026, 9, 15)))
    }

    @Test func calendar_tableExpired_2027_1_returnsTrue() {
        #expect(ChineseWorkdayCalendar.isTableExpired(Self.date(2027, 1, 1)))
    }

    // MARK: - SalarySettings 派生量

    @Test func settings_dailyWorkHours_includeLunch_true() {
        // 9-18 共 9h,午休也算 → 9h
        let s = SalarySettings(
            monthlyNetSalary: 10000,
            clockInMinute: 9 * 60,
            clockOutMinute: 18 * 60,
            lunchStartMinute: 12 * 60,
            lunchEndMinute: 13 * 60,
            includeLunchInEarnings: true
        )
        #expect(abs(s.dailyWorkHours - 9.0) < 0.0001)
    }

    @Test func settings_dailyWorkHours_includeLunch_false() {
        // 9-18,午休 12-13 减掉 → 8h
        let s = SalarySettings(
            monthlyNetSalary: 10000,
            clockInMinute: 9 * 60,
            clockOutMinute: 18 * 60,
            lunchStartMinute: 12 * 60,
            lunchEndMinute: 13 * 60,
            includeLunchInEarnings: false
        )
        #expect(abs(s.dailyWorkHours - 8.0) < 0.0001)
    }

    @Test func settings_isConfigured_zeroSalary_false() {
        let s = SalarySettings(monthlyNetSalary: 0)
        #expect(!s.isConfigured)
    }

    @Test func settings_isConfigured_positive_true() {
        let s = SalarySettings(monthlyNetSalary: 1)
        #expect(s.isConfigured)
    }

    // MARK: - SalaryEngine.dailySalary / hourlyRate

    @Test func dailySalary_basedOnCurrentMonthWorkdays() {
        // 2024-06 有 19 个工作日,月薪 21000 → daily ≈ 1105.26
        let s = SalarySettings(monthlyNetSalary: 21000)
        let now = Self.date(2024, 6, 3, 10, 0)
        let daily = SalaryEngine.dailySalary(settings: s, now: now)
        #expect(abs(daily - (21000.0 / 19.0)) < 0.0001)
    }

    @Test func hourlyRate_includeLunch_true() {
        // 8-12, lunch 9-10, includeLunch=true → dailyWorkHours=4
        // 2024-06 daily=21000/19,hourly=21000/(19*4)
        let s = SalarySettings(
            monthlyNetSalary: 21000,
            clockInMinute: 8 * 60,
            clockOutMinute: 12 * 60,
            lunchStartMinute: 9 * 60,
            lunchEndMinute: 10 * 60,
            includeLunchInEarnings: true
        )
        let now = Self.date(2024, 6, 3, 10, 0)
        let h = SalaryEngine.hourlyRate(settings: s, now: now)
        #expect(abs(h - (21000.0 / 19.0 / 4.0)) < 0.0001)
    }

    @Test func hourlyRate_includeLunch_false() {
        // 8-12, lunch 9-10, includeLunch=false → dailyWorkHours=3
        let s = SalarySettings(
            monthlyNetSalary: 21000,
            clockInMinute: 8 * 60,
            clockOutMinute: 12 * 60,
            lunchStartMinute: 9 * 60,
            lunchEndMinute: 10 * 60,
            includeLunchInEarnings: false
        )
        let now = Self.date(2024, 6, 3, 10, 0)
        let h = SalaryEngine.hourlyRate(settings: s, now: now)
        #expect(abs(h - (21000.0 / 19.0 / 3.0)) < 0.0001)
    }

    // MARK: - SalaryEngine.compute:基础状态

    @Test func compute_unconfigured_whenSalaryZero() {
        let s = SalarySettings(monthlyNetSalary: 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 10))
        #expect(snap.state == .unconfigured)
    }

    @Test func compute_dayOff_onNormalWeekend() {
        // 2024-06-08 = Saturday,不在表里 → 周末
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 8, 10))
        #expect(snap.state == .dayOff)
        #expect(snap.todayEarned == 0)
        #expect(snap.timeToOffDuty == nil)
    }

    @Test func compute_dayOff_onLegalHoliday() {
        // 2024-02-15 = 春节假期
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 2, 15, 10))
        #expect(snap.state == .dayOff)
    }

    @Test func compute_beforeWork_clockIn() {
        // 8:00 < 9:00,2024-06-03 是 workday
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 8, 0))
        #expect(snap.state == .beforeWork)
        #expect(snap.todayEarned == 0)
        #expect(snap.timeToWorkStart != nil)
        #expect(abs(snap.timeToWorkStart! - 3600) < 1)  // 1 小时
    }

    // MARK: - SalaryEngine.compute:working / onLunch 状态切换

    @Test func compute_working_morningAccruesProportionally() {
        // 9:30,includeLunch=true,totalWork=9h,worked=30min,fraction=30/540
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 9, 30))
        #expect(snap.state == .working)
        #expect(snap.todayEarned > 0)
        #expect(snap.todayEarned < snap.todayDaily)
        #expect(abs(snap.progress - (1800.0 / (9 * 3600.0))) < 0.0001)
        #expect(snap.timeToLunchEnd == nil)
    }

    @Test func compute_working_lunch_includeLunch_keepsAdvancing() {
        // 12:30,includeLunch=true → state 仍为 .working,进度按 now-clockIn 继续涨
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 12, 30))
        #expect(snap.state == .working)
        // worked = 12:30 - 9:00 = 3.5h
        // progress = 3.5 / 9 ≈ 0.3889
        #expect(abs(snap.progress - (3.5 * 3600.0 / (9 * 3600.0))) < 0.0001)
        // todayEarned > 0,且随时间推进
        #expect(snap.todayEarned > 0)
    }

    @Test func compute_onLunch_excludesLunch_freezesMorning() {
        // includeLunch=false,12:30 → .onLunch,进度冻结在 lunchStart
        var s = Self.defaultSettings
        s.includeLunchInEarnings = false
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 12, 30))
        #expect(snap.state == .onLunch)
        // worked = lunchStart - clockIn = 3h, totalWork = 8h, progress = 3/8
        #expect(abs(snap.progress - (3.0 * 3600.0 / (8 * 3600.0))) < 0.0001)
        // 12:30 → 13:00 = 30 分钟
        #expect(snap.timeToLunchEnd != nil)
        #expect(abs(snap.timeToLunchEnd! - 1800) < 1)
        // 验证冻结:13:00(午休刚结束)的 todayEarned 应 == 12:30 的 todayEarned
        let lunchEnd = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 13, 0))
        #expect(abs(snap.todayEarned - lunchEnd.todayEarned) < 0.0001)
    }

    @Test func compute_working_afternoonAccumulates() {
        // 15:00,includeLunch=true,total=9h,worked=6h,progress=6/9
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 15, 0))
        #expect(snap.state == .working)
        #expect(snap.todayEarned > 0)
        #expect(snap.timeToLunchEnd == nil)
        #expect(snap.timeToOffDuty != nil)
        #expect(abs(snap.progress - (6.0 * 3600.0 / (9 * 3600.0))) < 0.0001)
    }

    @Test func compute_working_afternoon_excludesLunch() {
        // includeLunch=false,15:00:worked = 3h(上午) + 2h(下午) = 5h,total=8h
        var s = Self.defaultSettings
        s.includeLunchInEarnings = false
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 15, 0))
        #expect(snap.state == .working)
        #expect(abs(snap.progress - (5.0 * 3600.0 / (8 * 3600.0))) < 0.0001)
    }

    @Test func compute_afterWork_earnsFullDaily() {
        // 19:00 → .afterWork, todayEarned = todayDaily
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 19, 0))
        #expect(snap.state == .afterWork)
        #expect(abs(snap.todayEarned - snap.todayDaily) < 0.0001)
        #expect(snap.progress == 1.0)
    }

    // MARK: - 节假日表过期

    @Test func compute_tableExpired_returnsExpiredFlag() {
        // 2027 年系统应标 tableExpired=true,计算仍用默认规则
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2027, 1, 4, 10))
        #expect(snap.tableExpired == true)
        // 2027-01-04 是周一,默认是工作日
        #expect(snap.state == .working)
    }

    @Test func compute_tableNotExpired_2026_12() {
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2026, 12, 1, 10))
        #expect(snap.tableExpired == false)
    }

    // MARK: - 累计:monthEarned

    @Test func monthEarned_basicWorkdays_2024June() {
        // 2024-06-03 (Mon) 19:00 → 截至 6/3 已赚 1 个工作日 (6/1,2 是周末)
        // daily = 21000/19,monthEarned = 21000 * 1 / 19
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 19, 0))
        #expect(abs(snap.monthEarned - (21000.0 / 19.0)) < 0.5)
    }

    @Test func monthEarned_skipsNationalDay() {
        // 2024-10-08 (Tue) 19:00 → 国庆后第一个工作日
        // 10/1-7 全是假日,10/8 刚下班 → monthEarned = 21000 * 1 / 19
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 10, 8, 19, 0))
        #expect(abs(snap.monthEarned - (21000.0 / 19.0)) < 0.5)
    }

    // MARK: - 累计:yearEarned

    @Test func yearEarned_basic() {
        // 2024-01-03 (Wed) 19:00 → 1/1 元旦,1/2-3 工作日 → 2 个工作日
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 1, 3, 19, 0))
        #expect(abs(snap.yearEarned - (21000.0 * 2 / 22)) < 0.5)
    }

    @Test func yearEarned_skipsSpringFestival() {
        // 2024-02-19 19:00 → yearEarned 跨完整 Jan + 部分 Feb
        // 1 月:从 1/1 到 2/1,完整月 → 22 个工作日(1/1 是元旦)
        // 2 月:从 2/1 到 2/19 19:00 → 2/1, 2/2, 2/4 调休, 2/5-9, 2/18 调休, 2/19 = 10 个工作日
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 2, 19, 19, 0))
        let jan = 21000.0 * 22.0 / 22.0
        let feb = 21000.0 * 10.0 / 18.0
        #expect(abs(snap.yearEarned - (jan + feb)) < 1.0)
    }

    // MARK: - 累计:totalEarned

    @Test func totalEarned_zeroWhenHireDateUnset() {
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 6, 3, 19, 0))
        #expect(snap.totalEarned == 0)
    }

    @Test func totalEarned_hireDateToday_justOneDay() {
        var s = Self.defaultSettings
        s.hireDate = Self.date(2024, 6, 3, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 19, 0))
        // 6/3 是 Monday,正常下班 → 1 个工作日
        #expect(abs(snap.totalEarned - (21000.0 / 19.0)) < 0.5)
    }

    @Test func totalEarned_hireDateInFuture_isZero() {
        var s = Self.defaultSettings
        s.hireDate = Self.date(2099, 1, 1, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 3, 19, 0))
        #expect(snap.totalEarned == 0)
    }

    @Test func totalEarned_partialMonth_startsFromHireDate() {
        // hire = 2024-06-17 (Mon),now = 2024-06-30 19:00 (Sun,after work)
        // 6/17-6/30 的工作日:6/17-21(5) + 6/24-28(5) = 10
        var s = Self.defaultSettings
        s.hireDate = Self.date(2024, 6, 17, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 6, 30, 19, 0))
        let expected = 21000.0 * 10.0 / 19.0
        #expect(abs(snap.totalEarned - expected) < 0.5)
    }

    @Test func totalEarned_completeMonths_crossYearBoundary() {
        // hire = 2024-01-15 (Mon),now = 2024-03-31 19:00 (Sun)
        // Jan:1/15-1/31 工作日 = 1/15-19, 1/22-26, 1/29-31 = 13,Jan 总 = 22
        // Feb:完整月 = 18
        // Mar:完整月 = 21(3/1 + 4 个完整周 Mon-Fri)
        var s = Self.defaultSettings
        s.hireDate = Self.date(2024, 1, 15, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 3, 31, 19, 0))
        let jan = 21000.0 * 13.0 / 22.0
        let feb = 21000.0 * 18.0 / 18.0
        let mar = 21000.0 * 21.0 / 21.0
        let expected = jan + feb + mar
        #expect(abs(snap.totalEarned - expected) < 1.0)
    }

    @Test func totalEarned_currentMonth_onlyUpToNow() {
        // hire = 2024-01-01,now = 2024-01-15 10:00 (Mon 上午 10 点)
        // 1/1 元旦假,1/2-5 (4) + 1/8-12 (5) = 9 个完整过去日;
        // 1/15 10:00 → worked=1h, total=9h, progress=1/9,todayEarn=daily*1/9
        var s = Self.defaultSettings
        s.hireDate = Self.date(2024, 1, 1, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2024, 1, 15, 10, 0))
        let expected = 21000.0 * (9.0 + 1.0 / 9.0) / 22.0
        #expect(abs(snap.totalEarned - expected) < 0.5)
    }

    @Test func totalEarned_skips2026SpringFestival() {
        // hire = 2025-12-01,now = 2026-03-15 19:00 (Sun)
        // 12 月:无调休,23 个工作日
        // 1 月:1/1-3 假 + 1/4 调休 → 21 个工作日
        // 2 月:春节 9 天 → 16 个工作日
        // 3 月:3/1-3/15 19:00 工作日 = 3/2-6 (5) + 3/9-13 (5) = 10;Mar 总 22 个工作日
        var s = Self.defaultSettings
        s.hireDate = Self.date(2025, 12, 1, 0, 0)
        let snap = SalaryEngine.compute(settings: s, now: Self.date(2026, 3, 15, 19, 0))
        let dec = 21000.0 * 23.0 / 23.0
        let jan = 21000.0 * 21.0 / 21.0
        let feb = 21000.0 * 16.0 / 16.0
        let mar = 21000.0 * 10.0 / 22.0
        let expected = dec + jan + feb + mar
        #expect(abs(snap.totalEarned - expected) < 1.0)
    }

    // MARK: - 累计:bug 修复 —— 跟 todayEarned 同步按秒增长

    /// 修复前 bug:9/9 当天的 monthEarned 整天不变(整天被算作 1 个工作日)。
    /// 修复后:9/9 18:00 应 > 9/9 10:00(今日 progress 从 1/9 涨到 8/9)。
    @Test func monthEarned_growsWithTimeInSameDay() {
        // 2024-09-09 = Mon,9 月有 21 个工作日,daily = 21000/21
        let morning = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 10, 0))
        let evening = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 18, 0))
        #expect(evening.monthEarned > morning.monthEarned,
                "monthEarned 应该在同一天内随时间增长,实际:morning=\(morning.monthEarned), evening=\(evening.monthEarned)")
    }

    /// 跨天切换:9/9 23:59(刚下班,今日 progress=1)≈ 9/10 09:30(新工作日,新 progress 小)
    /// 总值连续不跳变,且新一天的值 >= 旧一天收尾(增长由新一天新增 + progress 共同决定)。
    @Test func monthEarned_atDayBoundary_correctlyTransitions() {
        let endOfDay = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 23, 59))
        let nextDayLater = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 10, 9, 30))
        // 9/10 09:30 比 9/9 23:59 至少多 1 个完整工作日,差值 ≥ daily - progressToday
        #expect(nextDayLater.monthEarned > endOfDay.monthEarned,
                "9/10 09:30 应该 > 9/9 23:59,实际:end=\(endOfDay.monthEarned), next=\(nextDayLater.monthEarned)")
        // 同时验证两个时刻对应的 monthEarned 都在合理量级(> 5 个完整工作日)
        let daily = 21000.0 / 21.0
        #expect(endOfDay.monthEarned > 5 * daily)
    }

    /// 修复前 bug:yearEarned 同样按整天算,导致"今日在变,本年不变"。
    @Test func yearEarned_growsWithTimeInSameDay() {
        let morning = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 10, 0))
        let evening = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 18, 0))
        #expect(evening.yearEarned > morning.yearEarned,
                "yearEarned 应该在同一天内随时间增长")
    }

    /// 修复前 bug:totalEarned 同样按整天算。
    @Test func totalEarned_growsWithTimeInSameDay() {
        var s = Self.defaultSettings
        s.hireDate = Self.date(2024, 1, 1, 0, 0)
        let morning = SalaryEngine.compute(settings: s, now: Self.date(2024, 9, 9, 10, 0))
        let evening = SalaryEngine.compute(settings: s, now: Self.date(2024, 9, 9, 18, 0))
        #expect(evening.totalEarned > morning.totalEarned,
                "totalEarned 应该在同一天内随时间增长")
    }

    /// 今天是休息日:monthEarned = 完整过去日部分(今日 progress = 0)
    /// 2024-09-15 = Sun,属于中秋假期(9/15-17 全假)
    @Test func monthEarned_isWorkdayFalse_returnsCompleteDaysOnly() {
        let snap = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 15, 14, 0))
        // 9/1-9/14 完整过去日工作日 = 9/2-6 (5) + 9/9-13 (5) + 9/14 (Sat 调休,1) = 11
        // 9/15 是中秋假,isWorkday=false,todayEarn=0
        let expected = 21000.0 * 11.0 / 21.0
        #expect(abs(snap.monthEarned - expected) < 0.5,
                "休息日 monthEarned 应等于完整过去日部分,实际:\(snap.monthEarned), 期望:\(expected)")
    }

    /// 连续性:9/9 23:59(今日 progress 高)≈ 9/10 00:01(新完整日,新 progress 低),总值不跳变
    /// 修复前 bug:9/10 00:01 会比 9/9 23:59 多出"9/9 整天"但少"9/9 整天"也算当日,实际上同一天重算导致跳变。
    /// 修复后:9/9 23:59 = 5 完整 + 1.0 今日 = 6;9/10 00:01 = 6 完整 + 0.0 今日 = 6(连续)
    @Test func monthEarned_todayAndYesterday_continuous() {
        let endOfDay = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 9, 23, 59))
        let startOfNext = SalaryEngine.compute(settings: Self.defaultSettings, now: Self.date(2024, 9, 10, 0, 1))
        let daily = 21000.0 / 21.0
        // 跨天切换不应该跳变超过一天的日薪
        #expect(abs(endOfDay.monthEarned - startOfNext.monthEarned) < daily,
                "9/9 23:59 vs 9/10 00:01 不应跳变超过 1 天日薪,实际: end=\(endOfDay.monthEarned), start=\(startOfNext.monthEarned)")
    }

    // MARK: - 格式化

    @Test func formatCNY_basic() {
        #expect(SalaryEngine.formatCNY(1234.56) == "¥1,234.56")
        #expect(SalaryEngine.formatCNY(0) == "¥0.00")
        #expect(SalaryEngine.formatCNY(1_000_000) == "¥1,000,000.00")
    }

    @Test func formatCountdown_branches() {
        #expect(SalaryEngine.formatCountdown(0) == "0 秒")
        #expect(SalaryEngine.formatCountdown(45) == "45 秒")
        #expect(SalaryEngine.formatCountdown(95) == "1 分 35 秒")
        #expect(SalaryEngine.formatCountdown(3725) == "1h 2m")
        #expect(SalaryEngine.formatCountdown(-5) == "0 秒")
    }

    // MARK: - 持久化

    @Test func settings_persistAndLoad_roundtrip() {
        let s = SalarySettings(
            monthlyNetSalary: 12345.67,
            clockInMinute: 8 * 60 + 30,
            clockOutMinute: 17 * 60 + 30,
            lunchStartMinute: 12 * 60,
            lunchEndMinute: 13 * 60 + 30,
            includeLunchInEarnings: false,
            hireDate: Self.date(2024, 3, 15, 0, 0)
        )
        s.save()
        let loaded = SalarySettings.load()
        #expect(abs(loaded.monthlyNetSalary - s.monthlyNetSalary) < 0.0001)
        #expect(loaded.clockInMinute == s.clockInMinute)
        #expect(loaded.clockOutMinute == s.clockOutMinute)
        #expect(loaded.lunchStartMinute == s.lunchStartMinute)
        #expect(loaded.lunchEndMinute == s.lunchEndMinute)
        #expect(loaded.includeLunchInEarnings == s.includeLunchInEarnings)
        // hireDate 用日期部分比较(秒级可能漂)
        let cal = Calendar.current
        let loadedHire = loaded.hireDate.map { cal.startOfDay(for: $0) }
        let origHire = s.hireDate.map { cal.startOfDay(for: $0) }
        #expect(loadedHire == origHire)
        // 清理
        UserDefaults.standard.removeObject(forKey: SalarySettings.storageKey)
    }

    @Test func settings_storageKey_isV2() {
        // 锁定 storageKey 不被回退到 v1(避免解码旧数据崩)
        #expect(SalarySettings.storageKey == "salarySettings_v2")
    }
}
