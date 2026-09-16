//
//  ShortcutRecorderControl.swift
//  Vitals - Screenshot module
//
//  Vitals 简化版 ShortcutRecorderControl:
//  - 显示当前 shortcut 标签(⌘⇧2 / ⌃⌥⇧A 等)
//  - 点击进入录制模式,按 Esc 取消 / 按 Backspace 清除
//  - 不接管现有 Mio 完整 ShortcutRecorderView 的所有能力
//

import AppKit
import SwiftUI

struct ShortcutRecorderControl: View {
    @Binding var shortcut: ShortcutAssignment
    var defaultShortcut: ShortcutAssignment
    /// 这个控件对应的快捷键动作:用于 `onStartRecording` 通知外层 `globalShortcutService.pauseHotkey`
    /// 当前 Carbon 注册,避免「设快捷键时旧快捷键仍生效」。Bug 2-B 修复:从 `disable` 改成
    /// `pauseHotkey`,后者同步 unregister Carbon hotkey,不依赖 store sink 链路,
    /// 避免 Combine scheduler 微秒级延迟导致旧快捷键仍触发。
    var action: ShortcutAction
    /// 进入录制模式时调用(外层实现为 `globalShortcutService.pauseHotkey(action:)`)。
    /// 负责同步 unregister Carbon hotkey,避免旧快捷键在录制期间仍触发截图。
    var onStartRecording: () -> Void
    /// 退出录制模式时调用(确认 / 取消 / 清除 / view 消失;外层实现为
    /// `globalShortcutService.resumeHotkey(action:)`)。
    /// 负责 reconcile 当前 action 的 Carbon hotkey,让 service 恢复派发。
    var onStopRecording: () -> Void
    /// Bug 🟡 修复:录制开始时通知外层 `globalShortcutService.beginRecording(...)` 设置
    /// `activeRecording`,让 store.$assignments sink 在录制期间触发 `handleAssignmentsChanged`
    /// 时被 guard 拦截,避免重新注册 Carbon hotkey 导致 store 改动路径下的 race。
    /// 不调它的话,录制期间仍有理论窗口让 store 改动触发 reconcile,虽然概率极低
    /// (NSEvent local monitor 会吞掉按键),但是 verifier 复审指出的残留 race。
    var onBeginRecording: () -> Void
    /// Bug 🟡 修复:录制结束时通知外层 `globalShortcutService.endRecording(...)` 清
    /// `activeRecording`,确保下一帧 store sink / reconcile 路径正常工作。
    var onEndRecording: () -> Void

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording = true
                // Bug 2-B 修复:先 unregister 当前 Carbon hotkey,再装 local monitor。
                // 用 `pauseHotkey`(同步)而不是 `disable`(异步),避免旧快捷键仍触发的 race。
                onStartRecording()
                startRecording()
            } label: {
                Text(isRecording ? "请按键..." : displayText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .background(isRecording ? Color.accentColor.opacity(0.2) : Color.clear)
            // 旧版的 X(删除)/ ↻(重置)按钮已移除,实测无效且非必要。
            // 清除快捷键:点录制按钮 → 按 Backspace。
            // 恢复默认:点录制按钮 → 按 default 组合键(如 ⌘⇧2)。
        }
        .onDisappear {
            if isRecording {
                stopRecording()
                // view 消失也属于录制结束,外层需要重新注册 hotkey。
                onStopRecording()
            }
        }
    }

    private var displayText: String {
        if let sc = shortcut.shortcut {
            return format(sc)
        }
        return "未设置"
    }

    private func format(_ sc: Shortcut) -> String {
        var parts: [String] = []
        if sc.modifiers.contains(.control) { parts.append("⌃") }
        if sc.modifiers.contains(.option) { parts.append("⌥") }
        if sc.modifiers.contains(.shift) { parts.append("⇧") }
        if sc.modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(for: sc.keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5",
            22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        ]
        return map[keyCode] ?? "Key(\(keyCode))"
    }

    private func startRecording() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let monitor = keyMonitor else { return event }
            // 防止 monitor 还在的时候又被回调
            NSEvent.removeMonitor(monitor)
            self.keyMonitor = nil
            NSEvent.removeMonitor(self.flagsMonitor ?? monitor)
            self.flagsMonitor = nil

            // Bug 🟡 修复:local monitor 回调路径不走 stopRecording()(那里手动
            // removeMonitor + nil keyMonitor),这里单独调 onEndRecording 清
            // activeRecording,确保 Esc / Backspace / 普通键 / 无效键 四个结束路径
            // 都会同步触发外层 endRecording,不会漏。
            self.onEndRecording()

            // Esc 取消
            if event.keyCode == 53 {
                self.isRecording = false
                // Bug 2-B 修复:任何结束录制路径都要通知外层重新注册 hotkey。
                self.onStopRecording()
                return nil
            }
            // Backspace 清除
            if event.keyCode == 51 {
                self.shortcut = .disabled
                self.isRecording = false
                self.onStopRecording()
                return nil
            }

            // 至少要有一个修饰键 + 一个普通键
            let modifiers = Self.modifiersFromEvent(event)
            guard !modifiers.isEmpty, event.keyCode != 53 else {
                self.isRecording = false
                self.onStopRecording()
                return nil
            }
            self.shortcut = .assigned(Shortcut(keyCode: event.keyCode, modifiers: modifiers))
            self.isRecording = false
            self.onStopRecording()
            return nil
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // 当用户只按了修饰键,更新显示
            return event
        }
        // Bug 🟡 修复:local monitor 装上后通知外层 beginRecording,设 activeRecording
        // 让后续 store 改动被 handleAssignmentsChanged 的 guard 拦截。
        onBeginRecording()
    }

    private func stopRecording() {
        // Bug 🟡 修复:先通知外层 endRecording 清 activeRecording,再移除 local monitor。
        // 顺序保证:onEndRecording 之后 store sink / reconcile 路径才会真正执行,
        // 不会因为 onStopRecording 调 resumeHotkey 重新注册 Carbon 时 activeRecording 还卡住。
        onEndRecording()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        flagsMonitor = nil
    }

    private static func modifiersFromEvent(_ event: NSEvent) -> ShortcutModifiers {
        var mods: ShortcutModifiers = []
        if event.modifierFlags.contains(.command) { mods.insert(.command) }
        if event.modifierFlags.contains(.option) { mods.insert(.option) }
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if event.modifierFlags.contains(.control) { mods.insert(.control) }
        return mods
    }
}

// Vitals 简化版:在 ShortcutRecorderView 之上加一个 Control 别名,提供给 SettingsView 使用。
// (Mio 原版的 ShortcutRecorderView 也保留,以便未来扩展。)