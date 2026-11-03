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

    /// 最近一次**自动续期**成功的时间。nil = 还没续过。
    ///
    /// 持久化到 UserDefaults:「今天续过没」这个判断必须在应用重启后依然
    /// 成立,否则每重启一次就会重复续一次(续期本身无害,但没必要)。
    public private(set) var lastRenewalAt: Date?

    /// 当前 token 的过期时间(从 JWT 的 exp 解析)。
    ///
    /// 设置面板用它显示「还剩几天」——用户得看得到剩余有效期,才知道
    /// 离失效还有多远、该不该手动点一次「立即续期」。
    public private(set) var tokenExpiry: Date?

    /// 最近一次**续期**失败的原因。nil = 上次续期成功,或者还没试过。
    ///
    /// 刻意跟 `lastError` 分开存:`lastError` 说的是「用量拉取失败」,会被下一次
    /// 拉取成功直接抹平;而续期失败是**另一件事** —— 旧 token 还能用,用量照样
    /// 拉得回来,但 token 一直没换新。如果复用同一个字段,续期失败会被用量成功
    /// 盖掉,用户永远看不到「自动续期其实已经失灵了」,直到 40 天后接口真返 401。
    public private(set) var lastRenewalError: MinimaxRenewalError?

    /// 下次自动续期的时刻。
    ///
    /// 与 `shouldRenewToday` **同源**:返回的时刻一定是「那个时刻真的会续期」的
    /// 时刻。之前的实现各算各的,会出现面板写着「下次 今天 04:00」、但那一刻
    /// 因为「今天已经续过」根本不会续 —— 用户被误导。
    ///
    /// 三种状态:
    ///  - 今天还没到点   → 今天 04:00
    ///  - 今天已经续过   → 明天 04:00
    ///  - 到点了还没续   → nil(欠一次,下次拉取就补,没有固定时刻可言)
    public var nextRenewalDate: Date? {
        Self.nextRenewalDate(
            now: Date(),
            lastRenewalAt: lastRenewalAt,
            calendar: .current
        )
    }

    /// 可测版本 —— 时间和时区都由调用方给,不依赖真实时钟。
    nonisolated static func nextRenewalDate(
        now: Date,
        lastRenewalAt: Date?,
        calendar: Calendar
    ) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let todayMoment = renewalMoment(on: startOfToday, calendar: calendar) else {
            return nil
        }
        let renewedToday = lastRenewalAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false

        if renewedToday {
            // 今天续过了 → 明天
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                  let tomorrowMoment = renewalMoment(on: tomorrow, calendar: calendar) else {
                return nil
            }
            return tomorrowMoment
        }
        if now < todayMoment {
            return todayMoment
        }
        // 到点了但今天还没续 → 续期处于「待补」状态,发生在下一次拉取时,
        // 不是某个固定时刻。返回 nil,UI 显示「待补续」而不是一个过去的时间。
        return nil
    }

    /// 今天已经过了续期时刻、但今天还没续 —— 自动续期欠着一次。
    ///
    /// 跟 `nextRenewalDate == nil` 配合:两者合起来才能完整表达
    /// 「还没到点 / 已续过等明天 / 到点欠着待补」三种状态。
    public var isRenewalOverdue: Bool {
        Self.isRenewalOverdue(
            now: Date(),
            lastRenewalAt: lastRenewalAt,
            calendar: .current
        )
    }

    /// 可测版本 —— 时间和时区都由调用方给。
    nonisolated static func isRenewalOverdue(
        now: Date,
        lastRenewalAt: Date?,
        calendar: Calendar
    ) -> Bool {
        let startOfToday = calendar.startOfDay(for: now)
        guard let todayMoment = renewalMoment(on: startOfToday, calendar: calendar) else {
            return false
        }
        guard now >= todayMoment else { return false }
        let renewedToday = lastRenewalAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false
        return !renewedToday
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var lastFetchAt: Date?
    /// 有一次刷新撞上了正在飞的请求,被记在这里等当前这次结束后补跑。
    @ObservationIgnored private var pendingRefresh = false

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

    public init() {
        // 从 UserDefaults 恢复上次的续期时间 —— 让「今天续过没」跨重启成立
        let stored = UserDefaults.standard.double(forKey: WidgetSettings.minimaxLastRenewalKey)
        lastRenewalAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

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
    ///
    /// 但不是直接丢弃:续期成功后紧接着的刷新如果正好撞上 5 分钟定时器
    /// 正在飞,直接丢掉就意味着界面数字停在旧值,得再等一整个周期才更新。
    /// 所以记一个待刷新,当前这次结束后补跑一次。
    public func refresh() {
        if inFlight != nil {
            pendingRefresh = true
            return
        }
        let task = Task<Void, Never> { [weak self] in
            await self?.performFetch()
        }
        inFlight = task
    }

    private func performFetch() async {
        defer {
            inFlight = nil
            // 补跑被丢弃的那次刷新
            if pendingRefresh {
                pendingRefresh = false
                refresh()
            }
        }

        let stored: MinimaxCredentials
        switch MinimaxKeychain.load() {
        case .notFound:
            lastError = .notConfigured
            return
        case .unavailable:
            // 钥匙串锁着 / 读不出来 —— 不动 snapshot,只提示解锁
            lastError = .keychainUnavailable
            return
        case .found(let creds):
            guard creds.isValid else {
                lastError = .notConfigured
                return
            }
            stored = creds
            tokenExpiry = MinimaxTokenRenewer.expiry(of: creds.token)
        }

        isFetching = true
        defer { isFetching = false }

        // 拉用量之前先看 token 快不过期 —— 快过期就自动续期。
        let credentials = await renewIfNeeded(stored)

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

    /// 今天这个「续期日」是否还没续过。
    var shouldRenewToday: Bool {
        Self.shouldRenewToday(now: Date(), lastRenewalAt: lastRenewalAt)
    }

    /// 续期策略:当前本地时间已过当天的续期时刻(默认凌晨 4 点),且今天还没续过。
    ///
    /// 用「当天续期时刻」而不是「零点」,是为了避开 0 点前后系统休眠 /
    /// 定时任务抖动。错过这个点也不要紧 —— 下一次拉取会补上,不会漏。
    ///
    /// 续期时刻取的是**本地钟点**(见 `renewalMoment`),不是「零点 + 4 个绝对
    /// 小时」。后者在夏令时切换日会偏:实测 America/New_York 2026 年的 3/8 会
    /// 算到本地 5 点、11/1 会算到 3 点 —— 一年两天时刻算错,还会让依赖
    /// 「3 点 < 续期时刻」的测试在 DST 日间歇性变红。
    ///
    /// 抽成 static 是为了能直接单测这条时间规则,不依赖真实时钟。
    ///
    /// `nonisolated`:这是个纯时间计算,不碰任何 actor 状态。类本身标了
    /// `@MainActor`,不加这个修饰符的话 static 方法也会被主线程隔离,
    /// 测试里就没法同步调用了。
    nonisolated static func shouldRenewToday(now: Date, lastRenewalAt: Date?) -> Bool {
        shouldRenewToday(now: now, lastRenewalAt: lastRenewalAt, calendar: .current)
    }

    /// 带显式日历的重载 —— 测试可以固定时区,结果不受运行机器的时区影响。
    nonisolated static func shouldRenewToday(
        now: Date,
        lastRenewalAt: Date?,
        calendar: Calendar
    ) -> Bool {
        guard let moment = renewalMoment(
            on: calendar.startOfDay(for: now),
            calendar: calendar
        ) else { return false }
        guard now >= moment else { return false }
        guard let lastRenewalAt else { return true }
        return !calendar.isDate(lastRenewalAt, inSameDayAs: now)
    }

    /// 某一天的续期时刻(本地钟点 04:00)。
    ///
    /// `bySettingHour` 表达的是「本地几点」,不是「绝对加 N 小时」——
    /// 差别只在夏令时切换日出现,但那正是最不能出错的地方。
    nonisolated static func renewalMoment(on startOfDay: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: WidgetSettings.minimaxDailyRenewalHour,
            minute: 0,
            second: 0,
            of: startOfDay
        )
    }

    /// 每天固定时间自动续期一次。续期后有效期重置为 +40 天,所以每天续一次
    /// 完全无害 —— 换来的是「用户永远不用管 cookie」。
    ///
    /// 任何一步失败都返回**原凭据**:实测续期不会吊销旧 token,旧 token 还能
    /// 继续用 —— 所以「续期失败」不该把「用量拉取」也一起搞挂,更不该
    /// 让用户丢配置。但失败必须**看得见**:错误记在 `lastRenewalError`,
    /// 设置面板会单独显示一行,不会被用量拉取的成功结果盖掉。
    private func renewIfNeeded(_ credentials: MinimaxCredentials) async -> MinimaxCredentials {
        guard shouldRenewToday else { return credentials }
        do {
            let newToken = try await MinimaxTokenRenewer.renew(token: credentials.token)
            let updated = MinimaxCredentials(token: newToken, groupId: credentials.groupId)
            // 写回 Keychain 成功才用新 token —— 写回失败就继续用旧的
            try MinimaxKeychain.save(updated)
            recordRenewal(at: Date(), token: newToken)
            return updated
        } catch let error as MinimaxRenewalError {
            // 降级:续期失败不影响本次用量拉取,但要让用户看见
            lastRenewalError = error
            return credentials
        } catch {
            lastRenewalError = .transport(error.localizedDescription)
            return credentials
        }
    }

    /// 记录一次成功续期:更新内存状态 + 落盘(供应用重启后恢复)。
    private func recordRenewal(at date: Date, token: String) {
        lastRenewalAt = date
        tokenExpiry = MinimaxTokenRenewer.expiry(of: token)
        lastRenewalError = nil
        UserDefaults.standard.set(
            date.timeIntervalSince1970,
            forKey: WidgetSettings.minimaxLastRenewalKey
        )
    }

    /// 手动触发一次续期(设置面板的「立即续期」按钮)。
    ///
    /// 自动续期每天 04:00 跑一次,用户没法随时验证它是否工作 ——
    /// 这个入口让用户随时能强制走一遍完整链路(换 token → 写回 Keychain →
    /// 刷新用量),把「自动」变成「随时可验」。
    ///
    /// 返回 nil 表示成功;返回字符串是失败原因(可直接显示给用户)。
    @discardableResult
    public func renewNow() async -> String? {
        guard case .found(let creds) = MinimaxKeychain.load(), creds.isValid else {
            return "Keychain 里没有可用的凭据,请先保存"
        }
        do {
            let newToken = try await MinimaxTokenRenewer.renew(token: creds.token)
            let updated = MinimaxCredentials(token: newToken, groupId: creds.groupId)
            try MinimaxKeychain.save(updated)
            recordRenewal(at: Date(), token: newToken)
            // 续期完立刻刷一次用量,让界面上的数字用新 token 更新
            refresh()
            return nil
        } catch let error as MinimaxRenewalError {
            lastRenewalError = error
            return error.errorDescription
        } catch {
            lastRenewalError = .transport(error.localizedDescription)
            return error.localizedDescription
        }
    }
}
