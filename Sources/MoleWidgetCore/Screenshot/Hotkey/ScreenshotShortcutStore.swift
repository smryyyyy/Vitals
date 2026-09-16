//
//  ScreenshotShortcutStore.swift
//  Vitals - Screenshot module
//
//  Vitals 截图模块的快捷键存储。
//  - 复用外部共享的 `ShortcutStore`(进程级单例),只暴露 captureArea + captureAdvanced 两个动作。
//  - 关键:不能 new 一个独立的 `ShortcutStore` —— 否则 `ScreenshotServices` 里的
//    `GlobalShortcutService` 持有的 store 跟这里不是同一实例,UI 改了快捷键但
//    GlobalShortcutService 永远看不到、按下去没反应。
//  - 默认值:快速截图=⌘⇧2,高级窗口截图=⌃⌥⇧A。
//

import Combine
import Foundation

@MainActor
public final class ScreenshotShortcutStore: ObservableObject {
    static let defaultCaptureArea = ShortcutAssignment.assigned(Shortcut(
        keyCode: 19,         // kVK_ANSI_2
        modifiers: [.command, .shift]
    ))

    static let defaultCaptureAdvanced = ShortcutAssignment.assigned(Shortcut(
        keyCode: 0,          // kVK_ANSI_A
        modifiers: [.control, .option, .shift]
    ))

    @Published private(set) var captureArea: ShortcutAssignment
    @Published private(set) var captureAdvanced: ShortcutAssignment

    private let store: ShortcutStore
    private var cancellables: Set<AnyCancellable> = []

    init(store: ShortcutStore) {
        self.store = store
        self.captureArea = store.assignments.windowCapture
        self.captureAdvanced = store.assignments.advancedWindowCapture
        // 监听底层 store 的变化,同步 @Published,让 Settings UI 实时反映底层数据。
        // GlobalShortcutService 同样订阅 store.assignments 后,UI 改键 → 双方都更新。
        store.$assignments
            .receive(on: RunLoop.main)
            .sink { [weak self] assignments in
                guard let self else { return }
                if assignments.windowCapture != self.captureArea {
                    self.captureArea = assignments.windowCapture
                }
                if assignments.advancedWindowCapture != self.captureAdvanced {
                    self.captureAdvanced = assignments.advancedWindowCapture
                }
            }
            .store(in: &cancellables)
    }

    func shortcut(for command: CaptureCommand) -> ShortcutAssignment {
        switch command {
        case .captureArea: captureArea
        case .captureAdvanced: captureAdvanced
        }
    }

    func setShortcut(_ assignment: ShortcutAssignment, for command: CaptureCommand) {
        var current = store.assignments
        switch command {
        case .captureArea:
            current.windowCapture = assignment
            self.captureArea = assignment
        case .captureAdvanced:
            current.advancedWindowCapture = assignment
            self.captureAdvanced = assignment
        }
        _ = store.commit(current)
    }
}