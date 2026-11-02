//
//  MiniMaxTranslationClient.swift
//  Vitals - Screenshot module
//
//  MiniMax chat completions API 调用客户端。
//  - 端点:https://api.minimax.cn/v1/chat/completions
//    (官方现行 OpenAI 兼容端点,文档见 platform.minimax.cn/docs/api-reference/text-chat-openai;
//     旧路径 /v1/text/chatcompletion_v2 仍可达但已非主推)
//  - 模型:MiniMax-M3.1-Flash(2026-11-02 实测 200)
//  - 请求格式:OpenAI 兼容(messages + model + max_completion_tokens)
//  - 响应:同时兼容 choices[].message.content 和 reply 字段
//  - 批量翻译:一次调用翻译所有原文,系统 prompt 严格约束"绝不合并/拆分行"
//  - 15s 超时
//
//  **业务错误藏在 HTTP 200 里**:MiniMax 用 200 + body 内 base_resp.status_code
//  承载业务错误(模型下线 = 2069、参数非法 = 1002 ...)。只看 HTTP 状态码会把
//  "模型已下线"当成成功,再在解析 choices 时炸成 "unknown response shape",
//  真实原因丢失 —— 本客户端先查 base_resp,再走内容解析。
//
//  **行数不匹配兜底**:模型有时不严格遵循 prompt,把多行原文合并成一段。
//  旧版本在行数不匹配时直接让画布空着没译文覆盖 —— 体验差。
//  新版本用 `ParsedTranslation.lines + mergedParagraph` 双轨返回:
//    - count 匹配 → 仅 lines,渲染时按行 zip 覆盖(常规路径)
//    - count 不匹配 → lines + mergedParagraph,渲染时整段覆盖在首行 OCR 上
//  OCRService 拿到 ParsedTranslation 后用 TranslatedOverlay 携带 mergedParagraph,
//  EditorView / EditorCompositeRenderer 渲染时按 isLineMode / isParagraphMode 分流。
//

import Foundation

/// 模型响应的解析结果。
/// - `lines`:模型实际返回的拆分(可能是 JSON 数组,也可能是按行 split 的回退结果)
/// - `mergedParagraph`:`nil` 表示行数匹配,走行覆盖模式;`非 nil` 表示不匹配,
///   走段落覆盖模式 —— 把 `mergedParagraph` 整段覆盖在原文首行位置上。
nonisolated struct ParsedTranslation: Sendable, Equatable {
    let lines: [String]
    let mergedParagraph: String?

    /// 行覆盖模式:逐行 zip 配对覆盖(默认路径)。
    var isLineMode: Bool { mergedParagraph == nil }

    /// 段落覆盖模式:整段覆盖(兜底路径)。
    var isParagraphMode: Bool { mergedParagraph != nil }

    /// 便捷构造:行覆盖模式(mergedParagraph = nil)。
    init(lines: [String]) {
        self.lines = lines
        self.mergedParagraph = nil
    }

    /// 完整构造:可指定 mergedParagraph(段落覆盖模式)。
    init(lines: [String], mergedParagraph: String?) {
        self.lines = lines
        self.mergedParagraph = mergedParagraph
    }
}

/// MiniMax 翻译客户端抽象协议。`OCRService` 通过该协议注入,
/// 让单元测试可以用 mock 实现替换真实 HTTP 调用,避免网络依赖。
/// 生产代码走 `MiniMaxTranslationClient` actor 实现。
protocol MiniMaxTranslationClientProtocol: Sendable {
    /// 批量翻译多行文本到目标语言。返回 `ParsedTranslation`:
    /// - 行数匹配 → `mergedParagraph == nil`,调用方走行覆盖模式
    /// - 行数不匹配 → `mergedParagraph` 兜底,调用方走段落覆盖模式
    func translate(
        lines: [String],
        targetLanguage: String,
        apiKey: String
    ) async throws -> ParsedTranslation
}

actor MiniMaxTranslationClient: MiniMaxTranslationClientProtocol {
    /// 基础端点。官方现行文档:
    /// https://platform.minimax.cn/docs/api-reference/text-chat-openai
    /// 用 OpenAI 兼容的 /v1/chat/completions。实测 api.minimax.cn / api.minimaxi.com /
    /// api.minimax.chat 三个域名都接受同一把 key,但官方文档域名是 api.minimax.cn。
    private static let baseURL = URL(string: "https://api.minimax.cn/v1/chat/completions")!

    /// 15s 超时
    private static let timeoutSeconds: TimeInterval = 15.0

    /// 默认模型。MiniMax-M3.1-Flash —— 2026-11-02 实测 200。
    ///
    /// 坑(实测记录,别凭记忆改):
    /// - `MiniMax-M3.1`(不带后缀)**不存在**,服务端返回 HTTP 400 —— 必须带 `-Flash`。
    /// - `MiniMax-M3` 存在,但思考内容会混进 content(带 `<think>` 标签),不干净。
    /// - 旧模型 `abab6.5s-chat` **已下线**,服务端返回 HTTP 200 + base_resp 2069
    ///   「The model ... is no longer available.」—— 这正是本客户端要查 base_resp 的原因。
    private static let defaultModel = "MiniMax-M3.1-Flash"

    /// Bug-LCM-1:严格约束 prompt,要求模型绝不合并/拆分多行原文,输出严格 JSON 数组。
    /// 实测 6.5s-chat 偶尔会"贴心地"把 2 行原文合并翻译成 1 行译文,导致画布上
    /// 行覆盖失败 —— 严格 prompt 是第一道防线。
    /// 非 `private`:测试需要直接断言 prompt 内容,防止未来重构无意中放宽约束。
    static func systemPrompt(targetLanguage: String) -> String {
        """
        你是一个翻译助手。**严格遵守以下约束**:
        1. **每行原文独立翻译,绝不把多行原文合并成 1 行**
        2. **绝不把 1 行原文拆成多行**
        3. 输出严格 JSON 字符串数组,长度 = 输入行数,顺序对应
        4. 不要 markdown 包装,不要任何额外说明
        翻译为:\(targetLanguage)
        """
    }

    /// 批量翻译多行文本到目标语言。返回 `ParsedTranslation` —— 即使行数不匹配
    /// 也不再 throw,而是用 `mergedParagraph` 兜底,避免画布上没译文覆盖。
    func translate(
        lines: [String],
        targetLanguage: String,
        apiKey: String
    ) async throws -> ParsedTranslation {
        guard !lines.isEmpty else {
            return ParsedTranslation(lines: [], mergedParagraph: nil)
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OCRError.noAPIKey
        }

        let systemPrompt = Self.systemPrompt(targetLanguage: targetLanguage)
        let linesText = lines.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        let userPrompt = "请翻译下列文字为\(targetLanguage):\n\(linesText)"

        let requestBody: [String: Any] = [
            "model": Self.defaultModel,
            // `max_tokens` 已被官方标记弃用,新端点用 `max_completion_tokens`。
            "max_completion_tokens": 4096,
            // 不传 temperature:MiniMax-M3.1-Flash 的 temperature 固定为 1,传了不生效。
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeoutSeconds
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                throw OCRError.timeout
            }
            throw OCRError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OCRError.responseParseFailed("invalid response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw OCRError.unauthorized
        case 429:
            throw OCRError.rateLimit
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OCRError.translateFailed(http.statusCode, bodyText.prefix(200).description)
        }

        // 解析响应。顺序很重要:先查业务错误,再提内容。
        //
        // MiniMax 用 HTTP 200 + body 内 base_resp.status_code 承载业务错误
        // (模型下线 = 2069、参数非法 = 1002)。若直接去解析 choices,会炸成
        // 「unknown response shape」,真实原因丢失 —— 这里先把它变成可读的 typed error。
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OCRError.responseParseFailed("JSON parse failed")
        }
        if let apiError = Self.businessError(in: json) {
            throw apiError
        }

        // 同时兼容 OpenAI 格式和 MiniMax v1 原生 reply 字段。
        // Bug-LCM-1 修复:行数不匹配不再 throw,改用 mergedParagraph 兜底。
        let translatedText = try Self.extractContent(from: json)
        return Self.parseTranslatedTexts(translatedText, expectedCount: lines.count)
    }

    /// 识别 body 内的业务错误(base_resp.status_code != 0)。
    ///
    /// 返回非 nil 表示服务端回了业务错误,调用方应直接抛出,不要继续解析 choices。
    /// 暴露为 internal static:单元测试直接断言,不依赖 HTTP。
    static func businessError(in json: Any) -> OCRError? {
        guard let dict = json as? [String: Any],
              let baseResp = dict["base_resp"] as? [String: Any],
              let code = baseResp["status_code"] as? Int,
              code != 0 else {
            return nil
        }
        let msg = (baseResp["status_msg"] as? String) ?? "unknown error"
        return .miniMaxAPIError(code, msg)
    }

    /// 提取响应文本 content。优先 OpenAI 格式,fallback 到 MiniMax 原生 reply 字段。
    ///
    /// 入参是**已解析的 JSON 对象** —— 解析只做一次,业务错误检查与内容提取共用同一份,
    /// 避免「先解析一遍查错误,再解析一遍提内容」的双重开销。
    private static func extractContent(from json: Any) throws -> String {
        // OpenAI 格式:choices[0].message.content
        if let dict = json as? [String: Any],
           let choices = dict["choices"] as? [[String: Any]],
           let first = choices.first,
           let message = first["message"] as? [String: Any],
           let content = message["content"] as? String {
            return strippingThinkingTags(content)
        }

        // MiniMax 原生:reply 字段
        if let dict = json as? [String: Any],
           let reply = dict["reply"] as? String {
            return strippingThinkingTags(reply)
        }

        // MiniMax v1 嵌套格式:data.reply
        if let dict = json as? [String: Any],
           let inner = dict["data"] as? [String: Any],
           let reply = inner["reply"] as? String {
            return strippingThinkingTags(reply)
        }

        throw OCRError.responseParseFailed("unknown response shape")
    }

    /// 剥离 `<think>...</think>` 思考块。
    ///
    /// MiniMax-M3 系列的思考内容会混进 content(实测 `MiniMax-M3` 的 content 里
    /// 带 think 标签),`MiniMax-M3.1-Flash` 走 reasoning_content 字段但仍留一层防护 ——
    /// 思考标签混进译文会直接渲染到画布上。
    private static func strippingThinkingTags(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析模型返回的文本为 `ParsedTranslation`。4 种解析路径:
    /// 1. JSON 数组 + count 匹配 → 行覆盖模式(mergedParagraph = nil)
    /// 2. JSON 数组 + count 不匹配 → 段落覆盖模式(mergedParagraph = join)
    /// 3. 非 JSON 按行 split + count 匹配 → 行覆盖模式
    /// 4. 非 JSON 按行 split + count 不匹配 → 段落覆盖模式(join 拆分结果或原文本)
    ///
    /// 任意一条路径都不再因为行数不匹配 throw —— 画布永远会拿到译文覆盖层。
    /// 非 `private`:测试需要直接调用以覆盖 4 条解析路径,通过 `@testable import MoleWidgetCore` 访问。
    static func parseTranslatedTexts(
        _ raw: String,
        expectedCount: Int
    ) -> ParsedTranslation {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 去掉 markdown 代码块包装(模型偶尔会包 ```json ... ```)。
        // 正确处理 ` ``` ` 后面可能跟语言标识符(` ```json ` / ` ```javascript ` 等),
        // 必须跳过 opening fence 到第一个换行为止,然后再去掉 closing fence。
        if trimmed.hasPrefix("```") {
            if let openingNewline = trimmed.firstIndex(of: "\n") {
                let afterOpening = trimmed.index(after: openingNewline)
                trimmed = String(trimmed[afterOpening...])
            } else {
                // 没有换行 —— 异常情况(只有 ``` 没闭合),fallback 直接清空
                trimmed = ""
            }
            if let lastBacktickRange = trimmed.range(of: "```", options: .backwards) {
                trimmed.removeSubrange(lastBacktickRange)
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 尝试 1:直接解析 JSON 数组
        if let data = trimmed.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
            if array.count == expectedCount {
                return ParsedTranslation(lines: array)
            }
            // count 不匹配 → 段落兜底
            return ParsedTranslation(
                lines: array,
                mergedParagraph: array.joined(separator: " ")
            )
        }

        // 尝试 2:按行 split 兜底(模型偶尔返回纯文本而非 JSON 数组)
        let split = trimmed
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if split.count == expectedCount {
            return ParsedTranslation(lines: split)
        }
        // count 不匹配 → 段落兜底。优先用 split 后的非空行,若都空则回退到原 trimmed。
        let merged: String
        if split.isEmpty {
            merged = trimmed
        } else {
            merged = split.joined(separator: " ")
        }
        return ParsedTranslation(lines: split, mergedParagraph: merged)
    }
}