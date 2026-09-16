//
//  ScreenshotServices.swift
//  Vitals - Screenshot module
//
//  顶层协调服务(Vitals 精简版 AppServices):
//  - 持有所有子服务的引用
//  - 装配依赖关系
//  - 暴露启动 / 停止生命周期
//  - 把 GlobalShortcutService 的 ShortcutAction 回调映射成 CaptureCommand
//  - 把 OCRService 嵌入到编辑器窗口
//
//  不引入 Mio 的 AppServices,因为 Vitals 直接用 `let xxx = ...Manager()` 风格。
//

import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
public final class ScreenshotServices {
    // MARK: - 持久化
    let shortcutStore: ShortcutStore
    public let screenshotShortcutStore: ScreenshotShortcutStore
    public let captureSettings: CaptureSettings

    // MARK: - 截图核心
    let clipboardOutput: ClipboardOutputService
    let outputDelivery: OutputDeliveryService
    let capturePipeline: CapturePipeline
    let imageProcessor: ImageProcessor
    let selectionPresenter: SelectionPresenter
    public let globalShortcutService: GlobalShortcutService
    /// 跳转 System Settings 的统一出口。
    public let systemSettingsOpener: SystemSettingsOpener

    // MARK: - 编辑器
    let editorWindowRegistry: EditorWindowRegistry
    public let frameResources: FrameResources?
    private let compositeRenderer: EditorCompositeRenderer

    // MARK: - OCR / 翻译
    public let aiCredential: AICredentialKeychain
    let visionOCRClient: VisionOCRClient
    let minimaxTranslationClient: MiniMaxTranslationClient
    /// 跨 OCRService 实例共享的画布 hash 缓存(5 分钟 TTL)。
    /// 使用进程级 static `.shared`,关闭编辑器重开、连续多张截图都能命中缓存。
    private let canvasHashCache = OCRCanvasHashCache.shared

    // MARK: - 权限(屏幕录制 + 辅助功能,Carbon hotkey 必需)
    public let permissionManager: PermissionManager

    // MARK: - CaptureController(独立持有)
    private(set) var captureController: CaptureController?
    let feedbackPresenter: CaptureFeedbackPresenter

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults

        // 持久化层
        self.shortcutStore = ShortcutStore(defaults: defaults)
        // 关键:ScreenshotShortcutStore 必须复用同一个 ShortcutStore 实例,
        // 否则它的写入不会触达 GlobalShortcutService 持有的 store,
        // UI 改快捷键后 Carbon hotkey 永远不刷新。
        self.screenshotShortcutStore = ScreenshotShortcutStore(store: shortcutStore)
        self.captureSettings = CaptureSettings(defaults: defaults)

        // 输出
        self.clipboardOutput = ClipboardOutputService()
        self.outputDelivery = OutputDeliveryService(clipboardOutput: clipboardOutput)

        // 截图核心
        self.capturePipeline = CapturePipeline()
        self.frameResources = FrameResourceLoader.load()
        self.imageProcessor = ImageProcessor(frameResources: frameResources)
        self.selectionPresenter = SelectionPresenter()

        // 权限(Screen Recording + Accessibility)—— 必须在 GlobalShortcutService
        // 之前实例化,后者要拿到引用以监听 AX 授权变化并触发 Carbon hotkey 重注册。
        // Bug 1-A 修复。
        self.permissionManager = PermissionManager()

        // 快捷键
        self.globalShortcutService = GlobalShortcutService(
            store: shortcutStore,
            permissionManager: permissionManager
        )
        self.systemSettingsOpener = SystemSettingsOpener()

        // OCR / 翻译
        self.aiCredential = AICredentialKeychain.shared
        self.visionOCRClient = VisionOCRClient()
        self.minimaxTranslationClient = MiniMaxTranslationClient()

        // 反馈呈现
        self.feedbackPresenter = CaptureFeedbackPresenter()

        // 编辑器:装配依赖
        self.compositeRenderer = EditorCompositeRenderer()
        self.editorWindowRegistry = EditorWindowRegistry(
            imageProcessor: imageProcessor,
            outputDelivery: outputDelivery,
            feedbackPresenter: feedbackPresenter,
            compositeRenderer: compositeRenderer
        )

        // init 只构造依赖、不启动;start() 是唯一启动入口。
    }

    private func handleShortcut(_ action: ShortcutAction) {
        let command: CaptureCommand = switch action {
        case .windowCapture:        .captureArea
        case .advancedWindowCapture: .captureAdvanced
        }
        startCapture(command: command)
    }

    /// 主动发起一次截图命令。
    func startCapture(command: CaptureCommand) {
        ensureCaptureController()
        _ = captureController?.start(command)
    }

    private func ensureCaptureController() {
        if captureController != nil { return }

        captureController = CaptureController(
            pipeline: capturePipeline,
            imageProcessor: imageProcessor,
            clipboardOutput: clipboardOutput,
            selectionPresenter: selectionPresenter,
            feedbackPresenter: feedbackPresenter,
            openEditor: { [weak self] image, displayID, preferences, capturedAt in
                guard let self else { return }
                self.openEditor(
                    image: image,
                    displayID: displayID,
                    preferences: preferences,
                    capturedAt: capturedAt
                )
            },
            capturePreferencesSnapshot: { [weak self] in
                self?.captureSettings.snapshot() ?? CapturePreferencesSnapshot(
                    // 「截屏后播放音效」开关已移除 → 任何 fallback 都关掉音效。
                    playSoundOnCapture: false,
                    saveToFile: false,
                    organizeByMonth: false,
                    frame: CaptureFramePreference(isEnabled: false, signature: "", theme: .auto)
                )
            }
        )
    }

    // MARK: - 打开编辑器(供 CaptureController 回调 / 公共入口)

    /// 主动打开一个编辑器窗口:序列化画布 → 创建 OCRService → 调 EditorWindowRegistry.open。
    /// 这是 OCR / 翻译的注入点:ocrService + canvasData 由本方法构造并下传。
    /// 失败时静默吞 typed error(EditorOpenError.stopped = app 正在终止,没必要抛给用户)。
    func openEditor(
        image: CaptureImage,
        displayID: CGDirectDisplayID,
        preferences: CapturePreferencesSnapshot,
        capturedAt: CaptureTimestamp
    ) {
        let input = EditorInput(
            image: image,
            displayID: displayID,
            framePreference: preferences.frame,
            deliveryPolicy: DeliveryPolicy(preferences: preferences),
            capturedAt: capturedAt
        )
        let canvasData = Self.encodeCanvasPNG(image)
        // 从 UserDefaults 读取用户持久化的目标语言(默认"简体中文"),
        // 关编辑器后改的值仍然保留。
        let targetLanguage = WidgetSettings.ocrTargetLanguage(in: defaults)
        let ocrService = makeOCRService(targetLanguage: targetLanguage)
        _ = try? editorWindowRegistry.open(input, ocrService: ocrService, canvasData: canvasData)
    }

    /// 把 CaptureImage 的 CGImage 序列化为 PNG Data,供 Vision OCR 输入 + 画布 hash 缓存。
    /// 失败返回 nil(编辑器照常打开,只是 OCR 按钮被 .disabled,功能降级而非崩溃)。
    static func encodeCanvasPNG(_ image: CaptureImage) -> Data? {
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - 启动 / 停止

    public func start() {
        globalShortcutService.start { [weak self] action in
            self?.handleShortcut(action)
        }
    }

    public func stop() {
        _ = globalShortcutService.stop()
        captureController?.stop()
        editorWindowRegistry.stop(reason: .userInitiated)
    }

    // MARK: - OCR 测试连接

    /// 测试当前 API Key 是否有效。结果反馈到 ScreenshotSettingsManager。
    /// 从 UserDefaults 读目标语言,保证「测试连接」按钮使用的语言与编辑器内一致。
    public func testAPIConnection() async -> Bool {
        let targetLanguage = WidgetSettings.ocrTargetLanguage(in: defaults)
        let testService = makeOCRService(targetLanguage: targetLanguage)
        return await testService.testConnection()
    }

    /// 构建一个 OCRService 实例,绑定到当前选中的目标语言 + UserDefaults。
    /// 进程级共享 `OCRCanvasHashCache`,跨实例命中 5 分钟 TTL 缓存。
    func makeOCRService(targetLanguage: String) -> OCRService {
        OCRService(
            credential: aiCredential,
            targetLanguage: targetLanguage,
            defaults: defaults,
            canvasHashCache: canvasHashCache
        )
    }
}