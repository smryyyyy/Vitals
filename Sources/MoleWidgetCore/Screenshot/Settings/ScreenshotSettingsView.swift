//
//  ScreenshotSettingsView.swift
//  Vitals - Screenshot module
//
//  截图设置窗口内容:
//  - 权限 section:Screen Recording + Accessibility 状态与一键申请 / 跳转
//  - 快捷键 section:快速截图 + 高级窗口截图
//  - AI 翻译 section:API Key SecureField + 测试连接
//  - 偏好 section:沿用 CaptureSettings
//

import AppKit
import Combine
import SwiftUI

@MainActor
@Observable
public final class ScreenshotSettingsManager {
    let settings: ScreenshotShortcutStore
    var captureSettings: CaptureSettings
    let credential: AICredentialKeychain
    let onTestConnection: () async -> Bool
    /// 权限(Screen Recording + Accessibility):Carbon hotkey 必需。
    /// 设置窗口用它显示状态 + 引导跳转系统设置。
    let permissionManager: PermissionManager
    /// 全局快捷键服务:用户进入录制模式时调用 `pauseHotkey(action:)` 同步暂停对应
    /// Carbon 注册,退出录制时调 `resumeHotkey(action:)` 重新注册,避免「设快捷键时
    /// 旧快捷键也生效」。Bug 2-B 修复:之前用 `disable` + `retryRegistration` 走
    /// store sink → reconcile 路径,有 Combine scheduler 微秒级延迟,Carbon 事件
    /// 队列里已排队的 kEventHotKeyPressed 可能赶在 unregister 完成前被 dispatch。
    let globalShortcutService: GlobalShortcutService
    /// 设置窗口跳转 System Settings 的统一出口(单个 opener,与 `PermissionManager`
    /// 中的 `SystemSettingsDestination` 一一对应)。
    let systemSettingsOpener: SystemSettingsOpener

    var connectionStatus: ConnectionStatus = .idle

    enum ConnectionStatus: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    public init(
        settings: ScreenshotShortcutStore,
        captureSettings: CaptureSettings,
        credential: AICredentialKeychain,
        permissionManager: PermissionManager,
        globalShortcutService: GlobalShortcutService,
        systemSettingsOpener: SystemSettingsOpener,
        onTestConnection: @escaping () async -> Bool
    ) {
        self.settings = settings
        self.captureSettings = captureSettings
        self.credential = credential
        self.permissionManager = permissionManager
        self.globalShortcutService = globalShortcutService
        self.systemSettingsOpener = systemSettingsOpener
        self.onTestConnection = onTestConnection
    }

    /// 「测试连接」改用 Keychain 里实际存在的 key 做测试,而不是 input 框里的字符串。
    /// 避免 Keychain 已有有效 key 但 input 框为空时按钮被禁用的误判。
    func test() async {
        connectionStatus = .testing
        let success = await onTestConnection()
        if success {
            connectionStatus = .success
        } else if !managerHasStoredKey() {
            // 区分「没有配置 key」与「key 配置但网络/翻译失败」,用户能立刻定位问题。
            connectionStatus = .failure("未在 Keychain 中找到 API Key,请先粘贴并等 1 秒")
        } else {
            connectionStatus = .failure("连接失败:请检查 API Key 或网络")
        }
    }

    private func managerHasStoredKey() -> Bool {
        credential.hasValidAPIKey
    }
}

public struct ScreenshotSettingsView: View {
    @Bindable var manager: ScreenshotSettingsManager
    let onClose: () -> Void

    /// 订阅 `manager.settings.objectWillChange`,使 `ScreenshotShortcutStore`(ObservableObject)
    /// 写盘后 SwiftUI 重新计算 body —— 这样 X 按钮 / 重置按钮 binding 改了底层
    /// `ShortcutAssignment` 后 UI 能立刻 rebuild、按钮消失或 label 更新。
    /// 见 Bug #2 修复说明。
    ///
    /// 为什么用 `@ObservedObject` 包装:SwiftUI 对 `@Observable` 类型的依赖追踪
    /// 只追踪它自身访问到的属性,但 `PermissionManager` 是 `ObservableObject` +
    /// `@Published`,需要 `@ObservedObject` 订阅 `objectWillChange` 才能 rebuild。
    /// 而 `manager.settings`(ObservableObject)的 objectWillChange 只能通过
    /// 手动 `.onReceive` 桥接,因为外层 `@Bindable var manager` 不会下钻到它的子
    /// ObservableObject。
    @ObservedObject private var permissionObserver: PermissionManager

    /// 触发 body rebuild 的内部 tick。Bridging `manager.settings.objectWillChange`
    /// 到 view rebuild,见 Bug #2 修复说明。
    @State private var settingsChangeTick: Int = 0

    public init(manager: ScreenshotSettingsManager, onClose: @escaping () -> Void) {
        self.manager = manager
        self.onClose = onClose
        // SwiftUI 对 ObservableObject 的 @Published 字段需要 @ObservedObject wrapper
        // 才能自动 rebuild。这里把 manager.permissionManager 装成观察对象。
        self._permissionObserver = ObservedObject(wrappedValue: manager.permissionManager)
    }

    public var body: some View {
        VStack(spacing: 0) {
            form
                .frame(width: 500, height: 600)
            Divider()
            footer
        }
        // Bug #2 修复:订阅 manager.settings.objectWillChange,store 每次写盘触发
        // SwiftUI 重新求值 body,binding get 重跑,X 按钮 / 重置按钮才能立即生效。
        // 这是因为 `ScreenshotSettingsManager`(@Observable)没有观察内部的
        // `ScreenshotShortcutStore`(ObservableObject),SwiftUI 默认不会 rebuild。
        .onReceive(manager.settings.objectWillChange) { _ in
            settingsChangeTick &+= 1
        }
        // App 切回前台时(用户在系统设置里授权后回来)重读真实状态。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.permissionManager.refreshScreenCaptureDecision()
            manager.permissionManager.refreshAccessibilityDecision()
        }
    }

    private var form: some View {
        Form {
            permissionSection
            shortcutsSection
            aiSection
        }
        .formStyle(.grouped)
        .onAppear {
            // 每次 view 出现都主动刷新一次权限快照 —— `.onAppear` 重新打开窗口也会触发,
            // 此时用户可能已经从系统设置里改过授权。
            manager.permissionManager.refreshScreenCaptureDecision()
            manager.permissionManager.refreshAccessibilityDecision()
        }
    }

    // MARK: - 权限

    private var permissionSection: some View {
        Section("权限") {
            // 读 _permissionObserver 触发 SwiftUI 对它的 @Published 字段订阅;
            // 不需要保存返回值,只要在 body 里被读到了就行。
            let _ = permissionObserver.screenCaptureDecision
            let _ = permissionObserver.accessibilityDecision
            permissionRow(
                title: "屏幕录制",
                destination: .screenRecording,
                decision: manager.permissionManager.screenCaptureDecision,
                onRequest: {
                    _ = manager.permissionManager.authorizeScreenCapture()
                }
            )
            permissionRow(
                title: "辅助功能",
                destination: .accessibility,
                decision: manager.permissionManager.accessibilityDecision,
                onRequest: {
                    _ = manager.permissionManager.requestAccessibility()
                }
            )
            Text("全局快捷键依赖这两项权限。未授权时按 ⌘⇧2 / ⌃⌥⇧A 会被系统静默拦截。")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        destination: SystemSettingsDestination,
        decision: PermissionDecision,
        onRequest: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
                .frame(width: 100, alignment: .leading)
            permissionStatusLabel(decision)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("申请") { onRequest() }
                .disabled(isAuthorized(decision))
            Button("打开系统设置") {
                _ = manager.systemSettingsOpener.open(destination)
            }
            .disabled(isAuthorized(decision))
        }
    }

    @ViewBuilder
    private func permissionStatusLabel(_ decision: PermissionDecision) -> some View {
        switch decision {
        case .authorized:
            Label("已授权", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.green)
        case .denied:
            Label("未授权", systemImage: "xmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red)
        case .restricted:
            Label("受系统限制", systemImage: "lock.circle")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        case .failed:
            Label("检查失败", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundColor(.orange)
        }
    }

    private func isAuthorized(_ decision: PermissionDecision) -> Bool {
        if case .authorized = decision { return true }
        return false
    }

    // MARK: - 快捷键

    private var shortcutsSection: some View {
        Section("快捷键") {
            HStack {
                Text("快速截图")
                    .frame(width: 100, alignment: .leading)
                ShortcutRecorderControl(
                    shortcut: Binding(
                        get: { manager.settings.shortcut(for: .captureArea) },
                        set: { manager.settings.setShortcut($0, for: .captureArea) }
                    ),
                    defaultShortcut: ScreenshotShortcutStore.defaultCaptureArea,
                    action: .windowCapture,
                    onStartRecording: { [manager] in
                        // Bug 2-B 修复:进入录制模式前,同步 unregister 当前 Carbon hotkey。
                        // 走 `pauseHotkey` 而不是 `disable`,因为 `disable` 走 store sink →
                        // reconcile 路径,Combine scheduler 有微秒级延迟,Carbon 事件队列里
                        // 已排队的 kEventHotKeyPressed 可能在 UnregisterEventHotKey 完成前
                        // 被 dispatch,导致旧快捷键仍触发截图。`pauseHotkey` 不动 store、不
                        // 走 sink,直接同步 unregister,确保旧快捷键立即失效。
                        manager.globalShortcutService.pauseHotkey(action: .windowCapture)
                    },
                    onStopRecording: { [manager] in
                        // Bug 2-B 修复:退出录制(确认 / 取消 / 清除 / view 消失)后,从
                        // store 读当前 shortcut 重新注册 Carbon hotkey。`resumeHotkey`
                        // 走单一 action 的 reconcileAction 路径,等价于 `retryRegistration`
                        // 但意图更清晰——本方法就是「录制结束后恢复注册」。
                        _ = manager.globalShortcutService.resumeHotkey(action: .windowCapture)
                    },
                    // Bug 🟡 修复:beginRecording 设 activeRecording,让 store.$assignments
                    // sink 触发 handleAssignmentsChanged 时被 guard 拦截,避免录制期间
                    // store 改动导致 reconcile 重新注册 Carbon hotkey 的 race。
                    // onInvalidated 传空 closure:本路径(view 内 stopRecording → onEndRecording
                    // → endRecording)自己管理 activeRecording 生命周期,不走 onInvalidated
                    // 路径;onInvalidated 只在外部中断(比如 service.stop())触发,此时
                    // view 通常已 deinit,不需要 UI 桥接。
                    onBeginRecording: { [manager] in
                        _ = manager.globalShortcutService.beginRecording(
                            owner: RecorderOwnerID(),
                            host: .settings,
                            onInvalidated: { _ in }
                        )
                    },
                    onEndRecording: { [manager] in
                        manager.globalShortcutService.endRecording(forHost: .settings, reason: .cancelled)
                    }
                )
                .frame(width: 220)
                Spacer()
            }
            HStack {
                Text("高级窗口截图")
                    .frame(width: 100, alignment: .leading)
                ShortcutRecorderControl(
                    shortcut: Binding(
                        get: { manager.settings.shortcut(for: .captureAdvanced) },
                        set: { manager.settings.setShortcut($0, for: .captureAdvanced) }
                    ),
                    defaultShortcut: ScreenshotShortcutStore.defaultCaptureAdvanced,
                    action: .advancedWindowCapture,
                    onStartRecording: { [manager] in
                        manager.globalShortcutService.pauseHotkey(action: .advancedWindowCapture)
                    },
                    onStopRecording: { [manager] in
                        _ = manager.globalShortcutService.resumeHotkey(action: .advancedWindowCapture)
                    },
                    onBeginRecording: { [manager] in
                        _ = manager.globalShortcutService.beginRecording(
                            owner: RecorderOwnerID(),
                            host: .settings,
                            onInvalidated: { _ in }
                        )
                    },
                    onEndRecording: { [manager] in
                        manager.globalShortcutService.endRecording(forHost: .settings, reason: .cancelled)
                    }
                )
                .frame(width: 220)
                Spacer()
            }
        }
    }

    // MARK: - AI 翻译

    @State private var apiKeyInput: String = ""
    /// 等待中的 Keychain 写任务。debounce 用,每次输入会取消上一个未执行的任务,
    /// 250ms 内只写入最后一次值 —— 避免每字符都触发 Keychain 写带来的卡顿。
    @State private var pendingKeyWriteTask: Task<Void, Never>?
    /// Keychain 写盘 debounce 间隔。
    private static let keychainWriteDebounce: UInt64 = 250_000_000  // 250ms

    private var aiSection: some View {
        Section("AI 翻译") {
            HStack {
                Text("API Key")
                    .frame(width: 100, alignment: .leading)
                SecureField("sk-...", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    // 实时把 key 写进 Keychain(关窗不再丢);但加 250ms debounce,
                    // 避免每字符触发 Keychain 写带来的 50-100ms UI 卡顿。
                    .onChange(of: apiKeyInput) { _, newValue in
                        pendingKeyWriteTask?.cancel()
                        pendingKeyWriteTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: Self.keychainWriteDebounce)
                            if Task.isCancelled { return }
                            manager.credential.writeAPIKey(newValue)
                        }
                    }
            }
            HStack {
                Text("状态")
                    .frame(width: 100, alignment: .leading)
                statusLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    // 立即 flush 待写入的值,避免用户点「测试连接」时旧值还没落盘。
                    pendingKeyWriteTask?.cancel()
                    manager.credential.writeAPIKey(apiKeyInput)
                    Task { await manager.test() }
                } label: {
                    Text("测试连接")
                }
                // 只在已经在测试中时灰着;允许用户没配 key 时也点测试,这样能立刻
                // 在 UI 看到「未配置 API Key」,避免按键永远灰着让用户不知道原因。
                .disabled(manager.connectionStatus == .testing)
            }
            HStack {
                Text("说明")
                    .frame(width: 100, alignment: .leading)
                Text("MiniMax chat completions API Key,用于把识别出的文字翻译成目标语言。Keychain 保存。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .onAppear {
            apiKeyInput = manager.credential.readAPIKey() ?? ""
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch manager.connectionStatus {
        case .idle:
            Text("未测试").font(.system(size: 11)).foregroundColor(.secondary)
        case .testing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("测试中...").font(.system(size: 11))
            }
        case .success:
            Label("连接成功", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.red)
        }
    }

    // MARK: - 偏好
    // 「截屏后播放音效」选项已移除:
    //   - UI 上不再有 toggle
    //   - `CapturePreferencesSnapshot.playSoundOnCapture` 恒为 false
    //   - `CaptureController` 取到这个值后,`CaptureFeedbackPresenter` 走
    //     `shouldPlaySound = source == .directCapture && soundEnabled && summary.hasSuccessfulSink`
    //     计算时 soundEnabled==false → 不再播放截图音效

    // MARK: - 底部按钮

    private var footer: some View {
        HStack {
            Spacer()
            Button("完成") {
                // 关窗前 flush 待写入的 key,避免 debounce 中途关窗导致最后一笔丢失。
                pendingKeyWriteTask?.cancel()
                manager.credential.writeAPIKey(apiKeyInput)
                onClose()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}