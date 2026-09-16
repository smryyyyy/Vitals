//
//  MiniMaxTranslationClientTests.swift
//  Vitals - Screenshot/OCR 模块
//
//  Bug-LCM-1 修复的回归屏障:
//  1. parseTranslatedTexts 的 4 种解析路径(JSON 匹配 / JSON 不匹配 / 非 JSON split
//     匹配 / 非 JSON split 不匹配),保证行覆盖模式与段落覆盖模式正确分流。
//  2. markdown 代码块包装剥离(模型偶尔包 ```json ... ```),防止被错误识别为非 JSON。
//  3. systemPrompt 严格约束(绝不合并 / 拆分行,JSON 数组长度 = 输入行数),
//     防止未来重构无意中放宽约束,导致 6.5s-chat 重新开始"贴心地"合并多行。
//  4. TranslatedOverlay.isLineMode / isParagraphMode 计算属性在两种数据形态下分流正确。
//
//  设计原则:
//  - 直接调 `MiniMaxTranslationClient.parseTranslatedTexts` 与 `systemPrompt`,
//    不走 HTTP / mock 拦截 —— 这两个静态函数本身是无副作用的纯函数,无需 actor 隔离。
//  - 每个测试独立,无共享状态。
//

import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct MiniMaxTranslationClientTests {

    // MARK: - Parsing path 1: JSON 数组 + count 匹配 → 行覆盖模式

    /// 路径 1:模型返回严格 JSON 字符串数组,长度 = 期望行数 → 行覆盖模式。
    /// 这是最常见的成功路径,模型遵守 prompt 时的标准结果。
    @Test func parseTranslatedTextsJSONArrayMatchesCountReturnsLineMode() {
        let raw = #"["你好","世界","今天天气真好"]"#
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == true)
        #expect(result.isParagraphMode == false)
        #expect(result.mergedParagraph == nil)
        #expect(result.lines == ["你好", "世界", "今天天气真好"])
    }

    // MARK: - Parsing path 2: JSON 数组 + count 不匹配 → 段落覆盖模式

    /// 路径 2:模型返回 JSON 数组但长度 < 期望行数(把多行原文合并成 1 行的典型场景)。
    /// 必须走段落覆盖模式兜底,否则画布上没译文覆盖(Bug-LCM-1 修复点)。
    /// mergedParagraph 是数组用空格 join 后的结果,渲染层会把它整段覆盖在首行 OCR 上。
    @Test func parseTranslatedTextsJSONArrayFewerThanExpectedReturnsParagraphMode() {
        // 模型把 3 行原文合并成 2 行译文 —— 实测 6.5s-chat 的常见"贴心"行为。
        let raw = #"["FreeLLMAPI 是一个统一供应商仪表盘","支持多模型聚合调用"]"#
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == false)
        #expect(result.isParagraphMode == true)
        #expect(result.mergedParagraph != nil)
        #expect(result.mergedParagraph?.contains(" ") == true)
        #expect(result.mergedParagraph == "FreeLLMAPI 是一个统一供应商仪表盘 支持多模型聚合调用")
        #expect(result.lines.count == 2)
    }

    /// 路径 2 变体:模型返回 JSON 数组但长度 > 期望行数(罕见,模型过度拆分单行)。
    /// 同样走段落覆盖模式兜底,渲染层统一合并显示。
    @Test func parseTranslatedTextsJSONArrayMoreThanExpectedReturnsParagraphMode() {
        let raw = #"["hello","world","foo","bar"]"#
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 2)

        #expect(result.isLineMode == false)
        #expect(result.isParagraphMode == true)
        #expect(result.mergedParagraph == "hello world foo bar")
    }

    // MARK: - Parsing path 3: 非 JSON 按行 split + count 匹配 → 行覆盖模式

    /// 路径 3:模型返回纯文本(罕见),但恰好按行 split 后行数匹配期望 → 行覆盖模式。
    /// 这种情况下也能正常覆盖,不需要兜底。
    @Test func parseTranslatedTextsNonJSONLineSplitMatchesCountReturnsLineMode() {
        let raw = "你好\n世界\n今天天气真好"
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == true)
        #expect(result.isParagraphMode == false)
        #expect(result.mergedParagraph == nil)
        #expect(result.lines == ["你好", "世界", "今天天气真好"])
    }

    // MARK: - Parsing path 4: 非 JSON 按行 split + count 不匹配 → 段落覆盖模式

    /// 路径 4:模型返回纯文本 + 行数不匹配 → 段落覆盖模式兜底,渲染层整段覆盖。
    /// 与路径 2 等价的纯文本兜底路径,任何一条不匹配路径都必须保证画布有译文。
    @Test func parseTranslatedTextsNonJSONLineSplitMismatchesCountReturnsParagraphMode() {
        let raw = "你好世界"  // 单行纯文本,期望 3 行
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == false)
        #expect(result.isParagraphMode == true)
        #expect(result.mergedParagraph == "你好世界")
    }

    /// 路径 4 变体:split 后行数 < 期望(多行原文被合并成一段纯文本)。
    /// mergedParagraph 用空格 join 所有非空 split 行;若 split 全空则回退到原 trimmed。
    @Test func parseTranslatedTextsNonJSONLineSplitFewerThanExpectedReturnsParagraphMode() {
        let raw = "你好\n世界"  // 2 行纯文本,期望 3 行
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == false)
        #expect(result.isParagraphMode == true)
        #expect(result.mergedParagraph == "你好 世界")
    }

    // MARK: - Parsing path 5: markdown 代码块剥离

    /// 模型偶尔把 JSON 数组包在 ```json ... ``` 里 —— 必须正确剥离后再解析。
    /// 剥离后正常 JSON 匹配 → 行覆盖模式。
    @Test func parseTranslatedTextsStripsMarkdownCodeBlockWrapper() {
        let raw = "```json\n[\"你好\",\"世界\"]\n```"
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 2)

        #expect(result.isLineMode == true)
        #expect(result.isParagraphMode == false)
        #expect(result.mergedParagraph == nil)
        #expect(result.lines == ["你好", "世界"])
    }

    /// markdown 包装 + 行数不匹配 —— 剥离后进入 JSON 路径,再走段落兜底。
    @Test func parseTranslatedTextsStripsMarkdownWrapperAndFallsBackToParagraphMode() {
        let raw = "```json\n[\"你好\",\"世界\"]\n```"  // 2 行,期望 3 行
        let result = MiniMaxTranslationClient.parseTranslatedTexts(raw, expectedCount: 3)

        #expect(result.isLineMode == false)
        #expect(result.isParagraphMode == true)
        #expect(result.mergedParagraph == "你好 世界")
    }

    // MARK: - Prompt 严格约束回归

    /// 验证 systemPrompt 包含 4 条严格约束,防止未来重构无意中放宽约束,
    /// 导致 6.5s-chat 重新开始"贴心地"合并多行原文(回到 Bug-LCM-1 的根因场景)。
    /// - 绝不合并多行原文
    /// - 绝不拆分单行原文
    /// - JSON 数组长度 = 输入行数
    /// - 不要 markdown 包装
    @Test func systemPromptEnforcesStrictLineConstraints() {
        let prompt = MiniMaxTranslationClient.systemPrompt(targetLanguage: "简体中文")

        // 必须包含所有 4 条严格约束
        #expect(prompt.contains("绝不把多行原文合并成 1 行"), "prompt 缺少「绝不合并多行」约束")
        #expect(prompt.contains("绝不把 1 行原文拆成多行"), "prompt 缺少「绝不拆分单行」约束")
        #expect(prompt.contains("JSON 字符串数组"), "prompt 缺少「严格 JSON 数组」约束")
        #expect(prompt.contains("长度 = 输入行数"), "prompt 缺少「长度对齐输入」约束")
        #expect(prompt.contains("不要 markdown 包装"), "prompt 缺少「不要 markdown 包装」约束")

        // 必须包含目标语言
        #expect(prompt.contains("简体中文"))
    }

    // MARK: - TranslatedOverlay 双模式分流

    /// TranslatedOverlay.isLineMode:mergedParagraph == nil 且行数匹配 → true。
    /// 这是常规路径,模型正常返回时的标准覆盖形态。
    @Test func translatedOverlayIsLineModeWhenCountsMatchAndNoMergedParagraph() {
        let lines = [
            OCRLine(text: "hello", boundingBox: .zero, confidence: 1.0),
            OCRLine(text: "world", boundingBox: .zero, confidence: 1.0),
        ]
        let overlay = TranslatedOverlay(
            originalLines: lines,
            translatedLines: ["你好", "世界"],
            mergedParagraph: nil
        )

        #expect(overlay.isLineMode == true)
        #expect(overlay.isParagraphMode == false)
    }

    /// TranslatedOverlay.isParagraphMode:mergedParagraph != nil → true(兜底路径)。
    /// Bug-LCM-1 修复的核心数据形态:模型合并多行时,渲染层整段覆盖在首行 OCR 上。
    @Test func translatedOverlayIsParagraphModeWhenMergedParagraphSet() {
        let lines = [
            OCRLine(text: "hello", boundingBox: .zero, confidence: 1.0),
            OCRLine(text: "world", boundingBox: .zero, confidence: 1.0),
        ]
        let overlay = TranslatedOverlay(
            originalLines: lines,
            translatedLines: ["你好世界"],  // 任意长度都行 —— 段落模式以 mergedParagraph 为准
            mergedParagraph: "你好 世界"
        )

        #expect(overlay.isLineMode == false)
        #expect(overlay.isParagraphMode == true)
    }
}