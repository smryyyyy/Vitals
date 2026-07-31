import Foundation
import IOKit
import IOKit.ps

/// Battery data collector: IOPowerSources (level, status) + AppleSmartBattery registry
/// (cycles, capacities, temperature).
public struct PowerCollector {
    public init() {}

    /// nil — if no battery power source is present (desktop Mac).
    /// nil — if no battery is present (desktop Mac without one).
    /// Reads AppleSmartBattery directly from IORegistry — pmset / system_profiler
    /// use the same source, and unlike IOPSCopyPowerSourcesInfo it reflects
    /// `IsCharging` immediately on plug events on macOS 26.
    public func sample() -> PowerSnapshot? {
        guard let battery = smartBatteryProperties() else { return nil }

        // AppleSmartBattery exposes capacities as percentages on Apple Silicon.
        let currentCapacity = (battery["CurrentCapacity"] as? Int) ?? 0
        let maxCapacity = (battery["MaxCapacity"] as? Int) ?? 100
        let isCharging = (battery["IsCharging"] as? Bool) ?? false
        let fullyCharged = (battery["FullyCharged"] as? Bool) ?? false

        // TimeRemaining is the system's canonical "minutes left" estimate.
        // pmset shows "no estimate" for it as a special sentinel; AppleSmartBattery
        // mirrors that as a very large value (65535) when unknown.
        let rawRemaining = (battery["TimeRemaining"] as? Int) ?? -1
        let timeToFull = (battery["TimeToFullCharge"] as? Int) ?? -1
        // Pick the estimate that matches the current state.
        let minutes: Int = isCharging
            ? (timeToFull >= 0 ? timeToFull : -1)
            : (rawRemaining >= 0 && rawRemaining < 65535 ? rawRemaining : -1)

        // Suppress remaining-time text once the battery is full — the system
        // may still report "0 min" briefly after reaching 100%.
        let effectiveMinutes: Int? = fullyCharged ? nil
            : (minutes >= 0 ? minutes : nil)

        let cycleCount = battery["CycleCount"] as? Int
        let designCapacity = battery["DesignCapacity"] as? Int
        // On Apple Silicon "MaxCapacity" is a percentage; the actual capacity in mAh
        // is in AppleRawMaxCapacity (fallback: NominalChargeCapacity).
        let rawMax = (battery["AppleRawMaxCapacity"] as? Int)
            ?? (battery["NominalChargeCapacity"] as? Int)

        var health: Double?
        if let rawMax, let designCapacity {
            health = BatteryMath.health(rawMaxCapacity: rawMax, designCapacity: designCapacity)
        }
        let temperature = (battery["Temperature"] as? Int)
            .map(BatteryMath.celsius(fromRawTemperature:))

        return PowerSnapshot(
            levelFraction: maxCapacity > 0 ? min(1.0, Double(currentCapacity) / Double(maxCapacity)) : 0,
            healthFraction: health,
            isCharging: isCharging,
            timeRemainingMinutes: effectiveMinutes,
            cycleCount: cycleCount,
            temperatureCelsius: temperature
        )
    }


    private func smartBatteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return unmanaged?.takeRetainedValue() as? [String: Any]
    }
}
