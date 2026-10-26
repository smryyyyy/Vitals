//
//  CursorSettingsView.swift
//  Vitals - Cursor 模块
//
//  光标主题设置的独立窗口。内容很少,只是一个开关加一条状态说明,
//  但它必须独立成窗:光标是全局系统状态,和「工资」这类模块设置一样,
//  值得一个能被明确打开和确认的地方,而不是塞在菜单里看不见。
//

import SwiftUI

/// Settings window for the bundled cursor theme.
///
/// The cursors are registered into the window server by this process, so they
/// live and die with Vitals. The view says so explicitly rather than letting
/// the user wonder why quitting "uninstalled" their theme.
public struct CursorSettingsView: View {
    public init(health: CursorThemeService.Health,
                onToggle: @escaping (Bool) -> Void,
                onCancel: @escaping () -> Void) {
        self.health = health
        self.onToggle = onToggle
        self.onCancel = onCancel
    }

    public let health: CursorThemeService.Health
    public let onToggle: (Bool) -> Void
    public let onCancel: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("自定义光标")
                .font(.system(size: 15, weight: .semibold))

            Toggle("启用自定义光标", isOn: Binding(
                get: { health != .off },
                set: { onToggle($0) }
            ))

            Divider()

            statusRow

            Text("CatOmen Raiden · 16 组光标 · 随系统睡眠唤醒自动重应用")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("完成", action: onCancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460, height: 260)
    }

    /// Surfaces the registration result so a macOS update that breaks the
    /// private API shows up here instead of silently reverting to stock
    /// cursors with no explanation.
    @ViewBuilder
    private var statusRow: some View {
        switch health {
        case .off:
            label("未启用", tone: .secondary)
        case .active(let applied, let total):
            label("已生效（\(applied)/\(total) 组标识符）", tone: .secondary)
        case .apiUnavailable:
            label("系统 API 已变更，光标未能应用", tone: .secondary)
        case .resourcesMissing:
            label("找不到主题文件，运行 make cursors 安装", tone: .secondary)
        case .registrationFailed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                label("部分光标注册失败", tone: .secondary)
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(tone)
    }
}