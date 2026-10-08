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

import CoreGraphics
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

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Cursor.CGS"
    )

    /// Cursor registration mutates global window-server state, so callers coming
    /// from timer or background threads are serialized here.
    private static let lock = NSLock()

    /// Resolved once per process, lazily. `nil` means a symbol is missing.
    ///
    /// Deliberately **not** a `static let`: a `static let` initialiser runs
    /// inside `dispatch_once`, and `dlsym` can re-enter libdispatch, which
    /// aborts the process with "trying to lock recursively" (observed on
    /// macOS 26.6.2 at launch). This hand-rolled one-shot cache does the
    /// lookup under `lock` instead, which is re-entrancy safe.
    private static var cachedSymbols: Symbols?
    private static var didResolveSymbols = false

    private static func resolvedSymbols() -> Symbols? {
        lock.lock()
        defer { lock.unlock() }
        if didResolveSymbols { return cachedSymbols }
        didResolveSymbols = true
        guard let mainConnectionID = resolve("CGSMainConnectionID", as: CGSMainConnectionIDFn.self),
              let register = resolve("CGSRegisterCursorWithImages", as: CGSRegisterCursorWithImagesFn.self),
              let setRegistered = resolve("CGSSetRegisteredCursor", as: CGSSetRegisteredCursorFn.self),
              let unregister = resolve("CoreCursorUnregisterAll", as: CoreCursorUnregisterAllFn.self),
              let setCore = resolve("CoreCursorSet", as: CoreCursorSetFn.self),
              let setSystemDefined = resolve("CGSSetSystemDefinedCursor", as: CGSSetSystemDefinedCursorFn.self),
              let setDockOverride = resolve("CGSSetDockCursorOverride", as: CGSSetDockCursorOverrideFn.self),
              let getScale = resolve("CGSGetCursorScale", as: CGSGetCursorScaleFn.self),
              let setScale = resolve("CGSSetCursorScale", as: CGSSetCursorScaleFn.self)
        else {
            logger.warning("Private CGS cursor symbols are unavailable on this macOS build; cursor theming disabled")
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
        // Resolve symbols before taking the lock: `resolvedSymbols()` acquires
        // `lock` itself, so the re-entrant call would deadlock.
        guard let symbols = resolvedSymbols(), r.frameCount >= 1, !r.images.isEmpty else {
            logger.error("Refusing to register \(r.identifier, privacy: .public): missing symbols or empty frames")
            return false
        }
        lock.lock()
        defer { lock.unlock() }
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
        // See `register`: never touch `symbols` while holding `lock`.
        guard let symbols = resolvedSymbols() else { return }
        lock.lock()
        defer { lock.unlock() }
        activate(identifier: identifier, symbols: symbols)
    }

    /// Drop every custom cursor registered by this process.
    public static func unregisterAll() {
        guard let symbols = resolvedSymbols() else { return }
        lock.lock()
        defer { lock.unlock() }
        let error = symbols.unregisterAll(symbols.mainConnectionID())
        if error != cgSuccess {
            logger.error("CoreCursorUnregisterAll failed, error \(error)")
        } else {
            logger.info("Unregistered all custom cursors")
        }
    }

    /// Re-instantiate the built-in cursor slots `0...43`.
    /// Required after `unregisterAll()` for the system cursors to come back.
    public static func instantiateSystemCursors() {
        guard let symbols = resolvedSymbols() else { return }
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        let connection = symbols.mainConnectionID()
        guard connection != 0 else {
            logger.error("CGSMainConnectionID returned 0; skipping cursor reload")
            return
        }

        var live: Float = 1
        guard symbols.getCursorScale(connection, &live) == cgSuccess else {
            logger.error("CGSGetCursorScale failed; skipping cursor reload")
            return
        }
        let bump = live + 0.01
        guard symbols.setCursorScale(connection, bump) == cgSuccess,
              symbols.setCursorScale(connection, live) == cgSuccess else {
            logger.error("Scale nudge failed; cursors may not repaint")
            return
        }

        _ = symbols.setDockCursorOverride(connection, dockOverride)
        // Explicitly select the arrow so a stale active cursor cannot survive.
        _ = symbols.setSystemDefinedCursor(connection, 0)
        logger.info("Reloaded cursors (scale \(live) → \(bump) → \(live), dockOverride: \(dockOverride))")
    }

    // MARK: - Internals

    /// Callers already hold `lock`.
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

    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        guard let handle = defaultHandle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}