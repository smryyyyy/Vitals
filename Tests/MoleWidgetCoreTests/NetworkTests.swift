import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct NetworkTests {
    @Test func ratesFromCounterDeltas() {
        let prev = NetIOCounters(bytesIn: 1000, bytesOut: 2000)
        let cur = NetIOCounters(bytesIn: 1000 + 2_097_152, bytesOut: 2000 + 1_048_576)
        let rates = NetIO.rates(previous: prev, current: cur, interval: 2.0)
        #expect(abs(rates.download - 1_048_576) < 0.1)
        #expect(abs(rates.upload - 524_288) < 0.1)
    }

    @Test func ratesIgnoreCounterReset() {
        let prev = NetIOCounters(bytesIn: 5000, bytesOut: 5000)
        let cur = NetIOCounters(bytesIn: 100, bytesOut: 6000)
        let rates = NetIO.rates(previous: prev, current: cur, interval: 1.0)
        #expect(rates.download == 0)
        #expect(rates.upload == 1000)
    }

    @Test func ratesWithZeroIntervalAreZero() {
        let c = NetIOCounters(bytesIn: 1, bytesOut: 1)
        let rates = NetIO.rates(previous: c, current: c, interval: 0)
        #expect(rates.download == 0)
        #expect(rates.upload == 0)
    }

    @Test func collectorReturnsCumulativeCounters() throws {
        let collector = NetworkCollector()
        let first = try #require(collector.ioCounters())
        #expect(first.bytesIn > 0) // any live Mac has received bytes
        Thread.sleep(forTimeInterval: 0.3)
        let second = try #require(collector.ioCounters())
        #expect(second.bytesIn >= first.bytesIn)
    }

    @Test func collectorReturnsNetworkInfoOnLiveMac() {
        // Interface info may be nil on a fully offline machine — just must not crash
        _ = NetworkCollector().info()
    }

    // MARK: - 32-bit wrap compensation (the 4.29 GB sawtooth)

    @Test func wrapDeltaOnPlainProgress() {
        #expect(NetworkCollector.wrapDelta(1_500, 1_000) == 500)
        #expect(NetworkCollector.wrapDelta(42, 42) == 0)
    }

    /// The regression itself: raw 32-bit counters going backwards is a wrap, not a
    /// reset, and must contribute a real (small) delta instead of zero.
    @Test func wrapDeltaAddsExactlyOnePeriod() {
        #expect(NetworkCollector.wrapDelta(0x10, 0xFFFF_FFF0) == 32)
        #expect(NetworkCollector.wrapDelta(0, 0xFFFF_FFFF) == 1)
        #expect(NetworkCollector.wrapDelta(0xFFFF_FFFF, 0) == 0xFFFF_FFFF)
    }

    /// End-to-end over the accumulator: a wrap keeps the total moving forward, and
    /// an interface appearing or vanishing never looks like a counter reset.
    @Test func totalsSurviveWrapAndInterfaceChurn() {
        let collector = NetworkCollector()

        // First sample seeds from the raw sum so the initial reading is plausible.
        let seeded = collector.advance(to: ["en0": (0xFFFF_FFF0, 100), "en1": (50, 50)])
        #expect(seeded.bytesIn == 0xFFFF_FFF0 + 50)
        #expect(seeded.bytesOut == 150)

        // en0 wraps (32 bytes of traffic), en1 is idle, utun9 appears and must
        // contribute nothing on its first sighting.
        let second = collector.advance(to: [
            "en0": (0x10, 200), "en1": (50, 50), "utun9": (999, 999),
        ])
        #expect(second.bytesIn == seeded.bytesIn + 32)
        #expect(second.bytesOut == seeded.bytesOut + 100)

        // en1 and utun9 disappear; en0 advances by 16.
        let third = collector.advance(to: ["en0": (0x20, 200)])
        #expect(third.bytesIn == second.bytesIn + 16)
        #expect(third.bytesOut == second.bytesOut)

        // An interface that comes back is a new sighting, not a reset to zero.
        let fourth = collector.advance(to: ["en0": (0x20, 200), "en1": (900, 900)])
        #expect(fourth.bytesIn == third.bytesIn)
        #expect(fourth.bytesOut == third.bytesOut)
    }

    /// Whatever the raw counters do, the rate layer must never see a decrease.
    @Test func accumulatedTotalsNeverDecrease() {
        let collector = NetworkCollector()
        var previous = collector.advance(to: ["en0": (10, 10)])
        let samples: [[String: (in: UInt32, out: UInt32)]] = [
            ["en0": (0xFFFF_FFF0, 0xFFFF_FFF0)],
            ["en0": (0x20, 0x20)],
            ["en0": (0x30, 0x10)],
            ["en0": (5, 5), "en2": (1, 1)],
            ["en0": (0xFFFF_FFFF, 0xFFFF_FFFF)],
            ["en0": (0, 0)],
        ]
        for sample in samples {
            let next = collector.advance(to: sample)
            #expect(next.bytesIn >= previous.bytesIn)
            #expect(next.bytesOut >= previous.bytesOut)
            previous = next
        }
    }
}
