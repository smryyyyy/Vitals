//
//  OCRError.swift
//  Vitals - Screenshot module
//
//  OCR / 翻译模块的统一 typed error。
//  AI 面板根据这些错误显示对应的提示文案。
//

import Foundation

nonisolated enum OCRError: Error, Sendable, Equatable {
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
        case .responseParseFailed(let msg): "响应解析失败: \(msg)"
        case .network(let msg): "网络错误: \(msg)"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .noAPIKey, .unauthorized: false
        case .timeout, .rateLimit, .network: true
        case .visionFailed, .translateFailed, .responseParseFailed: false
        }
    }
}