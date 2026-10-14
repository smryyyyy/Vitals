import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct SMCTemperatureTests {
    @Test func aggregate_empty_returnsNil() {
        #expect(SMCTemperature.aggregate([]) == nil)
    }

    @Test func aggregate_normalSet_returnsMedian() {
        // Odd count → middle value.
        #expect(SMCTemperature.aggregate([44, 46, 48]) == 46)
        // Even count → mean of the two middle values.
        #expect(SMCTemperature.aggregate([44, 46, 48, 50]) == 47)
    }

    @Test func aggregate_singleOutlier_isIgnored() {
        // A lone hot sensor near the 130° filter edge must not drag the figure up.
        let result = SMCTemperature.aggregate([45, 46, 47, 125])
        #expect(result != nil)
        #expect(abs(result! - 46.5) < 0.001)
        #expect(result! < 100)
    }

    /// A machine under sustained load legitimately runs above the old 110 °C cut-off
    /// (M-series parts throttle around 100–105 °C, sensors read higher), and the old
    /// threshold blanked the menu-bar figure outright. Real readings must survive.
    @Test func aggregate_hotButRealReadings_areKept() {
        #expect(SMCTemperature.aggregate([112, 115, 118]) == 115)
        #expect(SMCTemperature.aggregate([118, 120, 124]) == 120)
    }

    /// Only a genuinely impossible *whole sensor set* is dropped.
    @Test func aggregate_allImplausiblyHigh_returnsNil() {
        #expect(SMCTemperature.aggregate([126, 128, 129]) == nil)
    }

    @Test func aggregate_atCeiling_isKept() {
        let ceiling = Float(SMCTemperature.plausibleCeiling)
        #expect(SMCTemperature.aggregate([ceiling]) == Double(ceiling))
    }

    @Test func plausibleCeiling_isNotTighterThanTheSensorFilter() {
        // It must stay strictly below the 130 °C per-sensor cut-off, otherwise
        // values in between are collected and then thrown away as a whole frame.
        #expect(SMCTemperature.plausibleCeiling < 130)
    }

    /// The headline regression. The old code wrote the scan result back
    /// unconditionally, so a first scan that found nothing cached `[]` and every
    /// later `cpuTemperature()` returned nil for the life of the process — no amount
    /// of retrying could recover it. The cache must now be either nil or populated.
    @Test func emptyScanIsNeverCached() {
        let smc = SMCTemperature()
        for _ in 0..<3 { _ = smc.cpuTemperature() }
        if let count = smc.cachedKeyCount {
            #expect(count > 0)
        }
    }

    /// Repeated reads must be stable and must not throw; on a Mac with working SMC
    /// hardware the value stays inside the per-sensor filter.
    @Test func repeatedReadsAreStable() {
        let smc = SMCTemperature()
        let first = smc.cpuTemperature()
        let second = smc.cpuTemperature()
        #expect(first == second)
        if let first {
            #expect(first > 0 && first < 130)
        }
    }
}
