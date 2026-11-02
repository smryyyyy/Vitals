//
//  OCRError.swift
//  Vitals - Screenshot module
//
//  OCR / 翻译模块的统一 typed error。
//  AI 面板根据这些错误显示对应的提示文案。
//

import Foundation

/// OCR / 翻译模块的统一 typed error。
/// AI 面板根据这些错误显示对应的提示文案。
///
/// public:`ScreenshotServices.testAPIConnection()` 与 `ScreenshotSettingsManager`
/// 是跨 module 的公开 API,返回值要带上具体失败原因,类型必须 public。
public nonisolated enum OCRError: Error, Sendable, Equatable {
    /// OCR 识别超时
    case timeout
    /// OCR 引擎报错
    case visionFailed(String)
    /// 翻译未配置 API Key
    case noAPIKey
    /// API Key 无效或被拒绝（401/403）
    case unauthorized
    /// 限流（429）
    case rateLimit
    /// 翻译失败（其它 4xx/5xx）
    case translateFailed(Int, String)
    /// MiniMax 业务错误（HTTP 200,但 body 内 base_resp.status_code != 0）。
    ///
    /// 典型场景:模型已下线(2069)、参数非法(1002)、限流、额度不足等。
    /// 服务端用 200 承载业务错误 —— 只看 HTTP 状态码会把它误判成成功,
    /// 然后在解析 choices 时炸成「unknown response shape」,真实原因彻底丢失。
    case miniMaxAPIError(Int, String)
    /// 解析响应失败（无法解析 JSON / content 为空）
    case responseParseFailed(String)
    /// 网络错误
    case network(String)

    var localizedDescription: String {
        switch self {
        case .timeout: "识别超时"
        case .visionFailed(let msg): "Vision 识别失败: \(msg)"
        case .noAPIKey: "未配置 MiniMax API Key"
        case .unauthorized: "API Key 无效或已过期"
        case .rateLimit: "请求过于频繁,请稍后再试"
        case .translateFailed(let code, let msg): "翻译失败 (\(code)): \(msg)"
        case .miniMaxAPIError(let code, let msg): "MiniMax 接口错误 (\(code)): \(msg)"
        case .responseParseFailed(let msg): "响应解析失败: \(msg)"
        case .network(let msg): "网络错误: \(msg)"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .noAPIKey, .unauthorized: false
        case .timeout, .rateLimit, .network: true
        case .visionFailed, .translateFailed, .responseParseFailed, .miniMaxAPIError: false
        }
    }
}