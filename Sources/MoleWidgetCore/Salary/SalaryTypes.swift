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
    /// 入职日期(可选),用于算在职累计。
    /// nil = 用户没填,此时 `totalEarned` 恒为 0,视图按本字段是否为空决定
    /// 是否展示「在职累计」这一行 —— 显示 0 会让用户误以为工作了 10 年却没赚到钱。
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

    // MARK: - 跨午夜班次归一化

    /// 下班时刻是否落在次日(跨午夜班次,如 22:00 → 02:00)。
    /// 表单只提供「当天第几分钟」,凌晨的下班时分在数值上小于上班时分,
    /// 必须靠这个判定把它归到次日,否则班次时长会算成负数。
    public var clockOutIsNextDay: Bool {
        clockOutMinute < clockInMinute
    }

    /// 把一个「当天第几分钟」换算到班次时间轴上。
    /// 跨午夜时,任何小于上班时刻的分值都属于次日,补 1440 分钟。
    public func normalizedMinute(_ minute: Int) -> Int {
        (clockOutIsNextDay && minute < clockInMinute) ? minute + 1440 : minute
    }

    public var normalizedClockInMinute: Int { clockInMinute }
    public var normalizedClockOutMinute: Int { normalizedMinute(clockOutMinute) }
    public var normalizedLunchStartMinute: Int { normalizedMinute(lunchStartMinute) }
    public var normalizedLunchEndMinute: Int { normalizedMinute(lunchEndMinute) }

    /// 当日班次时长(分钟)。跨午夜时下班算到次日,所以是 1440 + 差值。
    /// 加班不计入:超出 `normalizedClockOutMinute` 之后不再累加。
    public var shiftMinutes: Int {
        max(0, normalizedClockOutMinute - normalizedClockInMinute)
    }

    /// 应从班次里扣掉的午休分钟数(午休计入收入时为 0)。
    public var excludedLunchMinutes: Int {
        includeLunchInEarnings ? 0 : max(0, normalizedLunchEndMinute - normalizedLunchStartMinute)
    }

    /// 每日应工作时数(含/不含午休)。
    /// 跨午夜班次走归一化后的时刻,保证「下班时刻的 earned 恰好等于日薪」这条性质
    /// 在夜班下依然成立:时薪 = 日薪 / 班次小时数。
    public var dailyWorkHours: Double {
        Double(max(0, shiftMinutes - excludedLunchMinutes)) / 60.0
    }

    /// 每日应工作秒数,分母与 `dailyWorkHours` 同源。
    public var dailyWorkSeconds: Double {
        Double(max(0, shiftMinutes - excludedLunchMinutes)) * 60.0
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
