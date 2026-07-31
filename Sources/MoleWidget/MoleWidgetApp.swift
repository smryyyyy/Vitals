import AppKit
import MoleWidgetCore
import ServiceManagement
import SwiftUI

@main
struct MoleWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(WidgetSettings.positionLockedKey) private var positionLocked = false
    @AppStorage(WidgetSettings.widgetVisibleKey) private var widgetVisible = true

    // Settings: opacity
    // NOTE: write only via the Picker binding — the tags are exact Double
    // literals; arithmetic writes would break Picker selection matching.
    @AppStorage(WidgetSettings.backgroundOpacityKey)
    private var backgroundOpacity = WidgetSettings.defaultOpacity

    // Settings: refresh rate
    @AppStorage(WidgetSettings.refreshIntervalKey)
    private var refreshInterval = WidgetSettings.defaultRefreshInterval

    // Settings: font
    // NOTE: font-size tags are exact Double literals — same Picker matching
    // constraint as opacity above.
    @AppStorage(WidgetSettings.fontSizeKey)
    private var fontSize = WidgetSettings.defaultFontSize
    @AppStorage(WidgetSettings.fontStyleKey)
    private var fontStyle = WidgetSettings.defaultFontStyle.rawValue

    // Settings: menu bar metrics
    @AppStorage(WidgetSettings.menuBarShowCPUKey)     private var menuBarShowCPU     = WidgetSettings.defaultMenuBarShowCPU
    @AppStorage(WidgetSettings.menuBarShowMemoryKey)  private var menuBarShowMemory  = WidgetSettings.defaultMenuBarShowMemory
    @AppStorage(WidgetSettings.menuBarShowTempKey)    private var menuBarShowTemp    = WidgetSettings.defaultMenuBarShowTemp
    @AppStorage(WidgetSettings.menuBarShowNetworkKey) private var menuBarShowNetwork = WidgetSettings.defaultMenuBarShowNetwork
    @AppStorage(WidgetSettings.menuBarShowDiskKey)    private var menuBarShowDisk    = WidgetSettings.defaultMenuBarShowDisk
    @AppStorage(WidgetSettings.menuBarShowMinimax5hKey) private var menuBarShowMinimax5h = false
    @AppStorage(WidgetSettings.menuBarShowMinimaxWeeklyKey) private var menuBarShowMinimaxWeekly = false

    // Settings: section visibility
    @AppStorage(WidgetSettings.showHeaderKey)    private var showHeader    = true
    @AppStorage(WidgetSettings.showCPUKey)       private var showCPU       = true
    @AppStorage(WidgetSettings.showMemoryKey)    private var showMemory    = true
    @AppStorage(WidgetSettings.showDiskKey)      private var showDisk      = true
    @AppStorage(WidgetSettings.showPowerKey)     private var showPower     = true
    @AppStorage(WidgetSettings.showNetworkKey)   private var showNetwork   = true
    @AppStorage(WidgetSettings.showProcessesKey) private var showProcesses = true
    @AppStorage(WidgetSettings.showMinimaxKey)   private var showMinimax   = true

    /// Monochrome template glyph echoing the app icon: four bars of varying
    /// length. Template images get tinted by macOS for light/dark menu bars.
    private static let menuBarIcon: NSImage = {
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            let barHeight: CGFloat = 2.6
            let gap: CGFloat = 1.1
            // Bar lengths mirror the app icon proportions (560/360/470/220)
            let widths: [CGFloat] = [14, 9, 11.8, 5.5]
            var y: CGFloat = size.height - barHeight - 0.6
            for width in widths {
                let bar = NSRect(x: 2, y: y, width: width, height: barHeight)
                NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                y -= barHeight + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            Divider()
            Button("MiniMax 设置…") {
                appDelegate.openMinimaxSettings()
            }
            Toggle("锁定位置", isOn: $positionLocked)
            Toggle("显示在桌面", isOn: $widgetVisible)
            LaunchAtLoginToggle()
            Menu("设置") {
                if #unavailable(macOS 26) {
                    Picker("Opacity", selection: $backgroundOpacity) {
                        Text("100%").tag(1.0)
                        Text("92%").tag(0.92)
                        Text("85%").tag(0.85)
                        Text("70%").tag(0.7)
                    }
                }
                Picker("刷新率", selection: $refreshInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                }
                Picker("字体大小", selection: $fontSize) {
                    Text("小").tag(11.0)
                    Text("中").tag(12.0)
                    Text("大").tag(14.0)
                    Text("超大").tag(16.0)
                }
                Picker("字体样式", selection: $fontStyle) {
                    Text("等宽").tag(WidgetSettings.FontStyle.monospaced.rawValue)
                    Text("系统").tag(WidgetSettings.FontStyle.system.rawValue)
                }
                Menu("菜单栏指标") {
                    Toggle("CPU",     isOn: $menuBarShowCPU)
                    Toggle("内存",  isOn: $menuBarShowMemory)
                    Toggle("CPU 温度", isOn: $menuBarShowTemp)
                    Toggle("网络", isOn: $menuBarShowNetwork)
                    Toggle("磁盘",    isOn: $menuBarShowDisk)
                    Toggle("MiniMax 5h", isOn: $menuBarShowMinimax5h)
                    Toggle("MiniMax 周", isOn: $menuBarShowMinimaxWeekly)
                }
                Menu("模块") {
                    Toggle("顶部",    isOn: $showHeader)
                    Toggle("CPU",       isOn: $showCPU)
                    Toggle("内存",    isOn: $showMemory)
                    Toggle("磁盘",      isOn: $showDisk)
                    Toggle("电源",     isOn: $showPower)
                    Toggle("网络",   isOn: $showNetwork)
                    Toggle("进程", isOn: $showProcesses)
                    Toggle("MiniMax", isOn: $showMinimax)
                }
            }
            Divider()
            Button("退出 Vitals") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarLabel(store: appDelegate.store, minimaxManager: appDelegate.minimaxManager, icon: Self.menuBarIcon)
        }

    }
}

/// Menu bar label: shows live metric text when any metric toggle is on and
/// data is available, otherwise the static template icon. Reading the
/// `@Observable` store's properties in `body` subscribes this view to the
/// fast-timer updates, so the text refreshes on every sample.
private struct MenuBarLabel: View {
    let store: MetricsStore
    let minimaxManager: MinimaxManager
    let icon: NSImage

    @AppStorage(WidgetSettings.menuBarShowCPUKey)     private var showCPU     = WidgetSettings.defaultMenuBarShowCPU
    @AppStorage(WidgetSettings.menuBarShowMemoryKey)  private var showMemory  = WidgetSettings.defaultMenuBarShowMemory
    @AppStorage(WidgetSettings.menuBarShowTempKey)    private var showTemp    = WidgetSettings.defaultMenuBarShowTemp
    @AppStorage(WidgetSettings.menuBarShowNetworkKey) private var showNetwork = WidgetSettings.defaultMenuBarShowNetwork
    @AppStorage(WidgetSettings.menuBarShowDiskKey)    private var showDisk    = WidgetSettings.defaultMenuBarShowDisk
    @AppStorage(WidgetSettings.menuBarShowMinimax5hKey) private var showMinimax5h = false
    @AppStorage(WidgetSettings.menuBarShowMinimaxWeeklyKey) private var showMinimaxWeekly = false

    var body: some View {
        let values = MenuBarValues(
            cpuFraction: store.cpu?.totalUsage,
            memFraction: store.memory?.usedFraction,
            temperatureC: store.cpuTemperature,
            netDownBytesPerSec: store.netRates?.download,
            netUpBytesPerSec: store.netRates?.upload,
            diskReadBytesPerSec: store.diskIO?.read,
            diskWriteBytesPerSec: store.diskIO?.write,
            minimax5hPercent: minimaxManager.snapshot?.fiveHour?.usedPercent,
            minimaxWeeklyPercent: minimaxManager.snapshot?.weekly?.usedPercent
        )
        let metrics = MenuBarText.metrics(values) { kind in
            switch kind {
            case .cpu:           return showCPU
            case .memory:        return showMemory
            case .temp:          return showTemp
            case .network:       return showNetwork
            case .disk:          return showDisk
            case .minimax5h:     return showMinimax5h
            case .minimaxWeekly: return showMinimaxWeekly
            }
        }
        // MenuBarExtra squeezes a custom SwiftUI label to one line and clips its
        // width, so the two-line layout is rendered into an NSImage instead —
        // the menu bar renders images at full size reliably.
        Image(nsImage: metrics.isEmpty ? icon : Self.image(for: metrics))
    }

    /// Draws the metrics into a template image that macOS tints for the menu
    /// bar. A normal metric is a column with a small label on top and a larger
    /// value below; a `stacked` metric (network/disk) draws both of its lines at
    /// one mid size so the two directions read as equal rows. Columns are
    /// separated by a fixed gap.
    ///
    /// Rows are packed to cap height (no ascender/descender whitespace) so that
    /// when the image is scaled to the menu bar thickness the glyphs render as
    /// large as possible.
    private static func image(for metrics: [MenuBarMetric]) -> NSImage {
        let labelFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let valueFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        let stackFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        // Drawn opaque (black); the image is a template (see below) so macOS
        // ignores the hue and tints the glyphs to match the menu bar itself —
        // flipping between dark and light to stay legible against the wallpaper
        // behind the translucent bar, exactly like the clock and Wi-Fi icons.
        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] {
            [.font: font, .foregroundColor: NSColor.black]
        }

        let cells = metrics.map { metric -> (top: NSAttributedString, bottom: NSAttributedString, topFont: NSFont, bottomFont: NSFont, width: CGFloat) in
            let topFont = metric.stacked ? stackFont : labelFont
            let bottomFont = metric.stacked ? stackFont : valueFont
            let top = NSAttributedString(string: metric.label, attributes: attrs(topFont))
            let bottom = NSAttributedString(string: metric.value, attributes: attrs(bottomFont))
            return (top, bottom, topFont, bottomFont, ceil(max(top.size().width, bottom.size().width)))
        }

        let columnGap: CGFloat = 16
        let rowGap: CGFloat = 3
        let vPad: CGFloat = 2  // breathing room so cap tops/bottoms aren't clipped
        // Shared row bands so mixed normal/stacked columns stay aligned.
        let bottomCap = cells.map { $0.bottomFont.capHeight }.max() ?? valueFont.capHeight
        let topCap = cells.map { $0.topFont.capHeight }.max() ?? labelFont.capHeight
        let width = cells.reduce(0) { $0 + $1.width } + columnGap * CGFloat(max(0, cells.count - 1))
        let height = ceil(bottomCap + rowGap + topCap + vPad * 2)
        let bottomBaseline = vPad                       // bottom caps at [vPad, vPad+bottomCap]
        let topBaseline = bottomCap + rowGap + vPad     // top row sits above the bottom row

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for cell in cells {
                cell.bottom.draw(at: NSPoint(x: x, y: bottomBaseline + cell.bottomFont.descender))
                cell.top.draw(at: NSPoint(x: x, y: topBaseline + cell.topFont.descender))
                x += cell.width + columnGap
            }
            return true
        }
        // Template image: macOS renders it monochrome and tints it to match the
        // menu bar's current appearance, so the text stays readable on any
        // wallpaper (dark on light bars, light on dark) with no manual color.
        image.isTemplate = true

        // Scale the whole image down to the menu bar thickness so both rows stay
        // fully visible instead of the top one being clipped by the bar.
        let thickness = NSStatusBar.system.thickness
        if height > thickness {
            image.size = NSSize(width: width * thickness / height, height: thickness)
        }
        return image
    }
}

/// "开机启动" menu item backed by SMAppService (macOS 13+).
/// Registration only works when running as a proper .app bundle;
/// from a bare dev binary register() throws and the toggle reverts.
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("开机启动", isOn: Binding(
            get: { enabled },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    enabled = newValue
                } catch {
                    // Keep the toggle in sync with reality on failure
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
        ))
    }
}

/// Returns whether the widget can be dragged at this moment.
private var isDraggingAllowed: Bool {
    !UserDefaults.standard.bool(forKey: WidgetSettings.positionLockedKey)
}

/// NSHostingView for the widget:
/// - mouseDownCanMoveWindow == false disables AppKit's built-in auto-drag
///   (it would ignore the lock — inner SwiftUI views report "can move");
///   dragging goes ONLY through DesktopWindow.mouseDown;
/// - acceptsFirstMouse == true so the lock button responds on the very first
///   click even though the window never becomes key.
final class WidgetHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless desktop-level window: never steals focus,
/// draggable from anywhere (unless position is locked).
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Drag only on left button and only when position is not locked;
        // everything else uses the standard handler (right-click etc. are not swallowed)
        if event.type == .leftMouseDown, isDraggingAllowed {
            performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: DesktopWindow?
    let store = MetricsStore()
    let minimaxManager = MinimaxManager()
    private var minimaxWindow: NSWindow?
    private var minimaxSettingsHost: NSHostingController<MinimaxSettingsView>?


    /// Tracks the last refresh interval seen in UserDefaults so we can detect changes.
    private var lastRefreshInterval: Double = UserDefaults.standard.object(
        forKey: WidgetSettings.refreshIntervalKey
    ) as? Double ?? WidgetSettings.defaultRefreshInterval

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon

        // After `brew upgrade` the registered login item points at the old
        // versioned Cellar path; re-registering from the current bundle
        // refreshes it. Throws for non-bundled dev builds — ignored.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }

        store.start()
        minimaxManager.start()

        let window = DesktopWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // One level ABOVE the Finder desktop icon window, but still below normal windows.
        // Below the icons (like Übersicht), mouse events never reach the widget: Finder's
        // transparent full-screen desktop window intercepts all clicks, making the
        // widget impossible to drag.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        // Visible on all Spaces, stationary in Mission Control, excluded from cmd-tab
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        let hostingView = WidgetHostingView(rootView: WidgetRootView(store: store, minimaxManager: minimaxManager))
        window.contentView = hostingView
        // Fit the window exactly to its content: extra transparent area
        // would capture clicks outside the visible widget
        let fitting = hostingView.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            window.setContentSize(fitting)
        }

        // Idiomatic order: set default position first (center),
        // then autosave — it will overwrite with the saved frame if one exists
        window.center()
        window.setFrameAutosaveName("VitalsWindow")

        self.window = window
        if WidgetSettings.isVisible(in: .standard) {
            window.orderFrontRegardless()
        }

        // Reconcile the stored width with the actual frame once at startup:
        // without this, a missing autosave entry (fresh install, cleared
        // defaults) would leave the window at fittingSize and ignore
        // widgetWidthKey until the user touches a setting.
        syncWindowSize()

        // UserDefaults changes drive two things:
        // 1. Width/height sync so the window envelope tracks SwiftUI content size.
        // 2. Refresh-rate restart when the user selects a new interval.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncWindowSize()
                self?.restartStoreIfIntervalChanged()
                self?.reconcileVisibility()
            }
        }
    }

    /// Synchronises the window frame to the SwiftUI content size.
    /// Width follows the drag-resize handle; height follows section visibility changes.
    /// Uses DispatchQueue.main.async so SwiftUI has already re-laid-out before we read
    /// fittingSize.
    private func syncWindowSize() {
        guard let window else { return }

        // Width: driven by the drag-resize handle stored in UserDefaults.
        let stored = UserDefaults.standard.object(forKey: WidgetSettings.widgetWidthKey) as? Double
            ?? WidgetSettings.defaultWidth
        let targetWidth = WidgetSettings.clampWidth(stored)
        let widthChanged = abs(window.frame.width - targetWidth) > 0.5

        // Height: derived from SwiftUI fitting size after layout.
        // We schedule async so the layout pass has completed before we measure.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard let contentView = window.contentView else { return }

            let fittingHeight = contentView.fittingSize.height
            let heightChanged = fittingHeight > 0 && abs(window.frame.height - fittingHeight) > 0.5

            if widthChanged || heightChanged {
                let newWidth  = widthChanged  ? targetWidth   : window.frame.width
                let newHeight = heightChanged ? fittingHeight : window.frame.height
                // Borderless window: frame size == content size; origin stays put.
                window.setContentSize(NSSize(width: newWidth, height: newHeight))
            }
        }
    }

    /// Re-creates the fast timer when the user picks a different refresh interval.
    /// MetricsStore.start() is idempotent (calls stop() first), so calling it again
    /// is safe and picks up the new interval from UserDefaults.
    private func restartStoreIfIntervalChanged() {
        let current = UserDefaults.standard.object(forKey: WidgetSettings.refreshIntervalKey) as? Double
            ?? WidgetSettings.defaultRefreshInterval
        guard current != lastRefreshInterval else { return }
        lastRefreshInterval = current
        store.start()
    }

    /// Shows or hides the desktop window to match the stored visibility flag.
    /// Idempotent: it compares against the window's current on-screen state so
    /// unrelated UserDefaults changes don't re-order the window.
    /// Polling keeps running regardless of visibility so menu-bar metrics and
    /// usage history stay live even while the widget is hidden.
    private func reconcileVisibility() {
        guard let window else { return }
        let shouldBeVisible = WidgetSettings.isVisible(in: .standard)
        if shouldBeVisible, !window.isVisible {
            window.orderFrontRegardless()
        } else if !shouldBeVisible, window.isVisible {
            window.orderOut(nil)
        }
    }


    /// Opens (or reuses) a single non-activating settings window for the
    /// MiniMax credentials, similar to the usage-history window.
    func openMinimaxSettings() {
        if let window = minimaxWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: MinimaxSettingsView(manager: minimaxManager))
        self.minimaxSettingsHost = host
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.title = "MiniMax 设置"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.minimaxWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        minimaxManager.stop()
    }
}
