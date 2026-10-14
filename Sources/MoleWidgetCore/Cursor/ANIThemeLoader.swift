//
//  ANIThemeLoader.swift
//  Vitals - Cursor 模块
//
//  解析 Windows 动画光标文件(.ani, RIFF/ACON 容器),提取帧序列与热点坐标。
//
//  本文件是**纯数据解析层**,不涉及任何 CGS API 调用 —— 解码后的
//  `ParsedTheme` 由调用方(CursorThemeService)拿去注册系统光标。
//
//  ── .ani 容器结构(已在 Resources/Cursors/ 的 17 个样本上实测确认)──
//
//      'RIFF' + size + 'ACON'
//        'anih'  36B  cbSize=36, flags, nFrames, nSteps
//        'rate'  4*nFrames  每帧时长,单位 jiffies(1/60 秒)
//        'seq '  4*nSeq     播放步骤 -> 帧索引
//        'LIST'  type='fram',内含 nFrames 个 'icon' 块
//                 每个 'icon' 块都是一份完整的 .cur 文件数据
//
//  ⚠️ 实测坑位(踩过,勿回退):
//  1. `anih.nSteps` 字段在这些样本里恒为 32,但 `seq ` 块实际只有 nFrames
//     个 DWORD(96 字节 = 24 项)。**以 seq 块的实际长度为准**,盲目按 nSteps
//     读会越界读到 LIST 头,得到垃圾帧索引。见 `stepCount` 计算。
//  2. icon 块里的 DIB,BITMAPINFOHEADER 的 height 字段是**双倍值**
//     (32x32 的图标写 64),因为 DIB 同时含像素数据和 1bpp 的 AND mask。
//     实际像素行数 = abs(height) / 2。
//  3. `clrUsed`(offset +32)非 0 时,像素数据起点要后移 `clrUsed * 4`。
//     本样本恒为 0,但代码保留兼容。
//  4. DIB 是**底向上**存储,需要翻转为 CGImage 的顶向下。
//

import Foundation
import CoreGraphics
import AppKit

/// Parser for Windows animated-cursor (`.ani`) themes.
///
/// `ANIThemeLoader` turns the RIFF/ACON container into an ordered array of
/// `Frame` values (each an image plus its hotspot, in points), together with
/// the nominal point size of the theme.
///
/// The loader performs no window-server calls. Registering the parsed frames
/// with the system cursor server is the caller's responsibility.
public enum ANIThemeLoader {

    // MARK: - Public types

    /// A single decoded animation frame.
    public struct Frame {
        /// The decoded cursor image, ready to be handed to the system.
        public var image: CGImage
        /// The active-pixel anchor, expressed in **points**.
        ///
        /// Windows stores the hotspot in the same pixel grid as the image; the
        /// loader rescales it onto the theme's point grid (see `ParsedTheme`).
        public var hotSpot: CGPoint
    }

    /// The result of parsing one `.ani` file.
    public struct ParsedTheme {
        /// Frames in playback order, with the `seq ` table already expanded.
        ///
        /// Length equals the number of playback steps (not the number of
        /// distinct images): a step may repeat an image.
        public var frames: [Frame]

        /// Nominal theme width in points, derived from the widest image.
        public var pointsWide: CGFloat

        /// Nominal theme height in points, derived from the tallest image.
        public var pointsHigh: CGFloat

        /// Per-step duration in seconds, derived from the `rate` table
        /// (`jiffies / 60`).
        ///
        /// - Important: this is informational only. The system cursor API
        ///   accepts a *single* `frameDuration` shared by every frame, so a
        ///   caller cannot honour per-frame timing. `CursorThemeService`
        ///   collapses this array into one uniform value. Do not assume the
        ///   animations play back at these individual rates once registered.
        public var frameDurations: [CGFloat]
    }

    /// Failures that can occur while parsing an `.ani` file.
    public enum LoadError: Error, LocalizedError {
        /// The data does not start with a `RIFF` signature.
        case notRIFF
        /// The RIFF form type is not `ACON` (i.e. not an animated cursor).
        case notACON
        /// A chunk, cursor directory or bitmap payload runs past the end of data.
        case truncated
        /// The `fram` list contained no usable `icon` chunks.
        case noIconChunk
        /// An `icon` chunk is not a well-formed `.cur`/`.ico` file.
        case badCursorData
        /// An image payload was recognised but could not be decoded.
        case imageDecodeFailed
        /// A frame declares a bitmap larger than `maximumFrameDimension`.
        case imageTooLarge

        public var errorDescription: String? {
            switch self {
            case .notRIFF:
                return "Not a RIFF container (missing 'RIFF' signature)."
            case .notACON:
                return "Not an animated cursor (RIFF form type is not 'ACON')."
            case .truncated:
                return "Truncated .ani data: a chunk or image payload exceeds the file."
            case .noIconChunk:
                return "No usable 'icon' chunks found in the .ani 'fram' list."
            case .badCursorData:
                return "Malformed cursor (.cur/.ico) data inside an 'icon' chunk."
            case .imageDecodeFailed:
                return "Failed to decode cursor image data."
            case .imageTooLarge:
                return "Cursor frame is larger than the \(maximumFrameDimension)x\(maximumFrameDimension) pixel limit."
            }
        }
    }

    // MARK: - Constants

    /// Maximum number of frames the system cursor API accepts per cursor.
    ///
    /// Longer animations are resampled down to this count rather than rejected:
    /// a slightly choppier cursor is much better than no cursor at all.
    public static let maximumFrameCount = 24

    /// Maximum width or height, in pixels, of a single decoded frame.
    ///
    /// The CUR/ICO directory stores each dimension in a single byte, so the
    /// format itself tops out at 256 — but the **DIB header** inside the payload
    /// is a full 32-bit field, and the decoder allocates `width × height × 4`
    /// bytes from it. A corrupt or hostile file claiming 65535 × 65535 would
    /// therefore ask for ~17 GB on whatever thread parsed it, which is the
    /// main actor during `apply()`.
    ///
    /// 512 is deliberately generous: it is twice the format's own maximum, so
    /// every legitimate cursor passes and only genuinely broken headers are
    /// rejected. Rejecting a frame is safe — the rest of the theme still
    /// registers, and an oversized frame is never drawn anyway.
    public static let maximumFrameDimension = 512

    /// Jiffies per second used by the `rate` chunk (60 Hz).
    private static let jiffiesPerSecond: Double = 60.0

    /// Frame duration used when a file has no `rate` chunk.
    ///
    /// 6 jiffies (100 ms) — the value every bundled sample uses.
    private static let fallbackFrameDuration: CGFloat = 1.0 / 6.0

    // MARK: - Entry points

    /// Parse the bytes of an `.ani` file.
    ///
    /// - Throws: `LoadError` describing the first structural problem found.
    public static func parse(data: Data) throws -> ParsedTheme {
        let reader = ByteReader(data)

        guard reader.count >= 12 else { throw LoadError.truncated }
        guard try reader.matches("RIFF", at: 0) else { throw LoadError.notRIFF }
        guard try reader.matches("ACON", at: 8) else { throw LoadError.notACON }

        var nFrames = 0
        var nSteps = 0
        var rates: [UInt32] = []
        var seq: [UInt32] = []
        var iconRanges: [Range<Int>] = []

        // Top-level chunk walk. The RIFF size field at offset 4 is advisory
        // (samples are consistently honest, but trailing padding exists), so
        // the real end of the data bounds every read instead.
        var offset = 12
        while offset + 8 <= reader.count {
            let size = Int(try reader.u32(at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= reader.count else { throw LoadError.truncated }

            if try reader.matches("anih", at: offset) {
                // cbSize(36) flags(40) nFrames(44) nSteps(48)
                _ = try reader.u32(at: payloadStart)          // cbSize
                _ = try reader.u16(at: payloadStart + 4)      // flags
                nFrames = Int(try reader.u32(at: payloadStart + 8))
                nSteps = Int(try reader.u32(at: payloadStart + 12))
            } else if try reader.matches("rate", at: offset) {
                rates = try reader.u32Array(from: payloadStart, count: size / 4)
            } else if try reader.matches("seq ", at: offset) {
                seq = try reader.u32Array(from: payloadStart, count: size / 4)
            } else if try reader.matches("LIST", at: offset), size >= 4,
                      try reader.matches("fram", at: payloadStart) {
                // Walk the frame list, collecting each embedded .cur payload.
                var inner = payloadStart + 4
                let innerEnd = payloadEnd
                while inner + 8 <= innerEnd {
                    let innerSize = Int(try reader.u32(at: inner + 4))
                    let innerStart = inner + 8
                    let innerEndOfData = innerStart + innerSize
                    guard innerEndOfData <= innerEnd else { throw LoadError.truncated }
                    if try reader.matches("icon", at: inner) {
                        iconRanges.append(innerStart..<innerEndOfData)
                    }
                    // Chunks are word-aligned: an odd size is followed by a pad byte.
                    inner = innerEndOfData + (innerSize & 1)
                }
            }

            offset = payloadEnd + (size & 1)
        }

        guard !iconRanges.isEmpty else { throw LoadError.noIconChunk }

        // The header's nFrames is advisory too; the icon chunks are ground truth.
        if nFrames > iconRanges.count { nFrames = iconRanges.count }

        let decoded = try iconRanges.map { try parseCursorPayload(reader.slice($0)) }

        // Expand the playback table into the final frame order.
        let stepIndices = resolveSteps(seq: seq, nSteps: nSteps, imageCount: decoded.count)
        guard !stepIndices.isEmpty else { throw LoadError.noIconChunk }

        var frames: [Frame] = stepIndices.map {
            Frame(image: decoded[$0].image, hotSpot: decoded[$0].hotSpot)
        }
        var durations = stepIndices.map { durationSeconds(for: $0, rates: rates) }

        // Clamp to the system limit by even sampling (keeps start + end frames).
        if frames.count > maximumFrameCount {
            var sampledFrames: [Frame] = []
            var sampledDurations: [CGFloat] = []
            sampledFrames.reserveCapacity(maximumFrameCount)
            sampledDurations.reserveCapacity(maximumFrameCount)
            for k in 0..<maximumFrameCount {
                let i = Int((Double(k) * Double(stepIndices.count)) / Double(maximumFrameCount))
                sampledFrames.append(frames[i])
                sampledDurations.append(durations[i])
            }
            frames = sampledFrames
            durations = sampledDurations
        }

        // Point size and hotspot rescaling.
        //
        // Windows cursor images are sized on a pixel grid that is conventionally
        // a power of two, and hotspots are expressed on that same grid, so the
        // nominal point size equals the widest image's pixel width.
        let basePixels = frames.map { $0.image.width }.max() ?? 0
        let basePoints = CGFloat(basePixels)
        if basePixels > 0 {
            for i in frames.indices {
                let imagePixels = frames[i].image.width
                guard imagePixels > 0, imagePixels != basePixels else { continue }
                // A frame wider than the nominal base is scaled down onto the
                // base grid, so its hotspot must be scaled by the same factor.
                let scale = basePoints / CGFloat(imagePixels)
                frames[i].hotSpot = CGPoint(x: frames[i].hotSpot.x * scale,
                                            y: frames[i].hotSpot.y * scale)
            }
        }

        let pointsHigh = CGFloat(frames.map { $0.image.height }.max() ?? 0)

        return ParsedTheme(frames: frames,
                           pointsWide: basePoints,
                           pointsHigh: pointsHigh,
                           frameDurations: durations)
    }

    /// Read an `.ani` file from disk and parse it.
    ///
    /// - Throws: `LoadError` for malformed data, or the underlying file-system
    ///   error (e.g. `NSFileReadNoSuchFileError`) when the URL cannot be read.
    public static func load(url: URL) throws -> ParsedTheme {
        try parse(data: Data(contentsOf: url))
    }

    // MARK: - Playback table

    /// Work out which image each playback step shows.
    ///
    /// The `anih.nSteps` field cannot be trusted: every bundled sample declares
    /// 32 steps while its `seq ` chunk holds only `nFrames` entries (24 for the
    /// 32x32 themes). Reading `nSteps` entries would run 8 DWORDs past the chunk
    /// into the `LIST` header and produce nonsense frame indices, so the chunk's
    /// real length wins. `nSteps` is still honoured when it is *smaller* than the
    /// table, and is used as the sole length hint when there is no `seq ` chunk.
    private static func resolveSteps(seq: [UInt32], nSteps: Int, imageCount: Int) -> [Int] {
        guard imageCount > 0 else { return [] }

        if !seq.isEmpty {
            let usable = nSteps > 0 ? min(seq.count, nSteps) : seq.count
            var steps: [Int] = []
            steps.reserveCapacity(usable)
            for i in 0..<usable {
                let index = Int(seq[i])
                // Defensive: a corrupt table pointing outside the image list
                // drops that step rather than crashing the caller.
                if index < imageCount { steps.append(index) }
            }
            if !steps.isEmpty { return steps }
        }

        // No usable `seq ` chunk — play the images back in file order.
        let count = nSteps > 0 ? min(imageCount, nSteps) : imageCount
        return Array(0..<count)
    }

    /// Convert a frame's `rate` entry (jiffies) into seconds.
    private static func durationSeconds(for imageIndex: Int, rates: [UInt32]) -> CGFloat {
        guard imageIndex < rates.count else { return fallbackFrameDuration }
        let jiffies = rates[imageIndex]
        guard jiffies > 0 else { return fallbackFrameDuration }
        return CGFloat(Double(jiffies) / jiffiesPerSecond)
    }

    // MARK: - Cursor (.cur / .ico) decoding

    /// Decode one `icon` chunk, which holds a complete `.cur`/`.ico` file.
    ///
    /// - Returns: the decoded image plus the hotspot in the image's own pixel grid.
    private static func parseCursorPayload(_ data: Data) throws -> (image: CGImage, hotSpot: CGPoint) {
        let reader = ByteReader(data)

        guard reader.count >= 6 else { throw LoadError.badCursorData }

        let reserved = try reader.u16(at: 0)
        guard reserved == 0 else { throw LoadError.badCursorData }

        let type = try reader.u16(at: 2)
        guard type == 1 || type == 2 else { throw LoadError.badCursorData }

        let entryCount = Int(try reader.u16(at: 4))
        guard entryCount >= 1 else { throw LoadError.badCursorData }
        guard reader.count >= 6 + 16 else { throw LoadError.badCursorData }

        // ICONDIRENTRY — only the first entry is used; animated cursors always
        // carry exactly one image per chunk in practice.
        //
        // width/height are bytes where 0 means 256.
        let entryWidth = Int(try reader.u8(at: 6))
        let entryHeight = Int(try reader.u8(at: 7))
        let hotspotX = Int(try reader.u16(at: 10))
        let hotspotY = Int(try reader.u16(at: 12))
        let bytesInRes = Int(try reader.u32(at: 14))
        let imageOffset = Int(try reader.u32(at: 18))

        guard imageOffset >= 0, bytesInRes > 0 else { throw LoadError.badCursorData }
        let imageEnd = imageOffset + bytesInRes
        guard imageEnd <= reader.count else { throw LoadError.badCursorData }

        // Fall back to the directory entry's logical size if the bitmap header
        // disagrees later on.
        let logicalWidth = entryWidth == 0 ? 256 : entryWidth
        let logicalHeight = entryHeight == 0 ? 256 : entryHeight

        let image: CGImage
        if reader.isPNG(at: imageOffset) {
            image = try decodePNG(reader.slice(imageOffset..<imageEnd))
        } else {
            image = try decodeDIB(reader, range: imageOffset..<imageEnd)
        }

        // Directory-entry dimensions are only a fallback: the bitmap header is
        // authoritative for the decoded size. They are kept here as the declared
        // logical size of the cursor for reference.
        _ = (logicalWidth, logicalHeight)

        return (image, CGPoint(x: hotspotX, y: hotspotY))
    }

    /// Decode a PNG-compressed cursor image.
    private static func decodePNG(_ data: Data) throws -> CGImage {
        guard let rep = NSBitmapImageRep(data: data), let cgImage = rep.cgImage else {
            throw LoadError.imageDecodeFailed
        }
        // A PNG carries its own pixel dimensions inside a compressed stream, so
        // the DIB header check cannot cover this path — enforce the same
        // ceiling here or an oversized image gets through unchecked.
        guard cgImage.width <= maximumFrameDimension,
              cgImage.height <= maximumFrameDimension else {
            throw LoadError.imageTooLarge
        }
        return cgImage
    }

    /// Decode a DIB (device-independent bitmap) cursor image.
    ///
    /// Layout handled here:
    /// - `BITMAPINFOHEADER` (>= 40 bytes): size, width, height, planes, bpp.
    /// - `clrUsed` at header offset +32. When non-zero a colour table of
    ///   `clrUsed` BGRA entries follows the header, so pixel data starts at
    ///   `headerSize + clrUsed * 4`. The bundled samples all use `clrUsed == 0`,
    ///   but the offset is applied unconditionally for compatibility.
    /// - `height` is **doubled** for icon/cursor DIBs: the bitmap stores the
    ///   colour rows plus a 1bpp AND mask, so the real pixel row count is
    ///   `abs(height) / 2`.
    /// - Rows are stored bottom-up and are flipped here to match CGImage's
    ///   top-down convention.
    private static func decodeDIB(_ reader: ByteReader,
                                  range: Range<Int>) throws -> CGImage {
        let base = range.lowerBound
        guard range.count >= 40 else { throw LoadError.imageDecodeFailed }

        let headerSize = Int(try reader.u32(at: base))
        // Anything below BITMAPINFOHEADER cannot be trusted for dimensions.
        guard headerSize >= 40, base + headerSize <= range.upperBound else {
            throw LoadError.imageDecodeFailed
        }

        let width = abs(Int(try reader.i32(at: base + 4)))
        let heightField = try reader.i32(at: base + 8)
        let bitCount = Int(try reader.u16(at: base + 14))

        guard width > 0, heightField != 0 else { throw LoadError.imageDecodeFailed }

        // Doubled height: half of it is colour rows, the rest is the AND mask.
        let pixelRows = abs(Int(heightField)) / 2
        guard pixelRows > 0 else { throw LoadError.imageDecodeFailed }

        // Size ceiling, checked **before** the buffer below is allocated.
        // `width` and `pixelRows` both come straight out of the file's 32-bit
        // header fields, and `rgba` would be `width * pixelRows * 4` bytes —
        // on the main actor, during `apply()`. Rejecting here keeps a corrupt
        // header from turning into a multi-gigabyte allocation.
        guard width <= maximumFrameDimension, pixelRows <= maximumFrameDimension else {
            throw LoadError.imageTooLarge
        }

        // 32bpp BGRA is what Windows cursors ship; anything else would need a
        // palette/index expansion this loader deliberately does not do.
        guard bitCount == 32 else { throw LoadError.imageDecodeFailed }

        let clrUsed = Int(try reader.u32(at: base + 32))
        let pixelStart = base + headerSize + clrUsed * 4
        let bytesPerRow = width * 4
        let pixelBytes = pixelRows * bytesPerRow
        let pixelEnd = pixelStart + pixelBytes
        guard pixelStart >= base, pixelEnd <= range.upperBound else {
            throw LoadError.truncated
        }

        // Build an RGBA, top-down buffer. CG wants big-endian RGBA with
        // premultiplied-last alpha; the samples carry strictly binary alpha
        // (0 or 255), for which premultiplied and straight alpha coincide.
        var rgba = [UInt8](repeating: 0, count: pixelBytes)

        var alphaIsUnused = true
        for row in 0..<pixelRows {
            // DIB row 0 is the bottom row of the image, so destination row
            // `row` reads stored row `pixelRows - 1 - row`.
            //
            // Rows are measured back from the end of the **pixel data**, not
            // from the end of the image payload: the payload also carries the
            // 1bpp AND mask after the pixels, and anchoring on the payload end
            // would shift every row by the mask size (and decode mask bytes as
            // the top image row).
            let sourceRow = pixelEnd - (row + 1) * bytesPerRow
            var cursor = sourceRow
            for column in 0..<width {
                let b = try reader.u8(at: cursor)
                let g = try reader.u8(at: cursor + 1)
                let r = try reader.u8(at: cursor + 2)
                let a = try reader.u8(at: cursor + 3)
                cursor += 4

                let destination = row * bytesPerRow + column * 4
                rgba[destination] = r
                rgba[destination + 1] = g
                rgba[destination + 2] = b
                rgba[destination + 3] = a
                if a != 0 { alphaIsUnused = false }
            }
        }

        // Alpha handling: the bundled cursors use the alpha channel properly
        // (it agrees with the AND mask, where a set bit means transparent), so
        // per-pixel alpha is authoritative and is preserved verbatim.
        //
        // The fallback only fires when an entire frame's alpha channel is zero —
        // the signature of an unused/undefined alpha byte in legacy DIBs. In that
        // case the frame is opaque by definition. Applying the rule to
        // individual zero-alpha pixels would instead paint every transparent
        // outline pixel black.
        if alphaIsUnused {
            for i in stride(from: 3, to: rgba.count, by: 4) {
                rgba[i] = 255
            }
        }

        // The buffer holds straight (non-premultiplied) RGBA copied verbatim
        // from the DIB, so the image must be declared `last`, not
        // `premultipliedLast`. Declaring it premultiplied makes CoreGraphics
        // re-interpret the already-divided colour components, which washes a
        // dark cursor out to near-transparent — it registers fine and paints
        // as blank.
        let info = CGImageAlphaInfo.last.rawValue

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width,
                                  height: pixelRows,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: info),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw LoadError.imageDecodeFailed }

        return image
    }
}

// MARK: - ByteReader

/// Bounds-checked little-endian reader over an immutable byte buffer.
///
/// Every accessor throws `ANIThemeLoader.LoadError.truncated` rather than
/// trapping, so malformed cursor files surface as recoverable errors.
private struct ByteReader {
    private let bytes: [UInt8]

    init(_ data: Data) {
        self.bytes = [UInt8](data)
    }

    var count: Int { bytes.count }

    func u8(at offset: Int) throws -> UInt8 {
        guard offset >= 0, offset + 1 <= bytes.count else { throw ANIThemeLoader.LoadError.truncated }
        return bytes[offset]
    }

    func u16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ANIThemeLoader.LoadError.truncated }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    func u32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ANIThemeLoader.LoadError.truncated }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    func i32(at offset: Int) throws -> Int32 {
        let raw = try u32(at: offset)
        return Int32(bitPattern: raw)
    }

    func u32Array(from start: Int, count: Int) throws -> [UInt32] {
        guard count >= 0, start >= 0, start + count * 4 <= bytes.count else {
            throw ANIThemeLoader.LoadError.truncated
        }
        var result: [UInt32] = []
        result.reserveCapacity(count)
        for i in 0..<count { result.append(try u32(at: start + i * 4)) }
        return result
    }

    /// Compare four bytes against an ASCII tag such as `"RIFF"`.
    func matches(_ tag: String, at offset: Int) throws -> Bool {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ANIThemeLoader.LoadError.truncated }
        let expected = Array(tag.utf8)
        for i in 0..<4 where bytes[offset + i] != expected[i] { return false }
        return true
    }

    /// PNG files always begin with this 8-byte signature.
    func isPNG(at offset: Int) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard offset >= 0, offset + signature.count <= bytes.count else { return false }
        for (i, byte) in signature.enumerated() where bytes[offset + i] != byte { return false }
        return true
    }

    func slice(_ range: Range<Int>) -> Data {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return Data() }
        return Data(bytes[range.lowerBound..<range.upperBound])
    }
}