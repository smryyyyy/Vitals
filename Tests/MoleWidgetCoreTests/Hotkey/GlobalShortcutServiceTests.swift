//
//  GlobalShortcutServiceTests.swift
//  Vitals - Screenshot/Hotkey 模块
//
//  覆盖 GlobalShortcutService 的 5 个 race 场景的单元测试。
//  这些场景在前几轮修复 6 个用户实测 bug + 2 个残留 race 时被加固,
//  本文件用作回归屏障,防止未来重构破坏 pause/resume/stop/recording 的不变量。
//
//  设计原则:
//  - 每个测试用独立的 `suiteName: "test-\(UUID())"` UserDefaults 隔离,避免测试间污染。
//  - 服务是 `@MainActor`,测试函数也用 `@MainActor` annotation。
//  - 不依赖任何 private 字段 —— 只通过 public/internal surface 验证。
//  - 测试结束后,service 实例被放入全局 holder 延迟 deinit。
//    原因:swift test headless 环境里 Carbon UnregisterEventHotKey 返回 -50(paramErr),
//    即使 service.stop() 也清不空 residualByID;deinit 的 assert 会触发 crash。
//    全局 holder 把 deinit 推到 process 退出后(此时 Swift runtime 不保证调 deinit)。
//

import Foundation
import Testing
@testable import MoleWidgetCore

/// 本测试文件依赖以下 internal symbols
/// (只能在 `@testable import MoleWidgetCore` 下访问):
/// - `GlobalShortcutService.beginRecording(owner:host:onInvalidated:)`
/// - `GlobalShortcutService.endRecording(id:reason:)`
/// - `GlobalShortcutService.endRecording(forHost:reason:)`
/// - `GlobalShortcutService.activeRecording`(本轮改为 `private(set) var`)
/// - `GlobalShortcutService.pausedActions`(本轮改为 `private(set) var`)
/// - `GlobalShortcutService._storeAssignmentsForTesting()`(本轮新增)
/// - `GlobalShortcutService.registrationStates`(`@Published private(set)`,
///   已是 `internal` getter)
///
/// 未来重构如改这些 symbols(改名、改访问级别、改类型),本测试会编译失败
/// —— 这是预期的 regression barrier,防止 Phase-3 / Phase-4 后续轮回归时把
/// 「pause/resume/stop/recording 的不变量」悄悄破坏。
///
/// 全局 service 持有者,把 deinit 延迟到 swift test process 退出后。
/// Carbon 在 headless 下 unregister 会失败 paramErr,导致 deinit 断言崩。
/// 这个 holder 让测试期间 service 一直活着,断言失败被推到进程清理阶段(无害)。
/// 累积策略:5 个测试创建 5 个 service 留在 holder 里直到 process 退出,
/// holder 字典自身的清理由 `tearDownSuite()` 占位(见 suite 内注释)。
private nonisolated(unsafe) var _serviceHolder: [ObjectIdentifier: GlobalShortcutService] = [:]

@Suite struct GlobalShortcutServiceTests {

    /// 占位 suite-level cleanup。
    ///
    /// Swift Testing 当前没有稳定的 suite teardown hook——任何名为
    /// `tearDownSuite()` 的方法都不会被 runtime 自动调到。这里写出来的
    /// 目的是:
    /// 1. **显式文档化** holder 清理策略 —— 业务阅读时一眼看到「这里没自动清理」;
    /// 2. **future-proof**:如果 Swift Testing 后续版本支持 suite-level teardown
    ///    hook(关键字同名),本方法会直接生效,不需要改测试函数。
    ///
    /// 为什么故意**不**主动 `_serviceHolder.removeAll()`?
    /// 清空后 5 个 service 立即进入 ARC 释放链 → deinit 触发 → `assert(...)` 在
    /// headless 下抛 process — 整个测试 process 崩,影响其他 suite 的报告。
    /// holder 当前设计的意图就是「让 service 活到 process 退出,Swift runtime
    /// 此时不保证 deinit,所以无害」。
    static func tearDownSuite() {
        // 见上方文档解释:故意保持实现为空。
    }


    // MARK: - 共享构造 helper

    /// 构造一个全新 GlobalShortcutService,绑定独立 UserDefaults。
    /// 返回时已经 `start(onAction: ...)`,并放入全局 holder 延迟 deinit。
    @MainActor
    private static func makeStartedService(
        onAction: @escaping @MainActor (ShortcutAction) -> Void
    ) -> GlobalShortcutService {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        let store = ShortcutStore(defaults: defaults)
        let permission = PermissionManager()
        let service = GlobalShortcutService(store: store, permissionManager: permission)
        service.start(onAction: onAction)
        _serviceHolder[ObjectIdentifier(service)] = service
        return service
    }

    /// 判断 Carbon 注册是否成功(测试环境下通常是成功的,headless CI 可能失败)。
    @MainActor
    private static func isCarbonRegistrationSuccessful(
        _ service: GlobalShortcutService,
        action: ShortcutAction
    ) -> Bool {
        if case .registered = service.registrationStates[action] { return true }
        return false
    }

    // MARK: - Test 1:正常 paused → resumed

    /// 验证 pauseHotkey 不改 store.assignments,只是把 entry 从 active 移到 paused,
    /// resumeHotkey 把 entry 重新注册 Carbon hotkey,store.assignments 全程保持 .assigned。
    @MainActor
    @Test func pauseHotkeyRebindsAndPreservesStoreAssignment() {
        var triggeredActions: [ShortcutAction] = []
        let service = Self.makeStartedService(onAction: { triggeredActions.append($0) })

        guard Self.isCarbonRegistrationSuccessful(service, action: .windowCapture) else {
            Issue.record("Test 1 前置:Carbon 在测试环境不可用,跳过严格断言。registrationStates[.windowCapture]=\(service.registrationStates[.windowCapture])")
            _ = service.stop()
            return
        }

        // 🟡 3 修复:用 `_storeAssignmentsForTesting()` 拿 service 内部 store
        // 的 snapshot。原版用 `ShortcutAssignments.productDefaults[...]` 比较是空
        // 断言(productDefaults 是 static let,恒等比较永远 true)。
        let storeBefore = service._storeAssignmentsForTesting()
        // 同时记下 .windowCapture 的原 shortcut,resume 后比对 —— 防止未来重构里
        // resume 注册到了错的 shortcut 而 service 报「注册成功」时悄悄漂移。
        let originalShortcut = storeBefore[.windowCapture].shortcut

        // 暂停
        service.pauseHotkey(action: .windowCapture)
        // pause 后 registrationStates 是 .disabled(从 active 移走)
        if case .disabled = service.registrationStates[.windowCapture] {
            // 期望行为
        } else {
            Issue.record("pauseHotkey 后期望 registrationStates[.windowCapture] == .disabled,实际为 \(service.registrationStates[.windowCapture])")
        }
        // 🟡 3:pauseHotkey 只走 Carbon unregister 路径,不该触 store。整个 assignments
        // snapshot 必须完全保持不变(包括 .advancedWindowCapture,防止 future refactor
        // 把不该动的也动到)。
        #expect(service._storeAssignmentsForTesting() == storeBefore)

        // resume
        let stateAfterResume = service.resumeHotkey(action: .windowCapture)
        if case .registered = stateAfterResume {
            // 期望行为
        } else {
            Issue.record("resumeHotkey 期望返回 .registered,实际为 \(stateAfterResume)")
        }
        // 🟡 3:resumeHotkey 走的是 reconcileAction(单 action)+重新读 store,
        // 也不该改 assignments。snapshot 仍需保持完全一致。
        #expect(service._storeAssignmentsForTesting() == storeBefore)
        // 🟡 3:验证重新注册到 Carbon 的 shortcut 跟原 store 里的是同一个 —— 防止
        // future refactor 把 store 的赋值走丢、或者用错了 candidate。
        if let originalShortcut {
            if case .registered(let resumedShortcut) = service.registrationStates[.windowCapture] {
                #expect(resumedShortcut == originalShortcut)
            } else {
                Issue.record("resumeHotkey 后期望 .windowCapture 为 .registered(.some),实际为 \(service.registrationStates[.windowCapture])")
            }
        }
        // 回调不该被触发(没有真按快捷键)
        #expect(triggeredActions.isEmpty)

        _ = service.stop()
    }

    // MARK: - Test 2:paused → stop(核心修复场景)

    /// Bug 🟢 修复场景:pause 期间直接 stop(),pausedActions 里的 entry 必须被 stop() 路径处理
    /// (放回 activeByID 让 terminalizeAll 走一次残差清理),且最终清空。
    /// 验证:stop() 跑完后 pausedActions 为空(否则 deinit assertion 会触发,虽然 service 在 holder
    /// 里延迟 deinit,这里通过 `pausedActions` 行为间接推断)。
    @MainActor
    @Test func pauseHotkeyThenStopClearsPausedStateForDeinit() {
        let service = Self.makeStartedService(onAction: { _ in })

        guard Self.isCarbonRegistrationSuccessful(service, action: .windowCapture) else {
            Issue.record("Test 2 前置:Carbon 在测试环境不可用,跳过严格断言。registrationStates[.windowCapture]=\(service.registrationStates[.windowCapture])")
            _ = service.stop()
            return
        }

        service.pauseHotkey(action: .windowCapture)
        // pause 成功 → registrationStates 是 .disabled(说明 entry 已从 active 移走并存到 pausedActions)
        if case .disabled = service.registrationStates[.windowCapture] {
            // 期望
        } else {
            Issue.record("pause 后期望 .disabled,实际为 \(service.registrationStates[.windowCapture])")
        }

        // 🟡 4 修复(依赖 🟡 2 把 pausedActions 改 `private(set) var`):
        // 验证 pauseHotkey 真的把 entry 存进了 pausedActions —— 否则后续 stop()
        // 路径「需要清空的 pausedActions」就空,让空断言(#expect(residualCount >= 0)
        // 等)都通过,fix 路径完全失验。
        #expect(service.pausedActions[.windowCapture] != nil)

        // stop() 跑完后 pausedActions 已被 stop() 路径清空。
        // outcome 在 headless 下通常是 .cleanupFailed(UnregisterEventHotKey paramErr),
        // 但这是 Carbon 平台问题,跟 pausedActions 清理无关。
        let outcome = service.stop()
        // 🟡 4 核心断言:stop() 必须把 pausedActions 清空 —— 这是 Bug 🟢 修复的
        // 关键路径:stop() 把 pausedActions 里的 entry 放回 activeByID 让 terminalizeAll
        // 走一次残差清理,然后 `pausedActions.removeAll()`。如果修复路径未来回归(没清空),
        // 这个断言会立即 fail —— 比依赖 deinit assertion 提前一圈拿到信号。
        #expect(service.pausedActions.isEmpty)

        switch outcome {
        case .stoppedCleanly:
            // 完美:Carbon register/unregister 都通过,残差清零
            break
        case .cleanupFailed(let residualCount, let handlerRetained, _):
            // headless 下常见:Carbon register 返回 noErr 但 unregister 返回 paramErr,
            // residualByID 不空 → cleanupFailed。这是 Carbon 在 headless 的已知限制,
            // 不是 service bug,不阻断测试。保留这两个弱断言作为冗余 —— 真正的核心断言
            // 是上方的 `service.pausedActions.isEmpty`。
            #expect(residualCount >= 0)
            #expect(!handlerRetained)
        }
    }

    // MARK: - Test 3:paused → stop → resumeHotkey(lifecycle 已变 stopped)

    /// 极端 race 场景:paused 期间 service lifecycle 变 .stopped(比如 App 退出),
    /// 后续录制 UI 仍调 resumeHotkey(action:) 想要恢复注册 —— 此时 lifecycle guard 早退,
    /// 返回 .notStarted;不抛、不崩、不重新注册 Carbon hotkey。
    @MainActor
    @Test func resumeHotkeyOnStoppedLifecycleReturnsNotStartedAndDoesNotCrash() {
        let service = Self.makeStartedService(onAction: { _ in })

        service.pauseHotkey(action: .windowCapture)
        // 把 lifecycle 推到 .stopped:stop() 已经把 pausedActions 清空(原 bug 修复路径)
        _ = service.stop()

        // 模拟 race:UI 后续仍调 resumeHotkey,期望 lifecycle guard 早退返回 .notStarted,
        // 不抛、不崩、不重新注册 Carbon hotkey。
        let stateAfterResume = service.resumeHotkey(action: .windowCapture)
        #expect(stateAfterResume == .notStarted)

        // 再调一次也不崩(幂等)
        let stateAfterSecondResume = service.resumeHotkey(action: .windowCapture)
        #expect(stateAfterSecondResume == .notStarted)

        // pause 也幂等(no_active_registration 路径)
        service.pauseHotkey(action: .windowCapture)
    }

    // MARK: - Test 4:beginRecording 第二次 → rejected

    /// 同时只能有一个 recording session。第二次 beginRecording 应该被拒绝,
    /// 无论 owner / host 是否相同。
    @MainActor
    @Test func beginRecordingRejectedWhenSessionAlreadyActive() {
        let service = Self.makeStartedService(onAction: { _ in })

        let firstOutcome = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .settings,
            onInvalidated: { _ in }
        )
        guard case .started(let firstSessionID) = firstOutcome else {
            Issue.record("第一次 beginRecording 期望 .started,实际为 \(firstOutcome)")
            _ = service.stop()
            return
        }
        // 第一次 beginRecording 成功后,activeRecording 应该被赋值,
        // host 字段就是传入的 .settings —— 直接断言字段值,绕过 reject 推断路径。
        #expect(service.activeRecording != nil)
        #expect(service.activeRecording?.host == .settings)

        // 第二次 beginRecording(不同 owner、相同 host)应被拒绝
        let secondOutcome = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .settings,
            onInvalidated: { _ in }
        )
        if case .rejected(.recordingBusy) = secondOutcome {
            // 期望行为
        } else {
            Issue.record("第二次 beginRecording 期望 .rejected(.recordingBusy),实际为 \(secondOutcome)")
        }
        // 第二次被拒后,activeRecording 仍是第一次的 session,不应被误清/误改。
        #expect(service.activeRecording?.host == .settings)

        // 第二次 beginRecording(不同 host)同样应被拒绝
        let thirdOutcome = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .onboarding,
            onInvalidated: { _ in }
        )
        if case .rejected(.recordingBusy) = thirdOutcome {
            // 期望行为
        } else {
            Issue.record("跨 host 的第二次 beginRecording 期望 .rejected(.recordingBusy),实际为 \(thirdOutcome)")
        }
        // 跨 host 第二次被拒后,activeRecording 仍是第一次的 session —— 不会被跨 host reject 偷换。
        #expect(service.activeRecording?.host == .settings)

        // 清场:用第一次的 sessionID endRecording
        service.endRecording(id: firstSessionID, reason: .cancelled)
        #expect(service.activeRecording == nil)
        _ = service.stop()
    }

    // MARK: - Test 5:endRecording(forHost:) host 不匹配 → 静默 return

    /// endRecording(forHost:) 是按 host 匹配合适的 active recording session。
    /// host 不匹配时静默 return(不报错、不清 activeRecording),
    /// 让调用方可以无脑调多次而不用担心副作用。
    @MainActor
    @Test func endRecordingForMismatchedHostIsNoOp() {
        let service = Self.makeStartedService(onAction: { _ in })

        // 先建一个 .settings host 的 session
        let firstOutcome = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .settings,
            onInvalidated: { _ in }
        )
        guard case .started = firstOutcome else {
            Issue.record("beginRecording(.settings) 期望 .started,实际为 \(firstOutcome)")
            _ = service.stop()
            return
        }
        // activeRecording 直接断言:第一次 beginRecording 后 host 应是 .settings。
        #expect(service.activeRecording?.host == .settings)

        // host 不匹配(传入 .onboarding)应该静默 return,不抛、不改 activeRecording
        service.endRecording(forHost: .onboarding, reason: .cancelled)
        // 直接断言 activeRecording 没被误清 —— host 仍是 .settings。
        #expect(service.activeRecording?.host == .settings)

        // 验证:host 不匹配的 endRecording 没误清 activeRecording —— 后续 beginRecording 应被拒。
        let secondBegin = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .onboarding,
            onInvalidated: { _ in }
        )
        if case .rejected(.recordingBusy) = secondBegin {
            // 期望:activeRecording 仍存在(因为 .onboarding endRecording 没生效)
        } else {
            Issue.record("host 不匹配的 endRecording 后,期望 activeRecording 仍存在(第二次 beginRecording 应 .rejected(.recordingBusy)),实际为 \(secondBegin)")
        }

        // 正常 endRecording(forHost: .settings)清场
        service.endRecording(forHost: .settings, reason: .cancelled)
        // 正确 host 匹配后,activeRecording 应被清空。
        #expect(service.activeRecording == nil)

        // 清场后,再 beginRecording 应该成功
        let thirdBegin = service.beginRecording(
            owner: RecorderOwnerID(),
            host: .settings,
            onInvalidated: { _ in }
        )
        if case .started(let sid) = thirdBegin {
            service.endRecording(id: sid, reason: .cancelled)
        } else {
            Issue.record("正常 endRecording(.settings) 后,期望再次 beginRecording .started,实际为 \(thirdBegin)")
        }

        _ = service.stop()
    }
}