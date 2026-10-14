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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let urlError as URLError {
            // 断网 / DNS / 超时在这里归一,UI 才有办法区分"该重试"和"该换 cookie"
            throw MinimaxError.transport(urlError.code)
        }

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
    /// URLSession 层面的失败(断网 / DNS / TLS / 超时)。在 `fetchUsage` 里
    /// 把 `URLError` 归一到这一类,避免系统英文文案直接漏到 UI 上。
    case transport(URLError.Code)

    public var errorDescription: String? {
        kind.message
    }

    /// 结构化分类。UI 用它选文案和图标,不用再解析字符串。
    public var kind: MinimaxErrorKind {
        switch self {
        case .notAuthenticated:
            return .notConfigured
        case .unauthorized:
            return .authExpired
        case .httpStatus(let code):
            return .server(code)
        case .decode, .invalidResponse:
            return .unknown
        case .transport(let code):
            switch code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet,
                 .networkConnectionLost,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .dnsLookupFailed,
                 .internationalRoamingOff,
                 .dataNotAllowed:
                return .networkUnavailable
            default:
                return .unknown
            }
        }
    }

    public static func == (lhs: MinimaxError, rhs: MinimaxError) -> Bool {
        switch (lhs, rhs) {
        case (.notAuthenticated, .notAuthenticated): return true
        case (.unauthorized, .unauthorized): return true
        case (.httpStatus(let a), .httpStatus(let b)): return a == b
        case (.invalidResponse, .invalidResponse): return true
        case (.decode, .decode): return true
        case (.transport(let a), .transport(let b)): return a == b
        default: return false
        }
    }
}
