//
//  VisionOCRClient.swift
//  Vitals - Screenshot module
//
//  包装 macOS Vision 框架做文字识别。
//  - 用 VNRecognizeTextRequest 异步执行
//  - 2s 超时
//  - 返回带 boundingBox + confidence 的 [OCRLine]
//

import CoreGraphics
import Foundation
import Vision

/// Vision OCR 客户端抽象协议。`OCRService` 通过该协议注入,
/// 让单元测试可以用 mock 实现替换真实 Vision 调用,避免依赖 macOS Vision 框架
/// 与真实图像。生产代码走 `VisionOCRClient` actor 实现。
protocol VisionOCRClientProtocol: Sendable {
    /// 异步识别图像中的文字,返回带 boundingBox + confidence 的 OCR 行列表。
    func recognizeText(in cgImage: CGImage) async throws -> [OCRLine]
}

actor VisionOCRClient: VisionOCRClientProtocol {
    private static let timeoutSeconds: TimeInterval = 2.0

    /// 异步识别图像中的文字,带 2s 超时。
    /// 安全取消:Vision 的 callback 是异步的,如果超时触发 `group.cancelAll()` 后
    /// callback 后续才到达,需要在 callback 入口先查 `Task.isCancelled` 提前 return,
    /// 避免 `continuation.resume` 第二次执行导致对象泄漏/崩溃。
    func recognizeText(in cgImage: CGImage) async throws -> [OCRLine] {
        try await withThrowingTaskGroup(of: [OCRLine].self) { group in
            group.addTask(priority: .userInitiated) { [self] in
                try await performRecognition(cgImage: cgImage)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                throw OCRError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw OCRError.visionFailed("no result")
            }
            return result
        }
    }

    private func performRecognition(cgImage: CGImage) async throws -> [OCRLine] {
        // 任务被取消时(如上层超时)立刻 short-circuit,避免继续走到 VNRequestHandler.perform
        // 提交一个已无意义的 request。
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[OCRLine], Error>) in
                // 防止 callback 抵达时 continuation 已被上层 timeout throw 释放,
                // 导致 double-resume 崩溃;用 atomic flag + 单次 resume 守住。
                let resumeState = ResumeOnce()

                let request = VNRecognizeTextRequest { request, error in
                    // 已被超时路径 cancel → 静默吞掉,不让 callback 二次 resume。
                    if Task.isCancelled || resumeState.isResumed {
                        return
                    }
                    if let error {
                        resumeState.markResumed()
                        continuation.resume(throwing: OCRError.visionFailed(error.localizedDescription))
                        return
                    }
                    guard let observations = request.results as? [VNRecognizedTextObservation] else {
                        resumeState.markResumed()
                        continuation.resume(throwing: OCRError.visionFailed("no observations"))
                        return
                    }
                    let lines: [OCRLine] = observations.compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        return OCRLine(
                            text: candidate.string,
                            boundingBox: obs.boundingBox,
                            confidence: candidate.confidence
                        )
                    }
                    resumeState.markResumed()
                    continuation.resume(returning: lines)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]

                let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try requestHandler.perform([request])
                } catch {
                    // perform 同步抛错 → continuation 还没被 callback resume,
                    // 这里兜底一次 resume,callback 后续抵达时 `resumeState.isResumed`
                    // 会让它提前 return。
                    if !resumeState.isResumed {
                        resumeState.markResumed()
                        continuation.resume(throwing: OCRError.visionFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            // Vision 不支持从外部主动取消已 perform 的请求,但 cancellation handler
            // 至少能让上层 await 立刻抛 CancellationError → 触发外层 withThrowingTaskGroup
            // 的 group.next() 完成(timeout 路径)并清理上下文。callback 后续抵达时
            // 入口处的 `Task.isCancelled || resumeState.isResumed` 守卫保证不二次 resume。
        }
    }
}

/// 单次 resume 守卫。`actor` 内部所有 callback 串行执行,Vision 不会并发回调,
/// 用普通 atomic flag 已经够,但用 OSAllocatedUnfairLock 更稳。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    var isResumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    func markResumed() {
        lock.lock()
        resumed = true
        lock.unlock()
    }
}