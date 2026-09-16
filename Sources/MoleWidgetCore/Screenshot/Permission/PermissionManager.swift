//
//  PermissionManager.swift
//  Vitals - Screenshot module
//
//  Module-12 Screen Recording + Accessibility 授权。
//
//  权限是一次尝试的 **typed 终态** `PermissionDecision`：
//    · `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 无法可靠
//      区分 notDetermined / denied / policy restriction，因此**不伪造** `.restricted`；
//      false 一律收敛为 `.denied(.openSystemSettings(.screenRecording))`。
//    · `AXIsProcessTrustedWithOptions` 同样无法可靠区分 notDetermined / denied，
//      false 一律收敛为 `.denied(.openSystemSettings(.accessibility))`。
//    · request 是同步系统调用（`CGRequestScreenCaptureAccess()` 直接返回 Bool，首次
//      调用弹 TCC 对话框；`AXIsProcessTrustedWithOptions(prompt: true)` 触发系统授权
//      弹窗）；不做固定 sleep、不包装成假异步。
//    · `screenCaptureDecision` / `accessibilityDecision` 是**只读快照**：由 01 在 app
//      重新 active / wake 时调 `refreshScreenCaptureDecision()` / `refreshAccessibilityDecision()`
//      更新,供 UI（设置窗口权限 section）观察。刷新只读 actual state,不请求权限、
//      不改 desired state。
//    · 12 只决定权限；把 `PermissionRecovery` 映射成 08 feedback action 是 01 的事。
//
//  为什么必须检查 Accessibility：Carbon `RegisterEventHotKey` 在没有 Accessibility 权限时
// 会**静默失败或被系统拦截**——已注册的 global hotkey 按下后系统不派发,所以"快捷键有时候
// 没有效果"。这里把 Accessibility 也纳入权限决策,设置窗口引导用户去开。
//

import ApplicationServices
import Foundation
import CoreGraphics
import Combine

/// 一次授权尝试的 typed 终态（12-owned）。
public nonisolated enum PermissionDecision: Sendable, Equatable {
    case authorized
    case denied(recovery: PermissionRecovery)
    case restricted(recovery: PermissionRecovery?)
    case failed(PermissionFailure)
}

/// presentation-independent 恢复意图；01 映射成 08-owned feedback action。
public nonisolated enum PermissionRecovery: Sendable, Equatable {
    case openSystemSettings(SystemSettingsDestination)
}

/// System Settings 目标面板。Screen Recording / Accessibility / Login Item 共用。
public nonisolated enum SystemSettingsDestination: Sendable, Equatable {
    case screenRecording
    case accessibility
    case loginItems
}

/// 底层权限失败——只进 01/12 日志，不扩展 08 event（没有更精确分类时用 `.unknown`）。
public nonisolated enum PermissionFailure: Sendable, Equatable {
    case unknown
}

@MainActor
public final class PermissionManager: ObservableObject {
    /// 只读授权快照，供 UI 观察；由 `refreshScreenCaptureDecision()` / `authorizeScreenCapture()`
    /// 更新。它是 typed decision 的缓存，不是长驻二态 Bool。
    @Published private(set) var screenCaptureDecision: PermissionDecision

    /// 只读 Accessibility 授权快照,由 `refreshAccessibilityDecision()` / `requestAccessibility()`
    /// 更新。同上,是 typed decision 的缓存。
    @Published private(set) var accessibilityDecision: PermissionDecision

    public init() {
        screenCaptureDecision = Self.readScreenCaptureDecision()
        accessibilityDecision = Self.readAccessibilityDecision()
    }

    /// 只读刷新 Screen Capture（app-active / wake）：不弹窗，仅把快照对齐当前系统真相。
    public func refreshScreenCaptureDecision() {
        screenCaptureDecision = Self.readScreenCaptureDecision()
    }

    /// 只读刷新 Accessibility（app-active / wake）：不弹窗，仅把快照对齐当前系统真相。
    public func refreshAccessibilityDecision() {
        accessibilityDecision = Self.readAccessibilityDecision()
    }

    /// 只读当前 Screen Capture 授权（不弹窗），不改快照——per-command 路径用。
    public func currentScreenCaptureDecision() -> PermissionDecision {
        Self.readScreenCaptureDecision()
    }

    /// 只读当前 Accessibility 授权（不弹窗），不改快照。
    public func currentAccessibilityDecision() -> PermissionDecision {
        Self.readAccessibilityDecision()
    }

    /// 授权一次截图：已授权直接返回；否则请求系统弹窗并**使用其直接 Bool 结果**
    /// （曾被拒绝的进程系统不再弹窗、直接 false → `.denied`）。同步系统调用，
    /// 完成后更新只读快照。
    @discardableResult
    public func authorizeScreenCapture() -> PermissionDecision {
        let decision: PermissionDecision
        if CGPreflightScreenCaptureAccess() {
            decision = .authorized
        } else {
            decision = CGRequestScreenCaptureAccess()
                ? .authorized
                : .denied(recovery: .openSystemSettings(.screenRecording))
        }
        screenCaptureDecision = decision
        return decision
    }

    /// 请求 Accessibility 授权：通过 `AXIsProcessTrustedWithOptions(prompt: true)` 触发系统
    /// 弹窗（首次）或直接返回当前真实状态（已拒绝时不再弹窗）。同步系统调用,完成后
    /// 更新只读快照。
    ///
    /// 注意:`AXIsProcessTrustedWithOptions` **只在主线程安全**,而 `PermissionManager` 已经是
    /// `@MainActor`,所以这里可以直接调。
    @discardableResult
    public func requestAccessibility() -> PermissionDecision {
        let decision: PermissionDecision
        if AXIsProcessTrusted() {
            decision = .authorized
        } else {
            // prompt: true → 系统弹窗;同时也会返回真实授权结果(用户点过后 Bool 即更新)。
            // AXIsProcessTrustedWithOptions 接受 CFDictionary(NS dictionary 桥接)。
            let options: [String: Any] = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ]
            let granted = AXIsProcessTrustedWithOptions(options as CFDictionary)
            decision = granted
                ? .authorized
                : .denied(recovery: .openSystemSettings(.accessibility))
        }
        accessibilityDecision = decision
        return decision
    }

    private static func readScreenCaptureDecision() -> PermissionDecision {
        CGPreflightScreenCaptureAccess()
            ? .authorized
            : .denied(recovery: .openSystemSettings(.screenRecording))
    }

    private static func readAccessibilityDecision() -> PermissionDecision {
        AXIsProcessTrusted()
            ? .authorized
            : .denied(recovery: .openSystemSettings(.accessibility))
    }
}