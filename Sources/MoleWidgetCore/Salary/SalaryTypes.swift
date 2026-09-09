import Foundation

/// 用户配置的工资参数。`SalaryManager` 把它序列化为 JSON 存到 UserDefaults。
/// v2:删除了 `isPreTax` / `workdaysPerMonth` / `workMode` / 旧名 `monthlySalary`,
/// 改为 `monthlyNetSalary`(税后月薪)+ 自动按法定节假日算工作日。
public struct SalarySettings: Equatable, Codable {
    /// 税后月薪,元
    public var monthlyNetSalary: Double
    /// 上班时间(分, 0..1439)。例 9:00 = 540
    public var clockInMinute: Int
    /// 下班时间(分)。例 18:00 = 1080
    public var clockOutMinute: Int
    /// 午休开始(分)
    public var lunchStartMinute: Int
    /// 午休结束(分)
    public var lunchEndMinute: Int
    /// true = 午休算工作时间(分母不变),false = 午休不算(分母减午休)
    public var includeLunchInEarnings: Bool
    /// 入职日期(可选),用于算在职累计
    public var hireDate: Date?

    public init(
        monthlyNetSalary: Double = 10000,
        clockInMinute: Int = 9 * 60,
        clockOutMinute: Int = 18 * 60,
        lunchStartMinute: Int = 12 * 60,
        lunchEndMinute: Int = 13 * 60,
        includeLunchInEarnings: Bool = true,
        hireDate: Date? = nil
    ) {
        self.monthlyNetSalary = monthlyNetSalary
        self.clockInMinute = clockInMinute
        self.clockOutMinute = clockOutMinute
        self.lunchStartMinute = lunchStartMinute
        self.lunchEndMinute = lunchEndMinute
        self.includeLunchInEarnings = includeLunchInEarnings
        self.hireDate = hireDate
    }

    /// 已配置月薪即视为可用
    public var isConfigured: Bool {
        monthlyNetSalary > 0
    }

    /// 每日应工作时数(含/不含午休)
    public var dailyWorkHours: Double {
        let totalMin = clockOutMinute - clockInMinute
        let lunchMin = includeLunchInEarnings ? 0 : (lunchEndMinute - lunchStartMinute)
        return Double(max(0, totalMin - lunchMin)) / 60.0
    }
}

/// 高层时段状态,驱动视图。
public enum SalaryState: String, Equatable {
    case beforeWork    // 上班前
    case working       // 上班中
    case onLunch       // 午休中(仅 includeLunchInEarnings=false 时出现)
    case afterWork     // 下班后(今日已锁定)
    case dayOff        // 休息日
    case unconfigured  // 未配置
}

/// 工资视图的冻结快照。每秒由 `SalaryEngine.compute` 重算一次,
/// `@Observable` 包装仅负责发布最新值。
public struct SalarySnapshot: Equatable {
    public let state: SalaryState
    public let todayEarned: Double
    public let todayDaily: Double
    public let todayWorkedSeconds: Double
    public let todayTotalSeconds: Double
    public let progress: Double
    public let timeToOffDuty: TimeInterval?
    public let timeToWorkStart: TimeInterval?
    public let timeToLunchEnd: TimeInterval?
    public let hourlyRate: Double
    public let secondRate: Double
    public let yearEarned: Double
    public let monthEarned: Double
    public let totalEarned: Double
    public let error: String?
    public let tableExpired: Bool
    public let now: Date

    public init(
        state: SalaryState,
        todayEarned: Double = 0,
        todayDaily: Double = 0,
        todayWorkedSeconds: Double = 0,
        todayTotalSeconds: Double = 0,
        progress: Double = 0,
        timeToOffDuty: TimeInterval? = nil,
        timeToWorkStart: TimeInterval? = nil,
        timeToLunchEnd: TimeInterval? = nil,
        hourlyRate: Double = 0,
        secondRate: Double = 0,
        yearEarned: Double = 0,
        monthEarned: Double = 0,
        totalEarned: Double = 0,
        error: String? = nil,
        tableExpired: Bool = false,
        now: Date = Date()
    ) {
        self.state = state
        self.todayEarned = todayEarned
        self.todayDaily = todayDaily
        self.todayWorkedSeconds = todayWorkedSeconds
        self.todayTotalSeconds = todayTotalSeconds
        self.progress = progress
        self.timeToOffDuty = timeToOffDuty
        self.timeToWorkStart = timeToWorkStart
        self.timeToLunchEnd = timeToLunchEnd
        self.hourlyRate = hourlyRate
        self.secondRate = secondRate
        self.yearEarned = yearEarned
        self.monthEarned = monthEarned
        self.totalEarned = totalEarned
        self.error = error
        self.tableExpired = tableExpired
        self.now = now
    }
}
