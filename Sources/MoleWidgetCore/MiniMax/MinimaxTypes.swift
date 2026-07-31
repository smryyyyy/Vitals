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
public struct MinimaxSnapshot: Equatable, Codable {
    public let fiveHour: MinimaxLimit?
    public let weekly: MinimaxLimit?
    public let fetchedAt: Date
    public let error: String?

    public init(
        fiveHour: MinimaxLimit? = nil,
        weekly: MinimaxLimit? = nil,
        fetchedAt: Date = Date(),
        error: String? = nil
    ) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.error = error
    }

    public var isEmpty: Bool { fiveHour == nil && weekly == nil }

    /// When the API call or the auth has gone bad — show an error placeholder.
    public var isError: Bool { error != nil }
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
