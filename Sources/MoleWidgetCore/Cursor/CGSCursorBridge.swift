//
//  CGSCursorBridge.swift
//  Mio
//
//  Typed wrapper over the private CoreGraphics/SkyLight cursor symbols.
//
//  These functions (`CGSRegisterCursorWithImages`, `CoreCursorSet`, …) are not
//  part of the public SDK, so they are resolved with `dlsym` at runtime instead
//  of being linked. A macOS update can rename, re-sign or remove any of them;
//  `isAvailable` reports that state and every entry point degrades to a no-op
//  (or `false`) when the symbols are missing. Treat every call as best effort.
//
//  ── 回滚保证(改这块代码前必读)──
//
//  这个模块替换的是整个系统的鼠标指针,最坏的故障是"注册成功但回滚失败",
//  指针停在服务端缓存里的旧图案上,鼠标点不动任何界面。
//  因此 `reload()` 把 `CGSSetSystemDefinedCursor(conn, 0)` 注册成 `defer`,
//  在任何 early `return` 之前,让**每一条**退出路径(含错误分支)都会执行它。
//  详见 `reload` 里的说明。新增退出路径不需要手动补收尾。
//

import CoreGraphics
import Darwin
import Foundation
import OSLog

/// Runtime bridge to the private cursor API used to install custom cursors.
public enum CGSCursorBridge {
    /// Parameters for a single cursor registration.
    public struct Registration {
        /// CoreGraphics cursor name, e.g. `com.apple.coregraphics.Arrow`.
        public var identifier: String
        /// Cursor size in **points**, not pixels.
        public var size: CGSize
        /// Hot spot in **points**, measured from the top-left of the image.
        public var hotSpot: CGPoint
        /// Number of animation frames.
        public var frameCount: UInt
        /// Seconds each frame is displayed for.
        public var frameDuration: CGFloat
        /// One vertical strip per cursor: `height == width * frameCount`.
        public var images: [CGImage]

        public init(identifier: String, size: CGSize, hotSpot: CGPoint,
                    frameCount: UInt, frameDuration: CGFloat, images: [CGImage]) {
            self.identifier = identifier
            self.size = size
            self.hotSpot = hotSpot
            self.frameCount = frameCount
            self.frameDuration = frameDuration
            self.images = images
        }
    }

    // MARK: - Private symbols

    // `CGSConnectionID` is `int`, `CGError` is `int32_t`.
    private typealias CGSMainConnectionIDFn = @convention(c) () -> Int32
    private typealias CGSRegisterCursorWithImagesFn = @convention(c) (
        Int32, UnsafeMutablePointer<CChar>, Bool, Bool, CGSize, CGPoint,
        UInt, CGFloat, CFArray, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias CGSSetRegisteredCursorFn = @convention(c) (
        Int32, UnsafeMutablePointer<CChar>, UnsafeMutablePointer<Int32>
    ) -> Int32
    private typealias CoreCursorUnregisterAllFn = @convention(c) (Int32) -> Int32
    private typealias CoreCursorSetFn = @convention(c) (Int32, Int32) -> Int32
    private typealias CGSSetSystemDefinedCursorFn = @convention(c) (Int32, Int32) -> Int32
    private typealias CGSSetDockCursorOverrideFn = @convention(c) (Int32, Bool) -> Int32
    private typealias CGSGetCursorScaleFn = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private typealias CGSSetCursorScaleFn = @convention(c) (Int32, Float) -> Int32

    private struct Symbols {
        let mainConnectionID: CGSMainConnectionIDFn
        let registerCursorWithImages: CGSRegisterCursorWithImagesFn
        let setRegisteredCursor: CGSSetRegisteredCursorFn
        let unregisterAll: CoreCursorUnregisterAllFn
        let setCoreCursor: CoreCursorSetFn
        let setSystemDefinedCursor: CGSSetSystemDefinedCursorFn
        let setDockCursorOverride: CGSSetDockCursorOverrideFn
        let getCursorScale: CGSGetCursorScaleFn
        let setCursorScale: CGSSetCursorScaleFn
    }

    /// The image that owns each private symbol, verified with `dladdr`.
    ///
    /// Recorded on macOS 26.6.2: seven of the nine symbols live in SkyLight,
    /// while `CoreCursorUnregisterAll` and `CoreCursorSet` live in the
    /// HIServices framework nested inside ApplicationServices — *not* in
    /// SkyLight. Both paths are checked in, so a macOS update that relocates
    /// one of them shows up as a logged refusal rather than a call into a
    /// wrongly-signed function of the same name.
    private enum SymbolImage: String, CaseIterable {
        case skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        case hiServices = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"

        /// The `dlopen` path has no version component, but `dladdr` reports the
        /// version-resolved one (`…/SkyLight.framework/Versions/A/SkyLight`).
        /// Both sides are reduced to `<…>.framework/<binary>` before comparing.
        var canonicalPath: String { SymbolImage.canonicalize(rawValue) }

        static func canonicalize(_ path: String) -> String {
            let parts = path.split(separator: "/").map(String.init)
            let filtered = parts.filter { $0 != "Versions" && $0.count > 1 }
            return filtered.joined(separator: "/")
        }
    }

    /// `CGError.success` is 0; anything else is a failure.
    private static let cgSuccess: Int32 = 0
    /// Synthetic error for an argument that failed to materialise (never happens in practice).
    private static let cgInvalidArgument: Int32 = -1
    /// Highest built-in cursor slot, instantiated on restore.
    /// Slot 6 is absent from the CoreGraphics table — the numbering skips it —
    /// so the valid range is 0...43 with a hole, not 0...42.
    private static let maxCoreCursorID = 43
    /// -2 is `RTLD_DEFAULT`, i.e. search every image loaded in the process.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
    /// How often `unregisterAll` retries before reporting a failed rollback.
    private static let unregisterAttempts = 3

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Cursor.CGS"
    )

    /// Guards the one-shot symbol cache and **nothing else**.
    ///
    /// It deliberately does not cover a WindowServer call. Holding a lock
    /// across `CGS*` means two things go wrong at once: a background caller
    /// can block the main thread inside `lock()`, and the CGS call itself can
    /// block for as long as the window server takes to answer. Serialisation
    /// of the window-server mutations comes from main-thread confinement
    /// instead — see `requireMainThread(_:)` — because every caller in this
    /// target is main-actor isolated.
    private static let symbolsLock = NSLock()

    /// Resolved once per process, lazily. `nil` means a symbol is missing.
    ///
    /// Deliberately **not** a `static let`: a `static let` initialiser runs
    /// inside `dispatch_once`, and `dlsym` can re-enter libdispatch, which
    /// aborts the process with "trying to lock recursively" (observed on
    /// macOS 26.6.2 at launch). This hand-rolled one-shot cache does the
    /// lookup under `symbolsLock` instead, which is re-entrancy safe.
    private static var cachedSymbols: Symbols?
    private static var didResolveSymbols = false

    private static func resolvedSymbols() -> Symbols? {
        symbolsLock.lock()
        defer { symbolsLock.unlock() }
        if didResolveSymbols { return cachedSymbols }
        didResolveSymbols = true
        guard let mainConnectionID = resolve("CGSMainConnectionID", in: .skyLight, as: CGSMainConnectionIDFn.self),
              let register = resolve("CGSRegisterCursorWithImages", in: .skyLight, as: CGSRegisterCursorWithImagesFn.self),
              let setRegistered = resolve("CGSSetRegisteredCursor", in: .skyLight, as: CGSSetRegisteredCursorFn.self),
              let unregister = resolve("CoreCursorUnregisterAll", in: .hiServices, as: CoreCursorUnregisterAllFn.self),
              let setCore = resolve("CoreCursorSet", in: .hiServices, as: CoreCursorSetFn.self),
              let setSystemDefined = resolve("CGSSetSystemDefinedCursor", in: .skyLight, as: CGSSetSystemDefinedCursorFn.self),
              let setDockOverride = resolve("CGSSetDockCursorOverride", in: .skyLight, as: CGSSetDockCursorOverrideFn.self),
              let getScale = resolve("CGSGetCursorScale", in: .skyLight, as: CGSGetCursorScaleFn.self),
              let setScale = resolve("CGSSetCursorScale", in: .skyLight, as: CGSSetCursorScaleFn.self)
        else {
            logger.warning("Private CGS cursor symbols are unavailable or untrusted on this macOS build; cursor theming disabled")
            return nil
        }
        cachedSymbols = Symbols(mainConnectionID: mainConnectionID,
                                registerCursorWithImages: register,
                                setRegisteredCursor: setRegistered,
                                unregisterAll: unregister,
                                setCoreCursor: setCore,
                                setSystemDefinedCursor: setSystemDefined,
                                setDockCursorOverride: setDockOverride,
                                getCursorScale: getScale,
                                setCursorScale: setScale)
        return cachedSymbols
    }

    /// Whether every private symbol this bridge needs was resolved.
    public static var isAvailable: Bool { resolvedSymbols() != nil }

    // MARK: - Public API

    /// Register a cursor and make it active.
    /// - Returns: `true` when registration itself succeeded. Activation is best effort.
    @discardableResult
    public static func register(_ r: Registration) -> Bool {
        // Resolve symbols first: `resolvedSymbols()` takes `symbolsLock`
        // itself, and holding it across a WindowServer call is what this
        // module must never do.
        guard let symbols = resolvedSymbols(), r.frameCount >= 1, !r.images.isEmpty else {
            logger.error("Refusing to register \(r.identifier, privacy: .public): missing symbols or empty frames")
            return false
        }
        requireMainThread("register")
        var name = Array(r.identifier.utf8CString)
        var seed: Int32 = 0
        let error: Int32 = name.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return cgInvalidArgument }
            return symbols.registerCursorWithImages(symbols.mainConnectionID(), base,
                                                   true, true, r.size, r.hotSpot, r.frameCount,
                                                   r.frameDuration, r.images as CFArray, &seed)
        }
        guard error == cgSuccess else {
            logger.error("CGSRegisterCursorWithImages failed for \(r.identifier, privacy: .public), error \(error)")
            return false
        }
        logger.info("Registered \(r.identifier, privacy: .public) with \(r.frameCount) frame(s)")
        activate(identifier: r.identifier, symbols: symbols)
        return true
    }

    /// Make an already registered cursor effective immediately.
    public static func activate(identifier: String) {
        // See `register`: never touch `symbols` while holding a lock.
        guard let symbols = resolvedSymbols() else { return }
        requireMainThread("activate")
        activate(identifier: identifier, symbols: symbols)
    }

    /// Drop every custom cursor registered by this process.
    ///
    /// - Returns: `true` when the window server confirmed the drop (or when
    ///   there was nothing to drop). `false` means the rollback did **not**
    ///   complete and the caller should say so rather than assume the system
    ///   cursor is back.
    @discardableResult
    public static func unregisterAll() -> Bool {
        guard let symbols = resolvedSymbols() else {
            // Registration needs the same symbols, so with them missing this
            // process never registered anything — there is nothing to undo.
            return true
        }
        requireMainThread("unregisterAll")

        var lastError = cgSuccess
        for attempt in 1...unregisterAttempts {
            let error = symbols.unregisterAll(symbols.mainConnectionID())
            if error == cgSuccess {
                logger.info("Unregistered all custom cursors (attempt \(attempt)/\(unregisterAttempts))")
                return true
            }
            lastError = error
            logger.error("CoreCursorUnregisterAll failed (attempt \(attempt)/\(unregisterAttempts)), error \(error)")
        }
        logger.error("CoreCursorUnregisterAll still failing after \(unregisterAttempts) attempts, last error \(lastError); rollback is incomplete")
        return false
    }

    /// Re-instantiate the built-in cursor slots `0...43`.
    /// Required after `unregisterAll()` for the system cursors to come back.
    public static func instantiateSystemCursors() {
        guard let symbols = resolvedSymbols() else { return }
        requireMainThread("instantiateSystemCursors")
        let connection = symbols.mainConnectionID()
        guard connection != 0 else {
            logger.error("CGSMainConnectionID returned 0; cannot instantiate system cursors")
            return
        }
        for index in 0...maxCoreCursorID {
            _ = symbols.setCoreCursor(connection, Int32(index))
        }
        logger.info("Instantiated system cursor slots 0...\(maxCoreCursorID)")
    }

    // MARK: - Reload

    /// Force the window server to re-read every cursor slot.
    ///
    /// `unregisterAll()` + `instantiateSystemCursors()` alone is **not enough**:
    /// the server keeps painting whatever it had cached, which after a failed
    /// apply means a stale image over freed memory — the pointer goes blank.
    /// Nudging the cursor scale up and straight back down is the documented
    /// trick (Mousecape/MaCursor both rely on it); the round-trip is what
    /// triggers the redraw.
    ///
    /// - Parameter dockOverride: whether custom cursors should also apply to the
    ///   Dock. Pass `false` when restoring system defaults.
    public static func reload(dockOverride: Bool) {
        guard let symbols = resolvedSymbols() else { return }
        requireMainThread("reload")

        let connection = symbols.mainConnectionID()

        // ── 收尾保证 ──────────────────────────────────────────────────────
        // `CGSSetSystemDefinedCursor(conn, 0)` 选中系统箭头,是唯一能清掉服务端
        // 光标缓存的调用,也就是"回滚失败时鼠标能回来"的那一步。它注册成
        // `defer` 而不是写在每个 return 后面:下面每一个 early return / 错误
        // 分支都会先执行它。以后新增退出路径也不可能漏掉收尾。
        defer { selectSystemArrow(symbols: symbols, connection: connection) }

        guard connection != 0 else {
            logger.error("CGSMainConnectionID returned 0; skipping cursor reload")
            return
        }

        // 读缩放只是拿"扰动基准值",读不到不是理由退出——dock override 和箭头
        // 收尾仍然必须跑完,所以退回到默认 1.0 继续。
        var live: Float = 1
        if symbols.getCursorScale(connection, &live) != cgSuccess {
            logger.error("CGSGetCursorScale failed; nudging around the default scale instead")
            live = 1
        } else if live <= 0 {
            logger.error("CGSGetCursorScale returned \(live); nudging around the default scale instead")
            live = 1
        }

        // 两次写入都无条件尝试:写成 `a && b` 会在第一次失败后短路,缩放就永远
        // 停在被抬高的值上,光标一直画不出来。
        let bumped = symbols.setCursorScale(connection, live + 0.01) == cgSuccess
        let restored = symbols.setCursorScale(connection, live) == cgSuccess
        if !bumped || !restored {
            logger.error("Scale nudge failed (bump: \(bumped), restore: \(restored)); cursors may not repaint")
        }

        let dockError = symbols.setDockCursorOverride(connection, dockOverride)
        if dockError != cgSuccess {
            logger.error("CGSSetDockCursorOverride failed (dockOverride: \(dockOverride)), error \(dockError)")
        }
        logger.info("Reloaded cursors (scale \(live) → \(live + 0.01) → \(live), dockOverride: \(dockOverride))")
    }

    // MARK: - Internals

    /// The tail every `reload` exit path runs.
    ///
    /// A zero connection id means `CGSMainConnectionID` never worked in this
    /// process, so nothing was ever registered by us and there is no stale
    /// slot to clear — there is no address to call it with.
    private static func selectSystemArrow(symbols: Symbols, connection: Int32) {
        guard connection != 0 else { return }
        let error = symbols.setSystemDefinedCursor(connection, 0)
        if error != cgSuccess {
            logger.error("CGSSetSystemDefinedCursor failed, error \(error); the server may keep a stale cursor")
        }
    }

    /// Every window-server mutation must happen on the main thread.
    ///
    /// Two independent reasons, both verified on macOS 26.6.2:
    /// 1. Registration issued from an async context returns success but the
    ///    window server never paints it (see `CursorThemeService.start`).
    /// 2. The main thread is the only serialisation point. A lock cannot play
    ///    that role, because the CGS calls can block for an unbounded time
    ///    and a lock held across them lets a background caller freeze the UI.
    ///
    /// A violation is logged, never trapped: trapping inside
    /// `applicationWillTerminate` would abort the rollback and leave the
    /// custom pointer on screen — the one failure mode this module must not
    /// produce.
    private static func requireMainThread(_ operation: String) {
        guard Thread.isMainThread else {
            logger.error("\(operation, privacy: .public) was called off the main thread; window-server state may race")
            return
        }
    }

    private static func activate(identifier: String, symbols: Symbols) {
        var name = Array(identifier.utf8CString)
        var seed: Int32 = 0
        let error: Int32 = name.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return cgInvalidArgument }
            return symbols.setRegisteredCursor(symbols.mainConnectionID(), base, &seed)
        }
        if error != cgSuccess {
            logger.error("CGSSetRegisteredCursor failed for \(identifier, privacy: .public), error \(error)")
        }
    }

    /// Resolve one private symbol, refusing anything not owned by `image`.
    ///
    /// `RTLD_DEFAULT` alone is not safe here: it searches every image loaded in
    /// the process, and a same-named symbol exported by a differently signed
    /// library would be `unsafeBitCast` straight into the wrong
    /// `@convention(c)` type and crash inside the window server. The lookup is
    /// therefore scoped to the owning image, and the result is verified with
    /// `dladdr` before it is cast — an unrecognised owner is treated exactly
    /// like a missing symbol, so the whole bridge degrades to no-ops instead of
    /// calling a function it cannot vouch for.
    private static func resolve<T>(_ name: String, in image: SymbolImage, as _: T.Type) -> T? {
        guard let handle = dlopen(image.rawValue, RTLD_LAZY | RTLD_LOCAL) else {
            logger.error("Cannot dlopen \(image.rawValue, privacy: .public) while resolving \(name, privacy: .public)")
            return nil
        }
        // Scoped handle first; `RTLD_DEFAULT` is only a fallback for images
        // that are already loaded under a slightly different path. Either way
        // the `dladdr` check below still decides.
        guard let pointer = dlsym(handle, name) ?? dlsym(defaultHandle, name) else {
            logger.error("Symbol \(name, privacy: .public) is missing")
            return nil
        }

        var info = Dl_info()
        guard dladdr(pointer, &info) != 0, let owner = info.dli_fname else {
            logger.error("Cannot determine the owning image of \(name, privacy: .public); refusing to call it")
            return nil
        }
        let ownerPath = SymbolImage.canonicalize(String(cString: owner))
        guard ownerPath == image.canonicalPath else {
            logger.error("Symbol \(name, privacy: .public) resolved from \(ownerPath, privacy: .public), expected \(image.canonicalPath, privacy: .public); refusing to call it")
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
