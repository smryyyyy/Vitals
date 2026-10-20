//
//  EditorTextLayout.swift
//  Mio
//
//  文字标注的锚点语义与字体度量唯一来源（SPEC §6.6）。
//
//  背景：编辑器画布（TextAnnotationView）与导出渲染（EditorCompositeRenderer）
//  历史上各自解释 `TextAnnotation.origin`，导致「画布所见 ≠ 导出所得」。
//  现在两条渲染路径都调用本文件，保证数学等价：
//    · 锚点语义：origin = 文字**字形大写中线**（视觉中心）对应的源图 point
//    · 水平：字形起点 = origin.x + horizontalInset
//    · 垂直：基线 y  = origin.y + capHeightOffset(fontSize:)
//
//  垂直方向为什么不能用 `(ascent - descent) / 2`（曾经的 baselineOffset）：
//
//  画布侧用 SwiftUI 渲染 `Text`，SwiftUI 的行盒（line box）高度 = ascent + descent
//  + leading，且 SwiftUI 会对行盒做**取整**——14pt 系统 medium 字体的 CoreText 行盒
//  是 16.488pt，SwiftUI 实际行盒却是 17pt（多 0.51pt）。反推 10/12/14/18/24pt
//  几档，取整规则既不是单纯 ceil 也不稳定，**无法用公式复刻**。于是
//    画布实际基线 = origin.y + (ascent - SwiftUI行盒高 / 2)
//    导出基线     = origin.y + (ascent - descent) / 2
//  两者残差 0.26pt（14pt，2x 屏 = 0.52 图像像素），字号越大越明显——正是用户
//  看到的「导出文字相对画布正上方偏移」。
//
//  解法：不再用公式猜 SwiftUI 的行盒，而是让两侧共用**同一个由 SwiftUI 自己
//  提供的锚点**：
//    · 画布侧用 `.alignmentGuide(VerticalAlignment.top) { dim in dim[.firstTextBaseline] }`
//      —— firstTextBaseline 是 SwiftUI 直接从排版结果读出的**真实排版基线**，
//      不经过任何公式推导，绕开行盒取整黑盒；
//    · 锚点目标位置用「大写中线」定义：capHeight 是字体的几何量（无取整），
//      基线 = 大写中线 + capHeight / 2，导出侧（CoreText）能精确复现。
//  于是画布基线与导出基线**逐点相等**（不是近似相等）。
//
//  本文件只依赖 CoreText / CoreGraphics（无 AppKit），可被 actor 隔离的
//  离屏合成器（EditorCompositeRenderer）与主线程画布（TextAnnotationView）共用。
//

import CoreText
import CoreGraphics

/// 文字标注的锚点与字体度量唯一来源。
///
/// 两侧渲染路径必须调用本文件，禁止各自写死数值——数值一旦分叉就会重新出现
/// 「画布所见 ≠ 导出所得」的错位。
enum EditorTextLayout {

    // MARK: - 锚点内边距

    /// origin 语义（SPEC §6.6）：文字**字形大写中线**对应的源图 point（Y-down，左上原点）。
    /// 也就是文字的视觉中心——用户点击落点即视觉中心，最符合直觉。
    /// 字形实际起点 = origin.x + horizontalInset。
    static let horizontalInset: CGFloat = 6

    /// 文字框上下内边距（源图 point）。只影响命中区与视觉框，不影响基线位置——
    /// 上下内边距对称，文字框的竖直中线不因加内边距而移动。
    static let verticalInset: CGFloat = 4

    // MARK: - 字体

    /// medium 权重系统字体（CoreText，无 AppKit）。
    ///
    /// 以系统 UI 字体为基础，套一个 weight=0.23（≈ `NSFont.Weight.medium`）的
    /// descriptor，与画布侧 SwiftUI `.font(.system(size:weight:.medium))` 对齐。
    static func systemMediumFont(size: CGFloat) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.23]
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateCopyWithAttributes(base, size, nil, descriptor)
    }

    // MARK: - 垂直锚点

    /// 从「大写中线」到绘制基线的 Y 偏移（源图 point，向下为正）。
    ///
    /// 定义：capHeight 是基线到字形大写顶部的距离（纯字体几何量，**无取整**），
    /// 大写中线 = 基线 - capHeight / 2，于是
    ///   基线 = 大写中线 + capHeight / 2
    ///
    /// 画布侧与导出侧都调用本函数：
    ///   · 画布：`.offset` 的 y 目标 = origin.y + capHeightOffset(fontSize:)
    ///     （配合 `firstTextBaseline` 对齐 guide，基线精确落在该点）
    ///   · 导出：CoreText 的 `ctx.translateBy(x:y:)` 直接落在该基线上
    static func capHeightOffset(fontSize: CGFloat) -> CGFloat {
        CTFontGetCapHeight(systemMediumFont(size: fontSize)) / 2
    }
}
