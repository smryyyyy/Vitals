import Foundation

/// One menu bar metric, rendered as a two-line column to save horizontal space.
///
/// By default `label` is a small tag on top and `value` the large figure below
/// (e.g. `CPU` / `42%`). A `stacked` metric instead draws both lines at the same
/// size — used for the paired throughput metrics that show two directions in one
/// column (e.g. `↓ 0.5M` over `↑ 0.1M`).
public struct MenuBarMetric: Equatable {
    public let label: String
    public let value: String
    public let stacked: Bool

    public init(label: String, value: String, stacked: Bool = false) {
        self.label = label
        self.value = value
        self.stacked = stacked
    }
}

/// A metric that can be shown in the menu bar, in canonical display order.
/// `network` and `disk` each pair two directions in one stacked column.
public enum MenuBarMetricKind: String, CaseIterable {
    case cpu, memory, temp, network, disk, minimax5h, minimaxWeekly
}

/// The live values a menu bar metric may draw from. Each is optional and its
/// metric is omitted when absent (see `MenuBarText.metrics`).
public struct MenuBarValues {
    public var cpuFraction: Double?          // MetricsStore.cpu?.totalUsage, 0...1
    public var memFraction: Double?          // MetricsStore.memory?.usedFraction, 0...1
    public var temperatureC: Double?         // MetricsStore.cpuTemperature (SoC die temp)
    public var netDownBytesPerSec: Double?   // MetricsStore.netRates?.download
    public var netUpBytesPerSec: Double?     // MetricsStore.netRates?.upload
    public var diskReadBytesPerSec: Double?  // MetricsStore.diskIO?.read
    public var diskWriteBytesPerSec: Double? // MetricsStore.diskIO?.write
    public var minimax5hPercent: Int?        // MinimaxSnapshot.fiveHour?.usedPercent 0...100
    public var minimaxWeeklyPercent: Int?    // MinimaxSnapshot.weekly?.usedPercent 0...100

    public init(
        cpuFraction: Double? = nil,
        memFraction: Double? = nil,
        temperatureC: Double? = nil,
        netDownBytesPerSec: Double? = nil,
        netUpBytesPerSec: Double? = nil,
        diskReadBytesPerSec: Double? = nil,
        diskWriteBytesPerSec: Double? = nil,
        minimax5hPercent: Int? = nil,
        minimaxWeeklyPercent: Int? = nil
    ) {
        self.cpuFraction = cpuFraction
        self.memFraction = memFraction
        self.temperatureC = temperatureC
        self.netDownBytesPerSec = netDownBytesPerSec
        self.netUpBytesPerSec = netUpBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.minimax5hPercent = minimax5hPercent
        self.minimaxWeeklyPercent = minimaxWeeklyPercent
    }
}

/// Builds the live menu bar metrics.
///
/// Uses a tight format (integer percent, integer degrees, `Fmt.rateCompact` for
/// throughput). Metrics appear in the fixed `MenuBarMetricKind.allCases` order.
/// An enabled metric whose value is `nil` is omitted entirely — this keeps the
/// menu bar clean at startup and on Macs without a given sensor. An empty result
/// means the caller should fall back to the icon.
public enum MenuBarText {
    /// - Parameters:
    ///   - values: the live metric values to draw from.
    ///   - enabled: whether a given metric kind is switched on in settings.
    /// - Returns: e.g. `[CPU/42%, MEM/34%, TEMP/54°]`, empty when nothing to show.
    public static func metrics(
        _ values: MenuBarValues,
        enabled: (MenuBarMetricKind) -> Bool
    ) -> [MenuBarMetric] {
        MenuBarMetricKind.allCases.compactMap { kind in
            enabled(kind) ? metric(kind, values) : nil
        }
    }

    private static func metric(_ kind: MenuBarMetricKind, _ v: MenuBarValues) -> MenuBarMetric? {
        switch kind {
        case .cpu:     return v.cpuFraction.map { MenuBarMetric(label: "CPU", value: percent($0)) }
        case .memory:  return v.memFraction.map { MenuBarMetric(label: "内存", value: percent($0)) }
        case .temp:    return v.temperatureC.map { MenuBarMetric(label: "温度", value: degrees($0)) }
        case .network:
            guard let down = v.netDownBytesPerSec, let up = v.netUpBytesPerSec else { return nil }
            return MenuBarMetric(label: "↓ \(Fmt.rateCompact(down))",
                                 value: "↑ \(Fmt.rateCompact(up))", stacked: true)
        case .disk:
            guard let read = v.diskReadBytesPerSec, let write = v.diskWriteBytesPerSec else { return nil }
            return MenuBarMetric(label: "读 \(Fmt.rateCompact(read))",
                                 value: "写 \(Fmt.rateCompact(write))", stacked: true)
        case .minimax5h:
            return v.minimax5hPercent.map { MenuBarMetric(label: "5h", value: "\($0)%") }
        case .minimaxWeekly:
            return v.minimaxWeeklyPercent.map { MenuBarMetric(label: "week", value: "\($0)%") }
        }
    }

    private static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func degrees(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }
}
