//
//  GlobalShortcutService.swift
//  Mio
//
//  The single owner of Carbon's global-hotkey handler and registrations.
//

import Carbon.HIToolbox
import Combine
import Foundation
import OSLog

private nonisolated enum CarbonShortcutConstants {
    static let signature: OSType = {
        let bytes: [UInt8] = [0x56, 0x74, 0x6C, 0x73] // "Vtls" (Vitals)
        return UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
    }()
}

private nonisolated func mioGlobalShortcutEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    guard hotKeyID.signature == CarbonShortcutConstants.signature else {
        return OSStatus(eventNotHandledErr)
    }
    guard Thread.isMainThread else { return OSStatus(eventNotHandledErr) }

    let service = Unmanaged<GlobalShortcutService>
        .fromOpaque(userData)
        .takeUnretainedValue()

    // SAFETY: Carbon application-event callbacks are expected on the main
    // thread, and the runtime guard above proves that fact before entering
    // this target's MainActor-isolated service synchronously.
    return MainActor.assumeIsolated {
        service.handleCarbonEvent(registrationID: hotKeyID.id)
    }
}

@MainActor
public final class GlobalShortcutService: ObservableObject {
    private enum Lifecycle: Equatable {
        case constructed
        case started
        case stopped
    }

    private enum HandlerState {
        case notInstalled
        case installed(EventHandlerRef)
        case failed(ShortcutRegistrationFailure)
        case cleanupFailed(EventHandlerRef, ShortcutRegistrationFailure)
    }

    /// 注册条目(pause/resume 路径内部的协调用结构)。
    ///
    /// `internal` 而非 `private` 是为了配合 `pausedActions` 改成 `private(set)`:
    /// Swift 编译规则「property 的 access level 不能比其类型更高」——
    /// `private(set)` 的 getter 是 internal(default),要求类型至少是 internal。
    /// 这是第 6 轮复审要求加的回归屏障的配套可见性扩张 —— 但本类型的所有字段
    /// 仍没有 public 暴露路径(module 外只通过 `pausedActions` getter 间接拿到
    /// 引用,且 getter 也只在 `@testable import` 下可见,业务代码请勿引用)。
    struct RegistrationEntry {
        let action: ShortcutAction
        let shortcut: Shortcut
        let id: UInt32
        let ref: EventHotKeyRef
    }

    /// Recording session 内部表示(同 `RegistrationEntry` 升 `internal` 的原因)。
    struct RecordingSession {
        let id: RecordingSessionID
        let owner: RecorderOwnerID
        let host: ShortcutRecordingHost
        let startedAt: ContinuousClock.Instant
        let onInvalidated: @MainActor (RecordingEndReason) -> Void
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.iSoldLeo.Mio",
        category: "Hotkeys"
    )

    @Published private(set) var registrationStates: [ShortcutAction: ShortcutRegistrationState]
    @Published private(set) var presentationRevision: UInt64 = 0

    private let store: ShortcutStore
    private let permissionManager: PermissionManager
    private var lifecycle: Lifecycle = .constructed
    private var handlerState: HandlerState = .notInstalled
    private var activeByID: [UInt32: RegistrationEntry] = [:]
    private var activeIDByAction: [ShortcutAction: UInt32] = [:]
    private var residualByID: [UInt32: RegistrationEntry] = [:]
    private var nextRegistrationID: UInt32 = 1
    private var lifecycleEpoch: UInt64 = 0
    /// Bug 🟢 修复:追踪被 `pauseHotkey` 暂停但还没 resume 的 action 及其 entry。
    /// 极端 lifecycle race 场景:paused 期间 service lifecycle 变 stopped(比如 App 退出),
    /// 后续 `resumeHotkey` 调 `reconcileAction` 时 lifecycle guard 早退,不会重新注册
    /// Carbon hotkey —— 没有这个字段的话,这些 entry 完全脱离 service 状态跟踪,
    /// deinit 断言不触发(因为 activeByID 是空的)、Carbon 端注册由 OS 兜底但 service
    /// 内部状态不一致。记录 entry 让 stop() 路径能放回 activeByID 让 terminalizeAll 处理,
    // resumeHotkey 无论 lifecycle 状态都清掉对应 action,避免 stale 状态。
    //
    /// `private(set)`(getter 自动 internal)让 `GlobalShortcutServiceTests` 能
    /// 直接断言 `#expect(service.pausedActions.isEmpty)` 验证 stop() 路径清理完整
    /// —— 这是第 6 轮复审要求加的回归屏障。setter 仍是 private,业务侧不会误写。
    private(set) var pausedActions: [ShortcutAction: RegistrationEntry] = [:]
    /// 当前活跃的 recording session。
    ///
    /// `private(set)` 是为了让 `GlobalShortcutServiceTests` 能直接断言
    /// `#expect(service.activeRecording != nil)` 做更强回归屏障(替换原本只能
    /// 间接通过 `beginRecording` rejection 推断 activeRecording 状态的脆弱断言)。
    /// 业务侧不要访问此字段 —— 改用 `beginRecording` / `endRecording` 等
    /// 公共 surface。
    private(set) var activeRecording: RecordingSession?
    private var onAction: (@MainActor (ShortcutAction) -> Void)?
    private var inputSourceObserver: NSObjectProtocol?
    /// 订阅 store.assignments 变化的 Combine sink。
    /// 关键:Settings UI 改快捷键 → ShortcutStore 写盘 + 触发 @Published → 收到通知后
    /// `reconcile(reason: .storeChanged)` 重新注册 hotkey。
    private var storeSubscription: AnyCancellable?
    /// Combine 订阅持有的 bag,与订阅生命周期等长,清空时一起释放。
    private var storeCancellables: Set<AnyCancellable> = []
    /// Bug 1-A 修复:监听 `permissionManager.$accessibilityDecision`,非授权 → 授权 转换时
    /// 触发 reconcile 让 Carbon hotkey 重注册。start() 时装、stop() 时释放,
    /// 跟 `inputSourceObserver` 同生命周期模式。
    private var permissionSubscription: AnyCancellable?

    public init(store: ShortcutStore, permissionManager: PermissionManager) {
        self.store = store
        self.permissionManager = permissionManager
        self.registrationStates = Dictionary(
            uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, .notStarted) }
        )
        // 订阅 assignments 变化,UI 改快捷键后让 service 真正刷新 Carbon hotkey。
        // dropFirst 跳过 init 时的初值触发 —— start() 时再统一 reconcile。
        store.$assignments
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.handleAssignmentsChanged()
            }
            .store(in: &storeCancellables)
    }

    public func start(onAction: @escaping @MainActor (ShortcutAction) -> Void) {
        switch lifecycle {
        case .constructed:
            lifecycle = .started
        case .started:
            Self.logger.debug("event=shortcut.service.start result=ignored reason=already_started")
            return
        case .stopped:
            Self.logger.error("event=shortcut.service.start result=rejected reason=stopped")
            return
        }

        lifecycleEpoch &+= 1
        self.onAction = onAction
        installInputSourceObserver(epoch: lifecycleEpoch)

        guard installHandlerIfNeeded() == nil else {
            projectHandlerFailureToAssignedActions()
            Self.logger.error("event=shortcut.service.start result=handler_failed")
            return
        }

        // Bug 1-A 修复:handler 安装成功后再订阅 AX 变化,避免 reconcile 在 handler 未安装时被触发。
        installAccessibilityObserver()

        for action in ShortcutAction.allCases {
            _ = reconcileAction(action, reason: "start")
        }
        Self.logger.info(
            "event=shortcut.service.start result=started desired_count=\(self.assignedActionCount, privacy: .public)"
        )
    }

    public func stop() -> ShortcutStopOutcome {
        if lifecycle != .stopped {
            lifecycle = .stopped
            lifecycleEpoch &+= 1
            onAction = nil

            if let session = takeActiveRecording() {
                logRecordingEnded(session, reason: .serviceStopped)
                session.onInvalidated(.serviceStopped)
            }

            // Bug 🟢 修复:在 terminalizeAllActiveRegistrations() 之前,把 pausedActions
            // 里所有 action 的 entry 放回 activeByID,让 terminalizeAll 路径统一处理。
            // 极端 lifecycle race 场景:paused 期间 lifecycle 变 stopped(比如 App 退出),
            // 这些 entry 已经从 activeByID 移走且 Carbon 端已 unregister,但如果 pauseHotkey
            // 失败(entry 在 residualByID),这里再放回 activeByID 让 terminalizeAll 走
            // 一次残差清理路径,保证 stop() 覆盖到所有曾经注册过的 entry。
            for (pausedAction, pausedEntry) in pausedActions {
                if activeByID[pausedEntry.id] == nil {
                    activeByID[pausedEntry.id] = pausedEntry
                    activeIDByAction[pausedAction] = pausedEntry.id
                }
            }
            pausedActions.removeAll()

            removeInputSourceObserver()
            // Bug 1-A 修复:跟 inputSourceObserver 同步释放 AX 订阅。
            removeAccessibilityObserver()
            terminalizeAllActiveRegistrations()
        }

        var failures: [ShortcutRegistrationFailure] = []
        failures.append(contentsOf: releaseResidualRegistrations())
        if let failure = removeHandlerIfPresent() {
            failures.append(failure)
        }

        let handlerRetained: Bool
        switch handlerState {
        case .installed, .cleanupFailed: handlerRetained = true
        case .notInstalled, .failed: handlerRetained = false
        }

        if failures.isEmpty, residualByID.isEmpty, !handlerRetained {
            Self.logger.info("event=shortcut.service.stop result=stopped_cleanly residual_count=0 handler_retained=false")
            return .stoppedCleanly
        }

        Self.logger.error(
            "event=shortcut.service.stop result=cleanup_failed residual_count=\(self.residualByID.count, privacy: .public) handler_retained=\(handlerRetained, privacy: .public) failure_count=\(failures.count, privacy: .public)"
        )
        return .cleanupFailed(
            residualRegistrationCount: residualByID.count,
            handlerRetained: handlerRetained,
            failures: failures
        )
    }

    func beginRecording(
        owner: RecorderOwnerID,
        host: ShortcutRecordingHost,
        onInvalidated: @escaping @MainActor (RecordingEndReason) -> Void
    ) -> BeginRecordingOutcome {
        guard lifecycle == .started else {
            Self.logger.notice(
                "event=shortcut.recording.rejected owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public) reason=service_not_started"
            )
            return .rejected(.serviceNotStarted)
        }
        guard activeRecording == nil else {
            Self.logger.notice(
                "event=shortcut.recording.rejected owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public) reason=recording_busy"
            )
            return .rejected(.recordingBusy)
        }

        let session = RecordingSession(
            id: RecordingSessionID(),
            owner: owner,
            host: host,
            startedAt: ContinuousClock().now,
            onInvalidated: onInvalidated
        )
        activeRecording = session
        Self.logger.info(
            "event=shortcut.recording.started session_id=\(session.id.rawValue.uuidString, privacy: .public) owner_id=\(owner.rawValue.uuidString, privacy: .public) host=\(host.rawValue, privacy: .public)"
        )
        return .started(session.id)
    }

    func endRecording(id: RecordingSessionID, reason: RecordingEndReason) {
        guard activeRecording?.id == id, let session = takeActiveRecording() else {
            Self.logger.debug(
                "event=shortcut.recording.end result=ignored reason=stale_session requested_session_id=\(id.rawValue.uuidString, privacy: .public)"
            )
            return
        }
        logRecordingEnded(session, reason: reason)
    }

    func endRecording(forHost host: ShortcutRecordingHost, reason: RecordingEndReason) {
        guard activeRecording?.host == host, let session = takeActiveRecording() else {
            Self.logger.debug(
                "event=shortcut.recording.host_end result=ignored requested_host=\(host.rawValue, privacy: .public) requested_reason=\(reason.rawValue, privacy: .public) reason=no_matching_session"
            )
            return
        }
        logRecordingEnded(session, reason: reason)
        session.onInvalidated(reason)
    }

    func update(
        action: ShortcutAction,
        candidate: Shortcut,
        sessionID: RecordingSessionID
    ) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording?.id == sessionID else { return .rejectedStaleSession }

        if let failure = ShortcutValidator.validate(
            action: action,
            candidate: candidate,
            in: store.assignments
        ) {
            logValidationFailure(action: action, failure: failure)
            return .rejectedValidation(failure)
        }

        if store.assignments[action].shortcut == candidate,
           case .registered(candidate)? = registrationStates[action] {
            return .applied(.registered(candidate))
        }

        var candidateAssignments = store.assignments
        candidateAssignments[action] = .assigned(candidate)
        switch store.commit(candidateAssignments) {
        case .success:
            return .applied(reconcileAction(action, reason: "assignment_changed"))
        case let .failure(failure):
            return .rejectedStore(failure)
        }
    }

    public func disable(action: ShortcutAction) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording == nil else { return .rejectedRecordingActive }

        var candidateAssignments = store.assignments
        candidateAssignments[action] = .disabled
        switch store.commit(candidateAssignments) {
        case .success:
            return .applied(reconcileAction(action, reason: "disabled"))
        case let .failure(failure):
            return .rejectedStore(failure)
        }
    }

    public func retryRegistration(action: ShortcutAction) -> ShortcutMutationOutcome {
        guard lifecycle == .started else { return .rejectedServiceNotStarted }
        guard activeRecording == nil else { return .rejectedRecordingActive }
        return .applied(reconcileAction(action, reason: "explicit_retry"))
    }

    /// 临时 unregister Carbon hotkey,**不**改 store,也不触发 reconcile。
    /// 用于「录制快捷键」瞬间确保旧快捷键按下不会触发截图:不走 store sink
    /// 链路(`disable` 走的是 sink → reconcile 路径,Combine scheduler 有微秒级
    /// 延迟,Carbon 事件队列里已排队的 kEventHotKeyPressed 可能赶在
    /// `UnregisterEventHotKey` 完成前被 dispatch,导致旧快捷键仍触发)。
    /// 调用方负责在适当时机调 `resumeHotkey(action:)` 重新注册。
    public func pauseHotkey(action: ShortcutAction) {
        guard lifecycle == .started else {
            Self.logger.notice(
                "event=shortcut.pause result=ignored action=\(action.rawValue, privacy: .public) reason=service_not_started"
            )
            return
        }
        guard let activeID = activeIDByAction[action],
              let entry = activeByID[activeID] else {
            Self.logger.debug(
                "event=shortcut.pause result=ignored action=\(action.rawValue, privacy: .public) reason=no_active_registration"
            )
            return
        }
        // 立刻从 active 表里移除,这样 Carbon 事件回调即便在 UnregisterEventHotKey
        // 完成前 dispatch,`handleCarbonEvent` 也会因为 activeByID[registrationID]
        // 已经为 nil 而走 residual/unknown 路径,不再触发 onAction。
        activeByID.removeValue(forKey: activeID)
        activeIDByAction.removeValue(forKey: action)

        let status = UnregisterEventHotKey(entry.ref)
        if status != noErr {
            // unregister 失败时把 entry 放回 residualByID,跟现有 unregisterActive 模式一致。
            residualByID[activeID] = entry
            registrationStates[action] = .failed(
                desired: store.assignments[action],
                failure: ShortcutRegistrationFailure.platform(
                    operation: .unregister,
                    osStatus: status
                )
            )
            logUnregistration(entry: entry, status: status, ownershipAfter: "residual_after_pause")
            Self.logger.error(
                "event=shortcut.pause result=failed action=\(action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public) os_status=\(status, privacy: .public)"
            )
            return
        }
        // 同步更新 registrationStates:按 store 当前的 assignment,如果是 .assigned
        // 则回到 .disabled 状态(避免 UI 显示 .registered 但实际 Carbon 没注册)。
        registrationStates[action] = .disabled
        // Bug 🟢 修复:记录 paused entry,让 stop() 路径能感知到这些已经 unregister 但
        // 还没被 resume 重新注册的 entry。极端 lifecycle race 下,resumeHotkey 的
        // reconcileAction 会被 lifecycle guard 早退,pausedActions 留作这次「录制意图
        // 未完成」的信号,stop() 时把 entry 放回 activeByID 让 terminalizeAll 处理
        // (虽然 Carbon 端已 unregister 成功,但放进 residualByID 让 releaseResidual
        // 再次清理是幂等且保守的)。
        pausedActions[action] = entry
        logUnregistration(entry: entry, status: noErr, ownershipAfter: "released_by_pause")
        Self.logger.info(
            "event=shortcut.pause result=paused action=\(action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public)"
        )
    }

    /// 重新注册 action 对应的 Carbon hotkey,从 store 读当前 shortcut。
    /// 用于「录制快捷键结束」后恢复 hotkey 注册;等价于该 action 的一次
    /// reconcile,但走单一 action 路径而不是 reconcile-all。
    public func resumeHotkey(action: ShortcutAction) -> ShortcutRegistrationState {
        // Bug 🟢 修复:无论 lifecycle 状态,都先把 action 从 pausedActions 移除。
        // 这是极端 lifecycle race 的关键:即使 lifecycle 已变成 .stopped,
        // resumeHotkey 被延迟调用,也要把 paused 状态清掉,避免 stop() / deinit 时
        // 还残留这个 entry 造成状态不一致。
        pausedActions.removeValue(forKey: action)
        guard lifecycle == .started else {
            Self.logger.notice(
                "event=shortcut.resume result=ignored action=\(action.rawValue, privacy: .public) reason=service_not_started"
            )
            return .notStarted
        }
        let state = reconcileAction(action, reason: "resume_after_recording")
        Self.logger.info(
            "event=shortcut.resume result=reconciled action=\(action.rawValue, privacy: .public) state=\(Self.stateKind(state), privacy: .public)"
        )
        return state
    }

    private static func stateKind(_ state: ShortcutRegistrationState) -> String {
        switch state {
        case .notStarted: return "not_started"
        case .disabled: return "disabled"
        case .registered: return "registered"
        case .failed: return "failed"
        }
    }

    /// store.assignments 变化时由 Combine sink 回调。
    /// 已 started 的服务做一次 reconcile,未 started 的直接返回(start() 时会全量 reconcile)。
    private func handleAssignmentsChanged() {
        guard lifecycle == .started else { return }
        // 录制中跳过 —— 用户正在录快捷键时不能让 reconcile 把临时状态清掉。
        guard activeRecording == nil else { return }
        _ = reconcile(reason: .storeChanged)
    }

    public func reconcile(reason: ShortcutReconcileReason) -> ShortcutReconcileOutcome {
        guard lifecycle == .started else { return .serviceStopped }
        let startedAt = ContinuousClock().now

        if let failure = installHandlerIfNeeded() {
            projectHandlerFailureToAssignedActions()
            logReconcile(reason: reason, outcome: "failed", startedAt: startedAt)
            return .failed(failure)
        }

        var failedActions: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            if case .failed = reconcileAction(action, reason: reason.rawValue) {
                failedActions.append(action)
            }
        }

        if failedActions.isEmpty {
            logReconcile(reason: reason, outcome: "healthy", startedAt: startedAt)
            return .healthy
        }

        logReconcile(reason: reason, outcome: "degraded", startedAt: startedAt)
        return .degraded(failedActions: failedActions)
    }

    fileprivate func handleCarbonEvent(registrationID: UInt32) -> OSStatus {
        guard lifecycle == .started else {
            logDroppedEvent(registrationID: registrationID, action: nil, reason: "service_stopped")
            return noErr
        }
        guard let entry = activeByID[registrationID] else {
            let reason = residualByID[registrationID] == nil ? "unknown_id" : "residual_id"
            logDroppedEvent(registrationID: registrationID, action: nil, reason: reason)
            return noErr
        }
        guard activeRecording == nil else {
            logDroppedEvent(
                registrationID: registrationID,
                action: entry.action,
                reason: "recording_paused"
            )
            return noErr
        }

        Self.logger.info(
            "event=shortcut.dispatched action=\(entry.action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public)"
        )
        onAction?(entry.action)
        return noErr
    }

    isolated deinit {
        assert(lifecycle != .started, "GlobalShortcutService deinitialized before stop().")
        assert(activeByID.isEmpty, "GlobalShortcutService deinitialized with active registrations.")
        assert(activeIDByAction.isEmpty, "GlobalShortcutService deinitialized with active reverse registrations.")
        assert(residualByID.isEmpty, "GlobalShortcutService deinitialized with residual registrations.")
        // Bug 🟢 修复:断言 pausedActions 在 deinit 前已被 stop() 清空。
        // stop() 会把 pausedActions 的 entry 放回 activeByID 然后清空,如果这里非空
        // 说明 stop() 没跑或者 path 走错,需要排查。
        assert(pausedActions.isEmpty, "GlobalShortcutService deinitialized with paused actions.")
        assert(activeRecording == nil, "GlobalShortcutService deinitialized with an active recording session.")
        assert(inputSourceObserver == nil, "GlobalShortcutService deinitialized with an input-source observer.")
        assert(permissionSubscription == nil, "GlobalShortcutService deinitialized with an accessibility observer.")
        assert(onAction == nil, "GlobalShortcutService deinitialized with a business callback.")
        switch handlerState {
        case .notInstalled, .failed:
            break
        case .installed, .cleanupFailed:
            assertionFailure("GlobalShortcutService deinitialized with a retained Carbon handler.")
        }
    }

    private var assignedActionCount: Int {
        ShortcutAction.allCases.reduce(into: 0) { count, action in
            if case .assigned = store.assignments[action] { count += 1 }
        }
    }

    /// 测试专用:`Snapshot` 当前 store 的 assignments,供 `GlobalShortcutServiceTests`
    /// 验证 `pauseHotkey` / `resumeHotkey` 不改 store。
    ///
    /// 第 6 轮复审要求加的回归屏障:断言里需要比较 pause 前后 store.assignments 是否
    /// 完全一致,但 `store` 仍是 private —— 用一个 internal 访问器绕开这个限制。
    /// 带下划线前缀 + `_ForTesting` 后缀表示「仅 `GlobalShortcutServiceTests` 可见,
    /// 业务代码请勿调用」。默认 internal 访问级别,`@testable import MoleWidgetCore`
    /// 即可访问。
    func _storeAssignmentsForTesting() -> ShortcutAssignments {
        store.assignments
    }

    private func installHandlerIfNeeded() -> ShortcutRegistrationFailure? {
        switch handlerState {
        case .installed:
            return nil
        case let .cleanupFailed(_, failure):
            return failure
        case .notInstalled, .failed:
            break
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            mioGlobalShortcutEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        guard status == noErr, let handler else {
            let effectiveStatus = status == noErr ? OSStatus(eventInternalErr) : status
            let failure = ShortcutRegistrationFailure.platform(
                operation: .installHandler,
                osStatus: effectiveStatus
            )
            handlerState = .failed(failure)
            logPlatformResult(operation: .installHandler, status: effectiveStatus, result: "failed")
            return failure
        }

        handlerState = .installed(handler)
        logPlatformResult(operation: .installHandler, status: noErr, result: "installed")
        return nil
    }

    private func removeHandlerIfPresent() -> ShortcutRegistrationFailure? {
        let handler: EventHandlerRef
        switch handlerState {
        case let .installed(value), let .cleanupFailed(value, _):
            handler = value
        case .notInstalled, .failed:
            handlerState = .notInstalled
            return nil
        }

        let status = RemoveEventHandler(handler)
        guard status == noErr else {
            let failure = ShortcutRegistrationFailure.platform(
                operation: .removeHandler,
                osStatus: status
            )
            handlerState = .cleanupFailed(handler, failure)
            logPlatformResult(operation: .removeHandler, status: status, result: "cleanup_failed")
            return failure
        }

        handlerState = .notInstalled
        logPlatformResult(operation: .removeHandler, status: noErr, result: "removed")
        return nil
    }

    private func reconcileAction(
        _ action: ShortcutAction,
        reason: String
    ) -> ShortcutRegistrationState {
        if !cleanupResidualRegistrations(for: action) {
            return registrationStates[action] ?? .notStarted
        }

        let desired = store.assignments[action]
        if let activeID = activeIDByAction[action], let entry = activeByID[activeID] {
            if desired.shortcut == entry.shortcut {
                let state = ShortcutRegistrationState.registered(entry.shortcut)
                registrationStates[action] = state
                return state
            }

            guard unregisterActive(entry, desiredAfterFailure: desired) else {
                return registrationStates[action] ?? .notStarted
            }
        }

        guard case let .assigned(shortcut) = desired else {
            let state = ShortcutRegistrationState.disabled
            registrationStates[action] = state
            return state
        }

        if let handlerFailure = installHandlerIfNeeded() {
            let state = ShortcutRegistrationState.failed(
                desired: desired,
                failure: handlerFailure
            )
            registrationStates[action] = state
            return state
        }

        let state = register(shortcut: shortcut, action: action, reason: reason)
        registrationStates[action] = state
        return state
    }

    private func register(
        shortcut: Shortcut,
        action: ShortcutAction,
        reason: String
    ) -> ShortcutRegistrationState {
        guard let registrationID = allocateRegistrationID() else {
            let failure = ShortcutRegistrationFailure.registrationIdentifierExhausted
            Self.logger.error(
                "event=shortcut.registration result=failed action=\(action.rawValue, privacy: .public) reason=identifier_exhausted"
            )
            return .failed(desired: .assigned(shortcut), failure: failure)
        }

        let hotKeyID = EventHotKeyID(
            signature: CarbonShortcutConstants.signature,
            id: registrationID
        )
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            let effectiveStatus = status == noErr ? OSStatus(eventInternalErr) : status
            let failure = ShortcutRegistrationFailure.platform(
                operation: .register,
                osStatus: effectiveStatus
            )
            Self.logger.error(
                "event=shortcut.registration result=failed action=\(action.rawValue, privacy: .public) registration_id=\(registrationID, privacy: .public) reason=\(reason, privacy: .public) key_code=\(shortcut.keyCode, privacy: .public) modifiers=\(shortcut.modifiers.rawValue, privacy: .public) os_status=\(effectiveStatus, privacy: .public)"
            )
            return .failed(desired: .assigned(shortcut), failure: failure)
        }

        let entry = RegistrationEntry(
            action: action,
            shortcut: shortcut,
            id: registrationID,
            ref: ref
        )
        activeByID[registrationID] = entry
        activeIDByAction[action] = registrationID
        Self.logger.info(
            "event=shortcut.registration result=registered action=\(action.rawValue, privacy: .public) registration_id=\(registrationID, privacy: .public) reason=\(reason, privacy: .public) key_code=\(shortcut.keyCode, privacy: .public) modifiers=\(shortcut.modifiers.rawValue, privacy: .public) os_status=0"
        )
        return .registered(shortcut)
    }

    private func unregisterActive(
        _ entry: RegistrationEntry,
        desiredAfterFailure: ShortcutAssignment
    ) -> Bool {
        activeByID.removeValue(forKey: entry.id)
        activeIDByAction.removeValue(forKey: entry.action)

        let status = UnregisterEventHotKey(entry.ref)
        guard status == noErr else {
            let failure = ShortcutRegistrationFailure.platform(
                operation: .unregister,
                osStatus: status
            )
            residualByID[entry.id] = entry
            registrationStates[entry.action] = .failed(
                desired: desiredAfterFailure,
                failure: failure
            )
            logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
            return false
        }

        logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
        return true
    }

    private func cleanupResidualRegistrations(for action: ShortcutAction) -> Bool {
        let entries = residualByID.values
            .filter { $0.action == action }
            .sorted { $0.id < $1.id }
        var allReleased = true

        for entry in entries {
            let status = UnregisterEventHotKey(entry.ref)
            if status == noErr {
                residualByID.removeValue(forKey: entry.id)
                logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
            } else {
                let failure = ShortcutRegistrationFailure.platform(
                    operation: .unregister,
                    osStatus: status
                )
                residualByID[entry.id] = entry
                registrationStates[action] = .failed(
                    desired: store.assignments[action],
                    failure: failure
                )
                logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
                allReleased = false
            }
        }
        return allReleased
    }

    private func terminalizeAllActiveRegistrations() {
        let entries = activeByID.values.sorted { $0.id < $1.id }
        activeByID.removeAll()
        activeIDByAction.removeAll()
        for entry in entries {
            residualByID[entry.id] = entry
        }
    }

    private func releaseResidualRegistrations() -> [ShortcutRegistrationFailure] {
        var failures: [ShortcutRegistrationFailure] = []
        for entry in residualByID.values.sorted(by: { $0.id < $1.id }) {
            let status = UnregisterEventHotKey(entry.ref)
            if status == noErr {
                residualByID.removeValue(forKey: entry.id)
                logUnregistration(entry: entry, status: noErr, ownershipAfter: "released")
            } else {
                let failure = ShortcutRegistrationFailure.platform(
                    operation: .unregister,
                    osStatus: status
                )
                residualByID[entry.id] = entry
                failures.append(failure)
                logUnregistration(entry: entry, status: status, ownershipAfter: "residual")
            }
        }
        return failures
    }

    private func projectHandlerFailureToAssignedActions() {
        let failure: ShortcutRegistrationFailure
        switch handlerState {
        case let .failed(value), let .cleanupFailed(_, value):
            failure = value
        case .notInstalled, .installed:
            return
        }

        for action in ShortcutAction.allCases {
            let desired = store.assignments[action]
            switch desired {
            case .disabled:
                registrationStates[action] = .disabled
            case .assigned:
                registrationStates[action] = .failed(desired: desired, failure: failure)
            }
        }
    }

    private func allocateRegistrationID() -> UInt32? {
        guard nextRegistrationID != 0 else { return nil }
        let result = nextRegistrationID
        nextRegistrationID = result == UInt32.max ? 0 : result + 1
        return result
    }

    private func takeActiveRecording() -> RecordingSession? {
        guard let session = activeRecording else { return nil }
        activeRecording = nil
        return session
    }

    private func installInputSourceObserver(epoch: UInt64) {
        let center = DistributedNotificationCenter.default()
        let name = Notification.Name(
            rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        inputSourceObserver = center.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // The Notification and TIS objects stay inside the framework
            // callback. Only this primitive lifecycle epoch crosses to the
            // short MainActor task.
            Task { @MainActor [weak self] in
                guard
                    let self,
                    self.lifecycle == .started,
                    self.lifecycleEpoch == epoch
                else { return }
                self.presentationRevision &+= 1
                Self.logger.info(
                    "event=shortcut.presentation.input_source_changed result=refreshed revision=\(self.presentationRevision, privacy: .public)"
                )
            }
        }
    }

    private func removeInputSourceObserver() {
        guard let inputSourceObserver else { return }
        DistributedNotificationCenter.default().removeObserver(inputSourceObserver)
        self.inputSourceObserver = nil
    }

    /// Bug 1-A 修复:订阅 `permissionManager.$accessibilityDecision`,仅在 transition 到
    /// `.authorized` 时触发一次 reconcile。`removeDuplicates` 保证同值不重发;`dropFirst`
    /// 跳过 init 时的初值(初值代表启动期 reconcile 的那次失败,不该再立即触发一次)。
    private func installAccessibilityObserver() {
        permissionSubscription = permissionManager.$accessibilityDecision
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] decision in
                guard let self, self.lifecycle == .started else { return }
                guard case .authorized = decision else { return }
                Self.logger.info("event=shortcut.accessibility.changed result=triggered_reconcile")
                _ = self.reconcile(reason: .accessibilityChanged)
            }
    }

    private func removeAccessibilityObserver() {
        guard let subscription = permissionSubscription else { return }
        subscription.cancel()
        permissionSubscription = nil
    }

    private func logValidationFailure(
        action: ShortcutAction,
        failure: ShortcutValidationFailure
    ) {
        Self.logger.notice(
            "event=shortcut.validation.rejected action=\(action.rawValue, privacy: .public) reason=\(Self.logValue(failure), privacy: .public)"
        )
    }

    private func logRecordingEnded(_ session: RecordingSession, reason: RecordingEndReason) {
        Self.logger.info(
            "event=shortcut.recording.ended session_id=\(session.id.rawValue.uuidString, privacy: .public) owner_id=\(session.owner.rawValue.uuidString, privacy: .public) host=\(session.host.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: session.startedAt), privacy: .public)"
        )
    }

    private func logDroppedEvent(
        registrationID: UInt32,
        action: ShortcutAction?,
        reason: String
    ) {
        Self.logger.debug(
            "event=shortcut.dispatch.dropped registration_id=\(registrationID, privacy: .public) action=\(action?.rawValue ?? "none", privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func logUnregistration(
        entry: RegistrationEntry,
        status: OSStatus,
        ownershipAfter: String
    ) {
        Self.logger.log(
            level: status == noErr ? .info : .error,
            "event=shortcut.unregistration action=\(entry.action.rawValue, privacy: .public) registration_id=\(entry.id, privacy: .public) os_status=\(status, privacy: .public) ownership_after=\(ownershipAfter, privacy: .public)"
        )
    }

    private func logPlatformResult(
        operation: ShortcutRegistrationFailure.Operation,
        status: OSStatus,
        result: String
    ) {
        Self.logger.log(
            level: status == noErr ? .info : .error,
            "event=shortcut.platform operation=\(operation.rawValue, privacy: .public) result=\(result, privacy: .public) os_status=\(status, privacy: .public)"
        )
    }

    private func logReconcile(
        reason: ShortcutReconcileReason,
        outcome: String,
        startedAt: ContinuousClock.Instant
    ) {
        Self.logger.info(
            "event=shortcut.reconcile reason=\(reason.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(Self.durationMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func carbonModifiers(from modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private static func logValue(_ failure: ShortcutValidationFailure) -> String {
        switch failure {
        case .unsupportedModifierBits: "unsupported_modifier_bits"
        case .primaryModifierRequired: "primary_modifier_required"
        case let .duplicate(action): "duplicate:\(action.rawValue)"
        }
    }

    private static func durationMilliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let components = start.duration(to: ContinuousClock().now).components
        return components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
    }
}
