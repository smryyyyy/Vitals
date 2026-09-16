//
//  EditorView.swift
//  Mio
//
//  CH-E3 编辑器 root view。
//
//  渲染分层（spec §5）：
//  - L1: 原图 — 静态 CGImage GPU texture
//  - L2: Canvas（透明）— 所有 commands + drafting，每帧重画
//  - L3: 文字矢量层（CH-E5 起接入；当前阶段空 ForEach）
//

import SwiftUI
import AppKit

struct EditorView: View {
    @State private var state: EditorState

    let onCancel: () -> Void
    let onFinish: () -> Void
    let onRetryDelivery: () -> Void
    let onRequestMosaic: () -> Void
    let onRequestColorSampling: () -> Void
    /// 当前画布 PNG 数据(用于 OCR 哈希缓存)
    let canvasData: Data?
    /// 翻译完成时由 EditorView 冻结快照后调,EditorWindowController 用 `EditorCompositeRenderer`
    /// 渲染翻译后的画布 PNG 并回写 `OCRService.translatedCanvasData`,用于
    /// `.translated` 状态下再点"提取文字"按已翻译的图重新 OCR。
    /// 失败返回 nil —— 静默降级到「按原图 OCR」,不阻断用户流程。
    let onTranslatedCanvasReady: ((EditorCompositeSnapshot) async -> Data?)?

    init(
        state: EditorState,
        onCancel: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onRetryDelivery: @escaping () -> Void,
        onRequestMosaic: @escaping () -> Void,
        onRequestColorSampling: @escaping () -> Void,
        canvasData: Data? = nil,
        onTranslatedCanvasReady: ((EditorCompositeSnapshot) async -> Data?)? = nil
    ) {
        self._state = State(initialValue: state)
        self.onCancel = onCancel
        self.onFinish = onFinish
        self.onRetryDelivery = onRetryDelivery
        self.onRequestMosaic = onRequestMosaic
        self.onRequestColorSampling = onRequestColorSampling
        self.canvasData = canvasData
        self.onTranslatedCanvasReady = onTranslatedCanvasReady
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(
                state: state,
                onRequestColorSampling: onRequestColorSampling,
                canvasData: canvasData
            )
                .disabled(!state.isEditable)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    canvasArea
                        // 禁掉画布区的隐式动画（commands 增减、drafting 更新时不做溶解过渡），
                        // 但保留工具栏区域的动画能力（工具切换 / 颜色组 slide）。
                        .transaction { $0.animation = nil }
                        .allowsHitTesting(state.isEditable)
                    footerBar
                }
                // OCRService 收敛到 EditorState 后,这里从 state.ocrService 取(nil 时
                // 不显示 AI 面板,工具栏的 OCR/翻译按钮也由工具栏内部按 state.ocrService 判定)。
                if let ocrService = state.ocrService {
                    Divider()
                    AIPanel(service: ocrService, onCloseEditor: onFinish, canvasData: canvasData)
                }
            }
        }
        // SwiftUI fitting size 兜底 760×760：让 TextField 进/退编辑时的内部
        // fitting 抖动不传播到 NSHostingController.sizingOptions = [.minSize]
        // → 不触发窗口 contentMinSize 重算 → 图片不抖。配合 EditorWindowController
        // 的 sizingOptions 桥接，单一来源（SwiftUI fitting → window.contentMinSize）。
        .frame(minWidth: 760, minHeight: 760)
        .background(Color(NSColor.windowBackgroundColor))
        // Bug-OCR-2:监听 OCRService.status → .translated 时,冻结 snapshot 并
        // 交给 EditorWindowController 渲染翻译后的画布 PNG,回写到
        // `OCRService.translatedCanvasData`。让 `.translated` 状态下再点
        // 「提取文字」按已翻译的图重新 OCR,而不是原图。
        // 只在新状态是 .translated 时触发,避免每次 status 抖动都跑一次全分辨率合成。
        .onChange(of: state.ocrService?.status) { _, newStatus in
            guard newStatus == .translated else { return }
            guard let ocrService = state.ocrService,
                  let callback = onTranslatedCanvasReady else { return }
            let snapshot = EditorCompositeSnapshot.capture(
                from: state,
                ocrService: ocrService
            )
            Task { @MainActor in
                // Bug-OCR-10:renderTranslatedCanvasData 在 3 种情况下返回 nil
                // (identity 校验失败 / render 失败 / OCRService 已释放),
                // 语义都是"丢弃",不是"清空"。如果按原代码无脑调用
                // setTranslatedCanvasData(nil),stale callback 完成时会
                // 错误清掉后续 callback 即将写入的缓存。用 guard let 让
                // nil 等同于"丢弃",与 render 内部语义对齐。
                guard let data = await callback(snapshot) else { return }
                ocrService.setTranslatedCanvasData(data)
            }
        }
    }

    private var canvasArea: some View {
        GeometryReader { proxy in
            let imageRect = imageDisplayRect(in: proxy.size)
            let imgSize = state.original.size
            let scaleFactor: CGFloat = imgSize.width > 0 ? imageRect.width / imgSize.width : 1

            ZStack {
                // L1: 原图静态背景
                Image(decorative: state.original.cgImage, scale: state.original.scale)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                // L2: 命令 + drafting 的统一 Canvas（透明，矢量重画）
                annotationCanvas(in: proxy.size)

                // L3: 文字层（矢量视图，每条标注一个独立 view 处理交互）
                ForEach(state.textAnnotations) { annotation in
                    TextAnnotationView(
                        state: state,
                        annotationID: annotation.id,
                        scaleFactor: scaleFactor,
                        imageRectOrigin: imageRect.origin
                    )
                }

                if state.tool == .mosaic {
                    mosaicStatusOverlay
                }
            }
            .contentShape(Rectangle())
            .gesture(toolGesture(canvasSize: proxy.size))
            // 父级光标策略：
            // - 进入 canvas → set 当前工具光标
            // - 离开 canvas → set 回默认 arrow（让工具栏 / footer / 系统区域恢复正常）
            // - 工具/粗细变化时如果鼠标在画布内，由 onChange 触发重 set
            // 用 NSCursor.set() 而非 push/pop，避免栈失衡（push/pop 在工具切换
            // 跨 hover 边界时极易失衡 → 光标永远没法恢复）
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    EditorCursor.cursor(
                        for: state.tool,
                        thickness: state.thicknessIndex,
                        scaleFactor: scaleFactor
                    ).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            // 工具/粗细变化时，若鼠标仍在画布内 onContinuousHover 不会再次触发，
            // 这里通过 onChange 主动重 set。如果鼠标不在画布，set 也无害——
            // SwiftUI / AppKit 下次 hover 任何 cursor rect 时会自动覆盖。
            .onChange(of: state.tool) { _, _ in
                guard state.isEditable else { return }
                if state.tool == .mosaic {
                    onRequestMosaic()
                }
                EditorCursor.cursor(
                    for: state.tool,
                    thickness: state.thicknessIndex,
                    scaleFactor: scaleFactor
                ).set()
            }
            .onChange(of: state.thicknessIndex) { _, _ in
                guard state.isEditable else { return }
                guard state.tool == .mosaic else { return }
                EditorCursor.cursor(
                    for: state.tool,
                    thickness: state.thicknessIndex,
                    scaleFactor: scaleFactor
                ).set()
            }
            // 父级 clipped：文字超出 imageRect 时被裁掉（按用户预期）
            .clipped()
        }
        .padding(16)
        .background(Color(NSColor.underPageBackgroundColor))
    }

    /// 注释层 Canvas — 命令时间序 + drafting。
    /// 命令存的是「源图 point 空间」坐标（与最终合成一致）。Canvas 通过
    /// translate + scale 把源图坐标系映射到 imageRect 显示区域。
    private func annotationCanvas(in canvasSize: CGSize) -> some View {
        let imageRect = imageDisplayRect(in: canvasSize)
        let imgSize = state.original.size
        let scaleFactor: CGFloat = imgSize.width > 0
            ? imageRect.width / imgSize.width
            : 1

        return Canvas(opaque: false, rendersAsynchronously: false) { ctx, _ in
            // 把绘图坐标系映射到 imageRect 显示区域：
            // 1. 原点平移到 imageRect 左上
            // 2. 缩放：源图 1pt = imageRect 中的 scaleFactor pt
            ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
            ctx.scaleBy(x: scaleFactor, y: scaleFactor)

            for cmd in state.commands {
                CommandRenderer.draw(
                    cmd,
                    in: &ctx,
                    pixelatedSource: state.pixelatedSource,
                    canvasSize: imgSize
                )
            }
            if let drafting = state.drafting {
                CommandRenderer.draw(
                    drafting,
                    in: &ctx,
                    pixelatedSource: state.pixelatedSource,
                    canvasSize: imgSize
                )
            }

            // L2.5: 翻译覆盖层(.translated 状态下显示)。
            // EditorCompositeRenderer.drawTranslationOverlay 只在 finish() 合成最终 PNG
            // 时调用,实时画布原本不画翻译,所以用户在画布上完全看不到译文。
            // 这里按相同逻辑用 SwiftUI GraphicsContext 重画一份,坐标空间与 commands 一致
            // (已经在上方 translate + scale 到源图 point 空间)。
            // Bug-LCM-1 修复:`drawTranslationOverlay` 内部按 `mergedParagraph` 分流 —
            // 行覆盖模式(常规)逐行 zip 配对,段落覆盖模式(兜底)整段覆盖在首行 OCR 上。
            if let overlay = state.ocrService?.translatedOverlay, !overlay.isEmpty {
                drawTranslationOverlay(
                    originalLines: overlay.originalLines,
                    translatedLines: overlay.translatedLines,
                    mergedParagraph: overlay.mergedParagraph,
                    imageSize: imgSize,
                    in: ctx
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// 把 EditorCompositeRenderer.drawTranslationOverlay(CGContext 版) 用 SwiftUI
    /// GraphicsContext 重写,供实时画布 Canvas 使用。
    /// 坐标语义与 CGContext 版一致:ctx 已 translate + scale 到源图 point 空间(左上原点),
    /// `line.renderRect(imageSize:)` 直接给源图像素坐标,可直接画。
    ///
    /// Bug-LCM-1 修复:`mergedParagraph` 非空时走段落覆盖模式(模型兜底场景),
    /// 整段译文覆盖在原文首行 OCR 位置,扩大 padding + 字号自适应段长;
    /// `mergedParagraph == nil` 时走行覆盖模式(常规),逐行 zip 配对。
    ///
    /// 渲染细节(行模式与旧版一致):
    /// - 矩形:白色 85% 不透明度,作为覆盖原文字的背景。
    /// - 文字:近黑色,字号按 rect 高度自适应(最小 10pt,最大 20pt);长英文单词
    ///   按宽度按比例缩放(scale ≥ 0.4,跟 CGContext 版一致),不会撑破原文字框。
    ///   注:`GraphicsContext.draw(_: Text, in:)` 的 Text 只能接 Text modifier(.font /
    ///   .foregroundStyle),不能再加 `.lineLimit` / `.minimumScaleFactor`(那是 View
    ///   modifier,会把类型撑成 `some View` 让 draw 过载解析失败)。所以宽度自适应必须
    ///   通过 GraphicsContext.resolve(text:).measure(in:) 测量 + 手动按比例缩字号。
    /// - 垂直居中:跟 CGContext 版对齐 —— CGContext 版 baselineY = textRect.midY +
    ///   textBounds.midY(textBounds 来自 CTLineGetBoundsWithOptions(_, .useGlyphPathBounds),
    ///   midY ≈ (ascent - |descent|) / 2)。GraphicsContext 不暴露 ascent/descent,所以用
    ///   ResolvedText.measure 的 height 估算(经验值 baseline 偏移 = 0.25 * height,
    ///   对应 ascent ≈ 0.75 * height),再用 `ctx.draw(text, at:, anchor:)` 手动指定
    ///   drawing point,让文字 leading + first baseline 落在 (textRect.minX, baselineY),
    ///   视觉上字形中线对齐 textRect.midY。规避 `ctx.draw(_, in: rect)` 的自动居中
    ///   (SwiftUI 用 ascent+descent 中点,与 glyph path bounds 中点不同)导致的 0.5-2px
    ///   画布实时 ↔ finish PNG 视觉偏差。
    private func drawTranslationOverlay(
        originalLines: [OCRLine],
        translatedLines: [String],
        mergedParagraph: String?,
        imageSize: CGSize,
        in ctx: GraphicsContext
    ) {
        if let mergedParagraph, !mergedParagraph.isEmpty {
            // 段落覆盖模式:模型兜底场景 — 整段译文覆盖在原文首行 OCR 位置。
            guard let firstLine = originalLines.first else { return }
            drawSingleLineOverlay(
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
            drawSingleLineOverlay(
                line: line,
                translatedText: translated,
                imageSize: imageSize,
                in: ctx,
                paragraphMode: false
            )
        }
    }

    /// 单行翻译覆盖层渲染。`paragraphMode == true` 时扩大 padding + 字号自适应段长。
    private func drawSingleLineOverlay(
        line: OCRLine,
        translatedText: String,
        imageSize: CGSize,
        in ctx: GraphicsContext,
        paragraphMode: Bool
    ) {
        let rect = line.renderRect(imageSize: imageSize)
        guard rect.width > 1, rect.height > 1 else { return }

        // 矩形稍微比原文框大一点,覆盖更干净(避免原文边缘透出)。
        // 段落覆盖模式 padding 更大 —— 因为整段译文在首行 OCR 位置上,需要更大空间装下。
        let pad: CGFloat = paragraphMode ? 4 : 2
        let bgRect = rect.insetBy(dx: -pad, dy: -pad)

        ctx.fill(
            Path(roundedRect: bgRect, cornerSize: CGSize(width: 2, height: 2)),
            with: .color(.white.opacity(0.85))
        )

        // 字号自适应:rect 高度的 60%(比旧 85% 更克制),封顶 20pt,保底 10pt。
        // 段落模式下保底降到 9pt —— 兜底段常常比单行译文更长,需要更激进的缩字。
        // 然后按 textRect 宽度测一遍,如果基准字号下宽度溢出就按比例缩(scale ≥ 0.4),
        // 长英文单词("Temperature")自动缩字号而不是被截成 "Temperat…"。
        let baseFontSize: CGFloat = {
            let minSize: CGFloat = paragraphMode ? 9 : 10
            return max(minSize, min(rect.height * 0.6, 20))
        }()
        let textRect = bgRect.insetBy(dx: 4, dy: 2)

        let baseText = Text(translatedText)
            .font(.system(size: baseFontSize, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.95))
        let baseMeasured = ctx.resolve(baseText).measure(
            in: CGSize(width: textRect.width, height: textRect.height)
        )

        let scale: CGFloat
        if baseMeasured.width > textRect.width, baseMeasured.width > 0 {
            scale = max(0.4, textRect.width / baseMeasured.width)
        } else {
            scale = 1.0
        }
        let actualFontSize = baseFontSize * scale
        guard actualFontSize >= 1.0 else { return }

        // 用 actualFontSize 重测一次,拿最终绘制高度算 baseline 偏移。
        let finalText = Text(translatedText)
            .font(.system(size: actualFontSize, weight: .medium))
            .foregroundStyle(Color.black.opacity(0.95))
        let finalMeasured = ctx.resolve(finalText).measure(
            in: CGSize(width: textRect.width, height: textRect.height)
        )

        // 手动 baseline(跟 CGContext 版 textRect.midY + textBounds.midY 对齐):
        // textBounds.midY ≈ 0.25 * height(经验值,ascent ≈ 0.75 * height)。
        let baselineY = textRect.midY + finalMeasured.height * 0.25
        // anchor (0, 0.75) 表示文字 bbox 的 (leading, top + 75% * height) ≈ leading + first baseline。
        // 把这个点对齐到 (textRect.minX, baselineY),让文字 baseline 落在 baselineY 处,
        // 视觉上字形中线对齐 textRect.midY,跟 CGContext 版一致。
        ctx.draw(
            finalText,
            at: CGPoint(x: textRect.minX, y: baselineY),
            anchor: UnitPoint(x: 0, y: 0.75)
        )
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("取消", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            if state.deliveryPhase.showsRetry {
                Button("重试交付", action: onRetryDelivery)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    guard state.isEditable else { return }
                    onFinish()
                } label: {
                    if state.deliveryPhase.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("完成")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !state.isEditable
                    || (state.hasMosaicCommands && !state.isMosaicReady)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: - Gesture

    /// 当前选中工具的拖动手势：mouseDown → drafting，mouseUp → commit + 清 drafting。
    /// .text 工具的交互单独处理（不走 drafting 模式）：mouseUp 时若未拖动且
    /// 落点不在已有文字框内 → 创建新文字 + 进编辑。
    private func toolGesture(canvasSize: CGSize) -> some Gesture {
        let imageRect = imageDisplayRect(in: canvasSize)
        return DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard state.isEditable else { return }
                guard state.tool != .text else { return }  // text 工具不走 drafting
                guard state.tool != .mosaic || state.isMosaicReady else { return }
                let start = imagePoint(value.startLocation, in: imageRect)
                let current = imagePoint(value.location, in: imageRect)
                state.drafting = makeDraft(
                    from: start,
                    to: current,
                    appendingTo: state.drafting
                )
            }
            .onEnded { value in
                guard state.isEditable else {
                    state.drafting = nil
                    return
                }
                guard state.tool != .mosaic || state.isMosaicReady else {
                    state.drafting = nil
                    return
                }
                let start = imagePoint(value.startLocation, in: imageRect)
                let end = imagePoint(value.location, in: imageRect)
                if state.tool == .text {
                    handleTextToolClick(at: end)
                    return
                }
                if let cmd = makeCommand(from: start, to: end, draft: state.drafting) {
                    state.commit(cmd)
                }
                state.drafting = nil
            }
    }

    @ViewBuilder
    private var mosaicStatusOverlay: some View {
        switch state.mosaicPhase {
        case .idle:
            EmptyView()
        case .preparing:
            Label("正在生成马赛克...", systemImage: "hourglass")
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .accessibilityAddTraits(.updatesFrequently)
        case .ready:
            EmptyView()
        case .failed:
            VStack(spacing: 8) {
                Label("马赛克生成失败", systemImage: "exclamationmark.triangle")
                Button("重试", action: onRequestMosaic)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// .text 工具 mouseUp 处理：若已经在编辑某条文字 → 视为「点外面」结束编辑；
    /// 否则在落点创建新文字 + 进编辑（落点已被 TextAnnotationView 截获时此回调
    /// 不会被父级触发，所以「不在已有文字框内」自动满足）。
    private func handleTextToolClick(at point: CGPoint) {
        guard state.isEditable else { return }
        if state.editingTextID != nil {
            // TextField 失焦会自动触发 endEditing；这里兜底（用户从 .text 工具
            // 切到别的工具时 editing 会通过别的路径退出）
            state.endEditing()
            return
        }
        // 落点已经在源图 point 空间。创建新文字。
        state.startNewText(at: point)
    }

    /// 把 GeometryReader 坐标转换到「源图 point 空间」：
    /// 1. 减去 imageRect.origin 得到 imageRect 局部坐标（display 空间）
    /// 2. 除以 imageRect 与源图的比例（display → source point）
    /// 命令统一存源图 point 空间，与 EditorCompositeRenderer 合成时使用的坐标系一致。
    private func imagePoint(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        let imgSize = state.original.size
        guard imageRect.width > 0, imgSize.width > 0 else { return .zero }
        let invScale = imgSize.width / imageRect.width
        let local = CGPoint(x: point.x - imageRect.minX, y: point.y - imageRect.minY)
        // Clamp 到 [0, imgSize] 防止用户拖出 imageRect 外时存负值/超界
        let clamped = CGPoint(
            x: max(0, min(local.x * invScale, imgSize.width)),
            y: max(0, min(local.y * invScale, imgSize.height))
        )
        return clamped
    }

    /// 计算图像（scaledToFit）在 GeometryReader 内的实际显示矩形（point）。
    /// 图像源 size 是 state.original.size。
    private func imageDisplayRect(in containerSize: CGSize) -> CGRect {
        let imgSize = state.original.size
        guard imgSize.width > 0, imgSize.height > 0 else { return .zero }
        let containerAspect = containerSize.width / containerSize.height
        let imgAspect = imgSize.width / imgSize.height
        let displaySize: CGSize
        if imgAspect > containerAspect {
            // 图像更宽 → 按宽度铺满
            let w = containerSize.width
            let h = w / imgAspect
            displaySize = CGSize(width: w, height: h)
        } else {
            let h = containerSize.height
            let w = h * imgAspect
            displaySize = CGSize(width: w, height: h)
        }
        let originX = (containerSize.width - displaySize.width) / 2
        let originY = (containerSize.height - displaySize.height) / 2
        return CGRect(origin: CGPoint(x: originX, y: originY), size: displaySize)
    }

    // MARK: - Draft / Command construction

    /// 根据当前工具构造（或更新）drafting。
    private func makeDraft(
        from start: CGPoint,
        to current: CGPoint,
        appendingTo previous: DraftSnapshot?
    ) -> DraftSnapshot {
        let color = state.activeColor
        let thickness = state.thicknessIndex
        switch state.tool {
        case .rectangle:
            return .rectangle(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        case .ellipse:
            return .ellipse(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        case .arrow:
            return .arrow(from: start, to: current, color: color, thickness: thickness)
        case .pencil:
            // 增量 path：第一个点初始化，后续 addLine
            switch previous {
            case .pencil(let mutablePath, _, _):
                mutablePath.addLine(to: current)
                return .pencil(mutablePath: mutablePath, color: color, thickness: thickness)
            default:
                let mutablePath = CGMutablePath()
                mutablePath.move(to: start)
                if start != current {
                    mutablePath.addLine(to: current)
                }
                return .pencil(mutablePath: mutablePath, color: color, thickness: thickness)
            }
        case .mosaic:
            switch previous {
            case .mosaic(let mutablePath, _):
                mutablePath.addLine(to: current)
                return .mosaic(mutablePath: mutablePath, thickness: thickness)
            default:
                let mutablePath = CGMutablePath()
                mutablePath.move(to: start)
                if start != current {
                    mutablePath.addLine(to: current)
                }
                return .mosaic(mutablePath: mutablePath, thickness: thickness)
            }
        case .text:
            // 文字工具不走 drafting 模式：toolGesture 在 onEnded 时直接调
            // handleTextToolClick 创建文字。这里返回一个无害占位以保持 enum 完备。
            return .rectangle(rect: rectFromTwoPoints(start, current), color: color, thickness: thickness)
        }
    }

    /// onEnded 时根据 draft 构造正式 DrawCommand。
    /// 拖动距离过小（点击）时丢弃，避免误产生空命令。
    private func makeCommand(from start: CGPoint, to end: CGPoint, draft: DraftSnapshot?) -> DrawCommand? {
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        // minDrag 在「源图 point 空间」中判定 — 4pt 在 4K 屏 imageRect 缩到一半
        // 时仍约等于 2pt 显示距离，对单击误触够灵敏。
        let minDrag: CGFloat = 4

        switch state.tool {
        case .rectangle:
            let rect = rectFromTwoPoints(start, end)
            guard rect.width > minDrag || rect.height > minDrag else { return nil }
            return .rectangle(id: UUID(), rect: rect, color: state.activeColor, thickness: state.thicknessIndex)
        case .ellipse:
            let rect = rectFromTwoPoints(start, end)
            guard rect.width > minDrag || rect.height > minDrag else { return nil }
            return .ellipse(id: UUID(), rect: rect, color: state.activeColor, thickness: state.thicknessIndex)
        case .arrow:
            guard max(dx, dy) > minDrag else { return nil }
            return .arrow(id: UUID(), from: start, to: end, color: state.activeColor, thickness: state.thicknessIndex)
        case .pencil:
            // 单击丢弃（mutablePath.isEmpty 漏不住单击 — 已 move(to:)）
            guard max(dx, dy) > minDrag else { return nil }
            if case .pencil(let mutablePath, let color, let thickness) = draft,
               let frozen = mutablePath.copy() {
                return .pencil(id: UUID(), path: frozen, color: color, thickness: thickness)
            }
            return nil
        case .mosaic:
            guard max(dx, dy) > minDrag else { return nil }
            if case .mosaic(let mutablePath, let thickness) = draft,
               let frozen = mutablePath.copy() {
                return .mosaic(id: UUID(), path: frozen, thickness: thickness)
            }
            return nil
        case .text:
            return nil  // 已由 handleTextToolClick 处理
        }
    }

    private func rectFromTwoPoints(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
