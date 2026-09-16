//
//  OCRServiceTests.swift
//  Vitals - Screenshot/OCR 模块
//
//  覆盖 OCRService 状态机关键行为的单元测试。
//  本文件用作回归屏障,防止未来重构破坏:
//  - translatedCanvasData 优先级(startRecognition / retryRecognition 都按它优先 OCR)
//  - clearTranslation 只清 overlay,保留 translatedCanvasData
//  - resetToIdle / reset 清全部状态
//  - setTranslatedCanvasData 直接写字段
//  - 状态机转换:idle → ocrLoading → completed → translating → translated
//  - retryRecognition invalidate cache
//
//  设计原则:
//  - 每个测试用独立的 `UserDefaults(suiteName: "test-\(UUID())")!` 隔离,跟 GlobalShortcutServiceTests 一致。
//  - 服务是 `@MainActor`,测试函数也用 `@MainActor async` 标注。
//  - 不依赖 private 字段,只通过 public/internal surface 验证。
//  - Mock 实现用 `final class + @unchecked Sendable`(不是 actor),原因:测试全在
//    `@MainActor` 跑,不需要 actor 隔离;用 class 后字段直接可读可写,不需要 await。
//    Protocol 要求 `Sendable`,`@unchecked Sendable` 满足。
//  - 阻塞测试用 `await task.value` 等后台 task 完成,中间态采样用 continuation-based
//    gate(让 mock 在 async 上下文里等,而不是用 DispatchSemaphore —— 后者会阻塞
//    main thread 导致 main actor scheduling 死锁)。
//  - OCR 客户端 mock 需要有效 CGImage 输入,所以 helper `makeTestPNGData()` 生成
//    一个 1x1 白色 PNG,保证 `OCRService.cgImage(from:)` 能解码。
//

import Foundation
import Testing
import CoreGraphics
import AppKit
@testable import MoleWidgetCore

// MARK: - Mock 实现

/// Mock Vision OCR 客户端。每次 `recognizeText` 把传入的 CGImage 缓存到
/// `lastReceivedCGImage`,让测试验证 OCRService 是否按 translatedCanvasData
/// 优先级喂图。返回的 OCRLines 由 `linesToReturn` 配置,默认返回预定义行。
final class MockVisionOCRClient: VisionOCRClientProtocol, @unchecked Sendable {
    var linesToReturn: [OCRLine]
    var lastReceivedCGImage: CGImage?
    var callCount: Int = 0
    var errorToThrow: Error?

    init(linesToReturn: [OCRLine] = []) {
        self.linesToReturn = linesToReturn
    }

    func recognizeText(in cgImage: CGImage) async throws -> [OCRLine] {
        lastReceivedCGImage = cgImage
        callCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        return linesToReturn
    }

    /// 阻塞版本:在 mock 入口等测试放行。`gate` 是可选 continuation gate,
    /// 测试用 `await gate.signalAndWait()` 阻塞入口,采样 status 后再放行。
    /// 注意:这是异步等,不会阻塞 main thread,允许 main actor 调度其它 task。
    func recognizeTextBlocking(in cgImage: CGImage, gate: BlockingGate) async throws -> [OCRLine] {
        lastReceivedCGImage = cgImage
        callCount += 1
        await gate.waitForResume()
        if let errorToThrow {
            throw errorToThrow
        }
        return linesToReturn
    }
}

/// Mock MiniMax 翻译客户端。每次 `translate` 把传入参数缓存到
/// `lastReceivedLines` / `lastReceivedTargetLanguage`,让测试验证翻译流程。
final class MockMiniMaxTranslationClient: MiniMaxTranslationClientProtocol, @unchecked Sendable {
    var translatedLinesToReturn: [String]
    /// 段落覆盖模式兜底:模型返回行数不匹配时,`translate` 把这段内容作为
    /// `ParsedTranslation.mergedParagraph` 返回。`nil` 表示不模拟兜底场景。
    var mergedParagraphToReturn: String?
    var lastReceivedLines: [String]?
    var lastReceivedTargetLanguage: String?
    var lastReceivedAPIKey: String?
    var callCount: Int = 0
    var errorToThrow: Error?

    init(translatedLinesToReturn: [String] = []) {
        self.translatedLinesToReturn = translatedLinesToReturn
    }

    func translate(
        lines: [String],
        targetLanguage: String,
        apiKey: String
    ) async throws -> ParsedTranslation {
        lastReceivedLines = lines
        lastReceivedTargetLanguage = targetLanguage
        lastReceivedAPIKey = apiKey
        callCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        return ParsedTranslation(
            lines: translatedLinesToReturn,
            mergedParagraph: mergedParagraphToReturn
        )
    }

    /// 阻塞版本:在 translate 入口等测试放行。语义同 MockVisionOCRClient。
    func translateBlocking(
        lines: [String],
        targetLanguage: String,
        apiKey: String,
        gate: BlockingGate
    ) async throws -> ParsedTranslation {
        lastReceivedLines = lines
        lastReceivedTargetLanguage = targetLanguage
        lastReceivedAPIKey = apiKey
        callCount += 1
        await gate.waitForResume()
        if let errorToThrow {
            throw errorToThrow
        }
        return ParsedTranslation(
            lines: translatedLinesToReturn,
            mergedParagraph: mergedParagraphToReturn
        )
    }
}

/// Mock AICredentialKeychain。`storedKey` 控制是否报告 hasValidAPIKey,
/// 避免污染真实 Keychain。
final class MockAICredentialKeychain: AICredentialKeychainProtocol, @unchecked Sendable {
    var storedKey: String?
    func readAPIKey() -> String? { storedKey }
    var hasValidAPIKey: Bool {
        guard let k = storedKey else { return false }
        return !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - 阻塞 Gate(异步版)

/// 异步阻塞 gate。`waitForResume()` 让 mock 在入口 await,等测试放行。
/// `signal()` 由测试调用,放行 mock 继续走。
/// 用 CheckedContinuation 实现,不会阻塞 main thread,允许 main actor task 调度。
/// 注意:BlockingGate 本身是 class,需要测试持有同一个实例传入 mock 才能等同一个。
/// 状态机:`new` → `waitForResume()` 等待中 → `signal()` 唤醒 → 完成。
/// 单次使用:只能 wait 一次、signal 一次。
final class BlockingGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?

    /// mock 入口调用:阻塞直到测试 signal。
    func waitForResume() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.continuation = cont
        }
    }

    /// 测试调用:放行 mock。
    func signal() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - 测试 helper

/// 生成一个 1x1 白色 PNG Data,保证 `OCRService.cgImage(from:)` 能解码。
/// 用 NSBitmapImageRep 构造,bit-exact,字节级稳定。
@MainActor
private func makeTestPNGData() -> Data {
    makeTestPNGData(width: 1, height: 1)
}

/// 生成另一个字节不同的 PNG Data,用于断言 effective canvas 是哪一张
/// (测试需要 translatedCanvasData 跟 canvasData 字节不同)。
/// 实现:用 2x2 而不是 1x1 —— PNG 头里包含尺寸,字节就会不同。
/// 仍然是有效 PNG,`OCRService.cgImage(from:)` 能正常解码。
@MainActor
private func makeTestPNGDataWithOffset(byteOffset: UInt8) -> Data {
    // byteOffset 当前未使用,保留参数以兼容旧调用 —— 通过尺寸差异产生字节差异
    _ = byteOffset
    return makeTestPNGData(width: 2, height: 2)
}

/// 内部 helper:按指定尺寸生成白色 PNG。
@MainActor
private func makeTestPNGData(width: Int, height: Int) -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 32
    ) else {
        fatalError("测试 helper:无法构造 NSBitmapImageRep")
    }
    for x in 0..<width {
        for y in 0..<height {
            bitmap.setColor(NSColor.white, atX: x, y: y)
        }
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("测试 helper:无法编码 PNG")
    }
    return data
}

/// 构造测试用的 OCRLine(默认 confidence = 1.0,bounding box 全 0)。
@MainActor
private func makeOCRLine(text: String) -> OCRLine {
    OCRLine(
        text: text,
        boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1),
        confidence: 1.0
    )
}

/// Vision mock 包装成 protocol 调用,允许传入 blocking 开关。
/// 实际上 mock 用 `recognizeText` 还是 `recognizeTextBlocking` 由 OCRService 调
/// 哪个方法决定。但 protocol 只暴露一个 `recognizeText`,所以我们做一个
/// VisionOCRClientProtocol 适配包装器在 mock 外面。
@MainActor
private func makeBlockingVisionAdapter(_ mock: MockVisionOCRClient, gate: BlockingGate) -> VisionOCRClientProtocol {
    BlockingVisionAdapter(mock: mock, gate: gate)
}

/// BlockingVisionAdapter:把 MockVisionOCRClient 的阻塞版本包成 VisionOCRClientProtocol。
@MainActor
final class BlockingVisionAdapter: VisionOCRClientProtocol, @unchecked Sendable {
    let mock: MockVisionOCRClient
    let gate: BlockingGate

    init(mock: MockVisionOCRClient, gate: BlockingGate) {
        self.mock = mock
        self.gate = gate
    }

    func recognizeText(in cgImage: CGImage) async throws -> [OCRLine] {
        try await mock.recognizeTextBlocking(in: cgImage, gate: gate)
    }
}

/// MiniMaxTranslation 阻塞适配包装器。语义同 BlockingVisionAdapter。
@MainActor
final class BlockingTranslationAdapter: MiniMaxTranslationClientProtocol, @unchecked Sendable {
    let mock: MockMiniMaxTranslationClient
    let gate: BlockingGate

    init(mock: MockMiniMaxTranslationClient, gate: BlockingGate) {
        self.mock = mock
        self.gate = gate
    }

    func translate(
        lines: [String],
        targetLanguage: String,
        apiKey: String
    ) async throws -> ParsedTranslation {
        try await mock.translateBlocking(
            lines: lines,
            targetLanguage: targetLanguage,
            apiKey: apiKey,
            gate: gate
        )
    }
}

// MARK: - OCRServiceTests

@Suite struct OCRServiceTests {

    /// 构造一个全新 OCRService,绑定独立 UserDefaults、空白 cache、注入 mock client。
    /// 不写盘,OCRCanvasHashCache 是局部的不会跨测试污染。
    /// 注意:多个 mock 类型都是 `@MainActor` 隔离(因 conform `@MainActor` protocol),
    /// 无法在 default argument 里直接构造 —— 所以 mock 不暴露 default argument,
    /// 调用方显式传入。
    @MainActor
    private static func makeService(
        visionClient: any VisionOCRClientProtocol,
        translationClient: any MiniMaxTranslationClientProtocol,
        credential: MockAICredentialKeychain,
        targetLanguage: String = "简体中文",
        cache: OCRCanvasHashCache? = nil
    ) -> OCRService {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        return OCRService(
            credential: credential,
            targetLanguage: targetLanguage,
            defaults: defaults,
            canvasHashCache: cache ?? OCRCanvasHashCache(),
            visionClient: visionClient,
            translationClient: translationClient
        )
    }

    // MARK: - Test 1:startRecognition 用原图

    /// 验证无 translatedCanvasData 时,startRecognition 把原图喂给 Vision client,
    /// 状态走 idle → ocrLoading → completed,ocrLines 不为空。
    @MainActor
    @Test func startRecognitionWithOriginalCanvasDataCompletes() async {
        let line1 = makeOCRLine(text: "hello")
        let line2 = makeOCRLine(text: "world")
        let vision = MockVisionOCRClient(linesToReturn: [line1, line2])
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        // 前置:status 初始为 idle
        #expect(service.status == .idle)
        #expect(service.ocrLines.isEmpty)

        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)

        #expect(service.status == .completed)
        #expect(service.ocrLines.count == 2)
        #expect(service.ocrLines.map(\.text) == ["hello", "world"])
        #expect(service.translatedCanvasData == nil)
        #expect(service.translatedOverlay == nil)
        // mock 收到原图(effective == 原图)
        #expect(service.lastEffectiveCanvasDataForTesting == canvas)
    }

    // MARK: - Test 2:startRecognition 用 translatedCanvasData 覆盖

    /// 验证有 translatedCanvasData 时,startRecognition 把 translatedCanvasData
    /// 喂给 Vision client,而不是原图 —— 这是 .translated 状态下"提取文字"按译文图
    /// OCR 的关键不变量。
    @MainActor
    @Test func startRecognitionPrefersTranslatedCanvasDataOverOriginal() async {
        let line = makeOCRLine(text: "已翻译")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        // 原图 + 翻译后图(都是有效 PNG,才能通过 OCRService.cgImage 解码)。
        // 让两者字节不同,断言 lastEffectiveCanvasDataForTesting 能区分。
        let originalCanvas = makeTestPNGData()
        let translatedCanvas = makeTestPNGDataWithOffset(byteOffset: 200)
        service.setTranslatedCanvasData(translatedCanvas)

        await service.startRecognition(canvasData: originalCanvas)

        // 核心断言:effective canvas = translatedCanvasData,不是原图
        #expect(service.lastEffectiveCanvasDataForTesting == translatedCanvas)
        #expect(service.lastEffectiveCanvasDataForTesting != originalCanvas)
        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["已翻译"])
    }

    // MARK: - Test 3:clearTranslation 只清 overlay,保留 translatedCanvasData

    /// 验证 clearTranslation 只清 translatedOverlay,保留 ocrLines 和
    /// translatedCanvasData,status 回到 .completed。语义:用户按"清除翻译覆盖层"
    /// 只是关掉覆盖显示,缓存的"按翻译后图 OCR"能力应当保留。
    @MainActor
    @Test func clearTranslationKeepsOCRResultsAndTranslatedCanvasData() async {
        let line1 = makeOCRLine(text: "原文1")
        let line2 = makeOCRLine(text: "原文2")
        let vision = MockVisionOCRClient(linesToReturn: [line1, line2])
        let translation = MockMiniMaxTranslationClient(translatedLinesToReturn: ["译文1", "译文2"])
        let credential = MockAICredentialKeychain()
        credential.storedKey = "test-api-key"
        let service = Self.makeService(
            visionClient: vision,
            translationClient: translation,
            credential: credential
        )

        // 走完 OCR + 翻译
        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)
        await service.startTranslation()
        #expect(service.status == .translated)

        // 前置:overlay 不空,translatedCanvasData 被设置
        #expect(service.translatedOverlay != nil)
        service.setTranslatedCanvasData(Data([0xCA, 0xFE]))
        let translatedCanvasData = service.translatedCanvasData

        // 调 clearTranslation
        service.clearTranslation()

        // 断言:overlay 清了,ocrLines 保留,translatedCanvasData 保留,status 回到 .completed
        #expect(service.translatedOverlay == nil)
        #expect(service.ocrLines.map(\.text) == ["原文1", "原文2"])
        #expect(service.translatedCanvasData == translatedCanvasData)
        #expect(service.status == .completed)
    }

    // MARK: - Test 4:resetToIdle 清全部

    /// 验证 resetToIdle 把 ocrLines / translatedOverlay / translatedCanvasData 全清,
    /// status 回到 .idle。与 clearTranslation 的区别:本方法彻底放弃所有数据,
    /// 下次点"提取文字"必须重新走 Vision。
    @MainActor
    @Test func resetToIdleClearsAllState() async {
        let line = makeOCRLine(text: "hello")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)

        // 前置:有数据
        #expect(!service.ocrLines.isEmpty)
        service.setTranslatedCanvasData(Data([0xFA, 0xCE]))
        #expect(service.translatedCanvasData != nil)

        // 调 resetToIdle
        service.resetToIdle()

        // 断言:全部清,status = .idle
        #expect(service.ocrLines.isEmpty)
        #expect(service.translatedOverlay == nil)
        #expect(service.translatedCanvasData == nil)
        #expect(service.status == .idle)
    }

    // MARK: - Test 5:reset 清全部(等价 resetToIdle)

    /// 验证 reset 与 resetToIdle 行为一致:清 ocrLines / translatedOverlay /
    /// translatedCanvasData,status = .idle。
    @MainActor
    @Test func resetClearsAllStateLikeResetToIdle() async {
        let line = makeOCRLine(text: "world")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)

        service.setTranslatedCanvasData(Data([0xBA, 0xBE]))
        #expect(service.translatedCanvasData != nil)
        #expect(service.status == .completed)

        service.reset()

        #expect(service.ocrLines.isEmpty)
        #expect(service.translatedOverlay == nil)
        #expect(service.translatedCanvasData == nil)
        #expect(service.status == .idle)
    }

    // MARK: - Test 6:setTranslatedCanvasData 直接写

    /// 验证 setTranslatedCanvasData 直接把传入 data 写到字段上。
    /// 字段访问性是 `private(set) var`,测试可读;setter 由该方法暴露。
    @MainActor
    @Test func setTranslatedCanvasDataWritesFieldDirectly() {
        let vision = MockVisionOCRClient()
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        #expect(service.translatedCanvasData == nil)

        let payload = Data([0x01, 0x02, 0x03])
        service.setTranslatedCanvasData(payload)
        #expect(service.translatedCanvasData == payload)

        // 再 set nil 也能清掉
        service.setTranslatedCanvasData(nil)
        #expect(service.translatedCanvasData == nil)
    }

    // MARK: - Test 7:状态机转换(idle → ocrLoading → completed)

    /// 验证 startRecognition 的状态机转换:idle → ocrLoading → completed。
    /// 用 blocking mock 在 OCR 入口 await,让测试可靠采样 .ocrLoading 中间态。
    @MainActor
    @Test func stateMachineTransitionsIdleToCompleted() async {
        let gate = BlockingGate()
        let line = makeOCRLine(text: "alpha")

        let vision = MockVisionOCRClient(linesToReturn: [line])
        let service = Self.makeService(
            visionClient: BlockingVisionAdapter(mock: vision, gate: gate),
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        let canvas = makeTestPNGData()

        // 启动后台 task 跑 startRecognition —— 用 Task.detached 避免继承
        // test 函数的 main actor 隔离导致 task 同步等待
        let task = Task.detached(priority: .userInitiated) { @MainActor in
            await service.startRecognition(canvasData: canvas)
        }
        // 等 mock 入口被触发(callCount >= 1 表明已到入口,gate 已 await)
        while vision.callCount < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        }
        // 此时 mock 在 gate.waitForResume() 里挂起,status 必为 .ocrLoading
        #expect(service.status == .ocrLoading)

        // 放 mock 走完 → status 转 .completed
        gate.signal()
        await task.value

        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["alpha"])
    }

    // MARK: - Test 8:状态机转换(completed → translating → translated)

    /// 验证 startTranslation 的状态机转换:completed → translating → translated。
    /// 配置有效 API Key + blocking mock 翻译客户端,验证中间态 + overlay 正确生成。
    @MainActor
    @Test func stateMachineTransitionsCompletedToTranslated() async {
        let line1 = makeOCRLine(text: "hello")
        let line2 = makeOCRLine(text: "world")
        let vision = MockVisionOCRClient(linesToReturn: [line1, line2])

        let gate = BlockingGate()
        let translation = MockMiniMaxTranslationClient(translatedLinesToReturn: ["你好", "世界"])

        let credential = MockAICredentialKeychain()
        credential.storedKey = "test-api-key-xyz"
        let service = Self.makeService(
            visionClient: vision,
            translationClient: BlockingTranslationAdapter(mock: translation, gate: gate),
            credential: credential
        )

        // 先 OCR 到 .completed
        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)

        // 启动后台 task 跑翻译
        let task = Task.detached(priority: .userInitiated) { @MainActor in
            await service.startTranslation()
        }
        // 等 mock 翻译入口被触发
        while translation.callCount < 1 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // 此时 mock 在 gate.waitForResume() 里挂起,status 必为 .translating
        #expect(service.status == .translating)

        // 放 mock 走完 → status 转 .translated
        gate.signal()
        await task.value

        #expect(service.status == .translated)
        #expect(service.translatedOverlay != nil)
        #expect(service.translatedOverlay?.originalLines.count == 2)
        #expect(service.translatedOverlay?.translatedLines == ["你好", "世界"])
    }

    // MARK: - Test 9:retryRecognition 优先级(用 translatedCanvasData)

    /// 验证 retryRecognition 也按 translatedCanvasData 优先 OCR,与
    /// startRecognition 行为一致 —— .translated 状态下重试也按译文图。
    @MainActor
    @Test func retryRecognitionPrefersTranslatedCanvasData() async {
        let line = makeOCRLine(text: "retried")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let cache = OCRCanvasHashCache()
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain(),
            cache: cache
        )

        // 原图 + 翻译后图(都是有效 PNG,保证 cgImage 解码成功)
        let originalCanvas = makeTestPNGData()
        let translatedCanvas = makeTestPNGDataWithOffset(byteOffset: 200)
        service.setTranslatedCanvasData(translatedCanvas)

        await service.retryRecognition(canvasData: originalCanvas)

        // 核心断言:retry 走的也是 translatedCanvasData
        #expect(service.lastEffectiveCanvasDataForTesting == translatedCanvas)
        #expect(service.lastEffectiveCanvasDataForTesting != originalCanvas)
        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["retried"])
    }

    // MARK: - Test 10:retryRecognition invalidate cache

    /// 验证 retryRecognition 先把 effective canvas hash 在跨实例 cache 里
    /// 的旧条目 invalidate,否则 startRecognition 会命中缓存、跳过 Vision。
    /// 流程:先 OCR 把 effective hash 写入 cache → 再调一次 startRecognition 命中 cache
    /// (Vision callCount 不增加)→ 调 retry → 验证 Vision 被再调一次(callCount +1,
    /// invalidate 后 cache 不再命中)。
    @MainActor
    @Test func retryRecognitionInvalidatesCanvasHashCache() async {
        let line = makeOCRLine(text: "cached")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let cache = OCRCanvasHashCache()
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain(),
            cache: cache
        )

        let canvas = makeTestPNGData()

        // 第一次 OCR → 把 effective hash 写入 cache
        await service.startRecognition(canvasData: canvas)
        #expect(vision.callCount == 1)
        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["cached"])

        // 此时再调一次 startRecognition,会命中 cache,Vision 不会被再调
        await service.startRecognition(canvasData: canvas)
        #expect(vision.callCount == 1)  // 还是 1,因为命中 cache
        #expect(service.ocrLines.map(\.text) == ["cached"])  // 从 cache 取,内容一致

        // 调 retryRecognition → 必须 invalidate cache,Vision 被再调一次
        await service.retryRecognition(canvasData: canvas)
        #expect(vision.callCount == 2)  // invalidate 后 Vision 再跑一次
        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["cached"])  // 第二次 mock 仍返回 ["cached"]
    }

    // MARK: - Test 11:restartRecognition 覆盖式重做

    /// 验证 `restartRecognition` 在 `.completed` 状态下覆盖之前的结果:
    ///   - 清 ocrLines
    ///   - 清 translatedOverlay
    ///   - 清 translatedCanvasData(关键 —— 让后续 OCR 走原图,而不是上次翻译后的图)
    /// 然后按 canvasData 重新走 OCR。
    /// 与 retryRecognition 的区别:不强制 invalidate 缓存。
    @MainActor
    @Test func restartRecognitionClearsAllAndReOCRsFromOriginal() async {
        let line = makeOCRLine(text: "fresh")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let service = Self.makeService(
            visionClient: vision,
            translationClient: MockMiniMaxTranslationClient(),
            credential: MockAICredentialKeychain()
        )

        // 先做一次识别到 .completed
        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)

        // 前置:写入一些状态,验证 restart 会清掉
        service.setTranslatedCanvasData(Data([0xDE, 0xAD]))
        #expect(service.translatedCanvasData != nil)

        // 调 restartRecognition —— 必须覆盖式重做
        await service.restartRecognition(canvasData: canvas)

        // 关键断言:translatedCanvasData 被清掉 → effective canvas 是原图
        #expect(service.translatedCanvasData == nil)
        #expect(service.translatedOverlay == nil)
        #expect(service.status == .completed)
        #expect(service.ocrLines.map(\.text) == ["fresh"])
        #expect(service.lastEffectiveCanvasDataForTesting == canvas)
    }

    // MARK: - Test 12:startRecognitionAndTranslate 一步操作

    /// 验证 `startRecognitionAndTranslate` 从 `.idle` 一步完成 OCR + 翻译:
    /// - 内部先 startRecognition → status = .completed,ocrLines 不空
    /// - 再 startTranslation → status = .translated,overlay 不空
    /// 等价于用户点"翻译"按钮的最终状态。
    @MainActor
    @Test func startRecognitionAndTranslateFromIdleCompletes() async {
        let line = makeOCRLine(text: "hello")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let translation = MockMiniMaxTranslationClient(translatedLinesToReturn: ["你好"])

        let credential = MockAICredentialKeychain()
        credential.storedKey = "test-api-key"
        let service = Self.makeService(
            visionClient: vision,
            translationClient: translation,
            credential: credential
        )

        let canvas = makeTestPNGData()

        // .idle 起步,直接调
        #expect(service.status == .idle)
        await service.startRecognitionAndTranslate(canvasData: canvas)

        // 一步到底:识别 + 翻译
        #expect(service.status == .translated)
        #expect(service.ocrLines.map(\.text) == ["hello"])
        #expect(service.translatedOverlay?.translatedLines == ["你好"])
        // OCR 走的是原图(因为没设置 translatedCanvasData)
        #expect(service.lastEffectiveCanvasDataForTesting == canvas)
    }

    // MARK: - Test 13:startRecognitionAndTranslate 覆盖式

    /// 验证 `startRecognitionAndTranslate` 在 `.completed` 状态下是覆盖式:
    /// - 清掉之前残留的 translatedCanvasData(即使有,也不应该被翻译再次使用)
    /// - OCR 走原图,然后翻译
    /// 这是「翻译」按钮在 `.completed` 状态下的期望行为。
    @MainActor
    @Test func startRecognitionAndTranslateFromCompletedIsOverwrite() async {
        let line = makeOCRLine(text: "world")
        let vision = MockVisionOCRClient(linesToReturn: [line])
        let translation = MockMiniMaxTranslationClient(translatedLinesToReturn: ["世界"])

        let credential = MockAICredentialKeychain()
        credential.storedKey = "test-api-key"
        let service = Self.makeService(
            visionClient: vision,
            translationClient: translation,
            credential: credential
        )

        // 先 OCR 一次到 .completed,然后写入 translatedCanvasData(模拟 .translated
        // 之外的某种残留状态)
        let canvas = makeTestPNGData()
        await service.startRecognition(canvasData: canvas)
        #expect(service.status == .completed)
        service.setTranslatedCanvasData(Data([0xFE, 0xED]))
        #expect(service.translatedCanvasData != nil)

        // 现在调 startRecognitionAndTranslate —— 必须覆盖
        await service.startRecognitionAndTranslate(canvasData: canvas)

        // 覆盖语义:translatedCanvasData 被清掉,OCR 走原图,然后 overlay 写入
        #expect(service.translatedCanvasData == nil)
        #expect(service.status == .translated)
        #expect(service.ocrLines.map(\.text) == ["world"])
        #expect(service.translatedOverlay?.translatedLines == ["世界"])
        // effective canvas 是原图,不是之前的翻译后图(说明覆盖生效)
        #expect(service.lastEffectiveCanvasDataForTesting == canvas)
    }

    // MARK: - Test 14:OCRStatus 状态查询辅助

    /// 验证 OCRStatus 的便捷查询属性跟底层 case 一一对应。
    /// 这些属性是 EditorToolbar 按钮置灰逻辑的基础,必须稳定。
    @MainActor
    @Test func ocrStatusHelpersReflectUnderlyingCases() {
        // 静态属性 snapshot —— 用闭包初始化避免顺序依赖
        let cases: [(OCRStatus, Bool, Bool, Bool, Bool)] = [
            (.idle,                                false, false, false, false),
            (.ocrLoading,                          false, true,  false, false),
            (.completed,                           true,  false, false, false),
            (.translating,                         false, false, true,  false),
            (.translated,                          false, false, false, true),
            (.failed(.noAPIKey),                   false, false, false, false),
        ]

        for (status, isCompleted, isOCRLoading, isTranslating, isTranslated) in cases {
            #expect(status.isCompleted == isCompleted, "isCompleted mismatch for \(status)")
            #expect(status.isOCRLoading == isOCRLoading, "isOCRLoading mismatch for \(status)")
            #expect(status.isTranslating == isTranslating, "isTranslating mismatch for \(status)")
            #expect(status.isTranslated == isTranslated, "isTranslated mismatch for \(status)")
            // isBusy:ocrLoading / translating 才 true
            let expectedBusy = isOCRLoading || isTranslating
            #expect(status.isBusy == expectedBusy, "isBusy mismatch for \(status)")
        }

        // .idle / .completed / .translated / .failed 都 !isBusy
        #expect(OCRStatus.idle.isBusy == false)
        #expect(OCRStatus.completed.isBusy == false)
        #expect(OCRStatus.translated.isBusy == false)
        #expect(OCRStatus.failed(.noAPIKey).isBusy == false)

        // .idle / .failed.isIdle / isFailed 单独断言(避免元组里元组比对难读)
        #expect(OCRStatus.idle.isIdle == true)
        #expect(OCRStatus.completed.isIdle == false)
        #expect(OCRStatus.failed(.noAPIKey).isFailed == true)
        #expect(OCRStatus.completed.isFailed == false)
    }
}
