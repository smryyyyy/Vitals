import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct TempDiagTests {
    @Test func diag_nightShift() {
        let cal = ChineseWorkdayCalendar.calendar
        var c = DateComponents()
        c.year = 2024; c.month = 6; c.day = 3; c.timeZone = TimeZone.current
        let start = cal.date(from: c)!
        print("DIAG start=\(start)")
        print("DIAG byAdding1470=\(cal.date(byAdding: .minute, value: 1470, to: start)!)")
        print("DIAG byAdding1320=\(cal.date(byAdding: .minute, value: 1320, to: start)!)")
        print("DIAG range=\(cal.range(of: .day, in: .month, for: start)?.count ?? -1)")
        print("DIAG monthAdd1=\(cal.date(byAdding: .month, value: 1, to: start)!)")
        let startMay = cal.date(from: DateComponents(year: 2024, month: 5, day: 31))!
        print("DIAG may31plus1month=\(cal.date(byAdding: .month, value: 1, to: startMay)!)")
        print("DIAG wbMay31ToJun3=\(ChineseWorkdayCalendar.workdaysBetween(from: startMay, to: cal.date(from: DateComponents(year: 2024, month: 6, day: 3))!))")

        var s = SalarySettings(monthlyNetSalary: 21000, clockInMinute: 22 * 60, clockOutMinute: 2 * 60,
                               lunchStartMinute: 30, lunchEndMinute: 90, includeLunchInEarnings: false)
        print("DIAG nClockIn=\(s.normalizedClockInMinute) nClockOut=\(s.normalizedClockOutMinute) nLunchS=\(s.normalizedLunchStartMinute) nLunchE=\(s.normalizedLunchEndMinute)")
        print("DIAG hours=\(s.dailyWorkHours) seconds=\(s.dailyWorkSeconds) shift=\(s.shiftMinutes) lunch=\(s.excludedLunchMinutes)")
        let snap = SalaryEngine.compute(settings: s, now: cal.date(from: DateComponents(year: 2024, month: 6, day: 4, hour: 1, minute: 0))!)
        print("DIAG state=\(snap.state.rawValue) progress=\(snap.progress) worked=\(snap.todayWorkedSeconds) total=\(snap.todayTotalSeconds) earned=\(snap.todayEarned) daily=\(snap.todayDaily)")

        // 复刻 SalaryEngineTests 的 date() 辅助函数(用 Calendar.current)
        var c2 = DateComponents()
        c2.year = 2024; c2.month = 6; c2.day = 4; c2.hour = 1; c2.minute = 0; c2.timeZone = TimeZone.current
        let viaCurrent = Calendar.current.date(from: c2)!
        print("DIAG viaCurrent=\(viaCurrent)")
        let snap2 = SalaryEngine.compute(settings: s, now: viaCurrent)
        print("DIAG viaCurrent state=\(snap2.state.rawValue) progress=\(snap2.progress) worked=\(snap2.todayWorkedSeconds) total=\(snap2.todayTotalSeconds)")
    }
}
