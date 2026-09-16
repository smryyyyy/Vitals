//
//  Shortcut.swift
//  Mio
//
//  Stable, layout-independent shortcut values and product validation.
//

import Foundation

public nonisolated enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case windowCapture           // Vitals: 对应 captureArea
    case advancedWindowCapture   // Vitals: 对应 captureAdvanced
}

public nonisolated struct ShortcutModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = Self(rawValue: 1 << 0)
    public static let option = Self(rawValue: 1 << 1)
    public static let shift = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    public static let supported: Self = [.command, .option, .shift, .control]
    public static let primary: Self = [.command, .option, .control]
}

public nonisolated struct Shortcut: Hashable, Codable, Sendable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
}

public nonisolated enum ShortcutAssignment: Hashable, Codable, Sendable {
    case disabled
    case assigned(Shortcut)

    var shortcut: Shortcut? {
        guard case let .assigned(shortcut) = self else { return nil }
        return shortcut
    }
}

public nonisolated struct ShortcutAssignments: Equatable, Codable, Sendable {
    var windowCapture: ShortcutAssignment
    var advancedWindowCapture: ShortcutAssignment

    subscript(action: ShortcutAction) -> ShortcutAssignment {
        get {
            switch action {
            case .windowCapture: windowCapture
            case .advancedWindowCapture: advancedWindowCapture
            }
        }
        set {
            switch action {
            case .windowCapture: windowCapture = newValue
            case .advancedWindowCapture: advancedWindowCapture = newValue
            }
        }
    }

    /// Vitals 默认值:
    /// - 快速截图: ⌘⇧2 (kVK_ANSI_2 = 19, command + shift)
    /// - 高级窗口截图: ⌃⌥⇧A (kVK_ANSI_A = 0, control + option + shift)
    static let productDefaults = Self(
        windowCapture: .assigned(Shortcut(
            keyCode: 19,
            modifiers: [.command, .shift]
        )),
        advancedWindowCapture: .assigned(Shortcut(
            keyCode: 0,
            modifiers: [.control, .option, .shift]
        ))
    )
}

public nonisolated struct ShortcutStorePayload: Equatable, Codable, Sendable {
    let schemaVersion: UInt8
    let assignments: ShortcutAssignments
}

public nonisolated enum ShortcutRegistrationFailure: Equatable, Sendable {
    public nonisolated enum Operation: String, Sendable {
        case installHandler
        case register
        case unregister
        case removeHandler
    }

    case platform(operation: Operation, osStatus: Int32)
    case registrationIdentifierExhausted
}

public nonisolated enum ShortcutRegistrationState: Equatable, Sendable {
    case notStarted
    case disabled
    case registered(Shortcut)
    case failed(desired: ShortcutAssignment, failure: ShortcutRegistrationFailure)
}

public nonisolated enum ShortcutPersistenceFailure: String, Equatable, Sendable {
    case encodingFailed
}

public nonisolated enum ShortcutValidationFailure: Equatable, Sendable {
    case unsupportedModifierBits
    case primaryModifierRequired
    case duplicate(existingAction: ShortcutAction)
}

public nonisolated enum ShortcutSemanticFailure: Equatable, Sendable {
    case unsupportedModifierBits(action: ShortcutAction)
    case primaryModifierRequired(action: ShortcutAction)
    case duplicateAssignments(first: ShortcutAction, second: ShortcutAction)
}

public nonisolated enum ShortcutStoreCommitFailure: Error, Equatable, Sendable {
    case semanticInvalid(ShortcutSemanticFailure)
    case persistence(ShortcutPersistenceFailure)
}

public nonisolated enum ShortcutStoreLoadDisposition: Equatable, Sendable {
    case loaded
    case missingDefaulted
    case decodeFailedDefaulted
    case unsupportedVersionDefaulted
    case semanticInvalidDefaulted(ShortcutSemanticFailure)
}

public nonisolated enum ShortcutReconcileReason: String, Sendable {
    case systemWake
    case sessionBecameActive
    /// Settings UI 改快捷键后,store 通知 + GlobalShortcutService 重新注册。
    case storeChanged
    /// Accessibility 授权从非授权过渡到授权后,Carbon hotkey 需重新注册才能派发事件。
    /// Bug 1-A 修复:用户首次启动时未授权 → hotkey 启动期 reconcile 失败 → 状态卡在 failed;
    /// 授权变化触发本 reason 让 service 立即重试 register。
    case accessibilityChanged
}

public nonisolated enum ShortcutReconcileOutcome: Equatable, Sendable {
    case healthy
    case degraded(failedActions: [ShortcutAction])
    case failed(ShortcutRegistrationFailure)
    case serviceStopped
}

public nonisolated enum ShortcutRecordingHost: String, Equatable, Sendable {
    case settings
    case onboarding
}

public nonisolated struct RecorderOwnerID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public nonisolated struct RecordingSessionID: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public nonisolated enum RecordingEndReason: String, Equatable, Sendable {
    case saved
    case saveFailed
    case cancelled
    case monitorInstallationFailed
    case windowResigned
    case windowClosed
    case viewDetached
    case hostHidden
    case pageChanged
    case hostCompleted
    case serviceStopped
    case deinitialized
}

public nonisolated enum BeginRecordingRejection: Equatable, Sendable {
    case recordingBusy
    case serviceNotStarted
}

public nonisolated enum BeginRecordingOutcome: Equatable, Sendable {
    case started(RecordingSessionID)
    case rejected(BeginRecordingRejection)
}

public nonisolated enum ShortcutMutationOutcome: Equatable, Sendable {
    case applied(ShortcutRegistrationState)
    case rejectedValidation(ShortcutValidationFailure)
    case rejectedStore(ShortcutStoreCommitFailure)
    case rejectedRecordingActive
    case rejectedStaleSession
    case rejectedServiceNotStarted
}

public nonisolated enum ShortcutStopOutcome: Equatable, Sendable {
    case stoppedCleanly
    case cleanupFailed(
        residualRegistrationCount: Int,
        handlerRetained: Bool,
        failures: [ShortcutRegistrationFailure]
    )
}

public nonisolated enum ShortcutValidator {
    // HIToolbox virtual key codes. This explicit set is the approved D-001-C
    // bare-key allowlist; it must not be widened to navigation or text keys.
    private static let bareKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
        103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
        114 // kVK_Help; the physical PC key is labelled Insert.
    ]

    static func validate(
        action: ShortcutAction,
        candidate: Shortcut,
        in assignments: ShortcutAssignments
    ) -> ShortcutValidationFailure? {
        guard candidate.modifiers.subtracting(.supported).isEmpty else {
            return .unsupportedModifierBits
        }

        let hasPrimaryModifier = !candidate.modifiers.intersection(.primary).isEmpty
        guard hasPrimaryModifier || bareKeyCodes.contains(candidate.keyCode) else {
            return .primaryModifierRequired
        }

        for otherAction in ShortcutAction.allCases where otherAction != action {
            if assignments[otherAction].shortcut == candidate {
                return .duplicate(existingAction: otherAction)
            }
        }

        return nil
    }

    static func validateSnapshot(
        _ assignments: ShortcutAssignments
    ) -> ShortcutSemanticFailure? {
        for action in ShortcutAction.allCases {
            guard let shortcut = assignments[action].shortcut else { continue }

            guard shortcut.modifiers.subtracting(.supported).isEmpty else {
                return .unsupportedModifierBits(action: action)
            }

            let hasPrimaryModifier = !shortcut.modifiers.intersection(.primary).isEmpty
            guard hasPrimaryModifier || bareKeyCodes.contains(shortcut.keyCode) else {
                return .primaryModifierRequired(action: action)
            }
        }

        let actions = ShortcutAction.allCases
        for firstIndex in actions.indices {
            let first = actions[firstIndex]
            guard let firstShortcut = assignments[first].shortcut else { continue }

            for secondIndex in actions.index(after: firstIndex)..<actions.endIndex {
                let second = actions[secondIndex]
                if assignments[second].shortcut == firstShortcut {
                    return .duplicateAssignments(first: first, second: second)
                }
            }
        }

        return nil
    }
}
