import AppKit
import SwiftUI

// MARK: - Section identity

/// Ordered list of section slots. The order is fixed; visibility flags select which
/// slots appear in the grid. Using an enum makes ForEach ids stable and unique.
enum WidgetSection: Int, CaseIterable, Identifiable {
    case cpu, memory, disk, power, network, processes, minimax
    var id: Int { rawValue }
}


// MARK: - WidgetRootView

/// Root widget view: an always-visible title bar (app glyph + name on the
/// left, update/lock controls on the right), a dynamic grid of sections on
/// a dark backdrop, and an invisible resize handle along the right edge
/// (drag to adjust width).
public struct WidgetRootView: View {
    let store: MetricsStore
    let minimaxManager: MinimaxManager

    @AppStorage(WidgetSettings.positionLockedKey) private var positionLocked = false
    @AppStorage(WidgetSettings.widgetVisibleKey) private var widgetVisible = true
    @AppStorage(WidgetSettings.widgetWidthKey) private var widgetWidth = WidgetSettings.defaultWidth

    // Appearance
    @AppStorage(WidgetSettings.backgroundOpacityKey)
    private var backgroundOpacity = WidgetSettings.defaultOpacity
    @AppStorage(WidgetSettings.fontSizeKey)
    private var fontSize = WidgetSettings.defaultFontSize
    @AppStorage(WidgetSettings.fontStyleKey)
    private var fontStyle = WidgetSettings.defaultFontStyle.rawValue

    // Section visibility
    @AppStorage(WidgetSettings.showHeaderKey)    private var showHeader    = true
    @AppStorage(WidgetSettings.showCPUKey)       private var showCPU       = true
    @AppStorage(WidgetSettings.showMemoryKey)    private var showMemory    = true
    @AppStorage(WidgetSettings.showDiskKey)      private var showDisk      = true
    @AppStorage(WidgetSettings.showPowerKey)     private var showPower     = true
    @AppStorage(WidgetSettings.showNetworkKey)   private var showNetwork   = true
    @AppStorage(WidgetSettings.showProcessesKey) private var showProcesses = true
    @AppStorage(WidgetSettings.showMinimaxKey)   private var showMinimax   = true

    @State private var dragStartWidth: Double?

    /// Two columns + inter-column spacing (24) + horizontal padding (2×16).
    private var columnWidth: CGFloat {
        (WidgetSettings.clampWidth(widgetWidth) - 24 - 32) / 2
    }

    /// Ordered list of enabled section slots.
    private var enabledSections: [WidgetSection] {
        WidgetSection.allCases.filter { section in
            switch section {
            case .cpu:       return showCPU
            case .memory:    return showMemory
            case .disk:      return showDisk
            case .power:     return showPower
            case .network:   return showNetwork
            case .processes: return showProcesses
            case .minimax:   return showMinimax
            }
        }
    }



    public init(store: MetricsStore, minimaxManager: MinimaxManager) {
        self.store = store
        self.minimaxManager = minimaxManager
    }

    public var body: some View {
        let allHidden = !showHeader && enabledSections.isEmpty

        VStack(alignment: .leading, spacing: 12) {
            if allHidden {
                Text("所有模块已隐藏")
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                if showHeader {
                    HeaderView(info: store.systemInfo, score: store.healthScore)
                }

                if !enabledSections.isEmpty {
                    Grid(alignment: .topLeading, horizontalSpacing: 24, verticalSpacing: 16) {
                        // Chunk the enabled sections into pairs; the odd tail sits alone.
                        // Row identity = leading section, so rows keep stable identity
                        // when other sections are toggled on/off.
                        let pairs = enabledSections.chunks(of: 2)
                        ForEach(pairs, id: \.[0].id) { pair in
                            GridRow {
                                // Leading cell (always present)
                                sectionView(for: pair[0])
                                    .frame(width: columnWidth, alignment: .topLeading)
                                // Trailing cell (present only in full pairs)
                                if pair.count > 1 {
                                    sectionView(for: pair[1])
                                        .frame(width: columnWidth, alignment: .topLeading)
                                } else {
                                    // Empty spacer to keep the grid geometry consistent
                                    Color.clear
                                        .frame(width: columnWidth)
                                }
                            }
                        }
                    }
                }
            }
        }
        .font(Theme.font(
            size: WidgetSettings.clampFontSize(fontSize),
            style: WidgetSettings.resolveFontStyle(fontStyle)
        ))
        .padding(16)
        .modifier(WidgetBackground(opacity: backgroundOpacity))
        .overlay(alignment: .trailing) {
            resizeHandle
        }
    }
    /// Per-section view factory. Each case hands off to a dedicated SectionView
    /// with the latest snapshot from the corresponding collector.
    @ViewBuilder
    private func sectionView(for section: WidgetSection) -> some View {
        switch section {
        case .cpu:
            CPUSectionView(snapshot: store.cpu, history: store.cpuHistory.values, temperature: store.cpuTemperature).equatable()
        case .memory:
            MemorySectionView(snapshot: store.memory).equatable()
        case .disk:
            DiskSectionView(usage: store.diskUsage, io: store.diskIO).equatable()
        case .power:
            PowerSectionView(snapshot: store.power).equatable()
        case .network:
            NetworkSectionView(
                rates: store.netRates,
                info: store.networkInfo,
                downloadHistory: store.netInHistory.values,
                uploadHistory: store.netOutHistory.values
            ).equatable()
        case .processes:
            ProcessesSectionView(processes: store.topProcesses).equatable()
        case .minimax:
            MinimaxSectionView(snapshot: minimaxManager.snapshot).equatable()
        }
    }


    // MARK: - Resize handle

    /// Invisible strip along the right edge; drag it to resize the widget.
    /// Disabled while the position is locked.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                guard !positionLocked else { return }
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard !positionLocked else { return }
                        let start = dragStartWidth ?? widgetWidth
                        dragStartWidth = start
                        widgetWidth = WidgetSettings.clampWidth(start + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
    }

    // MARK: - Size preset buttons


    // MARK: - Lock button


    // MARK: - Hide button

}


// MARK: - Background

/// NSVisualEffectView wrapper — gives the same frosted-glass material native desktop
/// widgets use (.hudWindow + behindWindow blending). Stays active regardless of
/// window focus since the widget never becomes key.
private struct FrostView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// On macOS 26+ uses NSVisualEffectView (.hudWindow) to match native Tahoe widget
/// appearance; falls back to the opaque dark panel on earlier systems.
private struct WidgetBackground: ViewModifier {
    let opacity: Double

    func body(content: Content) -> some View {
        #if swift(>=6.3)
        if #available(macOS 26, *) {
            content
                .background(Color.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 12))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
        } else {
            content
                .background(
                    Theme.background.opacity(WidgetSettings.clampOpacity(opacity)),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        #else
        content
            .background(
                Theme.background.opacity(WidgetSettings.clampOpacity(opacity)),
                in: RoundedRectangle(cornerRadius: 12)
            )
        #endif
    }
}

// MARK: - Array chunking helper

private extension Array {
    /// Splits the array into sub-arrays of at most `size` elements.
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
