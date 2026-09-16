//
//  EditorCompositeRenderer.swift
//  Mio
//
//  Module-09 async final compositor (M09-03 / Review1 F02).
//
//  唯一 concrete actor，消费 MainActor 冻结的 `EditorCompositeSnapshot`，用纯
//  CoreGraphics + CoreText 做全分辨率离屏合成，把重位图工作移出 MainActor。
//  它**不**使用 AppKit 文字渲染（`NSAttributedString`/`NSGraphicsContext`）、不读
//  `EditorState`、不使用 `Task.detached` / `@unchecked Sendable` / `@preconcurrency`
//  / `nonisolated(unsafe)`。
//
//  栅格绘制逐条移植自 `CommandRenderer` 的 CGContext 路径（本就是纯 CoreGraphics）；
//  pencil/mosaic 从快照的点序列重建 `CGPath`。文字层用 CoreText（`CTFont` + `CTLine`）
//  实现，基线/翻转语义为 origin = 左边中线、baseline = origin.y + capHeight/2。
//

import CoreGraphics
import CoreText
import Foundation

actor EditorCompositeRenderer {

    /// 全分辨率合成：原图 → 栅格命令时间序 → 文字层（永远在栅格之上）。
    /// 像素尺寸非法或 context/image 创建失败时 typed throw，不返回原图。
    func render(_ snapshot: EditorCompositeSnapshot) throws -> CaptureImage {
        try Task.checkCancellation()

        // F02 strict boundary: 不一致快照必须 typed-fail——绝不静默丢弃打码
        // （mosaic）命令而返回一张“成功”的未打码图（confidentiality）。
        for command in snapshot.commands {
            if case .mosaic(let points, _) = command {
                guard snapshot.pixelatedSource != nil else {
                    throw EditorCompositeError.missingPixelatedSource
                }
                guard !points.isEmpty else {
                    throw EditorCompositeError.invalidMosaicPath
                }
            }
        }

        let original = snapshot.original
        let scale = original.scale
        let pointSize = original.size
        let pixelWidth = Int(pointSize.width * scale)
        let pixelHeight = Int(pointSize.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw EditorCompositeError.invalidDimensions
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw EditorCompositeError.contextCreationFailed
        }

        // 全尺寸位图分配前检查取消：close/20s watchdog 取消后不再启动整次合成。
        try Task.checkCancellation()

        // scaleBy 让后续命令直接用 point 坐标，CGContext 自动渲染到 retina 像素。
        ctx.scaleBy(x: scale, y: scale)

        // 1. 原图（CGContext.draw 自带 Y 翻转，Y-up CTM 下正确）。
        let canvasRect = CGRect(origin: .zero, size: pointSize)
        ctx.draw(original.cgImage, in: canvasRect)

        // 2. 栅格命令 + 3. 文字层:翻到 Y-down(与 SwiftUI Canvas 一致)后绘制。
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pointSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let pixelated = snapshot.pixelatedSource?.cgImage
        for command in snapshot.commands {
            try Task.checkCancellation()
            Self.draw(command, in: ctx, pixelatedSource: pixelated, canvasSize: pointSize)
        }
        for text in snapshot.texts {
            try Task.checkCancellation()
            Self.drawText(text, in: ctx)
        }
        ctx.restoreGState()

        // 4. 翻译覆盖层:在原图 + 标注 + 文字层之上再画一层,保证译文在最上面。
        //    必须在 restoreGState 之后画,因为下面要重新进入 Y-down 坐标系。
        // Bug-LCM-1 修复:`drawTranslationOverlay` 内部按 `mergedParagraph` 分流 —
        // 行覆盖模式(常规)逐行 zip 配对,段落覆盖模式(兜底)整段覆盖在首行 OCR 上。
        if let overlay = snapshot.translatedOverlay, !overlay.isEmpty {
            try Task.checkCancellation()
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pointSize.height)
            ctx.scaleBy(x: 1, y: -1)
            Self.drawTranslationOverlay(
                originalLines: overlay.originalLines,
                translatedLines: overlay.translatedLines,
                mergedParagraph: overlay.mergedParagraph,
                imageSize: pointSize,
                in: ctx
            )
            ctx.restoreGState()
        }

        try Task.checkCancellation()
        guard let image = ctx.makeImage() else {
            throw EditorCompositeError.imageCreationFailed
        }
        return try CaptureImage(validating: image, scale: scale)
    }

    // MARK: - Raster commands (ported from CommandRenderer CGContext path)

    private static func draw(
        _ command: CompositeCommand,
        in ctx: CGContext,
        pixelatedSource: CGImage?,
        canvasSize: CGSize
    ) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch command {
        case .rectangle(let rect, let color, let thickness):
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.strokePath()
        case .ellipse(let rect, let color, let thickness):
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.strokeWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokeEllipse(in: rect)
        case .arrow(let from, let to, let color, let thickness):
            drawArrow(from: from, to: to, color: color, thickness: thickness, in: ctx)
        case .pencil(let points, let color, let thickness):
            guard let path = strokePath(from: points) else { return }
            ctx.setStrokeColor(color.cgColorValue)
            ctx.setLineWidth(Thickness.pencilWidth(thickness))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
        case .mosaic(let points, let thickness):
            guard let pixelatedSource, let path = strokePath(from: points) else { return }
            drawMosaic(path: path, thickness: thickness, pixelatedSource: pixelatedSource, canvasSize: canvasSize, in: ctx)
        }
    }

    private static func strokePath(from points: [CGPoint]) -> CGPath? {
        guard let first = points.first else { return nil }
        let path = CGMutablePath()
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    // MARK: - Arrow (geometry identical to CommandRenderer)

    private static func drawArrow(
        from: CGPoint,
        to: CGPoint,
        color: ColorRef,
        thickness: Int,
        in ctx: CGContext
    ) {
        let tipLength = Thickness.arrowheadLength(thickness)
        let tipAngle: CGFloat = .pi / 6
        let theta = atan2(to.y - from.y, to.x - from.x)
        let lineEnd = CGPoint(
            x: to.x - cos(theta) * tipLength * 0.4,
            y: to.y - sin(theta) * tipLength * 0.4
        )
        let tipLeft = CGPoint(
            x: to.x - cos(theta - tipAngle) * tipLength,
            y: to.y - sin(theta - tipAngle) * tipLength
        )
        let tipRight = CGPoint(
            x: to.x - cos(theta + tipAngle) * tipLength,
            y: to.y - sin(theta + tipAngle) * tipLength
        )

        ctx.setStrokeColor(color.cgColorValue)
        ctx.setFillColor(color.cgColorValue)
        ctx.setLineWidth(Thickness.strokeWidth(thickness))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        ctx.move(to: from)
        ctx.addLine(to: lineEnd)
        ctx.strokePath()

        ctx.move(to: to)
        ctx.addLine(to: tipLeft)
        ctx.addLine(to: tipRight)
        ctx.closePath()
        ctx.fillPath()
    }

    // MARK: - Mosaic (clip stroke → draw pixelated source; Y-flip identical to CommandRenderer)

    private static func drawMosaic(
        path: CGPath,
        thickness: Int,
        pixelatedSource: CGImage,
        canvasSize: CGSize,
        in ctx: CGContext
    ) {
        let stroked = path.copy(
            strokingWithWidth: Thickness.mosaicWidth(thickness),
            lineCap: .square,
            lineJoin: .round,
            miterLimit: 10
        )
        ctx.saveGState()
        ctx.addPath(stroked)
        ctx.clip()
        // 抵消外层 Y-down 翻转，让 CGContext.draw 的内部翻转看到 Y-up 状态。
        ctx.translateBy(x: 0, y: canvasSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelatedSource, in: CGRect(origin: .zero, size: canvasSize))
        ctx.restoreGState()
    }

    // MARK: - Text (CoreText 文字层；no AppKit)

    private static func drawText(_ text: CompositeText, in ctx: CGContext) {
        guard !text.text.isEmpty else { return }

        let font = systemMediumFont(size: text.fontSize)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: text.color.cgColorValue
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            text.text as CFString,
            attributes as CFDictionary
        ) else { return }
        let line = CTLineCreateWithAttributedString(attributed)

        // origin = 左边中线；baseline y 让大写字母视觉中线对齐 origin.y。
        let baselineY = text.origin.y + CTFontGetCapHeight(font) / 2

        // 当前 CTM 是 Y-down；局部平移到 baseline 后再翻 Y，让 CoreText 的 Y-up
        // 字形正向渲染。
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: text.origin.x, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// medium 权重系统字体(CoreText,无 AppKit)。以系统 UI 字体为基础,套一个
    /// weight=0.23(≈ `NSFont.Weight.medium`)的 descriptor。
    private static func systemMediumFont(size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.23]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    // MARK: - Translation overlay (覆盖译文到画布原文字位置)

    /// 翻译覆盖层渲染:按 `mergedParagraph` 分流覆盖策略。
    /// 当前 ctx 已翻成 Y-down(point 空间,origin 左上),可直接用 point 坐标绘制。
    /// - 行覆盖模式(常规):`mergedParagraph == nil` 时,逐行 zip 配对覆盖。
    /// - 段落覆盖模式(兜底):`mergedParagraph != nil` 时,整段译文覆盖在原文首行 OCR
    ///   位置,扩大 padding + 字号自适应段长。
    /// Bug-LCM-1 修复:模型兜底场景下不再 throw,画布上始终能看到译文覆盖层。
    private static func drawTranslationOverlay(
        originalLines: [OCRLine],
        translatedLines: [String],
        mergedParagraph: String?,
        imageSize: CGSize,
        in ctx: CGContext
    ) {
        if let mergedParagraph, !mergedParagraph.isEmpty {
            // 段落覆盖模式:模型兜底场景 — 整段译文覆盖在原文首行 OCR 位置。
            guard let firstLine = originalLines.first else { return }
            drawSingleLineTranslationOverlay(
                line: firstLine,
                translatedText: mergedParagraph,
                imageSize: imageSize,
                in: ctx,
                paragraphMode: true
            )
            return
        }
        // 行覆盖模式(常规路径):逐行 zip 配对。
        for (line, translated) in zip(originalLines, translatedLines) {
            drawSingleLineTranslationOverlay(
                line: line,
                translatedText: translated,
                imageSize: imageSize,
                in: ctx,
                paragraphMode: false
            )
        }
    }

    /// 单行翻译覆盖层渲染(CoreText 路径,no AppKit)。
    /// - 矩形:白色 85% 不透明度,作为覆盖原文字的背景。
    /// - 文字:近黑色,字号按 rect 高度自适应(最小 10pt / 9pt,最大 20pt);
    ///   长英文单词按宽度按比例缩放(scale ≥ 0.4,跟 SwiftUI 版 `.minimumScaleFactor(0.4)`
    ///   一致),不会撑破原文字框(不再追加 "…" 截断)。
    /// - 段落模式下 padding 更大(4 vs 2)+ 字号保底降到 9pt,因为兜底段更长需要更激进的缩字。
    private static func drawSingleLineTranslationOverlay(
        line: OCRLine,
        translatedText: String,
        imageSize: CGSize,
        in ctx: CGContext,
        paragraphMode: Bool
    ) {
        let rect = line.renderRect(imageSize: imageSize)
        guard rect.width > 1, rect.height > 1 else { return }

        // 矩形稍微比原文框大一点,覆盖更干净(避免原文边缘透出)。
        // 段落覆盖模式 padding 更大 —— 兜底段在首行 OCR 位置上需要更大空间。
        let pad: CGFloat = paragraphMode ? 4 : 2
        let bgRect = rect.insetBy(dx: -pad, dy: -pad)
        let textRect = bgRect.insetBy(dx: 4, dy: 2)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        ctx.fill(bgRect)

        // 字号自适应:rect 高度的 60%(比旧 85% 更克制),封顶 20pt,保底 10pt。
        // 段落模式下保底降到 9pt —— 兜底段常常比单行译文更长,需要更激进的缩字。
        // 长英文单词("Temperature" 等)按宽度缩放 —— 测量基准字号下的宽度,如果超出
        // textRect.width 就按比例缩小(scale ≥ 0.4 防缩太小)。这跟 SwiftUI 版
        // `.minimumScaleFactor(0.4)` 行为对齐。
        let baseFontSize: CGFloat = {
            let minSize: CGFloat = paragraphMode ? 9 : 10
            return max(minSize, min(rect.height * 0.6, 20))
        }()
        let baseFont = systemMediumFont(size: baseFontSize)
        let measureAttributes: [CFString: Any] = [kCTFontAttributeName: baseFont]
        let measuredWidth: CGFloat = {
            guard let a = CFAttributedStringCreate(
                nil,
                translatedText as CFString,
                measureAttributes as CFDictionary
            ) else { return 0 }
            let l = CTLineCreateWithAttributedString(a)
            return CTLineGetTypographicBounds(l, nil, nil, nil)
        }()

        let scale: CGFloat
        if measuredWidth > textRect.width, measuredWidth > 0 {
            scale = max(0.4, textRect.width / measuredWidth)
        } else {
            scale = 1.0
        }
        let actualFontSize = baseFontSize * scale
        guard actualFontSize >= 1.0 else { return }
        let actualFont = systemMediumFont(size: actualFontSize)

        let textColor = CGColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: actualFont,
            kCTForegroundColorAttributeName: textColor
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            translatedText as CFString,
            attributes as CFDictionary
        ) else { return }
        let ctLine = CTLineCreateWithAttributedString(attributed)

        // 文字基线:左对齐 + 垂直居中。CoreText 在 Y-up 下画,所以先平移到基线再翻 Y。
        let textBounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
        let baselineY = textRect.midY + textBounds.midY
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: textRect.minX, y: baselineY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    /// 单行文字按可用宽度截断(末尾追加 "…" 表示截断)。优先按字符边界切,避免半字符。
    /// 注:drawTranslationOverlay 已经改为按比例缩放字号(不再截断),本函数保留
    /// 作为通用工具,未来若需要硬截断(标注/badge 等场景)可以复用。
    private static func truncatedText(
        _ text: String,
        maxWidth: CGFloat,
        fontSize: CGFloat
    ) -> String {
        guard !text.isEmpty, maxWidth > 0 else { return "" }
        let font = systemMediumFont(size: fontSize)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]

        func width(of s: String) -> CGFloat {
            guard let a = CFAttributedStringCreate(nil, s as CFString, attributes as CFDictionary) else { return 0 }
            let line = CTLineCreateWithAttributedString(a)
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }

        if width(of: text) <= maxWidth {
            return text
        }

        let ellipsis = "…"
        var lo = 0
        var hi = text.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let prefix = String(text.prefix(mid)) + ellipsis
            if width(of: prefix) <= maxWidth {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        let keep = max(0, lo - 1) // 保证加上 "…" 之后不超
        if keep <= 0 {
            return ellipsis
        }
        return String(text.prefix(keep)) + ellipsis
    }
}

// MARK: - ColorRef → CGColor (nonisolated, shared by the compositor)

extension ColorRef {
    /// 纯值 → `CGColor`（sRGB）。预设 RGB 与 `CommandRenderer` 一致。
    /// nonisolated：供 off-MainActor 的 `EditorCompositeRenderer` 使用。
    nonisolated var cgColorValue: CGColor {
        switch self {
        case .preset(let index):
            let presets: [(CGFloat, CGFloat, CGFloat)] = [
                (0.92, 0.20, 0.18),  // red
                (0.98, 0.65, 0.16),  // orange
                (0.20, 0.78, 0.42),  // green
                (0.10, 0.50, 0.96),  // blue
                (1.00, 1.00, 1.00),  // white
                (0.55, 0.55, 0.55),  // gray
                (0.00, 0.00, 0.00),  // black
            ]
            let idx = max(0, min(index, presets.count - 1))
            let (r, g, b) = presets[idx]
            return CGColor(red: r, green: g, blue: b, alpha: 1)
        case .sampled(let r, let g, let b, let a):
            return CGColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}
