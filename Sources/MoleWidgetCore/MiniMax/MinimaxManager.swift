import Foundation
import Observation

/// Polls the MiniMax usage API on a 5-minute cadence, mirrors the latest
/// snapshot into an `@Observable` field for SwiftUI, and exposes a manual
/// `refresh()` for the "fetch now" button. Concurrency is bounded — a
/// refresh in flight can't be pre-empted, but a second tap is a no-op
/// rather than a parallel request.
@MainActor
@Observable
public final class MinimaxManager {
    /// Latest snapshot, nil before the first successful fetch.
    public private(set) var snapshot: MinimaxSnapshot?

    /// True while a fetch is in flight — the UI uses this to disable the
    /// "立即刷新" button.
    public private(set) var isFetching: Bool = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastFetchAt: Date?

    /// 1 / 5 / 15 / 30 / 60 minutes. Resolved from UserDefaults each time the
    /// timer is (re)started so the Settings panel takes effect immediately.
    public static let interval: TimeInterval = {
        let raw = UserDefaults.standard.object(forKey: WidgetSettings.minimaxRefreshIntervalKey) as? Double
            ?? WidgetSettings.defaultMinimaxRefreshInterval
        // 范围保护: 落到合法选项里
        let valid = WidgetSettings.minimaxRefreshIntervalOptions
        let clamped = valid.min { abs($0 - raw) < abs($1 - raw) } ?? WidgetSettings.defaultMinimaxRefreshInterval
        return clamped * 60
    }()

    public init() {}

    deinit {
        timer?.invalidate()
    }

    public func start() {
        stop()
        let seconds = Self.interval
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = max(5, seconds * 0.1)  // 10% 容忍,最少 5s
        self.timer = timer
        // Kick off a first fetch immediately so the UI doesn't sit empty.
        refresh()
    }

    /// Reschedules the timer to pick up a new interval from UserDefaults.
    /// Call this from the settings window when the picker changes.
    public func restart() {
        start()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Manual refresh hook. No-op if a fetch is already running, so a
    /// double-click on "立即刷新" doesn't double-bill the backend.
    public func refresh() {
        if inFlight != nil { return }
        let task = Task<Void, Never> { [weak self] in
            await self?.performFetch()
        }
        inFlight = task
    }

    private func performFetch() async {
        defer { inFlight = nil }
        guard let credentials = MinimaxKeychain.load(), credentials.isValid else {
            snapshot = MinimaxSnapshot(error: "未配置")
            return
        }
        isFetching = true
        defer { isFetching = false }

        let client = MinimaxClient(credentials: credentials)
        do {
            let response = try await client.fetchUsage()
            snapshot = MinimaxMapper.snapshot(from: response)
            lastFetchAt = Date()
        } catch let error as MinimaxError {
            snapshot = MinimaxSnapshot(error: error.errorDescription)
        } catch {
            snapshot = MinimaxSnapshot(error: error.localizedDescription)
        }
    }
}
