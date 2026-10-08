//
//  CursorThemeService.swift
//  Vitals - Cursor 模块
//
//  把打包在 Resources/Cursors/ 里的 CatOmen Raiden 主题注册到系统光标服务。
//
//  ── 生命周期约束(决定了本类的全部设计)──
//
//  Cursors 图案存放在**本进程的堆内存**里,WindowServer 只持有指针。
//  进程退出 → 内存释放 → 指针悬空 → 光标自动掉回系统默认。
//
//  这意味着:
//  1. 没有任何"安装"语义,只有"当前进程持有"这一种状态。
//  2. Vitals 退出时光标必然恢复默认,这是正确行为而非缺陷。
//  3. 睡眠唤醒 / 长时间内存压力后,已注册的光标可能被系统丢弃,
//     必须重新注册。所以本类监听 NSWorkspace 通知并重注册。
//  4. macOS 升级后 dlsym 可能取不到私有符号,此时整条链路静默失效。
//     `health` 把这件事暴露给 UI,而不是让人对着默认光标猜原因。
//  5. 主题文件从 Application Support 读(不进 .app 包),原因见
//     `cursorResourceDirectory()` 的注释。
//

import AppKit
import CoreGraphics
import Foundation
import OSLog

/// Applies the bundled cursor theme for as long as this process lives.
@MainActor
@Observable
public final class CursorThemeService {

    // MARK: - Health

    /// Why the theme is not (or no longer) applied, for display in the UI.
    public enum Health: Equatable {
        /// Not started, or stopped by the user.
        case off
        /// Registration succeeded; both counts are in source `.ani` files.
        case active(applied: Int, total: Int)
        /// The private API is gone — almost always a macOS update.
        case apiUnavailable
        /// Cursors bundled in the app are missing from the resource bundle.
        case resourcesMissing
        /// The private API was present but registration failed.
        case registrationFailed(reason: String)

        /// One-line status suitable for a settings row.
        public var summary: String {
            switch self {
            case .off:
                return "光标主题：未启用"
            case .active(let applied, let total):
                return "光标主题：已生效 (\(applied)/\(total))"
            case .apiUnavailable:
                return "光标主题：未生效（系统 API 已变更）"
            case .resourcesMissing:
                return "光标主题：未生效（资源缺失）"
            case .registrationFailed(let reason):
                return "光标主题：未生效（\(reason)）"
            }
        }
    }

    /// Current theme state. Observed by the settings UI.
    public private(set) var health: Health = .off

    // MARK: - Cursor map

    /// Bundled `.ani` file → the macOS cursor slots it feeds.
    ///
    /// Keyed by the exact file name so a missing or renamed asset is reported
    /// rather than silently skipped. Only slots macOS actually requests are
    /// listed; anything absent falls back to the system cursor.
    ///
    /// Each file registers **every** name in its list, not just the first.
    /// macOS 26 mixes the modern `com.apple.coregraphics.*` spelling with the
    /// legacy numbered `com.apple.cursor.N` slots, and which one a given caller
    /// asks for varies by context (app vs Dock vs browser). Registering one
    /// name and assuming coverage is what made the theme silently not apply.
    private static let catalog: [(file: String, identifiers: [String])] = [
        ("Normal Select",        ["com.apple.coregraphics.Arrow",
                                  "com.apple.coregraphics.ArrowS",
                                  "com.apple.cursor.0"]),
        ("alternate select",     ["com.apple.coregraphics.ArrowCtx",
                                  "com.apple.cursor.24"]),
        ("Text Select",          ["com.apple.coregraphics.IBeam",
                                  "com.apple.coregraphics.IBeamS",
                                  // Terminal.app, iTerm2 and other text editors
                                  // ask for the horizontal variant, not `IBeam`.
                                  // Without this the shell prompt keeps the
                                  // stock beam while app text fields are themed.
                                  "com.apple.coregraphics.IBeamH",
                                  "com.apple.cursor.1",
                                  "com.apple.cursor.26"]),
        ("Link",                 ["com.apple.coregraphics.Alias",
                                  "com.apple.coregraphics.PointingHand",
                                  "com.apple.cursor.2",
                                  "com.apple.cursor.13"]),
        ("Person Select",        ["com.apple.coregraphics.PointingHand",
                                  "com.apple.cursor.13"]),
        ("Busy",                 ["com.apple.coregraphics.Wait",
                                  "com.apple.cursor.4"]),
        ("Work",                 ["com.apple.coregraphics.Wait"]),
        ("Location Select",      ["com.apple.coregraphics.Cell",
                                  "com.apple.cursor.41"]),
        ("Precision Select",     ["com.apple.coregraphics.Cell"]),
        ("Unavailable",          ["com.apple.coregraphics.NotAllowed",
                                  "com.apple.cursor.3"]),
        ("Help Select",          ["com.apple.coregraphics.Help",
                                  "com.apple.cursor.40"]),
        ("Move",                 ["com.apple.coregraphics.Move",
                                  "com.apple.cursor.39"]),
        ("Vertical Resize",      ["com.apple.coregraphics.ResizeUpDown",
                                  "com.apple.cursor.23"]),
        ("Horizontal Resize",    ["com.apple.coregraphics.ResizeLeftRight",
                                  "com.apple.cursor.19"]),
        ("Diagonal Resize 1",    ["com.apple.coregraphics.WindowResizeNorthEastSouthWest",
                                  "com.apple.coregraphics.WindowResizeNorthWestSouthEast",
                                  "com.apple.cursor.30",
                                  "com.apple.cursor.34"]),
        ("Diagonal Resize 2",    ["com.apple.coregraphics.WindowResizeNorthWestSouthEast",
                                  "com.apple.coregraphics.WindowResizeNorthEastSouthWest",
                                  "com.apple.cursor.34",
                                  "com.apple.cursor.30"]),
    ]

    /// `handwriting.ani` is intentionally absent: macOS has no pen/handwriting
    /// cursor slot at all (no equivalent of Windows' tablet-PC mode), so
    /// registering it would be a no-op. It is also not copied into Resources.

    private static let resourceDirectory = "Cursors"

    // MARK: - State

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Cursor.Theme"
    )

    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []
    private var isApplied = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // No `deinit`: observer tokens are main-actor isolated and the app
    // delegate always calls `stop()` on terminate, which removes them.

    // MARK: - Lifecycle

    /// Starts observing sleep/wake and applies the theme if the setting allows.
    public func start() {
        installObservers()

        guard WidgetSettings.isCursorThemeEnabled(in: defaults) else {
            health = .off
            return
        }
        guard CGSCursorBridge.isAvailable else {
            Self.logger.error("Private cursor API unavailable; theme cannot be applied")
            health = .apiUnavailable
            return
        }

        // Applied synchronously on the main actor, on the same call stack as
        // `applicationDidFinishLaunching`. An earlier version deferred this into
        // a `Task`, and the registration then returned success without ever
        // taking effect — the CGS connection obtained from that async context
        // appears not to be the one the window server paints from.
        apply()
    }

    /// Stops observing, restores the system cursors and drops all registrations.
    public func stop() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()

        if isApplied {
            CGSCursorBridge.unregisterAll()
            CGSCursorBridge.instantiateSystemCursors()
            CGSCursorBridge.reload(dockOverride: false)
            isApplied = false
            Self.logger.info("Restored system cursors")
        }
        health = .off
    }

    /// Re-reads the enable flag. Called when the user flips the menu toggle.
    public func settingDidChange() {
        if WidgetSettings.isCursorThemeEnabled(in: defaults) {
            if case .active = health { return }
            start()
        } else {
            stop()
        }
    }

    // MARK: - Application

    private func apply() {
        guard CGSCursorBridge.isAvailable else {
            health = .apiUnavailable
            return
        }
        guard let directory = Self.cursorResourceDirectory() else {
            Self.logger.error("Cursors directory missing from the app bundle")
            health = .resourcesMissing
            return
        }

        var applied = 0
        var lastFailure: String?

        // Diagnostic escape hatch: VITALS_CURSOR_LIMIT=N applies only the first
        // N catalog entries, so the batch size can be bisected from the command
        // line without a rebuild. Unset (or 0) means the full theme.
        let limit = Int(ProcessInfo.processInfo.environment["VITALS_CURSOR_LIMIT"] ?? "")
            .flatMap { $0 > 0 ? $0 : nil }
        let entries = limit.map { Array(Self.catalog.prefix($0)) } ?? Self.catalog
        Self.logger.info("Applying \(entries.count) of \(Self.catalog.count) cursor source file(s)")

        // Parse and flatten everything *before* touching the window server. A
        // malformed asset must never leave the user with no cursor at all.
        var pending: [(entry: (file: String, identifiers: [String]),
                            parsed: ANIThemeLoader.ParsedTheme,
                            strip: Strip)] = []
        for entry in entries {
            let url = directory.appendingPathComponent("\(entry.file).ani")
            guard let parsed = try? ANIThemeLoader.load(url: url) else {
                Self.logger.error("Failed to parse \(entry.file, privacy: .public).ani")
                lastFailure = "解析失败: \(entry.file)"
                continue
            }
            guard let strip = Self.makeStrip(from: parsed) else {
                Self.logger.error("Failed to flatten frames for \(entry.file, privacy: .public)")
                lastFailure = "帧转换失败: \(entry.file)"
                continue
            }
            pending.append((entry, parsed, strip))
        }

        guard !pending.isEmpty else {
            CGSCursorBridge.unregisterAll()
            CGSCursorBridge.instantiateSystemCursors()
            CGSCursorBridge.reload(dockOverride: false)
            health = .resourcesMissing
            Self.logger.error("No cursor could be prepared; system defaults restored")
            return
        }

        CGSCursorBridge.unregisterAll()
        CGSCursorBridge.instantiateSystemCursors()

        var appliedFiles = 0
        Self.logger.info("Cleared system cursors; registering \(pending.count) source file(s)")
        for item in pending {
            let hotspot = item.parsed.frames.first?.hotSpot ?? .zero
            Self.logger.info("  \(item.entry.file, privacy: .public): strip \(item.strip.image.width)x\(item.strip.image.height), \(item.strip.frameCount) frames, duration \(item.strip.frameDuration), hotspot (\(hotspot.x), \(hotspot.y))")
            var entrySucceeded = false
            for identifier in item.entry.identifiers {
                let registration = CGSCursorBridge.Registration(
                    identifier: identifier,
                    size: CGSize(width: item.parsed.pointsWide, height: item.parsed.pointsHigh),
                    hotSpot: item.parsed.frames.first?.hotSpot ?? .zero,
                    frameCount: UInt(item.strip.frameCount),
                    frameDuration: item.strip.frameDuration,
                    images: [item.strip.image]
                )
                if CGSCursorBridge.register(registration) {
                    entrySucceeded = true
                    applied += 1
                } else {
                    lastFailure = "注册失败: \(identifier)"
                }
            }
            if entrySucceeded {
                appliedFiles += 1
            } else {
                Self.logger.error("No identifier accepted for \(item.entry.file, privacy: .public)")
            }
        }

        // Roll back rather than leave a half-applied theme: an unregistered
        // slot repaints as blank, which is what makes the pointer disappear.
        guard applied > 0 else {
            CGSCursorBridge.unregisterAll()
            CGSCursorBridge.instantiateSystemCursors()
            CGSCursorBridge.reload(dockOverride: false)
            health = .registrationFailed(reason: lastFailure ?? "全部注册失败")
            Self.logger.error("All registrations failed; system defaults restored")
            return
        }

        CGSCursorBridge.reload(dockOverride: true)
        isApplied = true
        if let lastFailure {
            health = .registrationFailed(reason: lastFailure)
        } else {
            // Both counters are in files, not identifiers: one .ani can feed
            // several macOS slots, so "40/16 identifiers" would be nonsense.
            health = .active(applied: appliedFiles, total: pending.count)
        }
        Self.logger.info("Applied \(applied) cursor registration(s) for \(Self.catalog.count) source file(s)")
    }

    // MARK: - Frame flattening

    /// A registration-ready frame strip plus the uniform duration CGS accepts.
    private struct Strip {
        let image: CGImage
        let frameCount: Int
        let frameDuration: CGFloat
    }

    /// CGS wants one vertical strip (`height == width * frameCount`) and a single
    /// duration for every frame, so the loader's per-step timings collapse to
    /// their mean and the frames are stacked bottom-up (CG y-axis).
    private static func makeStrip(from parsed: ANIThemeLoader.ParsedTheme) -> Strip? {
        let frames = parsed.frames
        guard !frames.isEmpty, let template = frames.first?.image else { return nil }

        let width = template.width
        let height = template.height
        let count = min(frames.count, ANIThemeLoader.maximumFrameCount)
        guard width > 0, height > 0, count > 0 else { return nil }

        let duration = parsed.frameDurations.isEmpty
            ? 0.1
            : parsed.frameDurations.prefix(count).reduce(0, +)
                / CGFloat(min(parsed.frameDurations.count, count))

        let stripHeight = height * count
        guard let context = CGContext(
            data: nil,
            width: width,
            height: stripHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: width, height: stripHeight))
        for (index, frame) in frames.prefix(count).enumerated() {
            // CG y 向上,第 0 帧在底部。
            //
            // ⚠️ 实测坑位(踩过,勿回退):y 必须乘以 `height`。漏掉这个乘号时,
            // 24 帧全部叠在长条图最底部的 24 个像素里,上面的 744 行保持透明,
            // 注册照样返回成功、光标却几乎不可见(只有第 0 帧有像素,表现为
            // "偶尔闪一下")。cursor-probe 的 `ANI.frameStrip` 就是这个写法。
            let originY = (count - 1 - index) * height
            context.draw(frame.image,
                         in: CGRect(x: 0, y: originY, width: width, height: height))
        }

        guard let image = context.makeImage() else { return nil }
        return Strip(image: image, frameCount: count, frameDuration: duration)
    }

    // MARK: - Resources

    /// Resolves the directory holding the user's `.ani` themes.
    ///
    /// These live in Application Support, **not** inside the app bundle. The
    /// files carry `com.apple.provenance` (macOS tags anything downloaded from
    /// the web), that attribute cannot be removed, and codesign rejects any
    /// bundle containing such a file — so shipping them in `Contents/Resources`
    /// would make the app unsignable. See the `cursors` target in the Makefile.
    private static func cursorResourceDirectory() -> URL? {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Vitals", isDirectory: true)
            .appendingPathComponent(resourceDirectory, isDirectory: true)

        guard let base else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return base
    }

    // MARK: - Notifications

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Waking restores the cursor server's state and can drop registrations.
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyAfterWake() }
        })
    }

    private func reapplyAfterWake() {
        guard WidgetSettings.isCursorThemeEnabled(in: defaults), CGSCursorBridge.isAvailable else { return }
        Self.logger.info("System woke; re-applying cursor theme")
        // Synchronous for the same reason as `start()`: registration from a
        // detached `Task` returns success but never paints.
        apply()
    }
}