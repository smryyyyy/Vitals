import Foundation
import Testing
@testable import MoleWidgetCore

@Suite struct MetricsStoreTests {
    @MainActor
    @Test func refreshPopulatesSnapshots() async throws {
        let store = MetricsStore()

        // The `*Inline` entry points collect synchronously on the calling thread;
        // the timer-driven ones hand the work to the collection queue.
        store.refreshFastInline()
        #expect(store.cpu == nil)   // first CPU sample only records ticks
        #expect(store.memory != nil)

        try await Task.sleep(for: .milliseconds(10))
        store.refreshFastInline()
        #expect(store.cpu != nil)
        #expect(store.diskIO != nil)

        store.refreshDiskUsageInline()
        #expect(store.diskUsage != nil)

        // Power may be nil on a Mac without a battery — must not crash
        store.refreshPowerInline()
    }

    @MainActor
    @Test func startStopDoesNotCrashAndIsIdempotent() {
        let store = MetricsStore()
        store.start()
        store.start() // repeated start must not duplicate timers
        store.stop()
        store.stop() // repeated stop is a no-op
        #expect(store.memory != nil) // start() performs an initial refresh
    }

    /// Regression for the main-thread stall: the timer-driven refreshes must hand
    /// collection to the background queue instead of doing it inline, and must
    /// still publish the result back onto the observable properties.
    @MainActor
    @Test func timerDrivenRefreshRunsOffTheMainThread() async throws {
        let store = MetricsStore()

        store.refreshFast()
        // Nothing can have been applied yet — the sample is still in flight. This
        // assertion is deterministic, not timing-based: `memory` is only ever
        // assigned from the background result.
        #expect(store.memory == nil)

        try await Task.sleep(for: .milliseconds(500))
        #expect(store.memory != nil)
    }

    @MainActor
    @Test func backgroundRefreshDoesNotLeaveTheStoreInFlight() async throws {
        let store = MetricsStore()
        store.refreshProcesses()
        store.refreshFast()
        try await Task.sleep(for: .milliseconds(500))
        // A stuck in-flight flag would make every later refreshFast() a no-op.
        store.refreshFastInline()
        store.refreshFastInline()
        #expect(store.memory != nil)
    }

    /// Regression for sampling stopping during menu tracking / window dragging.
    ///
    /// AppKit runs the run loop in `NSEventTrackingRunLoopMode` for the whole time a
    /// menu is open or a window is dragged, and that mode does **not** run
    /// `.default` sources — so the four timers used to go silent for the entire
    /// interaction. This drives the run loop in exactly that mode and checks the fast
    /// timer still produced samples.
    @MainActor
    @Test func timersKeepFiringDuringEventTracking() async throws {
        // The store floors the interval at 1 s; keep the test honest by asking for it.
        UserDefaults.standard.set(1.0, forKey: WidgetSettings.refreshIntervalKey)
        defer { UserDefaults.standard.removeObject(forKey: WidgetSettings.refreshIntervalKey) }

        let store = MetricsStore()
        store.start()
        defer { store.stop() }

        await runCurrentRunLoopInEventTrackingMode(for: .seconds(4))
        // Two ticks are needed before cpuHistory records anything: the first only
        // establishes a baseline. A `.default`-only timer would leave this empty.
        #expect(store.cpuHistory.values.count >= 1)
    }

    /// Pumps the current run loop inside AppKit's event-tracking mode.
    ///
    /// `CFRunLoopRunInMode` drives whatever run loop is current — on the main actor
    /// that is the main run loop, the one `makeTimer` registers against. Slices are
    /// short and `Task.yield()` in between lets the timers' `@MainActor` hop-backs
    /// run, otherwise the callbacks would be queued but never applied.
    private func runCurrentRunLoopInEventTrackingMode(for duration: Duration) async {
        let mode = CFRunLoopMode("NSEventTrackingRunLoopMode" as CFString)
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            pumpRunLoop(mode, seconds: 0.05)
            await Task.yield()
        }
    }

    /// `CFRunLoopRunInMode` is annotated unavailable-from-async because it parks the
    /// calling thread. Confining it to a synchronous helper and slicing it into 50 ms
    /// chunks keeps the diagnostic away and the parking harmless — we are on the main
    /// actor, and `runCurrentRunLoopInEventTrackingMode` yields between chunks.
    private nonisolated func pumpRunLoop(_ mode: CFRunLoopMode, seconds: CFTimeInterval) {
        CFRunLoopRunInMode(mode, seconds, true)
    }

    /// `.common` must not cost us the coalescing tolerance.
    @MainActor
    @Test func timersKeepTheirTolerance() {
        let store = MetricsStore()
        store.start()
        defer { store.stop() }

        #expect(store.registeredTimers.count == 4)
        #expect(store.registeredTimers.allSatisfy { $0.tolerance > 0 })
        #expect(store.registeredTimers.allSatisfy { $0.isValid })
    }
}
