//
//  OCRLine.swift
//  Vitals - Screenshot module
//
//  Vision 框架识别出的单行文本结果,带 bounding box（归一化坐标 0-1）。
//  boundingBox 用 normalizedRect 表示,可直接转换为图像像素坐标。
//

import CoreGraphics
import Foundation

/// 一行 OCR 识别结果。
nonisolated struct OCRLine: Sendable, Identifiable, Equatable {
    let id: UUID
    /// 识别出的文本内容
    let text: String
    /// Vision 框架的 bounding box,坐标原点在左下角,值域 0-1
    let boundingBox: CGRect
    /// 置信度 0-1
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }

    /// 把 Vision 归一化坐标(origin 在左下角,值域 0-1)
    /// 转换成 SwiftUI/图像像素坐标(origin 在左上角),
    /// 同时按 imageSize 缩放到实际像素。
    func renderRect(imageSize: CGSize) -> CGRect {
        let normalized = boundingBox
        let pixelX = normalized.origin.x * imageSize.width
        let yFromBottom = normalized.origin.y * imageSize.height
        let pixelY = imageSize.height - yFromBottom - normalized.height * imageSize.height
        let pixelW = normalized.width * imageSize.width
        let pixelH = normalized.height * imageSize.height
        return CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
    }
}

/// 译文覆盖层数据:把 OCRLine 和对应翻译文本按顺序绑定。
/// 用于编辑器画布上原位覆盖显示译文。
///
/// **覆盖模式**:
/// - 行覆盖模式(`isLineMode == true`):`translatedLines.count == originalLines.count`,
///   渲染时按顺序 zip 配对,逐行覆盖到对应 OCR 行的 bounding box。
/// - 段落覆盖模式(`isParagraphMode == true`):模型把多行原文合并成一段译文返回,
///   兜底路径 —— 把整段译文覆盖到首行 OCR 的 bounding box 上,字号/边距自适应段长。
nonisolated struct TranslatedOverlay: Sendable, Equatable {
    let originalLines: [OCRLine]
    let translatedLines: [String]
    /// 整段译文。`nil` = 行覆盖模式;`非 nil` = 段落覆盖模式(兜底)。
    /// 段落模式下 `translatedLines` 仍保留模型返回的原始拆分(可能与原文行数不符),
    /// 渲染逻辑以本字段为准 —— 行覆盖模式的逐行 zip 会被忽略。
    let mergedParagraph: String?

    init(
        originalLines: [OCRLine],
        translatedLines: [String],
        mergedParagraph: String? = nil
    ) {
        self.originalLines = originalLines
        self.translatedLines = translatedLines
        self.mergedParagraph = mergedParagraph
    }

    var isEmpty: Bool { originalLines.isEmpty }

    /// 行覆盖模式:逐行 zip 配对覆盖(默认路径,模型正常返回时)。
    var isLineMode: Bool {
        mergedParagraph == nil && translatedLines.count == originalLines.count
    }

    /// 段落覆盖模式:模型把多行原文合并成一段译文返回时的兜底路径。
    var isParagraphMode: Bool { !isLineMode }

    /// 把 Vision 归一化坐标(origin 在左下角,值域 0-1)
    /// 转换成 SwiftUI/图像像素坐标(origin 在左上角),
    /// 同时按 imageSize 缩放到实际像素。逻辑与 `OCRLine.renderRect(imageSize:)` 一致,
    /// 保留这里供调用方按 (overlay, line, imageSize) 组合使用的场景。
    func renderRect(for line: OCRLine, imageSize: CGSize) -> CGRect {
        line.renderRect(imageSize: imageSize)
    }
}