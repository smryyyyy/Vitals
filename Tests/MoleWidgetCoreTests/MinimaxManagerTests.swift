//
//  MinimaxManagerTests.swift
//  Vitals - MiniMax 模块
//
//  续期策略的回归屏障。
//
//  策略:每天固定时刻(默认凌晨 4 点)续期一次。
//   - 到了点、今天还没续 → 续
//   - 到了点、今天已续过 → 不续(等明天)
//   - 还没到点 → 不续
//   - 昨天续过 → 今天到点后要续(不能因为"续过"就永远不再续)
//
//  所有用例都用**固定日历 + 固定时间点**,不依赖真实时钟:
//   - 依赖 `Date()` 的用例在凌晨 0~5 点跑会整片变红(那时"今天 5 点"还在未来)
//   - 依赖 `Calendar.current` 的用例会随运行机器的时区漂移
//
//

import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct MinimaxManagerTests {

    /// 固定时区(无夏令时)。
    private static var shanghai: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return cal
    }

    /// 固定时区(有夏令时)—— 用来盯住 DST 边界。
    private static var newYork: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }

    /// 构造一个确定的时刻。用例不再依赖"现在几点"。
    private static func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int, _ minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    // MARK: - 续期时刻常量

    /// 「每天 4 点」是用户可见的产品行为,不是实现细节。
    ///
    /// 把它改成 3 点或 5 点,其它用例可能一条都不红(用例取的是 3 点和 5 点,
    /// 对 4→5 这种改动恰好不敏感)。这条把它锁死。
    @Test func dailyRenewalHourIsPinnedToFour() {
        #expect(WidgetSettings.minimaxDailyRenewalHour == 4)
    }

    // MARK: - 基本判定

    /// 当天续期时刻之前(凌晨 3 点)→ 今天还没到点,不续。
    @Test func shouldRenewFalseBeforeDailyRenewalMoment() {
        let cal = Self.shanghai
        let now = Self.date(2026, 11, 3, 3, 0, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: now, lastRenewalAt: nil, calendar: cal) == false)
    }

    /// 过了续期时刻、今天还没续过 → 要续。
    @Test func shouldRenewTrueAfterMomentWhenNotRenewedYet() {
        let cal = Self.shanghai
        let now = Self.date(2026, 11, 3, 5, 0, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: now, lastRenewalAt: nil, calendar: cal) == true)
    }

    /// 今天已经续过 → 今天不再续,等明天。
    @Test func shouldRenewFalseWhenAlreadyRenewedToday() {
        let cal = Self.shanghai
        let now = Self.date(2026, 11, 3, 5, 0, calendar: cal)
        let earlierToday = Self.date(2026, 11, 3, 4, 30, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: now, lastRenewalAt: earlierToday, calendar: cal) == false)
    }

    /// 昨天续过、今天到点了 → 要续。
    /// 这条挡的是"续过一次就再也不续"的退化。
    @Test func shouldRenewTrueWhenLastRenewalWasYesterday() {
        let cal = Self.shanghai
        let now = Self.date(2026, 11, 3, 5, 0, calendar: cal)
        let yesterday = Self.date(2026, 11, 2, 4, 0, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: now, lastRenewalAt: yesterday, calendar: cal) == true)
    }

    // MARK: - 时刻边界

    /// 续期时刻前 1 分钟 → 不续;正好到点 → 续。
    ///
    /// 「到点即续」是边界,差一分钟结果就不同,所以边界值必须钉住。
    @Test func shouldRenewFlipsExactlyAtTheRenewalMoment() {
        let cal = Self.shanghai
        let oneMinuteBefore = Self.date(2026, 11, 3, 3, 59, calendar: cal)
        let exactly = Self.date(2026, 11, 3, 4, 0, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: oneMinuteBefore, lastRenewalAt: nil, calendar: cal) == false)
        #expect(MinimaxManager.shouldRenewToday(now: exactly, lastRenewalAt: nil, calendar: cal) == true)
    }

    // MARK: - 夏令时

    /// 续期时刻取的是**本地钟点 4 点**,不是「零点 + 4 个绝对小时」。
    ///
    /// 绝对小时加法在夏令时切换日会偏:纽约 2026-03-08(春季跳变,那天只有
    /// 23 小时)会算到本地 5 点,2026-11-01(秋季回拨,25 小时)会算到 3 点。
    /// 一年错两天 —— 对用户是"续期时间变了",对测试是间歇性变红。
    @Test func renewalMomentIsLocalFourOClockOnDSTTransitionDays() {
        let cal = Self.newYork

        // 春季跳变日
        let spring = Self.date(2026, 3, 8, 12, calendar: cal)
        let springMoment = MinimaxManager.renewalMoment(
            on: cal.startOfDay(for: spring),
            calendar: cal
        )
        #expect(springMoment.map { cal.component(.hour, from: $0) } == 4)

        // 秋季回拨日
        let fall = Self.date(2026, 11, 1, 12, calendar: cal)
        let fallMoment = MinimaxManager.renewalMoment(
            on: cal.startOfDay(for: fall),
            calendar: cal
        )
        #expect(fallMoment.map { cal.component(.hour, from: $0) } == 4)
    }

    /// 回拨日的判定也要落在本地 4 点上。
    ///
    /// 这条在旧实现(绝对小时加法)下会红:11-01 的续期时刻被算成本地 3 点,
    /// 于是 3:59 就被判成"已到点" → 提前一小时续期。
    @Test func shouldRenewOnDSTFallbackDayUsesLocalFourOClock() {
        let cal = Self.newYork
        let threeFiftyNine = Self.date(2026, 11, 1, 3, 59, calendar: cal)
        let fourOClock = Self.date(2026, 11, 1, 4, 0, calendar: cal)

        #expect(MinimaxManager.shouldRenewToday(now: threeFiftyNine, lastRenewalAt: nil, calendar: cal) == false)
        #expect(MinimaxManager.shouldRenewToday(now: fourOClock, lastRenewalAt: nil, calendar: cal) == true)
    }

    // MARK: - 下次续期时刻

    /// `nextRenewalDate` 必须如实反映三种状态。
    @Test func nextRenewalDateReflectsThreeStates() {
        let cal = Self.shanghai

        // 1) 今天还没到点、还没续过 → 今天 4:00
        let before = Self.date(2026, 11, 3, 3, 0, calendar: cal)
        let today = MinimaxManager.nextRenewalDate(now: before, lastRenewalAt: nil, calendar: cal)!
        #expect(cal.component(.day, from: today) == 3)
        #expect(cal.component(.hour, from: today) == 4)

        // 2) 今天还没到点、但今天已经续过(用户手动点的)→ 明天 4:00
        let renewedThisMorning = Self.date(2026, 11, 3, 2, 0, calendar: cal)
        let tomorrow = MinimaxManager.nextRenewalDate(
            now: before,
            lastRenewalAt: renewedThisMorning,
            calendar: cal
        )!
        #expect(cal.component(.day, from: tomorrow) == 4)
        #expect(cal.component(.hour, from: tomorrow) == 4)

        // 3) 到点了还没续 → 没有固定时刻(待补续)
        let after = Self.date(2026, 11, 3, 5, 0, calendar: cal)
        #expect(MinimaxManager.nextRenewalDate(now: after, lastRenewalAt: nil, calendar: cal) == nil)
    }

    /// 到点还没续时:不显示一个已经过去的时刻,而是标记为「待补续」。
    @Test func renewalOverdueIsReportedInsteadOfAPastTimestamp() {
        let cal = Self.shanghai
        let after = Self.date(2026, 11, 3, 5, 0, calendar: cal)

        #expect(MinimaxManager.isRenewalOverdue(now: after, lastRenewalAt: nil, calendar: cal) == true)
        #expect(MinimaxManager.nextRenewalDate(now: after, lastRenewalAt: nil, calendar: cal) == nil)

        // 已经续过 → 不欠,下次是明天
        let renewed = Self.date(2026, 11, 3, 4, 30, calendar: cal)
        #expect(MinimaxManager.isRenewalOverdue(now: after, lastRenewalAt: renewed, calendar: cal) == false)
        let next = MinimaxManager.nextRenewalDate(now: after, lastRenewalAt: renewed, calendar: cal)!
        #expect(cal.component(.day, from: next) == 4)
    }

    /// 不变量:面板上显示的「下次续期时刻」,那个时刻**一定会真的续期**。
    ///
    /// 这条直接盯住"两处逻辑各算各的"那个缺陷 —— 旧实现里会出现
    /// 「下次 今天 04:00」但那一刻因为今天已续过而不会续的情况。
    @Test func nextRenewalDateAlwaysPointsToAMomentThatActuallyRenews() {
        let cal = Self.shanghai
        let scenarios: [(name: String, now: Date, last: Date?)] = [
            ("还没到点、没续过",
             Self.date(2026, 11, 3, 3, 0, calendar: cal), nil),
            ("还没到点、今天已续过",
             Self.date(2026, 11, 3, 3, 0, calendar: cal),
             Self.date(2026, 11, 3, 2, 0, calendar: cal)),
            ("到点了、今天已续过",
             Self.date(2026, 11, 3, 5, 0, calendar: cal),
             Self.date(2026, 11, 3, 4, 30, calendar: cal)),
            ("昨天的续期",
             Self.date(2026, 11, 3, 5, 0, calendar: cal),
             Self.date(2026, 11, 2, 4, 0, calendar: cal)),
        ]

        for scenario in scenarios {
            guard let next = MinimaxManager.nextRenewalDate(
                now: scenario.now,
                lastRenewalAt: scenario.last,
                calendar: cal
            ) else { continue }

            #expect(
                MinimaxManager.shouldRenewToday(
                    now: next,
                    lastRenewalAt: scenario.last,
                    calendar: cal
                ) == true,
                "「下次续期时刻」必须是真的会续的时刻 —— \(scenario.name)"
            )
            #expect(
                next > scenario.now,
                "「下次」不能是过去或当前时刻 —— \(scenario.name)"
            )
        }
    }
}
