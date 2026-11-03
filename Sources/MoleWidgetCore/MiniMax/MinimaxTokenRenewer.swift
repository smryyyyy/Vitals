//
//  MinimaxTokenRenewer.swift
//  Vitals - MiniMax module
//
//  自动续期 `_token`(JWT),让用户不必每隔一段时间就重抓 cookie。
//
//  协议(2026-11-03 真机实测,不是照抄文档):
//  - `_token` 本身就是 JWT,exp 约 40 天。
//  - 续期端点:`POST /v1/api/user/renewal`
//      · body 是**空串**(不是 `{}`)—— 写错服务端会报签名错误
//      · token 必须放 HTTP 头 `token:`,同时 query 里也带一份
//      · 另带 `x-timestamp` / `x-signature` 两个头
//  - 签名:`x-signature = md5(f"{ts}{盐值}{实际 body}")`,盐值与服务端一致。
//  - 实测只要 token 头 + 签名 + `unix` 参数就能续,**不需要** uuid / device_id /
////    user_id 那一堆设备指纹参数。
//  - 续期后有效期重置为「当前时间 + 40 天」。
//  - **续期不会吊销旧 token** —— 实测续期两次后旧 token 仍能正常拉用量。
//    这条很关键:续期失败时继续用旧 token 是安全的,不会把用户配置搞挂。
//
//  移植自本地 minimaxday 项目的 `signin.py` 的 `renew_token()`。
//

import CryptoKit
import Foundation

/// 自动续期 MiniMax `_token`。
public struct MinimaxTokenRenewer: Sendable {

    /// 续期端点域名。`agent.minimax.cn`(国内站)与 `agent.minimaxi.com`(国际站)
    /// 实测都能用同一把 token 续期,这里取国内站。
    public static let host = "agent.minimax.cn"

    private static let renewalPath = "/v1/api/user/renewal"
    /// 签名盐值(与服务端一致,硬编码)。
    private static let signSalt = "I*7Cf%WZ#S&%1RlZJ&C2"
    private static let timeoutSeconds: TimeInterval = 15.0
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/150.0.0.0 Safari/537.36"

    // MARK: - 过期时间

    /// 解析 JWT 的 exp(**不做签名校验** —— 我们只需要知道它什么时候过期,
    /// 签名校验由服务端负责)。解析不出来返回 nil。
    public static func expiry(of token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        // base64url → base64,并补齐 padding
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    /// 剩余有效天数。解析不出来返回 nil。
    public static func remainingDays(of token: String) -> Double? {
        guard let expiry = expiry(of: token) else { return nil }
        return expiry.timeIntervalSinceNow / 86_400
    }

    // MARK: - 签名

    /// 计算 `x-signature`:`md5(f"{ts}{盐值}{body}")`。
    /// body 必须是**实际发出去的字节** —— renewal 的 body 是空串。
    static func signature(timestamp: String, body: String = "") -> String {
        let raw = timestamp + signSalt + body
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 续期

    /// 续期并返回新 token。失败抛 `MinimaxRenewalError` —— 调用方决定是否降级。
    public static func renew(token: String) async throws -> String {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw MinimaxRenewalError.missingToken }

        let now = Date()
        let ts = String(Int(now.timeIntervalSince1970))
        let unix = String(Int(now.timeIntervalSince1970 * 1000))

        var components = URLComponents(string: "https://\(host)\(renewalPath)")
        components?.queryItems = [
            URLQueryItem(name: "unix", value: unix),
            URLQueryItem(name: "token", value: clean),
        ]
        guard let url = components?.url else { throw MinimaxRenewalError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue(clean, forHTTPHeaderField: "token")
        request.setValue(ts, forHTTPHeaderField: "x-timestamp")
        request.setValue(signature(timestamp: ts), forHTTPHeaderField: "x-signature")
        request.setValue("https://\(host)", forHTTPHeaderField: "Origin")
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        // 刻意**不带** Content-Type —— body 是空串,真实客户端的 renewal 请求
        // 只有 content-length: 0,带 content-type 会被网关判成另一类请求。

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MinimaxRenewalError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MinimaxRenewalError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MinimaxRenewalError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MinimaxRenewalError.decodeFailed
        }

        // 业务错误同样藏在 200 里:statusInfo.code != 0 就是失败。
        let statusInfo = json["statusInfo"] as? [String: Any]
        let code = statusInfo?["code"] as? Int ?? -1
        guard code == 0 else {
            let message = statusInfo?["message"] as? String ?? ""
            throw MinimaxRenewalError.server(code, message)
        }
        guard let newToken = (json["data"] as? [String: Any])?["token"] as? String,
              !newToken.isEmpty else {
            throw MinimaxRenewalError.noNewToken
        }
        return newToken
    }
}

/// 续期失败的原因。全部可枚举,不用靠字符串区分。
public enum MinimaxRenewalError: Error, LocalizedError, Equatable {
    /// 没有 token 可续
    case missingToken
    /// URL 拼不出来
    case invalidURL
    /// 响应不是 HTTP 响应
    case invalidResponse
    /// 网络层失败(断网 / DNS / TLS / 超时)
    case transport(String)
    /// HTTP 非 2xx
    case httpStatus(Int)
    /// 业务错误(statusInfo.code != 0)
    case server(Int, String)
    /// 响应里没有新 token
    case noNewToken
    /// 响应不是合法 JSON
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .missingToken: "缺少 token,无法续期"
        case .invalidURL: "续期地址无效"
        case .invalidResponse: "续期响应无效"
        case .transport(let msg): "续期网络错误: \(msg)"
        case .httpStatus(let code): "续期失败 (HTTP \(code))"
        case .server(let code, let msg): "续期被拒 (\(code)): \(msg)"
        case .noNewToken: "续期响应里没有新 token"
        case .decodeFailed: "续期响应解析失败"
        }
    }
}
