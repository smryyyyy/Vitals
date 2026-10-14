//
//  ANIThemeLoaderTests.swift
//  Vitals - Cursor 模块
//
//  覆盖 ANIThemeLoader 对真实 .ani 样本的解析行为。
//
//  设计原则:
//  - 路径用**绝对路径**:`swift test` 的工作目录不确定,相对路径会假失败。
//  - 断言锚定在实测数据上(不是猜测值),见每个 case 的注释。
//  - 解析失败必须抛具体 error case,不许静默返回空 —— 错误路径用例验证这点。
//
//  ⚠️ 故意没有覆盖的:`CGSCursorBridge`。它一被调用就会真的改掉本机的鼠标指针,
//  而 CI/测试环境里光标坏掉没法自救,所以注册路径只能手测。见 CURSOR.md「跑测试」。
//

import Foundation
import CoreGraphics
import Testing
@testable import MoleWidgetCore

@Suite struct ANIThemeLoaderTests {

    /// 样本目录(绝对路径)。
    private static let cursorsDirectory = URL(fileURLWithPath: "/Users/sunshuo/Documents/GitHub/Vitals/Resources/Cursors")

    private static func cursorURL(_ name: String) -> URL {
        cursorsDirectory.appendingPathComponent(name)
    }

    // MARK: - Test 1:正常样本解析(Normal Select.ani)

    /// 解析 Resources/Cursors/Normal Select.ani。
    ///
    /// 实测结构:`anih` 声明 nFrames=24 / nSteps=32,但 `seq ` 块只有 24 个
    /// DWORD(96 字节)。解析器以 seq 块实际长度为准,所以展开后的帧数是
    /// **24**,而不是 nSteps 字段里的 32 —— 按 32 读会越界 8 个 DWORD 读到
    /// LIST 头,得到垃圾帧索引。
    @Test func parsesNormalSelectTheme() throws {
        let theme = try ANIThemeLoader.load(url: Self.cursorURL("Normal Select.ani"))

        // 播放步骤数 = seq 块实际长度(24),与 nFrames / icon 块数一致。
        #expect(theme.frames.count == 24)

        // 每帧都解出了图像(而不是占位/空图)。
        #expect(theme.frames.allSatisfy { $0.image.width > 0 && $0.image.height > 0 })

        // DIB 双倍高度坑:32x32 图标 height 字段写 64,解析后必须回到 32 行。
        #expect(theme.frames.allSatisfy { $0.image.width == 32 && $0.image.height == 32 })

        // 基准点尺寸取自最宽图像的像素宽(Windows 光标像素网格 == 点网格)。
        #expect(theme.pointsWide == 32)
        #expect(theme.pointsHigh == 32)

        // rate 块 24 项均为 6 jiffies = 0.1 秒。
        #expect(theme.frameDurations.count == theme.frames.count)
        #expect(theme.frameDurations.allSatisfy { abs($0 - 0.1) < 0.0001 })
    }

    // MARK: - Test 2:热点坐标

    /// 验证热点既被正确读出,又落在合理范围内。
    ///
    /// 实测:`Normal Select.ani` 全部 24 帧的热点都是 (1, 1) 点;
    /// 不同光标热点不同(`Work` 是 (1,1),`Move` 是 (10,10))。
    @Test func parsesHotSpotCoordinates() throws {
        let normal = try ANIThemeLoader.load(url: Self.cursorURL("Normal Select.ani"))
        #expect(normal.frames.allSatisfy { $0.hotSpot == CGPoint(x: 1, y: 1) })

        // 跨样本热点不一致 —— 说明热点确实来自文件,不是硬编码常量。
        let move = try ANIThemeLoader.load(url: Self.cursorURL("Move.ani"))
        #expect(move.frames.allSatisfy { $0.hotSpot == CGPoint(x: 10, y: 10) })

        // 所有热点都必须落在图像边界内。
        for theme in [normal, move] {
            for frame in theme.frames {
                #expect(frame.hotSpot.x >= 0 && frame.hotSpot.x <= theme.pointsWide)
                #expect(frame.hotSpot.y >= 0 && frame.hotSpot.y <= theme.pointsHigh)
            }
        }
    }

    // MARK: - Test 3:帧数来自文件本身,不写死

    /// 每个 `.ani` 的帧数由 `anih` 头和 `seq ` 表决定。样本里
    /// `nSteps` 一律虚报 32,但 `seq ` 实际只有 24 项——解析器必须以
    /// `seq ` 的真实长度为准,而不是任何写死的常量。
    ///
    /// `handwriting.ani` 曾是这里的 4 帧样本,它已从资源中移除
    /// (macOS 没有手写笔光标槽位,注册了也不会被请求)。
    @Test func frameCountComesFromSequenceTable() throws {
        for name in ["Normal Select.ani", "Move.ani", "Text Select.ani"] {
            let theme = try ANIThemeLoader.load(url: Self.cursorURL(name))
            #expect(theme.frames.count == 24, "\(name) 应解析出 24 帧")
            #expect(theme.frameDurations.count == 24, "\(name) 的 rate 表应有 24 项")
        }
    }

    // MARK: - Test 4:透明通道没有被 alpha 兜底规则吃掉

    /// 回归屏障:所有样本帧的 alpha 通道都是真实的 {0, 255}(与 AND mask 一致,
    /// mask 置位 = 透明)。如果解析层把「alpha == 0」一律当成不透明,
    /// 这些光标会变成一坨黑方块。
    ///
    /// 断言图像本身含有透明像素:解码后的 CGImage 在全不透明的情况下
    /// 不该出现 alpha == 0 的像素。这里通过对比「首帧 alpha 全部为 0 的判据」
    /// 反向确认 loader 走了 per-pixel alpha 分支。
    @Test func preservesPerPixelTransparency() throws {
        let theme = try ANIThemeLoader.load(url: Self.cursorURL("Normal Select.ani"))
        let image = theme.frames[0].image

        let alphaInfo = image.alphaInfo
        // 解码器直传 RGBA 字节,所以必须是 `last`(非预乘)。
        // 若声明成 `premultipliedLast`,CoreGraphics 会把已经除过 alpha 的
        // 颜色再解释一次,深色光标会淡到近乎透明——注册成功但画出来是空的。
        #expect(alphaInfo == .last)

        // 把图像画进一个 alpha 上下文,统计真正透明的像素数。
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drew)

        let transparentCount = (stride(from: 3, to: pixels.count, by: 4))
            .filter { pixels[$0] == 0 }
            .count

        // 实测 1024 像素里 435 个透明;只要「不是全不透明」就能挡住
        // 「alpha 0 一律当不透明」的回归。
        #expect(transparentCount > 0)
        #expect(transparentCount < width * height)
    }

    // MARK: - Test 5:图像朝向(底向上 DIB 已翻转)

    /// DIB 是**底向上**存储的,解析层必须翻成 CGImage 的顶向下。
    ///
    /// 参考值直接从文件原始字节算出:`Normal Select.ani` 第一帧顶向下每行的
    /// 不透明像素数。这个断言逐行比对全部 32 行,任何行错位(包括把 AND mask
    /// 当成像素行这种整体偏移)都会立刻挂掉。
    ///
    /// 注意:内存里 `CGBitmapContext` 的第 0 行就是图像的**顶行**
    /// (逻辑原点在左下,内存是自上而下排布),所以 buffer 行序即顶向下行序。
    @Test func flipsBottomUpDIBRows() throws {
        let theme = try ANIThemeLoader.load(url: Self.cursorURL("Normal Select.ani"))
        let image = theme.frames[0].image

        // 由原始 DIB 字节算出的顶向下每行不透明像素数。
        let expectedRowOpaqueCounts = [
            3, 4, 5, 6, 7, 8, 9, 10, 11, 20, 22, 24, 24, 23, 21, 20,
            20, 20, 20, 20, 21, 22, 23, 23, 23, 25, 26, 27, 25, 25, 26, 26,
        ]

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGBitmapInfo(rawValue: info)) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        #expect(drew)

        var actualRowOpaqueCounts: [Int] = []
        for row in 0..<height {
            let base = row * width * 4
            let opaque = (stride(from: base + 3, to: base + width * 4, by: 4))
                .filter { pixels[$0] > 0 }
                .count
            actualRowOpaqueCounts.append(opaque)
        }

        // 整帧翻转会让每一行错位,断言整个数组而不是单个采样点。
        #expect(actualRowOpaqueCounts == expectedRowOpaqueCounts)

        // 顶行前 3 个像素是白色(不透明),第 4 个透明 —— 顺带验证 BGRA->RGBA 通道顺序。
        // 像素 N 位于字节 N*4。
        #expect(pixels[0] == 255 && pixels[1] == 255 && pixels[2] == 255 && pixels[3] == 255)
        #expect(pixels[12] == 0 && pixels[13] == 0 && pixels[14] == 0 && pixels[15] == 0)
    }

    // MARK: - Test 6:文件不存在的错误路径

    /// 读取不存在的文件要抛错,不许返回空主题。
    @Test func loadMissingFileThrows() {
        let missing = Self.cursorsDirectory.appendingPathComponent("does-not-exist.ani")
        #expect(throws: (any Error).self) {
            try ANIThemeLoader.load(url: missing)
        }
    }

    // MARK: - Test 7:非 RIFF / 非 ACON

    /// 错误必须落到具体的 error case,而不是笼统失败或静默空结果。
    @Test func rejectsNonRIFFAndNonACONData() {
        let notRIFF = Data("NOPE and then some padding bytes".utf8)
        #expect(throws: ANIThemeLoader.LoadError.notRIFF) {
            try ANIThemeLoader.parse(data: notRIFF)
        }

        // 合法 RIFF 头,但 form type 不是 ACON。
        var wrongForm = Data("RIFF".utf8)
        wrongForm.append(contentsOf: [0x10, 0x00, 0x00, 0x00])
        wrongForm.append(contentsOf: Array("WAVE".utf8))
        wrongForm.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        #expect(throws: ANIThemeLoader.LoadError.notACON) {
            try ANIThemeLoader.parse(data: wrongForm)
        }
    }

    // MARK: - Test 8:截断数据

    /// 合法 ACON 头但块长度超出文件末尾 -> .truncated,不崩溃。
    @Test func rejectsTruncatedData() {
        var truncated = Data("RIFF".utf8)
        truncated.append(contentsOf: [0xFF, 0x00, 0x00, 0x00]) // 声称 255 字节
        truncated.append(contentsOf: Array("ACON".utf8))
        truncated.append(contentsOf: Array("anih".utf8))
        truncated.append(contentsOf: [0x24, 0x00, 0x00, 0x00]) // size = 36
        // 数据到此为止,anih 需要 36 字节 -> 越界
        #expect(throws: ANIThemeLoader.LoadError.truncated) {
            try ANIThemeLoader.parse(data: truncated)
        }

        // 完全空数据。
        #expect(throws: ANIThemeLoader.LoadError.truncated) {
            try ANIThemeLoader.parse(data: Data())
        }
    }

    // MARK: - Test 9:没有 icon 块

    /// 合法 ACON + 合法 anih,但没有 'fram'/'icon' 块 -> .noIconChunk。
    @Test func rejectsThemeWithoutIconChunks() {
        func u32Bytes(_ value: UInt32) -> [UInt8] {
            [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
             UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
        }

        // 一个 36 字节的 anih:nFrames = 0, nSteps = 0。
        var anihBody = Data()
        anihBody.append(contentsOf: u32Bytes(36))   // cbSize
        anihBody.append(contentsOf: [0x18, 0x00])   // flags
        anihBody.append(contentsOf: u32Bytes(0))     // nFrames
        anihBody.append(contentsOf: u32Bytes(0))     // nSteps
        anihBody.append(contentsOf: [UInt8](repeating: 0, count: 36 - anihBody.count))

        var body = Data("ACON".utf8)
        body.append(contentsOf: Array("anih".utf8))
        body.append(contentsOf: u32Bytes(36))
        body.append(anihBody)

        var file = Data("RIFF".utf8)
        file.append(contentsOf: u32Bytes(UInt32(body.count)))
        file.append(body)

        #expect(throws: ANIThemeLoader.LoadError.noIconChunk) {
            try ANIThemeLoader.parse(data: file)
        }
    }

    // MARK: - Test 10:坏的光标数据

    /// 'icon' 块里塞非 .cur 数据(保留字段不为 0)-> .badCursorData。
    @Test func rejectsMalformedCursorPayload() {
        var iconBody = Data()
        iconBody.append(contentsOf: [0x01, 0x00])  // reserved != 0 -> 非法
        iconBody.append(contentsOf: [0x02, 0x00])  // type = CUR
        iconBody.append(contentsOf: [0x01, 0x00])  // count = 1
        iconBody.append(contentsOf: [UInt8](repeating: 0, count: 16))
        iconBody.append(contentsOf: [UInt8](repeating: 0xAB, count: 32))

        let iconChunkSize = UInt32(iconBody.count)
        var listBody = Data("fram".utf8)
        listBody.append(contentsOf: Array("icon".utf8))
        listBody.append(contentsOf: [UInt8(iconChunkSize & 0xFF),
                                     UInt8((iconChunkSize >> 8) & 0xFF),
                                     UInt8((iconChunkSize >> 16) & 0xFF),
                                     UInt8((iconChunkSize >> 24) & 0xFF)])
        listBody.append(iconBody)

        var body = Data("ACON".utf8)
        body.append(contentsOf: Array("anih".utf8))
        var anihBody = Data()
        func u32Bytes(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        anihBody.append(contentsOf: u32Bytes(36))
        anihBody.append(contentsOf: [0x18, 0x00])
        anihBody.append(contentsOf: u32Bytes(1))
        anihBody.append(contentsOf: u32Bytes(1))
        anihBody.append(contentsOf: [UInt8](repeating: 0, count: 36 - anihBody.count))
        body.append(contentsOf: u32Bytes(36))
        body.append(anihBody)

        body.append(contentsOf: Array("LIST".utf8))
        body.append(contentsOf: u32Bytes(UInt32(listBody.count)))
        body.append(listBody)

        var file = Data("RIFF".utf8)
        file.append(contentsOf: u32Bytes(UInt32(body.count)))
        file.append(body)

        #expect(throws: ANIThemeLoader.LoadError.badCursorData) {
            try ANIThemeLoader.parse(data: file)
        }
    }

    // MARK: - Test 11:超大尺寸的 DIB 被拒绝

    /// 构造一个只含 1 帧的 .ani,帧里的 DIB 头**声称** `width × height` 这么大,
    /// 但 payload 里只有 BITMAPINFOHEADER 那 40 字节、没有像素数据。
    ///
    /// 关键在于检查顺序:尺寸上限必须**先于**缓冲区分配触发,所以即使文件里
    /// 根本没有那么多像素字节,也必须报 `.imageTooLarge` 而不是 `.truncated`
    /// 或直接去分配 `width * height * 4`。
    private static func aniWithDIBClaiming(width: Int32, pixelHeight: Int32) -> Data {
        func leU32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func leI32(_ v: Int32) -> [UInt8] { leU32(UInt32(bitPattern: v)) }

        // BITMAPINFOHEADER(40B):height 写双倍值,真实像素行数 = height / 2。
        var dib = Data()
        dib.append(contentsOf: leU32(40))                       // biSize
        dib.append(contentsOf: leI32(width))                    // biWidth
        dib.append(contentsOf: leI32(pixelHeight * 2))          // biHeight(双倍)
        dib.append(contentsOf: [0x01, 0x00])                   // biPlanes
        dib.append(contentsOf: [0x20, 0x00])                   // biBitCount = 32
        dib.append(contentsOf: [UInt8](repeating: 0, count: 40 - dib.count))

        // ICONDIR + 一条 ICONDIRENTRY,payload 紧跟在 22 字节目录之后。
        var cursor = Data()
        cursor.append(contentsOf: [0x00, 0x00])                // idReserved
        cursor.append(contentsOf: [0x02, 0x00])                // idType = CUR
        cursor.append(contentsOf: [0x01, 0x00])                // idCount
        cursor.append(contentsOf: [0x20, 0x20, 0x00, 0x00])    // 32x32, 0 色, reserved
        cursor.append(contentsOf: [0x01, 0x00, 0x01, 0x00])    // hotspot (1,1)
        cursor.append(contentsOf: leU32(UInt32(dib.count)))     // dwBytesInRes
        cursor.append(contentsOf: leU32(UInt32(22)))            // dwImageOffset
        cursor.append(dib)

        var frameList = Data("fram".utf8)
        frameList.append(contentsOf: Array("icon".utf8))
        frameList.append(contentsOf: leU32(UInt32(cursor.count)))
        frameList.append(cursor)

        var anih = Data()
        anih.append(contentsOf: leU32(36))                      // cbSize
        anih.append(contentsOf: [0x18, 0x00])                  // flags
        anih.append(contentsOf: leU32(1))                       // nFrames
        anih.append(contentsOf: leU32(1))                       // nSteps
        anih.append(contentsOf: [UInt8](repeating: 0, count: 36 - anih.count))

        var body = Data("ACON".utf8)
        body.append(contentsOf: Array("anih".utf8))
        body.append(contentsOf: leU32(36))
        body.append(anih)
        body.append(contentsOf: Array("LIST".utf8))
        body.append(contentsOf: leU32(UInt32(frameList.count)))
        body.append(frameList)

        var file = Data("RIFF".utf8)
        file.append(contentsOf: leU32(UInt32(body.count)))
        file.append(body)
        return file
    }

    /// 一个声称 4096×4096 的帧必须在分配缓冲区**之前**被拒掉。
    /// 4096² × 4B ≈ 64 MB,放任下去就是在主线程上凭空吃掉这么多内存。
    @Test func rejectsOversizedDIBBeforeAllocating() {
        let file = Self.aniWithDIBClaiming(width: 4096, pixelHeight: 4096)
        #expect(throws: ANIThemeLoader.LoadError.imageTooLarge) {
            try ANIThemeLoader.parse(data: file)
        }
    }

    /// 上限按"宽或高任一超限"判定,单边超限也要挡住。
    @Test func rejectsOversizedDIBOnEitherAxis() {
        #expect(throws: ANIThemeLoader.LoadError.imageTooLarge) {
            try ANIThemeLoader.parse(data: Self.aniWithDIBClaiming(
                width: 8, pixelHeight: Int32(ANIThemeLoader.maximumFrameDimension) + 1))
        }
        #expect(throws: ANIThemeLoader.LoadError.imageTooLarge) {
            try ANIThemeLoader.parse(data: Self.aniWithDIBClaiming(
                width: Int32(ANIThemeLoader.maximumFrameDimension) + 1, pixelHeight: 8))
        }
    }

    /// 上限本身要留得住真光标:CUR 格式自身的上限是 256,阈值 512 是它的两倍,
    /// 所以任何合法光标都不该被这个检查误伤。样本是 32×32,远在阈值之内。
    @Test func dimensionCeilingIsWideEnoughForRealCursors() throws {
        #expect(ANIThemeLoader.maximumFrameDimension >= 256,
                "阈值必须至少覆盖 CUR 格式自身的 256 上限")
        let theme = try ANIThemeLoader.load(url: Self.cursorURL("Normal Select.ani"))
        #expect(theme.frames.allSatisfy { frame in
            frame.image.width <= ANIThemeLoader.maximumFrameDimension
                && frame.image.height <= ANIThemeLoader.maximumFrameDimension
        })
    }
}