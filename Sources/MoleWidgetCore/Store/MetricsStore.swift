import Foundation
import Observation

/// Central snapshot store. Polls collectors on timers at different frequencies
/// and publishes the results for SwiftUI.
///
/// ## Thread model
///
/// Every collector is blocking C/IOKit work — the process sweep alone is ~10 ms —
/// and it used to run on the main actor inside the timer callback, so a 10 ms
/// hitch landed on SwiftUI layout and on menu tracking every 5 seconds. (A mean
/// of "< 1% CPU" hides that: the average is tiny, the periodic stall is not.)
///
/// Collection now runs on a background **concurrent** queue and only the cheap
/// snapshot assignment hops back to the main actor:
///
/// - Concurrent rather than serial on purpose. The four timers are independent, and
///   one serial queue would let a stalled `statfs` on a busy volume push the 2 s fast
///   tick behind it. Per-call QoS lets the scheduler prioritise the fast tick over
///   the 60 s disk sweep.
/// - Safe because every collector is either a stateless `struct` (CPU, memory, disk,
///   power, process) or guards its own mutable state with a lock
///   (`NetworkCollector`'s wrap compensation, `SMCTemperature`'s sensor cache).
///   `SystemInfoCollector` stores nothing at all.
/// - The store stays `@MainActor @Observable` with an unchanged public API, so views
///   keep refreshing off ordinary property observation — no new notification
///   mechanism, and no view changes.
///
/// Each timer drops its sample if the previous one for the same timer is still
/// running (`*InFlight`). Without that, two overlapping samples could apply out of
/// order and report a negative rate.
@MainActor
@Observable
public final class MetricsStore {
    public private(set) var cpu: CPUSnapshot?
    public private(set) var memory: MemorySnapshot?
    public private(set) var diskUsage: DiskUsageSnapshot?
    public private(set) var diskIO: DiskIORates?
    public private(set) var power: PowerSnapshot?
    public private(set) var cpuTemperature: Double?
    public private(set) var netRates: NetIORates?
    public private(set) var networkInfo: NetworkInfo?
    public private(set) var topProcesses: [ProcessUsage] = []
    public private(set) var systemInfo: SystemInfoSnapshot?
    public private(set) var healthScore: Int = 100
    public private(set) var cpuHistory = History()
    public private(set) var netInHistory = History()
    public private(set) var netOutHistory = History()

    @ObservationIgnored private let collectors = CollectorSet()

    /// Background collection queue. See the thread-model note above.
    @ObservationIgnored private let collectQueue = DispatchQueue(
        label: "com.molewidget.metrics.collect",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // Rate deltas need the previous sample. These are main-actor state because they
    // are applied on the main actor; they are *read* here and handed to the
    // background work by value, never shared by reference.
    @ObservationIgnored private var previousCPU: CPUSample?
    @ObservationIgnored private var previousIO: (counters: DiskIOCounters, at: Date)?
    @ObservationIgnored private var previousNetIO: (counters: NetIOCounters, at: Date)?
    @ObservationIgnored private var previousProcs: (samples: [ProcSample], at: Date)?

    @ObservationIgnored private var fastInFlight = false
    @ObservationIgnored private var processInFlight = false
    @ObservationIgnored private var timers: [Timer] = []

    public init() {}

    deinit {
        timers.forEach { $0.invalidate() }
    }

    public func start() {
        stop() // a repeated start() must not leave stale timers in the RunLoop
        // The first sample is taken synchronously so the panel has numbers in its
        // very first frame instead of one tick later; steady-state ticks are
        // backgrounded. This costs one ~10 ms hitch per launch, once.
        refreshFastInline()
        refreshProcessesInline()
        refreshDiskUsageInline()
        refreshPowerInline()
        // Read the fast-timer interval from user defaults; floor at 1 s.
        let interval = max(
            1.0,
            UserDefaults.standard.object(forKey: WidgetSettings.refreshIntervalKey) as? Double
                ?? WidgetSettings.defaultRefreshInterval
        )
        timers = [
            makeTimer(interval, tolerance: interval * 0.2) { $0.refreshFast() },
            makeTimer(5, tolerance: 1) { $0.refreshProcesses() },
            makeTimer(60, tolerance: 15) { $0.refreshDiskUsage() },
            makeTimer(30, tolerance: 8) { $0.refreshPower() },
        ]
    }

    /// Repeating timer with a wake-up tolerance so macOS can coalesce it with
    /// other timers — fewer wake-ups means noticeably lower energy use than
    /// forcing the system awake precisely on every interval.
    ///
    /// Registered in `RunLoop.Mode.common`, not the `.default` mode that
    /// `Timer.scheduledTimer` picks. AppKit pushes the run loop into event-tracking
    /// mode while a menu is open or a window is being dragged, and that mode does
    /// not run `.default` sources — so all four timers used to stop dead for the
    /// whole interaction and dragging the widget froze every metric. `.common` is a
    /// superset of `.default`, so ordinary ticking is unchanged.
    private func makeTimer(
        _ interval: TimeInterval,
        tolerance: TimeInterval,
        _ body: @escaping (MetricsStore) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self { body(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        timer.tolerance = tolerance
        return timer
    }

    public func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
    }

    /// The timers `start()` registered. Internal so tests can assert the run-loop
    /// mode they were added in.
    var registeredTimers: [Timer] { timers }

    // MARK: - CPU + Memory + Disk I/O (every 2 s)

    public func refreshFast() {
        guard !fastInFlight else { return } // previous sample still running
        fastInFlight = true
        let work = Transfer(value: (collectors, previousCPU, previousIO, previousNetIO))

        collectQueue.async(qos: .userInteractive) {
            let reading = Self.collectFast(
                collectors: work.value.0, previousCPU: work.value.1,
                previousIO: work.value.2, previousNetIO: work.value.3
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.fastInFlight = false
                self.apply(reading)
            }
        }
    }

    /// Synchronous entry point — collects on the calling thread.
    /// Used for the first paint in `start()` and by tests.
    func refreshFastInline() {
        apply(Self.collectFast(
            collectors: collectors, previousCPU: previousCPU,
            previousIO: previousIO, previousNetIO: previousNetIO
        ))
    }

    // MARK: - Top processes (every 5 s)

    /// Top processes — every 5 seconds. Enumerating every pid
    /// (`proc_listallpids` + `proc_pid_rusage`/`proc_name` per pid) is the most
    /// expensive sample, and the "top processes" list does not need sub-second
    /// freshness, so it runs on its own slower timer instead of the fast tick.
    public func refreshProcesses() {
        guard !processInFlight else { return }
        processInFlight = true
        let work = Transfer(value: (collectors, previousProcs))

        collectQueue.async(qos: .userInitiated) {
            let reading = Self.collectProcesses(processes: work.value.0.processes, previous: work.value.1)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processInFlight = false
                self.apply(reading)
            }
        }
    }

    /// Synchronous entry point — collects on the calling thread. Used by tests.
    func refreshProcessesInline() {
        apply(Self.collectProcesses(processes: collectors.processes, previous: previousProcs))
    }

    // MARK: - Disk usage (every 60 s)

    /// Disk usage — every 60 seconds (changes slowly).
    public func refreshDiskUsage() {
        let collector = Transfer(value: collectors.disk)
        collectQueue.async(qos: .utility) {
            let usage = collector.value.usage()
            Task { @MainActor [weak self] in
                if let usage { self?.diskUsage = usage }
            }
        }
    }

    /// Synchronous entry point — collects on the calling thread. Used by tests.
    func refreshDiskUsageInline() {
        if let usage = collectors.disk.usage() { diskUsage = usage }
    }

    // MARK: - Battery + temperature + interface info + system info (every 30 s)

    /// Battery + temperature + network interface info + system info — every 30 seconds.
    public func refreshPower() {
        let work = Transfer(value: collectors)
        collectQueue.async(qos: .utility) {
            let reading = Self.collectPower(work.value)
            Task { @MainActor [weak self] in self?.apply(reading) }
        }
    }

    /// Synchronous entry point — collects on the calling thread. Used by tests.
    func refreshPowerInline() {
        apply(Self.collectPower(collectors))
    }

    // MARK: - Collectors and queue-boundary types

    /// Every collector the store drives.
    ///
    /// Grouped into one type so the "is this safe off the main actor?" question has
    /// a single answer instead of eight: every member is either a stateless `struct`
    /// (CPU, memory, disk, power, process) or a class that serialises its own
    /// mutable state behind a lock (`NetworkCollector`, `SMCTemperature`).
    private struct CollectorSet {
        let cpu = CPUCollector()
        let memory = MemoryCollector()
        let disk = DiskCollector()
        let power = PowerCollector()
        let network = NetworkCollector()
        let processes = ProcessCollector()
        let systemInfo = SystemInfoCollector()
        let temperature = SMCTemperature()
    }

    /// Carries an immutable work item onto the collection queue.
    ///
    /// `@unchecked Sendable` is only sound because the two things ever wrapped here
    /// are safe: `CollectorSet` (above) and a previous-sample snapshot, which is a
    /// read-only value copied off the main actor and never written back from the
    /// queue. It exists so this file does not have to retro-fit `Sendable` onto the
    /// public collector types.
    private struct Transfer<Value>: @unchecked Sendable {
        let value: Value
    }

    /// One fast tick's worth of readings, gathered off the main actor.
    ///
    /// Carries the previous samples in and the derived rates out, so all mutable
    /// store state stays on the main actor and only values cross the boundary.
    /// `*At` is stamped at collection time, not at apply time — re-stamping on the
    /// main actor would inflate every measured interval by the queue hop and
    /// understate the rate.
    private struct FastReading {
        var ticks: CPUSample?
        var cpuSnapshot: CPUSnapshot?
        var memory: MemorySnapshot?
        var diskRates: DiskIORates?
        var diskNow: DiskIOCounters?
        var diskAt: Date?
        var netRates: NetIORates?
        var netNow: NetIOCounters?
        var netAt: Date?
    }

    private struct ProcessReading {
        var processes: [ProcessUsage]
        var samples: [ProcSample]
    }

    private struct PowerReading {
        var power: PowerSnapshot?
        var temperature: Double?
        var networkInfo: NetworkInfo?
        var systemInfo: SystemInfoSnapshot?
    }

    private nonisolated static func collectFast(
        collectors: CollectorSet,
        previousCPU: CPUSample?,
        previousIO: (counters: DiskIOCounters, at: Date)?,
        previousNetIO: (counters: NetIOCounters, at: Date)?
    ) -> FastReading {
        var reading = FastReading(
            ticks: nil, cpuSnapshot: nil, memory: nil,
            diskRates: nil, diskNow: nil, diskAt: nil,
            netRates: nil, netNow: nil, netAt: nil
        )

        reading.ticks = collectors.cpu.sampleTicks()
        if let ticks = reading.ticks, let previous = previousCPU {
            reading.cpuSnapshot = CPUUsage.snapshot(
                previous: previous,
                current: ticks,
                loadAverage: collectors.cpu.loadAverage()
            )
        }

        reading.memory = collectors.memory.sample()

        if let counters = collectors.disk.ioCounters() {
            let now = Date()
            if let previous = previousIO {
                reading.diskRates = DiskIO.rates(
                    previous: previous.counters,
                    current: counters,
                    interval: now.timeIntervalSince(previous.at)
                )
            }
            reading.diskNow = counters
            reading.diskAt = now
        }

        if let counters = collectors.network.ioCounters() {
            let now = Date()
            if let previous = previousNetIO {
                reading.netRates = NetIO.rates(
                    previous: previous.counters,
                    current: counters,
                    interval: now.timeIntervalSince(previous.at)
                )
            }
            reading.netNow = counters
            reading.netAt = now
        }

        return reading
    }

    private nonisolated static func collectProcesses(
        processes: ProcessCollector,
        previous: (samples: [ProcSample], at: Date)?
    ) -> ProcessReading {
        let samples = processes.sample()
        guard !samples.isEmpty else { return ProcessReading(processes: [], samples: []) }
        let now = Date()
        let top = previous.map {
            ProcessMath.top(previous: $0.samples, current: samples, interval: now.timeIntervalSince($0.at))
        } ?? []
        return ProcessReading(processes: top, samples: samples)
    }

    private nonisolated static func collectPower(_ collectors: CollectorSet) -> PowerReading {
        PowerReading(
            power: collectors.power.sample(),
            temperature: collectors.temperature.cpuTemperature(),
            networkInfo: collectors.network.info(),
            systemInfo: collectors.systemInfo.sample()
        )
    }

    // MARK: - Applying results (main actor)

    private func apply(_ reading: FastReading) {
        if let snapshot = reading.cpuSnapshot {
            cpu = snapshot
            cpuHistory.push(snapshot.totalUsage)
        }
        previousCPU = reading.ticks
        if let memory = reading.memory { self.memory = memory }

        if let rates = reading.diskRates { diskIO = rates }
        // A failed sample clears the pair so the next tick starts a fresh baseline
        // instead of diffing against a stale counter.
        previousIO = reading.diskNow.map { (counters: $0, at: reading.diskAt ?? Date()) }

        if let rates = reading.netRates {
            netRates = rates
            netInHistory.push(rates.download)
            netOutHistory.push(rates.upload)
        }
        previousNetIO = reading.netNow.map { (counters: $0, at: reading.netAt ?? Date()) }

        healthScore = HealthScore.compute(
            cpu: cpu?.totalUsage,
            memUsedFraction: memory?.usedFraction,
            diskUsedFraction: diskUsage?.usedFraction,
            batteryHealth: power?.healthFraction,
            batteryLevel: power?.levelFraction,
            isCharging: power?.isCharging ?? false
        )
    }

    private func apply(_ reading: ProcessReading) {
        if !reading.samples.isEmpty {
            topProcesses = reading.processes
            previousProcs = (reading.samples, Date())
        } else {
            previousProcs = nil // collection failure → next sample pair starts fresh
        }
    }

    private func apply(_ reading: PowerReading) {
        power = reading.power
        cpuTemperature = reading.temperature
        networkInfo = reading.networkInfo
        systemInfo = reading.systemInfo
    }
}
