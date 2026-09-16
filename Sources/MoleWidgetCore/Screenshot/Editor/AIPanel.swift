//
//  AIPanel.swift
//  Vitals - Screenshot module
//
//  编辑器右侧的 AI 面板:
//  - 顶部状态条(idle / loading / translating / completed / translated / failed)
//  - 中部 OCR 文本列表(NSTextView,支持圈选 + Cmd+C + 右键"复制")
//    .translated 状态下显示**翻译后**文本列表(避免误导复制原文)。
//  - 目标语言输入框(TextField,默认"简体中文")
//  - 底部按钮:**永远只显示「一键复制」** —— 识别 / 翻译 / 重试入口已全部
//    上移到工具栏,本面板只承担「状态展示」+「复制结果」两个职责。
//  - 翻译完成后原文列表清空,只显示「一键复制」复制翻译后的内容。
//

import AppKit
import SwiftUI

struct AIPanel: View {
    @Bindable var service: OCRService
    let onCloseEditor: () -> Void
    /// 当前画布 PNG 数据。重试按钮触发 `retryRecognition` 时回传它。
    let canvasData: Data?

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            languageField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            ocrTextArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            actionButtons
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 280)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
            Spacer()
        }
    }

    private var statusColor: Color {
        switch service.status {
        case .idle: return .gray
        case .ocrLoading, .translating: return .orange
        case .completed, .translated: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch service.status {
        case .idle: return "AI 面板 - 等待识别"
        case .ocrLoading: return "正在识别文字..."
        case .completed:
            let count = service.ocrLines.count
            return "识别完成 (\(count) 行)"
        case .translating: return "正在翻译..."
        case .translated:
            let count = service.ocrLines.count
            return "翻译完成 (\(count) 行)"
        case .failed(let err): return err.localizedDescription
        }
    }

    // MARK: - 目标语言输入框

    private var languageField: some View {
        HStack(spacing: 6) {
            Text("目标语言")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            TextField("简体中文", text: Binding(
                get: { service.targetLanguage },
                set: { service.targetLanguage = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
        }
    }

    // MARK: - OCR 文本区域

    private var ocrTextArea: some View {
        Group {
            if displayText.isEmpty {
                emptyPlaceholder
            } else {
                SelectableTextView(text: displayText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text(emptyPlaceholderText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 占位文案 —— 跟 status 联动。识别 / 翻译中提示「处理中」,失败给出原因,
    /// 翻译完成时让用户去点「清除翻译覆盖层」回到 idle,识别前引导点工具栏「提取文字」。
    private var emptyPlaceholderText: String {
        switch service.status {
        case .ocrLoading: return "识别中..."
        case .translating: return "翻译中..."
        case .failed(let err): return err.localizedDescription
        case .translated: return "翻译完成,点击工具栏「清除翻译覆盖层」回到初始状态"
        case .idle: return "点击上方「提取文字」按钮开始识别"
        case .completed: return "识别结果为空"
        }
    }

    /// 中间区段显示的文本:
    ///   .translated → 翻译后的文本(overlay.translatedLines)
    ///   其它状态   → 原文(ocrLines.map(\.text))
    /// 这样在 .translated 状态下用户看到的是译文,避免「识别原文 + 翻译覆盖层」
    /// 视觉冲突;同时也配合「一键复制」按钮在 .translated 时复制译文。
    private var displayText: String {
        if service.status.isTranslated, let overlay = service.translatedOverlay {
            return overlay.translatedLines.joined(separator: "\n")
        }
        return service.ocrLines.map(\.text).joined(separator: "\n")
    }

    // MARK: - 操作按钮

    /// 底部操作按钮区 —— **永远只显示「一键复制」**(配合 OCR 失败时的
    /// 「前往设置」入口)。识别 / 翻译 / 重试 / 清除翻译覆盖层按钮已全部
    /// 移到上方 EditorToolbar,本面板不再承担触发入口的职责,只展示
    /// 「状态文字 + 文本列表 + 一键复制」三段。
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyRelevantText()
            } label: {
                Label("一键复制", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(copyableText.isEmpty)
            .help(copyableHint)

            // .noAPIKey 时引导用户去设置 API Key(其它失败由工具栏「提取文字」
            // /「翻译」按钮自然触发 retry)。
            if case .failed(let err) = service.status, err == .noAPIKey {
                Button {
                    NotificationCenter.default.post(name: .openScreenshotSettings, object: nil)
                } label: {
                    Text("前往设置")
                }
                .controlSize(.small)
            }
        }
    }

    /// 当前应该被「一键复制」复制走的文本:
    ///   - .translated + 行覆盖模式 → 翻译后的逐行文本(overlay.translatedLines)
    ///   - .translated + 段落覆盖模式 → 整段译文(overlay.mergedParagraph)
    ///                                    —— 模型把多行原文合并翻译时,逐行 zip
    ///                                       没有意义,直接复制段落整段文本。
    ///   - 其它状态   → 原文(ocrLines.map(\.text))
    /// 配合 ocrTextArea 同步显示,避免「列表里看到原文却复制了译文」的反直觉体验。
    private var copyableText: String {
        if service.status.isTranslated, let overlay = service.translatedOverlay {
            if overlay.isParagraphMode, let merged = overlay.mergedParagraph, !merged.isEmpty {
                return merged
            }
            return overlay.translatedLines.joined(separator: "\n")
        }
        return service.ocrLines.map(\.text).joined(separator: "\n")
    }

    private var copyableHint: String {
        if service.status.isTranslated { return "复制翻译后的文本" }
        return "复制识别出的原文"
    }

    private func copyRelevantText() {
        let text = copyableText
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - 可选中文本视图(包装 NSTextView)

struct SelectableTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.string = text
        textView.autoresizingMask = [.width]

        scroll.documentView = textView
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

extension Notification.Name {
    public static let openScreenshotSettings = Notification.Name("Vitals.openScreenshotSettings")
}