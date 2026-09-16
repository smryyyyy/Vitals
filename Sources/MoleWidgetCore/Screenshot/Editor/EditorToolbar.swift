//
//  EditorToolbar.swift
//  Mio
//
//  编辑器单行工具栏。视觉布局与 EditorToolbarMockup 一致：
//
//    粗细 | 7 色 | 取色器 + 取色结果圆 |  spacer  | 6 工具 | 撤销 / 恢复
//
//  CH-E3 接入：撤销 / 恢复按钮调 state.undo() / state.redo()；
//             ColorRef 替代旧的 SwiftUI Color sampledColor。
//

import SwiftUI
import AppKit

struct EditorToolbar: View {
    @Bindable var state: EditorState
    let onRequestColorSampling: () -> Void
    /// 当前画布 PNG 数据(用于 OCR 哈希缓存)
    var canvasData: Data?

    var body: some View {
        HStack(spacing: 12) {
            // 左：粗细（形态随当前工具切换）
            HStack(spacing: 4) {
                ForEach(0..<3) { level in
                    ThicknessSelector(
                        tool: state.tool,
                        level: level,
                        isSelected: state.thicknessIndex == level
                    ) { state.thicknessIndex = level }
                }
            }

            // 颜色 + 取色组：马赛克时整组滑左隐藏。
            // 用 .mask 限定可见区域到分隔线右侧—粗细按钮所在区域不会被颜色组
            // 滑动时穿过。.transition(.move(edge: .leading)) 让进出从左缘开始。
            ColorGroup(state: state, onRequestColorSampling: onRequestColorSampling)

            Spacer(minLength: 16)

            // 右：6 工具 + 2 AI 按钮
            HStack(spacing: 6) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(
                        tool: tool,
                        isSelected: state.tool == tool
                    ) { state.tool = tool }
                }

                if let ocrService = state.ocrService {
                    Divider().frame(height: 22)

                    // AI 按钮组(永远两个并存):
                    //   「提取文字」+ 「翻译」,在 .ocrLoading / .translating 时都置灰。
                    //   完整状态机矩阵见 OCRService.swift 顶部注释。
                    //   取代旧版 5 状态分支设计,改用两个独立按钮按当前 status
                    //   决定回调 + label,UI 不再变化。
                    ocrButtons(ocrService: ocrService, canvasData: canvasData)
                }
            }

            Divider().frame(height: 22)

            // 撤销 / 恢复
            HStack(spacing: 4) {
                Button {
                    state.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canUndo)
                .help("撤销")
                .keyboardShortcut("z", modifiers: [.command])

                Button {
                    state.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .disabled(!state.canRedo)
                .help("重做")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        // 工具切换时给颜色组做 slide 动画
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.tool == .mosaic)
    }
}

// MARK: - 颜色 + 取色组

/// 颜色 + 取色器整组。马赛克工具时整体向左滑出隐藏；其他工具时滑入。
/// 用独立容器 + .clipped 限定动画范围在自己边界内，避免向左滑动时
/// 越过分隔线侵入粗细按钮区域。
private struct ColorGroup: View {
    @Bindable var state: EditorState
    let onRequestColorSampling: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if state.tool != .mosaic {
                Divider().frame(height: 22)

                HStack(spacing: 2) {
                    ForEach(Array(editorPresetColors.enumerated()), id: \.offset) { index, item in
                        ColorSwatch(
                            color: item.color,
                            isSelected: !state.usingSampled && state.colorIndex == index
                        ) {
                            state.colorIndex = index
                            state.usingSampled = false
                        }
                    }
                }

                Divider().frame(height: 22)

                HStack(spacing: 4) {
                    EyedropperButton {
                        onRequestColorSampling()
                    }
                    SampledColorDot(
                        color: sampledSwiftUIColor(state.sampledColor),
                        isSelected: state.usingSampled
                    ) {
                        if state.sampledColor != nil {
                            state.usingSampled = true
                        }
                    }
                }
            }
        }
        // clipped 把动画约束在容器自己的水平范围内，向左滑出时不会穿过左侧
        // 的粗细按钮区域。马赛克时容器空 → HStack 自然宽度为 0，不占位。
        .clipped()
    }

    private func sampledSwiftUIColor(_ ref: ColorRef?) -> Color? {
        switch ref {
        case .sampled(let r, let g, let b, let a):
            return Color(red: r, green: g, blue: b, opacity: a)
        case .preset, nil:
            return nil
        }
    }
}

// MARK: - 子组件

private struct ToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if tool == .text {
                    Text("A")
                        .font(.system(size: 17, weight: .semibold))
                } else {
                    Image(systemName: tool.icon)
                        .font(.system(size: 15, weight: .medium))
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.borderless)
        .help(tool.label)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

private struct ColorSwatch: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .padding(3)
                .background(
                    Circle()
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }
}

/// 粗细选择器：形态随当前工具切换（spec §15）。
///   矩形 / 椭圆 / 箭头 / 画笔 → 圆点（直径递增）
///   马赛克                  → 方块（边长递增，影响方头画笔大小）
///   文字                    → 数字 1 / 2 / 3（对应 14 / 18 / 24 字号）
private struct ThicknessSelector: View {
    let tool: EditorTool
    let level: Int       // 0=细 1=中 2=粗
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())  // 整个 26×26 区域都可点，不限于内部图标
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: tool)
    }

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .text:
            Text("\(level + 1)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
        case .mosaic:
            let side: CGFloat = [5, 8, 12][level]
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(.primary)
                .frame(width: side, height: side)
        default:
            let diameter: CGFloat = [4, 7, 11][level]
            Circle()
                .fill(.primary)
                .frame(width: diameter, height: diameter)
        }
    }
}

private struct EyedropperButton: View {
    let onPick: () -> Void
    var body: some View {
        Button(action: onPick) {
            Image(systemName: "eyedropper")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .help("取色器:从屏幕拾取颜色")
    }
}

private struct SampledColorDot: View {
    let color: Color?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                        )
                } else {
                    Circle()
                        .strokeBorder(
                            Color.primary.opacity(0.25),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                        .frame(width: 18, height: 18)
                }
            }
            .padding(3)
            .background(
                Circle()
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .disabled(color == nil)
        .help(color == nil ? "暂无取色结果" : "使用取色结果")
    }
}

// MARK: - AI 按钮辅助

private extension EditorToolbar {
    /// 工具栏右侧 AI 按钮组。**永远同时显示「提取文字」+「翻译」两个按钮**,
    /// 跟当前 status 解耦 —— 两个按钮只在 .ocrLoading / .translating 时置灰,
    /// 其他所有状态都可点。
    ///
    /// 状态机矩阵(点击回调):
    ///
    /// | 当前 status | 「提取文字」                           | 「翻译」                            |
    /// | ----------- | ------------------------------------- | ----------------------------------- |
    /// | .idle       | restartRecognition(原图 OCR)         | startRecognitionAndTranslate       |
    /// | .completed  | restartRecognition(覆盖式重做)         | startRecognitionAndTranslate(覆盖式)|
    /// | .translated | startRecognition(按翻译后图)          | resetToIdle(全重置)                 |
    /// | .failed     | retryRecognition                      | startRecognitionAndTranslate        |
    /// | .ocrLoading / .translating | 灰 / 灰                  | 灰 / 灰                            |
    ///
    /// 「翻译」按钮在 .translated 状态下作为「清除翻译覆盖层」入口(走 resetToIdle
    /// 清掉 OCR + 翻译缓存,等价于一次全重置);在其它状态下作为「翻译」入口。
    @ViewBuilder
    func ocrButtons(ocrService: OCRService, canvasData: Data?) -> some View {
        ocrExtractButton(ocrService: ocrService, canvasData: canvasData)
        ocrTranslateButton(ocrService: ocrService, canvasData: canvasData)
    }

    /// 「提取文字」按钮 —— 永远显示,行为按 status 分发:
    ///   .idle / .completed → restartRecognition(canvasData:)
    ///     - .idle:无内容可清,等价于 startRecognition。
    ///     - .completed:覆盖式重做(清 ocrLines + translatedOverlay + translatedCanvasData,
    ///       保证 OCR 走原图)。
    ///   .translated → startRecognition(canvasData:)
    ///     - 必须用 startRecognition,保留 translatedCanvasData 优先级,
    ///       让 OCR 走上次翻译后的图(用户在 .translated 下点「提取文字」是想
    ///       重新识别译文图,不是原图)。
    ///   .failed → retryRecognition(canvasData:)
    ///     - 失败重试语义:invalidate 缓存 + 重跑 Vision。
    ///   .ocrLoading / .translating → 按钮置灰。
    @ViewBuilder
    func ocrExtractButton(ocrService: OCRService, canvasData: Data?) -> some View {
        Button {
            guard let canvasData else { return }
            Task { @MainActor in
                switch ocrService.status {
                case .idle, .completed:
                    await ocrService.restartRecognition(canvasData: canvasData)
                case .translated:
                    // 保留 translatedCanvasData 优先级 → 按翻译后的图重新 OCR。
                    await ocrService.startRecognition(canvasData: canvasData)
                case .failed:
                    await ocrService.retryRecognition(canvasData: canvasData)
                case .ocrLoading, .translating:
                    break  // 按钮置灰,理论上不会到这里
                }
            }
        } label: {
            Label(
                ocrService.status.isOCRLoading ? "识别中…" : "提取文字",
                systemImage: "text.viewfinder"
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(canvasData == nil || ocrService.status.isBusy)
        .help("识别图像中的文字")
    }

    /// 「翻译」按钮 —— 永远显示,行为按 status 分发:
    ///   .translated → resetToIdle()
    ///     - 「清除翻译覆盖层」入口:清 ocrLines + translatedOverlay + translatedCanvasData,
    ///       回到 .idle 全干净状态。
    ///   .idle / .completed / .failed → startRecognitionAndTranslate(canvasData:)
    ///     - 一步操作,内部先 OCR(覆盖式)再翻译,用户无感。
    ///   .ocrLoading / .translating → 按钮置灰。
    @ViewBuilder
    func ocrTranslateButton(ocrService: OCRService, canvasData: Data?) -> some View {
        Button {
            guard let canvasData else { return }
            Task { @MainActor in
                if ocrService.status.isTranslated {
                    ocrService.resetToIdle()
                } else {
                    await ocrService.startRecognitionAndTranslate(canvasData: canvasData)
                }
            }
        } label: {
            Label(
                translateButtonLabel(for: ocrService.status),
                systemImage: "character.bubble"
            )
            .labelStyle(.titleAndIcon)
            .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(canvasData == nil || ocrService.status.isBusy)
        .help(translateButtonHelp(for: ocrService.status))
    }

    /// 「翻译」按钮的 label 文案,跟 status 联动但**不**改变 UI 元素个数。
    private func translateButtonLabel(for status: OCRStatus) -> String {
        switch status {
        case .translating: return "翻译中…"
        case .translated: return "清除翻译覆盖层"
        case .ocrLoading: return "翻译"  // ocrLoading 时按钮灰,只是占位文案
        case .idle, .completed, .failed: return "翻译"
        }
    }

    private func translateButtonHelp(for status: OCRStatus) -> String {
        if status.isTranslated {
            return "清除翻译覆盖层与识别结果,回到未启用状态"
        }
        return "翻译识别出的文字"
    }
}
