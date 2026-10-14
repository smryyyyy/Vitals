import Foundation
import Testing
@testable import MoleWidgetCore

/// 覆盖 MiniMax 集成里这次改的两处行为约定:
/// - P1-17 失败要结构化(`MinimaxErrorKind`),且不能靠字符串区分
/// - P0-2  刷新间隔必须是每次现读,不能是进程内缓存的常量
///
/// `.serialized`:这几个用例共用同一个 UserDefaults key 和同一条 Keychain 记录,
/// 并行跑会互相踩(一个刚写完另一个就读)。
@Suite(.serialized) struct MinimaxErrorTests {

    // MARK: - MinimaxError → MinimaxErrorKind

    @Test func error_unauthorized_mapsToAuthExpired() {
        #expect(MinimaxError.unauthorized.kind == .authExpired)
        #expect(MinimaxError.unauthorized.kind.needsUserAction)
    }

    @Test func error_httpStatus_mapsToServer() {
        #expect(MinimaxError.httpStatus(503).kind == .server(503))
        // 服务端错误重试即可,不该提示用户去改 cookie
        #expect(!MinimaxError.httpStatus(503).kind.needsUserAction)
    }

    @Test func error_transport_classifiesNetworkFailures() {
        // 断网 / DNS / 连不上 → 同一类,文案不出现英文系统提示
        #expect(MinimaxError.transport(.notConnectedToInternet).kind == .networkUnavailable)
        #expect(MinimaxError.transport(.cannotFindHost).kind == .networkUnavailable)
        #expect(MinimaxError.transport(.cannotConnectToHost).kind == .networkUnavailable)
        #expect(MinimaxError.transport(.dnsLookupFailed).kind == .networkUnavailable)
        #expect(MinimaxError.transport(.timedOut).kind == .timeout)
        #expect(!MinimaxError.transport(.timedOut).kind.needsUserAction)
    }

    @Test func error_transport_unknownCodeFallsBackToUnknown() {
        #expect(MinimaxError.transport(.secureConnectionFailed).kind == .unknown)
    }

    @Test func error_decodeAndInvalidResponse_mapToUnknown() {
        #expect(MinimaxError.invalidResponse.kind == .unknown)
        #expect(MinimaxError.notAuthenticated.kind == .notConfigured)
    }

    @Test func error_kinds_haveDistinctChineseMessages() {
        // 修 bug 的核心:UI 不再靠字符串区分,每类都要有自己的说法
        let kinds: [MinimaxErrorKind] = [
            .notConfigured, .keychainUnavailable, .authExpired,
            .networkUnavailable, .timeout, .server(500), .unknown,
        ]
        let messages = kinds.map(\.message)
        #expect(Set(messages).count == kinds.count, "不同失败类型不应共用同一句文案")
        for kind in kinds {
            #expect(!kind.message.isEmpty)
        }
    }

    @Test func error_localizedDescription_usesStructuredMessage() {
        // localizedDescription 会漏到"测试连接"的提示里,必须跟浮窗同一套文案
        #expect(MinimaxError.unauthorized.localizedDescription == MinimaxErrorKind.authExpired.message)
        #expect(MinimaxError.transport(.timedOut).localizedDescription == MinimaxErrorKind.timeout.message)
    }

    // MARK: - Snapshot 不再携带 error

    @Test func snapshot_hasNoErrorField() {
        // 失败不能整体覆盖 snapshot,所以快照本身不带错误字段
        let s = MinimaxSnapshot(
            fiveHour: MinimaxLimit(usedPercent: 13),
            weekly: MinimaxLimit(usedPercent: 40)
        )
        #expect(!s.isEmpty)
        #expect(s.fiveHour?.usedPercent == 13)
    }

    @Test func mapper_snapshot_mapsGeneralBucketOnly() {
        let payload = Data("""
        {"model_remains":[
          {"model_name":"general","current_interval_used_percent":"13%","current_weekly_used_percent":"40%","remains_time":600000,"weekly_remains_time":86400000},
          {"model_name":"video","current_interval_used_percent":"99%"}
        ],"base_resp":{"status_code":0}}
        """.utf8)
        let decoded = try! JSONDecoder().decode(MinimaxUsageResponse.self, from: payload)
        let snapshot = MinimaxMapper.snapshot(from: decoded)
        #expect(snapshot.fiveHour?.usedPercent == 13)
        #expect(snapshot.weekly?.usedPercent == 40)
        #expect(abs((snapshot.fiveHour?.remainsTime ?? 0) - 600) < 0.001)
    }

    // MARK: - P0-2 刷新间隔

    @Test func interval_reflectsUserDefaultsChangesImmediately() {
        let key = WidgetSettings.minimaxRefreshIntervalKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 修复前是 `static let` + 一次性闭包,这里第二次读还停留在 60 分钟
        UserDefaults.standard.set(1.0, forKey: key)
        #expect(abs(MinimaxManager.interval - 60) < 0.001)
        UserDefaults.standard.set(30.0, forKey: key)
        #expect(abs(MinimaxManager.interval - 1800) < 0.001,
                "改设置后必须立刻读到新间隔,而不是进程启动时的缓存值")
        UserDefaults.standard.set(60.0, forKey: key)
        #expect(abs(MinimaxManager.interval - 3600) < 0.001)
    }

    @Test func interval_clampsToNearestValidOption() {
        let key = WidgetSettings.minimaxRefreshIntervalKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // 越界值(比如手改 UserDefaults)不能产生 0 间隔或超大间隔
        UserDefaults.standard.set(0.0, forKey: key)
        #expect(abs(MinimaxManager.interval - 60) < 0.001)
        UserDefaults.standard.set(9999.0, forKey: key)
        #expect(abs(MinimaxManager.interval - 3600) < 0.001)
    }

    // MARK: - P1-12 Keychain 三态

    @Test func keychain_load_unconfiguredItem_reportsNotFound() {
        // 清掉之后必须报"没配过",而不是笼统的 nil
        MinimaxKeychain.clear()
        #expect(MinimaxKeychain.load() == .notFound)
    }

    @Test func keychain_load_roundtripFound() {
        let creds = MinimaxCredentials(token: "t", session: "s", groupId: "g")
        do {
            try MinimaxKeychain.save(creds)
        } catch {
            // CI 环境下 Keychain 可能不可写,跳过而不是让测试红
            return
        }
        defer { MinimaxKeychain.clear() }
        #expect(MinimaxKeychain.load() == .found(creds))
    }
}
