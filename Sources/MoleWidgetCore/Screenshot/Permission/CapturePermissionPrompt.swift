//
//  CapturePermissionPrompt.swift
//  Vitals - Screenshot module
//
//  P0-4 修复:截图入口预检未通过时的用户可见失败态。
//
//  为什么需要它:未授权屏幕录制时按快捷键,ScreenCaptureKit 抛 permissionDenied 后
//  统一收敛成笼统的「截图失败」,用户既不知道缺什么权限、也不知道去哪里开。
//  这里在**入口**就拦住请求,并弹一个说明缺哪项权限 + 三颗按钮的窗口:
//    · 「打开系统设置」→ 复用 SystemSettingsOpener(M12 唯一出口,不新写 deep link)
//    · 「重新检查」→ 复用 PermissionManager.refreshAllDecisions(),授权完当场生效
//    · 「稍后」     → 关窗,不截图
//
//  权限是动态的:用户可能在系统设置里授权完再回来,所以必须有「重新检查」,
//  不能只在启动时查一次。
//

import AppKit
import SwiftUI

/// 缺失权限的纯文案。UI 只消费它,不做任何系统调用。
nonisolated enum CapturePermissionCopy {
    static func title(for destination: SystemSettingsDestination) -> String {
        switch destination {
        case .screenRecording: "需要屏幕录制权限"
        case .accessibility:   "需要辅助功能权限"
        case .loginItems:      "需要登录项权限"
        }
    }

    static func detail(for destination: SystemSettingsDestination) -> String {
        switch destination {
        case .screenRecording:
            "Vitals 要读取屏幕画面才能截图。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中打开 Vitals 的开关。"
        case .accessibility:
            "全局快捷键依赖辅助功能权限,否则按快捷键会被系统静默拦截。请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 Vitals。"
        case .loginItems:
            "该权限需要在「系统设置 → 通用 → 登录项」中允许 Vitals。"
        }
    }
}

// MARK: - View

struct CapturePermissionPromptView: View {
    let destination: SystemSettingsDestination
    /// 授权仍然缺失时,「重新检查」后把最新缺失面板回填,让用户看到状态没变。
    let stillMissing: SystemSettingsDestination?
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(CapturePermissionCopy.title(for: destination))
                        .font(.system(size: 15, weight: .semibold))
                    Text(CapturePermissionCopy.detail(for: destination))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let stillMissing, stillMissing != destination {
                Text("仍然缺少:「\(CapturePermissionCopy.title(for: stillMissing))」")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("稍后", action: onDismiss)
                Button("重新检查", action: onRecheck)
                    .keyboardShortcut(.cancelAction)
                Button("打开系统设置", action: onOpenSettings)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Window owner

/// 权限缺失提示窗的持有者。窗口非强制(modal):用户可能想先记下路径再去设置,
/// 所以「稍后」是正常出口。主流程用同一个实例反复 present,不叠窗口。
@MainActor
final class CapturePermissionPrompt {
    private var window: NSWindow?

    /// 三颗按钮的语义回调,由 `ScreenshotServices` 注入(它持有 PermissionManager
    /// 与 SystemSettingsOpener)。这里不碰系统调用,保持纯 UI。
    struct Actions {
        let openSettings: (SystemSettingsDestination) -> Void
        /// 返回 true 表示权限已经齐了,调用方应关窗并继续原本被拦下的截图。
        let recheck: () -> Bool
        let dismiss: () -> Void
    }

    func present(destinations: [SystemSettingsDestination], actions: Actions) {
        guard let destination = destinations.first else {
            close()
            return
        }

        let root = CapturePermissionPromptView(
            destination: destination,
            stillMissing: destinations.count > 1 ? destinations[1] : nil,
            onOpenSettings: { actions.openSettings(destination) },
            onRecheck: {
                // 权限动态:当场重查,不要让用户重开一次截图才知道结果。
                if actions.recheck() { self.close() }
            },
            onDismiss: {
                self.close()
                actions.dismiss()
            }
        )

        if let window {
            window.contentViewController = NSHostingController(rootView: root)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "截图权限"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        // 浮窗应用(Landlord/LSUIElement)没有 Dock 图标,必须显式激活自己,
        // 否则窗口会开在系统设置背后,用户以为没反应。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
    }
}
