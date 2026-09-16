//
//  OCRService.swift
//  Vitals - Screenshot module
//
//  OCR + 翻译的统一状态机。
//  状态机:idle / ocrLoading / completed / translating / translated / failed
//  缓存:画布 PNG SHA256 hash,5 分钟内同画布不重发 OCR。
//
//  工具栏按钮语义映射:
//    「提取文字」按钮:
//      .idle          → startRecognition(canvasData:)        (原图 OCR)
//      .completed     → restartRecognition(canvasData:)      (覆盖式重做)
//      .translated    → startRecognition(canvasData:)        (按翻译后图)
//      .failed        → retryRecognition(canvasData:)        (OCR 重试)
//      .ocrLoading / .translating → 灰,不可点
//
//    「翻译」按钮:
//      .idle / .completed / .failed → startRecognitionAndTranslate(canvasData:)
//      .translated                  → resetToIdle()
//      .ocrLoading / .translating   → 灰,不可点
//
//  AIPanel 底部永远只有「一键复制」按钮;识别/翻译/重试入口全部上移到工具栏。
//  翻译完成后原文列表清空(避免误导复制原文),只显示一键复制翻译后的内容。
//

import CryptoKit
import Foundation
import SwiftUI

nonisolated enum OCRStatus: Sendable, Equatable {
    case idle
    case ocrLoading
    case completed          // OCR 识别完成,等待用户点翻译
    case translating
    case translated         // 翻译完成,已叠加覆盖层
    case failed(OCRError)
}

/// OCRStatus 的便捷查询属性。供 EditorToolbar / AIPanel 等 UI 状态机分发使用。
/// 所有判断都是纯函数,可直接用 `switch` 或 `if case .xxx = self` 调用。
extension OCRStatus {
    /// 是否处于「忙碌」状态(识别中 / 翻译中)。工具栏按钮在这种状态下需要置灰。
    var isBusy: Bool {
        switch self {
        case .ocrLoading, .translating: return true
        case .idle, .completed, .translated, .failed: return false
        }
    }

    var isOCRLoading: Bool {
        if case .ocrLoading = self { return true }
        return false
    }

    var isTranslating: Bool {
        if case .translating = self { return true }
        return false
    }

    var isTranslated: Bool {
        if case .translated = self { return true }
        return false
    }

    var isCompleted: Bool {
        if case .completed = self { return true }
        return false
    }

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
@Observable
final class OCRService {
    /// UserDefaults 写盘的 debounce 间隔。250ms 足以把粘贴/连打合并成 1 次,
    /// 又不至于让用户切语言时感觉到丢字。
    private static let userDefaultsWriteDebounce: UInt64 = 250_000_000  // 250ms

    /// 协议化的 client 引用,默认走真实 Vision/MiniMax 实现,测试通过
    /// internal init 注入 mock 实现。这样核心业务逻辑(状态机、缓存、优先级)
    /// 可以脱离真实 Vision/HTTP 跑测试。
    private let visionClient: VisionOCRClientProtocol
    private let translationClient: MiniMaxTranslationClientProtocol
    private let credential: AICredentialKeychainProtocol
    private let defaults: UserDefaults

    /// 当前状态
    var status: OCRStatus = .idle
    /// OCR 识别结果
    var ocrLines: [OCRLine] = []
    /// 当前已完成的翻译覆盖层
    var translatedOverlay: TranslatedOverlay?
    /// 翻译后的画布 PNG 数据(翻译完成时由外部调 `setTranslatedCanvasData` 写入)。
    /// 作用:.translated 状态下再点「提取文字」按已翻译的图重新 OCR,而不是原图。
    /// 由 EditorWindowController 在 status = .translated 时调一次
    /// `EditorCompositeRenderer.render(snapshot)` 生成 PNG 后写入。
    /// `clearTranslation()` 不清这个字段 —— 用户按"清除翻译覆盖层"只是想关掉
    /// 覆盖显示,缓存的"按翻译后图 OCR"能力应当保留,下次点"提取文字"继续按已翻译图。
    private(set) var translatedCanvasData: Data?
    /// 画布 SHA256 hash 缓存:hash -> (OCR 识别行,上次识别时间)。
    /// 缓存本身委托给共享 holder,跨实例命中;holder 由外部(`ScreenshotServices` 或
    /// `AICredentialKeychain` 静态属性)持有,这里只暴露 setter。
    private let canvasHashCache: OCRCanvasHashCache
    /// 当前翻译的目标语言。任何赋值都会同步写回 UserDefaults,关编辑器后仍保留。
    var targetLanguage: String {
        didSet {
            guard targetLanguage != oldValue else { return }
            // debounce 250ms 后写盘,避免粘粘贴长文本时连续多次写 UserDefaults。
            pendingTargetLanguageWrite?.cancel()
            let snapshot = targetLanguage
            pendingTargetLanguageWrite = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.userDefaultsWriteDebounce)
                if Task.isCancelled { return }
                self?.defaults.set(snapshot, forKey: WidgetSettings.ocrTargetLanguageKey)
            }
        }
    }
    /// 等待中的 targetLanguage 写盘任务。debounce 用。
    private var pendingTargetLanguageWrite: Task<Void, Never>?

    private static let cacheTTLSeconds: TimeInterval = 300 // 5 分钟

    init(
        credential: AICredentialKeychainProtocol,
        targetLanguage: String,
        defaults: UserDefaults,
        canvasHashCache: OCRCanvasHashCache
    ) {
        self.credential = credential
        self.targetLanguage = targetLanguage
        self.defaults = defaults
        self.canvasHashCache = canvasHashCache
        self.visionClient = VisionOCRClient()
        self.translationClient = MiniMaxTranslationClient()
    }

    /// 内部测试 init:允许注入 mock client 实现,跳过真实 Vision/HTTP 调用。
    /// 仅在 `@testable import MoleWidgetCore` 下访问,生产代码走上面的默认 init。
    /// 引入目的是给 OCRService 的状态机(优先级、缓存 invalidate、清空策略)
    /// 提供回归屏障,Vision 依赖的 2s timeout / 真实 GPU 调用不便在 CI 跑。
    init(
        credential: AICredentialKeychainProtocol,
        targetLanguage: String,
        defaults: UserDefaults,
        canvasHashCache: OCRCanvasHashCache,
        visionClient: VisionOCRClientProtocol,
        translationClient: MiniMaxTranslationClientProtocol
    ) {
        self.credential = credential
        self.targetLanguage = targetLanguage
        self.defaults = defaults
        self.canvasHashCache = canvasHashCache
        self.visionClient = visionClient
        self.translationClient = translationClient
    }

    /// 检查是否已配置有效的 API Key。
    var hasValidCredential: Bool {
        credential.hasValidAPIKey
    }

    /// 启动 OCR 识别。会先检查画布 hash 缓存,如果 5 分钟内同画布识别过则直接复用
    /// 缓存的 ocrLines,跳过 Vision 调用。
    /// **若已有 `translatedCanvasData`(由外部翻译完成后写入),优先按翻译后的图
    /// 重新识别** —— .translated 状态下"提取文字"按译文图 OCR 而不是原图。
    /// 缓存 key 用 effectiveCanvasData 算:识别过的原图与识别过的译文图是两个
    /// 独立的缓存条目,互不污染。
    func startRecognition(canvasData: Data) async {
        let effectiveCanvasData = translatedCanvasData ?? canvasData
        lastEffectiveCanvasDataForTesting = effectiveCanvasData
        let hash = Self.sha256Hex(of: effectiveCanvasData)

        // 缓存命中:直接从跨实例共享 cache 取回 ocrLines,跳过 Vision 调用。
        if let cachedLines = canvasHashCache.lines(for: hash), !cachedLines.isEmpty {
            self.ocrLines = cachedLines
            self.translatedOverlay = nil
            status = .completed
            return
        }

        status = .ocrLoading
        guard let cgImage = Self.cgImage(from: effectiveCanvasData) else {
            status = .failed(.visionFailed("无法解码图像"))
            return
        }

        do {
            let lines = try await visionClient.recognizeText(in: cgImage)
            self.ocrLines = lines
            self.canvasHashCache.store(lines: lines, for: hash)
            self.translatedOverlay = nil
            if lines.isEmpty {
                status = .failed(.visionFailed("未识别到任何文字"))
            } else {
                status = .completed
            }
        } catch let error as OCRError {
            status = .failed(error)
        } catch {
            status = .failed(.visionFailed(error.localizedDescription))
        }
    }

    /// 重试识别。强制绕过缓存重新跑一遍 Vision,清空上次结果 + 失败状态。
    /// SPEC 要求失败时显示「重试」按钮,本方法是按钮的回调入口。
    /// 与 `startRecognition` 一致:`translatedCanvasData` 存在时按翻译后的图重试。
    func retryRecognition(canvasData: Data) async {
        ocrLines = []
        translatedOverlay = nil
        // 先把 effective canvas hash 在跨实例 cache 里的旧条目作废,
        // 否则 `startRecognition` 仍然会命中缓存、跳过 Vision 重试。
        let effectiveCanvasData = translatedCanvasData ?? canvasData
        lastEffectiveCanvasDataForTesting = effectiveCanvasData
        let staleHash = Self.sha256Hex(of: effectiveCanvasData)
        canvasHashCache.invalidate(hash: staleHash)
        status = .idle
        await startRecognition(canvasData: canvasData)
    }

    /// 重新 OCR(覆盖式):清 `ocrLines` + `translatedOverlay` + `translatedCanvasData`,
    /// 然后按 `canvasData` 重新走 OCR。
    /// **覆盖语义关键**:同时清掉 `translatedCanvasData`,保证下一次 OCR 走**原图**
    /// 而不是上次翻译后的图,符合用户在 `.completed` 状态下点「提取文字」时
    /// 「重新 OCR(覆盖)」的期望。
    /// 与 `retryRecognition` 的区别:不强制 invalidate 缓存(允许 5 分钟内
    /// 同一张原图直接命中缓存复用结果),不强行把 status 先置 .idle(避免 UI 闪烁)。
    /// 适用场景:.idle / .completed 状态下点「提取文字」按钮的统一入口。
    ///   - .idle:本来就是空的,clear 是 no-op,直接 OCR 即可。
    ///   - .completed:覆盖之前识别结果 + 翻译缓存,再 OCR 原图。
    /// 注意:**不要**用于 .translated 状态 —— 那里要保留 `translatedCanvasData`
    /// 让 OCR 走翻译后的图,这种情况应直接调 `startRecognition`。
    func restartRecognition(canvasData: Data) async {
        ocrLines = []
        translatedOverlay = nil
        translatedCanvasData = nil
        await startRecognition(canvasData: canvasData)
    }

    /// OCR + 翻译一步操作。这是「翻译」按钮的统一入口(除 `.translated` 之外):
    /// - .idle / .completed 状态下,先 OCR(覆盖式:translatedCanvasData 清掉,
    ///   保证 OCR 走原图)再翻译。
    /// - .failed 状态下,先 OCR 重试,成功后接着翻译。
    /// - OCR 失败(空识别结果 / Vision 报错)时不翻译,直接停在 .failed,
    ///   让用户从「翻译」按钮自然过渡到「提取文字」按钮的 retry 路径。
    /// - .ocrLoading / .translating 时按钮被禁用,本方法不会被调用。
    /// - .translated 状态走 `resetToIdle`,不进本方法。
    func startRecognitionAndTranslate(canvasData: Data) async {
        await restartRecognition(canvasData: canvasData)
        // OCR 失败或识别为空时停在 .failed,不发起翻译调用 —— startTranslation
        // 内部对空 ocrLines 也有 fail guard,这里提前返回避免多余网络请求。
        guard status == .completed else { return }
        await startTranslation()
    }

    /// 启动翻译。把当前 OCR 结果批量翻译为目标语言。
    /// Bug-LCM-1 修复:即使模型返回行数与原文不匹配,也不再让画布空着,
    /// 翻译客户端用 `ParsedTranslation.mergedParagraph` 兜底;本方法把 `mergedParagraph`
    /// 透传到 `TranslatedOverlay.mergedParagraph`,渲染层按 `isLineMode / isParagraphMode`
    /// 自动分流覆盖策略。
    func startTranslation() async {
        guard !ocrLines.isEmpty else {
            status = .failed(.visionFailed("请先识别文字"))
            return
        }
        guard hasValidCredential else {
            status = .failed(.noAPIKey)
            return
        }
        let originalTexts = ocrLines.map(\.text)
        let target = targetLanguage
        status = .translating
        do {
            let apiKey = credential.readAPIKey() ?? ""
            let parsed = try await translationClient.translate(
                lines: originalTexts,
                targetLanguage: target,
                apiKey: apiKey
            )
            self.translatedOverlay = TranslatedOverlay(
                originalLines: ocrLines,
                translatedLines: parsed.lines,
                mergedParagraph: parsed.mergedParagraph
            )
            status = .translated
        } catch let error as OCRError {
            status = .failed(error)
        } catch {
            status = .failed(.network(error.localizedDescription))
        }
    }

    /// 清除翻译覆盖层,回到 OCR 完成状态。
    /// **不**清 `translatedCanvasData` —— 用户只是关掉覆盖显示,缓存的
    /// "按翻译后图 OCR"能力仍保留;下次点"提取文字"继续按已翻译图识别。
    func clearTranslation() {
        translatedOverlay = nil
        if !ocrLines.isEmpty {
            status = .completed
        } else {
            status = .idle
        }
    }

    /// 翻译完成后再点"翻译"按钮的语义入口:把 OCR + 翻译状态全部清回未启用。
    /// 与 `clearTranslation`(只关覆盖层、保留 ocrLines + translatedCanvasData)
    /// 的区别:本方法**丢弃所有 OCR / 翻译数据**,回到 `.idle` 完全干净状态,
    /// 用户需要重新走「提取文字」→「翻译」流程。
    /// - 清 `ocrLines`(再点"提取文字"重新识别)
    /// - 清 `translatedOverlay`(画布覆盖层一并消失)
    /// - 清 `translatedCanvasData`("按翻译后图 OCR"能力也一并丢弃)
    /// - status = .idle
    func resetToIdle() {
        ocrLines = []
        translatedOverlay = nil
        translatedCanvasData = nil
        status = .idle
    }

    /// 清除所有 OCR / 翻译状态。包含 `translatedCanvasData` —— 整个会话都放弃时
    /// 缓存的"按翻译后图 OCR"能力也应当丢弃。
    func reset() {
        status = .idle
        ocrLines = []
        translatedOverlay = nil
        translatedCanvasData = nil
    }

    /// 翻译完成时由外部(EditorWindowController)写入翻译后的画布 PNG。
    /// 下一次 `startRecognition` / `retryRecognition` 会优先用它做 OCR。
    /// MainActor:同其它状态字段一致,UI 线程直接读。
    func setTranslatedCanvasData(_ data: Data?) {
        translatedCanvasData = data
    }

    /// 测试用 hook:最近一次 `startRecognition` / `retryRecognition` 实际喂给
    /// Vision client 的 effective canvas data。生产代码不会读这个字段,
    /// 仅供单元测试断言「translatedCanvasData 优先级」时使用。
    /// 引入原因:VisionOCRClient protocol 签名只接受 CGImage,无法在 mock 里
    /// 直接拿到原始 Data —— 用这个 hook 把 effective canvas data 透出。
    var lastEffectiveCanvasDataForTesting: Data?

    /// 立即同步 flush 待写的 targetLanguage 到 UserDefaults。
    /// 场景:用户改了语言 → 250ms debounce 还没 fire → 关编辑器 → OCRService deinit
    /// → 默认 pending Task 被取消,最后一次写盘丢失。`EditorWindowController.isolated deinit`
    /// 在 MainActor 上调用本方法,绕过 debounce 同步写盘,保证用户最后的语言选择不丢。
    /// 同步路径上读 `targetLanguage` + 写 `UserDefaults` 都是 MainActor + 线程安全,无 actor hop。
    func flushPendingTargetLanguageWrite() {
        pendingTargetLanguageWrite?.cancel()
        pendingTargetLanguageWrite = nil
        defaults.set(targetLanguage, forKey: WidgetSettings.ocrTargetLanguageKey)
    }

    /// 测试 API Key 连接。任何失败(网络断开 / 超时 / 401 / 403 / 429 / 5xx /
    /// JSON 解析失败)都返回 `false`,避免误报「成功」。
    func testConnection() async -> Bool {
        guard let apiKey = credential.readAPIKey(), !apiKey.isEmpty else {
            return false
        }
        do {
            _ = try await translationClient.translate(
                lines: ["hello"],
                targetLanguage: targetLanguage,
                apiKey: apiKey
            )
            return true
        } catch OCRError.unauthorized, OCRError.noAPIKey {
            return false
        } catch OCRError.timeout {
            return false
        } catch OCRError.rateLimit {
            return false
        } catch OCRError.translateFailed {
            return false
        } catch OCRError.responseParseFailed {
            return false
        } catch OCRError.network {
            return false
        } catch {
            return false
        }
    }

    // MARK: - 工具函数

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(data: data) else { return nil }
        return bitmap.cgImage
    }
}

// MARK: - 跨实例共享的画布 hash 缓存

/// 跨 OCRService 实例共享的画布 hash 缓存(5 分钟 TTL)。
/// 不只是时间戳占位 —— 真存上次识别出的 OCR 行,关闭编辑器重开、连续多张截图
/// 都能直接复用识别结果,跳过 Vision 调用。
///
/// 线程模型:`@MainActor` 访问,跟 `OCRService` 一致;读写都是 `MainActor` 内调用,
/// 不需要锁。共享的目的是跨实例、不是跨线程。
@MainActor
final class OCRCanvasHashCache {
    /// 单条缓存条目
    struct Entry {
        let lines: [OCRLine]
        let timestamp: Date
    }

    /// 进程内单例。注入 `OCRService` 时若不显式指定,默认走这里。
    static let shared = OCRCanvasHashCache()

    private var entries: [String: Entry] = [:]
    private let cacheTTL: TimeInterval = 300  // 5 分钟

    init() {}

    /// 命中缓存返回缓存的 OCR 行(没命中或过期返回 nil)。
    /// 命中后会顺手剔除过期条目,避免内存只增不减。
    func lines(for hash: String) -> [OCRLine]? {
        guard let entry = entries[hash] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > cacheTTL {
            entries.removeValue(forKey: hash)
            return nil
        }
        return entry.lines
    }

    /// 写入 OCR 识别结果到缓存。
    func store(lines: [OCRLine], for hash: String) {
        entries[hash] = Entry(lines: lines, timestamp: Date())
    }

    /// 主动作废某 hash 的条目。重试按钮 / 用户手动重置时使用,
    /// 让下一次 `startRecognition` 强制重新走 Vision。
    func invalidate(hash: String) {
        entries.removeValue(forKey: hash)
    }
}