import Foundation

/// One quota bucket reported by the MiniMax API (5h or weekly).
/// `usedPercent` is 0…100; `remainsTime` is the seconds left until the
/// counter resets; `endTime` is the absolute reset moment (UTC).
public struct MinimaxLimit: Equatable, Codable {
    public let usedPercent: Int
    public let remainsTime: TimeInterval?
    public let endTime: Date?

    public init(usedPercent: Int, remainsTime: TimeInterval? = nil, endTime: Date? = nil) {
        self.usedPercent = usedPercent
        self.remainsTime = remainsTime
        self.endTime = endTime
    }

    /// Used as a 0…1 fraction for the UI bar.
    public var usedFraction: Double {
        min(1.0, max(0.0, Double(usedPercent) / 100.0))
    }
}

/// Aggregate view of the MiniMax account. The video bucket is intentionally
/// dropped — only the 5h and weekly counters are surfaced.
///
/// 刻意不带 `error` 字段:用量数据和"这次拉取失败"是两件事,失败时不应该把
/// 上一次成功的数字一起抹掉。失败信息由 `MinimaxManager.lastError` 单独承载。
public struct MinimaxSnapshot: Equatable, Codable {
    public let fiveHour: MinimaxLimit?
    public let weekly: MinimaxLimit?
    public let fetchedAt: Date

    public init(
        fiveHour: MinimaxLimit? = nil,
        weekly: MinimaxLimit? = nil,
        fetchedAt: Date = Date()
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
    }

    public var isEmpty: Bool { fiveHour == nil && weekly == nil }
}

/// Authentication trio required by the MiniMax backend. None of the values
/// are persisted in plain-text — see `MinimaxKeychain`.
public struct MinimaxCredentials: Equatable, Codable {
    public let token: String        // _token JWT
    public let session: String      // HERTZ-SESSION
    public let groupId: String      // minimax_group_id_v2 (== x-group-id)

    public init(token: String, session: String, groupId: String) {
        self.token = token
        self.session = session
        self.groupId = groupId
    }

    public var isValid: Bool {
        !token.isEmpty && !session.isEmpty && !groupId.isEmpty
    }
}

/// Raw DTOs that mirror the JSON shape exactly. Kept private to the mapper
/// to keep `Snapshot` decoupled from the wire format.
public struct MinimaxModelRemains: Decodable {
    public let modelName: String
    public let currentIntervalUsedPercent: String?  // "13%" 字符串带百分号
    public let currentIntervalTotalPercent: String?
    public let currentWeeklyUsedPercent: String?
    public let currentWeeklyTotalPercent: String?
    public let startTime: Int64?     // unix ms
    let endTime: Int64?       // unix ms
    let weeklyStartTime: Int64?
    public let weeklyEndTime: Int64?
    public let remainsTime: Int64?   // ms until 5h reset
    public let weeklyRemainsTime: Int64?  // ms until weekly reset

    public enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalUsedPercent = "current_interval_used_percent"
        case currentIntervalTotalPercent = "current_interval_total_percent"
        case currentWeeklyUsedPercent = "current_weekly_used_percent"
        case currentWeeklyTotalPercent = "current_weekly_total_percent"
        case startTime = "start_time"
        case endTime = "end_time"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case remainsTime = "remains_time"
        case weeklyRemainsTime = "weekly_remains_time"
    }
}

extension MinimaxModelRemains {
    /// Parse "13%" → 13, "100%" → 100. Returns 0 for nil or malformed input.
    public func parsePercent(_ raw: String?) -> Int {
        guard let raw = raw, let n = Int(raw.replacingOccurrences(of: "%", with: "")) else {
            return 0
        }
        return n
    }
}

public struct MinimaxBaseResp: Decodable {
    public let statusCode: Int
    public let statusMsg: String?

    public enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case statusMsg = "status_msg"
    }
}

public struct MinimaxUsageResponse: Decodable {
    public let modelRemains: [MinimaxModelRemains]
    public let baseResp: MinimaxBaseResp?

    public enum CodingKeys: String, CodingKey {
        case modelRemains = "model_remains"
        case baseResp = "base_resp"
    }
}

// MARK: - 失败分类

/// 拉取失败的分类。UI 按类型选文案和图标,不再靠字符串比对。
///
/// 为什么建模:之前所有失败都塞进一个 `error: String?`,认证过期和断网在
/// 浮窗上长得一模一样,用户只能看到一段话猜下一步该干什么。
public enum MinimaxErrorKind: Equatable {
    /// 从没配置过 cookie
    case notConfigured
    /// Keychain 里存着,但当前读不出来(锁屏 / 未解锁 / 权限拒绝)
    case keychainUnavailable
    /// HTTP 401/403,cookie 过期
    case authExpired
    /// 断网 / DNS 解析失败 / 连不上
    case networkUnavailable
    /// 请求超时
    case timeout
    /// 服务端返回了非 2xx / 非 401 / 403
    case server(Int)
    /// 解码失败等其它情况
    case unknown

    /// 浮窗和设置页共用的文案,保持两边说法一致。
    public var message: String {
        switch self {
        case .notConfigured:       return "未配置,请在 MiniMax 设置里填入 cookie"
        case .keychainUnavailable: return "钥匙串已锁定,解锁后重试"
        case .authExpired:         return "认证已过期,请重新登录并更新 cookie"
        case .networkUnavailable:  return "网络不可用,连不上 minimaxi.com"
        case .timeout:             return "请求超时,请稍后重试"
        case .server(let code):    return "服务器返回 \(code)"
        case .unknown:             return "拉取失败"
        }
    }

    /// 浮窗行的前缀图标。认证过期最需要用户处理,用感叹号;网络类用弱化的箭头。
    public var symbol: String {
        switch self {
        case .notConfigured, .keychainUnavailable, .authExpired: return "!"
        case .networkUnavailable, .timeout: return "↯"
        case .server: return "!"
        case .unknown: return "?"
        }
    }

    /// 认证类错误需要用户去改设置,不该用和"临时抖动"一样的呈现方式。
    public var needsUserAction: Bool {
        switch self {
        case .notConfigured, .keychainUnavailable, .authExpired: return true
        default: return false
        }
    }
}
