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
    /// 拉取失败时**不会**被清空 —— 网络抖一下不该让已经拿到的用量数字和倒计时消失。
    public private(set) var snapshot: MinimaxSnapshot?

    /// 最近一次失败的原因,成功时置 nil。跟 `snapshot` 分开存,
    /// UI 才能同时显示"旧数据 + 一行错误"。
    public private(set) var lastError: MinimaxErrorKind?

    /// True while a fetch is in flight — the UI uses this to disable the
    /// "立即刷新" button.
    public private(set) var isFetching: Bool = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastFetchAt: Date?

    /// 1 / 5 / 15 / 30 / 60 分钟,单位秒。
    ///
    /// 必须是计算属性:之前是 `static let` + 一次性闭包,进程内只求值一次,
    /// 设置页改频率后 `restart()` 读到的还是缓存值,必须重启应用才生效。
    /// 现在每次 `start()` 都重新从 UserDefaults 解析。
    /// `nonisolated`:纯读取,跟主线程无关,这样测试和其它模块都能直接用。
    public nonisolated static var interval: TimeInterval {
        let raw = UserDefaults.standard.object(forKey: WidgetSettings.minimaxRefreshIntervalKey) as? Double
            ?? WidgetSettings.defaultMinimaxRefreshInterval
        // 范围保护: 落到合法选项里
        let valid = WidgetSettings.minimaxRefreshIntervalOptions
        let clamped = valid.min { abs($0 - raw) < abs($1 - raw) } ?? WidgetSettings.defaultMinimaxRefreshInterval
        return clamped * 60
    }

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

        let credentials: MinimaxCredentials
        switch MinimaxKeychain.load() {
        case .notFound:
            lastError = .notConfigured
            return
        case .unavailable:
            // 钥匙串锁着 / 读不出来 —— 不动 snapshot,只提示解锁
            lastError = .keychainUnavailable
            return
        case .found(let stored):
            guard stored.isValid else {
                lastError = .notConfigured
                return
            }
            credentials = stored
        }

        isFetching = true
        defer { isFetching = false }

        let client = MinimaxClient(credentials: credentials)
        do {
            let response = try await client.fetchUsage()
            snapshot = MinimaxMapper.snapshot(from: response)
            lastFetchAt = Date()
            lastError = nil
        } catch let error as MinimaxError {
            // 保留上一次的 snapshot:短暂抖动不该把已获取的用量数字一并抹掉
            lastError = error.kind
        } catch {
            lastError = .unknown
        }
    }
}
