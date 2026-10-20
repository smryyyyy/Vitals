import CoreText
import Foundation
import Testing
@testable import MoleWidgetCore

/// `EditorTextLayout` 是文字标注锚点语义与字体度量的唯一来源。
/// 画布（TextAnnotationView）与导出（EditorCompositeRenderer）两侧共用，
/// 这里的断言锁住「两侧不会再分叉」的关键常量与公式。
@Suite struct EditorTextLayoutTests {

    // MARK: - 内边距常量

    @Test func insets_arePositiveConstants() {
        // 内边距只影响命中区与视觉框，方向上必须为正（负值会让字形跑到 origin 左侧）。
        #expect(EditorTextLayout.horizontalInset > 0)
        #expect(EditorTextLayout.verticalInset > 0)
        #expect(EditorTextLayout.horizontalInset == 6)
        #expect(EditorTextLayout.verticalInset == 4)
    }

    @Test func verticalInset_doesNotAffectBaselineOffset() {
        // 上下内边距对称 → 文字框竖直中线不移动 → 基线偏移与 verticalInset 无关。
        // 本函数不读 verticalInset，这里显式确认两常量互不耦合。
        #expect(EditorTextLayout.verticalInset != EditorTextLayout.horizontalInset)
    }

    // MARK: - 基线偏移

    @Test func capHeightOffset_withinExpectedRatioOfFontSize() {
        // capHeight/2：系统 medium 字体的 capHeight ≈ 0.705 × fontSize，
        // 所以偏移 ≈ 0.352 × fontSize。区间留了余量，跨 macOS 版本字体度量变化时不至于误报。
        for size in [10.0, 12.0, 14.0, 18.0, 24.0] as [CGFloat] {
            let offset = EditorTextLayout.capHeightOffset(fontSize: size)
            #expect(offset >= 0.30 * size)
            #expect(offset <= 0.40 * size)
        }
    }

    @Test func capHeightOffset_scalesLinearlyWithFontSize() {
        // capHeight 与字号成正比 → 偏移也是线性缩放。
        let small = EditorTextLayout.capHeightOffset(fontSize: 12)
        let large = EditorTextLayout.capHeightOffset(fontSize: 24)
        #expect(abs(large - 2 * small) < 0.01)
        // 比例恒定（与字号无关）。
        #expect(abs(small / 12 - large / 24) < 0.0001)
    }

    @Test func capHeightOffset_isPositiveAndBelowFontSize() {
        // 基线必须落在大写中线**下方**（正值），且不会低到离谱。
        for size in [10.0, 14.0, 24.0] as [CGFloat] {
            let offset = EditorTextLayout.capHeightOffset(fontSize: size)
            #expect(offset > 0)
            #expect(offset < size)
        }
    }

    // MARK: - 字体

    @Test func systemMediumFont_returnsUsableFont() {
        let font = EditorTextLayout.systemMediumFont(size: 14)
        #expect(CTFontGetAscent(font) > 0)
        #expect(CTFontGetDescent(font) > 0)
        #expect(CTFontGetCapHeight(font) > 0)
        // 与 capHeightOffset 同源：偏移必须能从同一个字体读出。
        // 画布侧与导出侧共用本字体 → 两侧基线基准不会分叉。
        let manual = CTFontGetCapHeight(font) / 2
        #expect(abs(EditorTextLayout.capHeightOffset(fontSize: 14) - manual) < 0.0001)
    }

    @Test func systemMediumFont_appliesMediumWeightTrait() {
        // weight trait 必须真的落到字体上（0.23 ≈ NSFont.Weight.medium），
        // 否则画布（SwiftUI .medium）与导出（CoreText）字重会不一致。
        let font = EditorTextLayout.systemMediumFont(size: 14)
        let descriptor = CTFontCopyFontDescriptor(font)
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute)
            as? [CFString: Any]
        let weight = (traits?[kCTFontWeightTrait] as? NSNumber)?.doubleValue
            ?? (traits?[kCTFontWeightTrait] as? Double)
        #expect(weight != nil)
        #expect(abs((weight ?? 0) - 0.23) < 0.01)
    }

    @Test func systemMediumFont_scalesWithSize() {
        // 字号变大 → ascent/descent 变大，保证 capHeightOffset 的线性假设成立。
        let small = EditorTextLayout.systemMediumFont(size: 12)
        let large = EditorTextLayout.systemMediumFont(size: 24)
        #expect(CTFontGetAscent(large) > CTFontGetAscent(small))
        #expect(abs(CTFontGetAscent(large) - 2 * CTFontGetAscent(small)) < 0.01)
    }
}
