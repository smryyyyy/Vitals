//
//  TextAnnotationView.swift
//  Mio
//
//  矢量文字标注视图（spec §6.6）。
//
//  锚点：origin = 文字**字形大写中线**（视觉中心）对应的源图 point
//        视图用 .alignmentGuide(VerticalAlignment.top) { dim in dim[.firstTextBaseline] }
//        把文字的**排版基线**精确落在 positionY 上，
//        再用 .offset 平移到目标位置。
//
//  内边距与字体度量的唯一来源是 EditorTextLayout（画布与导出共用）：
//  字形实际起点 = origin.x + EditorTextLayout.horizontalInset
//  基线 y      = origin.y + EditorTextLayout.capHeightOffset(fontSize:)
//  本文件只消费这些常量，不再自行写死数值。
//
//  为什么用 firstTextBaseline 而不是「行盒中线」：
//  SwiftUI 的行盒高度带**取整**（14pt 系统 medium 字体 CoreText 行盒 16.488pt，
//  SwiftUI 实际行盒 17pt），取整规则不公开、无法用公式复刻 → 画布与导出只要
//  各自推算行盒就必然错开（用户实测：导出文字相对画布正上方偏移 0.36pt@14pt）。
//  firstTextBaseline 是 SwiftUI 自己从排版结果读出的真实基线，绕开取整黑盒；
//  导出侧用「大写中线 + capHeight/2」定位基线，两侧定义同源、结果逐点相等。
//
//  状态机：
//  - 落笔态：仅显示文字（无边框）。
//      · 单击按住拖动 → 改 origin
//      · 双击 → 进编辑（系统 doubleClickInterval + 移动 ≤ 4pt 自动判定）
//      · 单次单击且未拖动 → 视为「未达双击」，无效
//  - 编辑态：带细边框 TextField，自适应宽度。
//      · 失焦（点外面 / Tab 走焦）→ endEditing
//      · ESC → endEditing
//      · 不响应拖动手势
//

import SwiftUI
import AppKit

struct TextAnnotationView: View {
    @Bindable var state: EditorState
    let annotationID: UUID
    /// 源图 point → 显示 point 的缩放系数（imageRect.width / image.size.width）
    let scaleFactor: CGFloat
    /// imageRect 在 GeometryReader 中的偏移
    let imageRectOrigin: CGPoint

    @FocusState private var isFocused: Bool
    @State private var dragOriginAtStart: CGPoint?
    @State private var isDragging: Bool = false

    var body: some View {
        if let annotation = state.textAnnotations.first(where: { $0.id == annotationID }) {
            let isEditing = state.editingTextID == annotation.id
            let displayFont = annotation.fontSize * scaleFactor
            // 水平：origin 是「带内边距的文字框左边」→ 字形实际起点 = origin.x + horizontalInset
            let positionX = imageRectOrigin.x + annotation.origin.x * scaleFactor
            // 垂直：origin 是「字形大写中线」→ 目标基线 = origin.y + capHeight/2
            // （capHeight/2 在源图 point 空间，乘 scaleFactor 换算到显示 point）
            let positionY = imageRectOrigin.y
                + (annotation.origin.y + EditorTextLayout.capHeightOffset(fontSize: annotation.fontSize))
                    * scaleFactor

            // 两个分支各自调用 textLayer（content 在调用点就是**确定的一个视图**）：
            // SwiftUI 的 alignmentGuide 在子树含 if/else（条件内容）时会静默失效，
            // 详见 textLayer 的注释。
            if isEditing {
                textLayer(positionX: positionX, positionY: positionY) {
                    editingField(annotation: annotation, displayFont: displayFont, textColor: swiftUIColor(annotation.color))
                        .padding(.horizontal, EditorTextLayout.horizontalInset * scaleFactor)
                        .padding(.vertical, EditorTextLayout.verticalInset * scaleFactor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1)
                        )
                }
            } else {
                textLayer(positionX: positionX, positionY: positionY) {
                    displayLabel(annotation: annotation, displayFont: displayFont, textColor: swiftUIColor(annotation.color))
                        .padding(.horizontal, EditorTextLayout.horizontalInset * scaleFactor)
                        .padding(.vertical, EditorTextLayout.verticalInset * scaleFactor)
                        .contentShape(Rectangle())
                        // hover 文字框时显示 openHand（提示「可拖动」）。
                        // 拖动期间由 dragGesture 临时设 closedHand。
                        // 离开时不主动 set arrow——父级 EditorView 的 onContinuousHover
                        // 会在父级 hover phase = active 时把光标 set 回工具光标，
                        // 文字框内（子）→ 文字框外（父）的过渡由 SwiftUI hit-test 自动协调。
                        .onContinuousHover { phase in
                            switch phase {
                            case .active:
                                if !isDragging {
                                    NSCursor.openHand.set()
                                }
                            case .ended:
                                // 离开文字框：父级会立即收到 .active 重 set 工具光标
                                break
                            }
                        }
                        .gesture(dragGesture(annotation: annotation))
                        .onTapGesture(count: 2) {
                            state.enterEditing(id: annotation.id)
                        }
                }
            }
        }
    }

    /// 承载文字标注的图层（落笔态 / 编辑态共用同一套锚点逻辑）。
    ///
    /// 锚点对齐策略：
    /// - 父 ZStack(alignment: .topLeading) 默认让子视图左上角对齐 (0, 0)
    /// - 把子视图的 .top 重定义为「排版基线」（firstTextBaseline）→ 基线对齐父 (0,0).y
    /// - 然后 .offset 平移到 (positionX, positionY)
    /// 结果：文字基线 = positionY（= origin.y + capHeight/2 的显示坐标）
    ///
    /// 不用 .position：.position 把视图中心硬性对齐到给定点，宽度变化时
    /// 视觉上视图整体「漂移」（左右半各扩展 W/2）。.offset + alignment guide
    /// 让左边缘成为不动点，宽度只向右增长，符合产品意图。
    ///
    /// **为什么 content 必须是「非条件视图」**（泛型参数传入，而不是在这里 if/else）：
    /// SwiftUI 的 `alignmentGuide` 在子树含条件内容（if/else、switch）时会**静默失效**
    /// —— 实测（NSHostingView 离屏渲染，10pt 字号、scaleFactor 0.5）：
    /// 条件 content 下基线 guide 被忽略，视图顶边直接落在 positionY，
    /// 基线 = positionY + ascent + 内边距，比目标低 7.0pt（换算回源图 point 是 14pt）。
    /// 也就是说 guide 一旦失效，画布与导出侧会整体错开十几 pt，而不是亚 pt 级误差。
    /// 所以编辑态 / 落笔态各自单独调用本方法：调用点传入的是一个确定视图。
    private func textLayer<C: View>(
        positionX: CGFloat,
        positionY: CGFloat,
        @ViewBuilder content: () -> C
    ) -> some View {
        ZStack(alignment: .topLeading) {
            content()
                .fixedSize()
                .alignmentGuide(VerticalAlignment.top) { dim in
                    // firstTextBaseline = SwiftUI 从排版结果读出的真实基线位置，
                    // 相对**当前视图**顶部（padding 已计入：padding 在 content 内部、
                    // guide 之外，dim 即含 padding 的视图尺寸）。
                    // 不做任何行盒推算 → 与导出侧同源。
                    dim[.firstTextBaseline]
                }
                .offset(x: positionX, y: positionY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Editing field

    private func editingField(
        annotation: TextAnnotation,
        displayFont: CGFloat,
        textColor: Color
    ) -> some View {
        let binding = Binding<String>(
            get: { state.textAnnotations.first(where: { $0.id == annotation.id })?.text ?? "" },
            set: { state.updateText(id: annotation.id, text: $0) }
        )

        return TextField("", text: binding)
            .textFieldStyle(.plain)
            .font(.system(size: displayFont, weight: .medium))
            .foregroundStyle(textColor)
            .focused($isFocused)
            .task(id: state.editingTextID) {
                // SwiftUI focus 在 macOS 上有 view-lifecycle timing mismatch:
                // .task 触发时 NSTextField 可能还没完成 first responder attach。
                // 50ms 是「NSTextField attach 完毕」+「用户感知不到延迟」的甜点。
                if state.editingTextID == annotation.id {
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch {
                        return  // view-owned task cancelled (id changed / view gone)
                    }
                    if state.editingTextID == annotation.id {
                        isFocused = true
                    }
                }
            }
            .onChange(of: isFocused) { _, focused in
                // 失焦 = 用户点了外面，结束编辑
                if !focused {
                    state.endEditing()
                }
            }
            .onSubmit {
                state.endEditing()
            }
            .onExitCommand {
                state.endEditing()
            }
    }

    // MARK: - Display label

    private func displayLabel(
        annotation: TextAnnotation,
        displayFont: CGFloat,
        textColor: Color
    ) -> some View {
        Text(annotation.text)
            .font(.system(size: displayFont, weight: .medium))
            .foregroundStyle(textColor)
    }

    // MARK: - Drag

    /// 落笔态拖动：移动 ≥ 4pt 才算开始拖动（SwiftUI minimumDistance）。
    /// 第一次 onChanged 记下 origin 起点，后续按 startLocation→location 增量更新。
    private func dragGesture(annotation: TextAnnotation) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragOriginAtStart == nil {
                    dragOriginAtStart = annotation.origin
                    isDragging = true
                    NSCursor.closedHand.set()
                }
                guard let start = dragOriginAtStart else { return }
                let dx = (value.location.x - value.startLocation.x) / scaleFactor
                let dy = (value.location.y - value.startLocation.y) / scaleFactor
                state.moveText(id: annotation.id, to: CGPoint(x: start.x + dx, y: start.y + dy))
            }
            .onEnded { _ in
                if let start = dragOriginAtStart,
                   let current = state.textAnnotations.first(where: { $0.id == annotation.id })?.origin {
                    state.commitTextMove(id: annotation.id, from: start, to: current)
                }
                dragOriginAtStart = nil
                isDragging = false
                NSCursor.openHand.set()
            }
    }

    // MARK: - Color

    private func swiftUIColor(_ ref: ColorRef) -> Color {
        switch ref {
        case .preset(let i):
            return editorPresetColors[max(0, min(i, editorPresetColors.count - 1))].color
        case .sampled(let r, let g, let b, let a):
            return Color(red: r, green: g, blue: b, opacity: a)
        }
    }
}
