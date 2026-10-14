import Foundation
import Observation

/// Owns the live salary snapshot. Recomputes every second on a main-actor
/// `Timer` and mirrors the result into `@Observable` state for SwiftUI.
/// Persistence is a thin JSON blob in UserDefaults — see `SalarySettings.load/save`.
@MainActor
@Observable
public final class SalaryManager {
    public private(set) var snapshot: SalarySnapshot
    public private(set) var settings: SalarySettings

    @ObservationIgnored private var timer: Timer?

    public init() {
        let s = SalarySettings.load()
        self.settings = s
        self.snapshot = SalaryEngine.compute(settings: s)
    }

    deinit {
        timer?.invalidate()
    }

    /// 1-second cadence: the live "今日已赚" figure needs per-second updates
    /// to feel real.
    ///
    /// 开销说明:重算本身没有 I/O,也不联网;之前"cheap"的印象来自 `isWorkday`
    /// 没开缓存时每 30 天就要做一次 `String(format:)` 拼 key,而 `totalEarned`
    /// 在入职 10 年时每轮要扫 120 个月。现在 `ChineseWorkdayCalendar` 按
    /// (年, 月) 缓存工作日位图,同一秒内的重复重算退化成几次位运算。
    public func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute() }
        }
        timer.tolerance = 0.1
        self.timer = timer
        recompute()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func updateSettings(_ new: SalarySettings) {
        settings = new
        new.save()
        recompute()
    }

    public func resetSettings() {
        updateSettings(SalarySettings())
    }

    private func recompute() {
        snapshot = SalaryEngine.compute(settings: settings)
    }
}

extension SalarySettings {
    /// UserDefaults key for the JSON blob。Public so tests can pre-seed it。
    /// v2:字段重构(税后月薪 + 自动算工作日),与 v1 不兼容,旧数据被丢弃。
    public static let storageKey = "salarySettings_v2"

    public static func load() -> SalarySettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(SalarySettings.self, from: data) else {
            return SalarySettings()
        }
        return decoded
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: SalarySettings.storageKey)
    }
}
