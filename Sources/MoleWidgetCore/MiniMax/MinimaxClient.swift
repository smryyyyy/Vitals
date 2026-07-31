import Foundation

/// Thin URLSession wrapper around the MiniMax usage API. The three cookies
/// and `x-group-id` header are the entire auth surface — no bearer token,
/// no API key, no signature. All headers required by the backend are set
/// explicitly so we don't inherit the system UA.
public struct MinimaxClient {
    public let credentials: MinimaxCredentials

    public init(credentials: MinimaxCredentials) {
        self.credentials = credentials
    }

    private static let endpoint = URL(string: "https://www.minimaxi.com/backend/account/token_plan/remains_percent")!

    /// Issues the GET and returns the decoded payload, or an error describing
    /// the failure mode (network, HTTP status, decode). Cookie expiration
    /// surfaces as HTTP 401/403 — the caller decides how to surface it.
    public func fetchUsage() async throws -> MinimaxUsageResponse {
        guard credentials.isValid else {
            throw MinimaxError.notAuthenticated
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Cookies — only the three we need; the rest are noise the backend
        // would gladly ignore but they pad the request for no reason.
        let cookies = [
            "_token": credentials.token,
            "HERTZ-SESSION": credentials.session,
            "minimax_group_id_v2": credentials.groupId,
        ].map { "\($0.key)=\($0.value)" }.joined(separator: "; ")

        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(credentials.groupId, forHTTPHeaderField: "x-group-id")
        request.setValue("https://platform.minimaxi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.minimaxi.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MinimaxError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            // Auth trio is stale — the user must log in again and re-paste.
            throw MinimaxError.unauthorized
        default:
            throw MinimaxError.httpStatus(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(MinimaxUsageResponse.self, from: data)
        } catch {
            throw MinimaxError.decode(error)
        }
    }
}

public enum MinimaxError: LocalizedError, Equatable {
    case notAuthenticated
    case unauthorized
    case httpStatus(Int)
    case decode(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "尚未配置 MiniMax 认证信息"
        case .unauthorized:     return "认证已过期，请重新登录 platform.minimaxi.com 并更新 cookie"
        case .httpStatus(let code): return "服务器返回 \(code)"
        case .decode:           return "返回数据格式错误"
        case .invalidResponse:  return "无有效响应"
        }
    }

    public static func == (lhs: MinimaxError, rhs: MinimaxError) -> Bool {
        switch (lhs, rhs) {
        case (.notAuthenticated, .notAuthenticated): return true
        case (.unauthorized, .unauthorized): return true
        case (.httpStatus(let a), .httpStatus(let b)): return a == b
        case (.invalidResponse, .invalidResponse): return true
        case (.decode, .decode): return true
        default: return false
        }
    }
}
