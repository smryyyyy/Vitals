//
//  ScreenshotTypes.swift
//  Vitals - Screenshot module shared types
//
//  统一收纳截图模块的公共枚举、值类型、错误定义。
//  按 SPEC：CaptureCommand 只有 captureArea + captureAdvanced 两个分支。
//  公共类型集中在这里,避免散落在 Mio 多个文件的引用断链。
//

import CoreGraphics
import Foundation

// MARK: - 截图指令（SPEC 明确：砍掉 captureFullScreen）

/// Vitals 截图模块支持的指令集合。
/// 只保留两个：captureArea（普通区域截图）+ captureAdvanced（高级窗口截图，进编辑器）。
nonisolated enum CaptureCommand: String, Sendable, Equatable {
    /// 普通区域截图（带选区 UI，复制到剪贴板）
    case captureArea
    /// 高级窗口截图（打开编辑器）
    case captureAdvanced

    var logCode: String {
        switch self {
        case .captureArea: "capture_area"
        case .captureAdvanced: "capture_advanced"
        }
    }

    var isEditorFlow: Bool {
        self == .captureAdvanced
    }
}

// MARK: - 应用停止原因（来自 Mio module-12,简化保留）

/// 应用终止原因。CaptureController 在 stop() / cancelActiveSession 时使用。
nonisolated enum AppStopReason: Sendable, Equatable {
    case userInitiated
    case systemShutdown
    case sleep
    case userSessionResign
    case displayEnvironmentChange

    var logCode: String {
        switch self {
        case .userInitiated: "user_initiated"
        case .systemShutdown: "system_shutdown"
        case .sleep: "sleep"
        case .userSessionResign: "user_session_resign"
        case .displayEnvironmentChange: "display_environment_change"
        }
    }
}

// MARK: - Delivery types（Mio module-07 简化版）

nonisolated struct CaptureTimestamp: Sendable, Equatable {
    let instant: Date
    let timeZoneIdentifier: String
}

nonisolated enum DeliveryPolicy: Sendable, Equatable {
    case clipboardOnly

    init(preferences: CapturePreferencesSnapshot) {
        // Vitals 截图只复制到剪贴板,不落盘
        self = .clipboardOnly
    }

    var fileOrganization: CaptureFileOrganization? { nil }

    var logCode: String { "clipboard_only" }
}

nonisolated enum CaptureFileOrganization: Sendable, Equatable {
    case root
    case yearAndMonth
}

nonisolated enum FileDeliveryFailure: Error, Sendable, Equatable {
    case pngEncodingFailed
    case authorization
    case authorizationUnavailable
    case invalidCaptureTimestamp
    case directoryCreationFailed
    case permissionDenied
    case diskFull
    case nameAllocationFailed
    case temporaryWriteFailed
    case atomicPublishUnsupported
    case atomicPublishFailed

    var logCode: String {
        switch self {
        case .pngEncodingFailed: "png_encoding_failed"
        case .authorization: "authorization_failed"
        case .authorizationUnavailable: "authorization_unavailable"
        case .invalidCaptureTimestamp: "invalid_capture_timestamp"
        case .directoryCreationFailed: "directory_creation_failed"
        case .permissionDenied: "permission_denied"
        case .diskFull: "disk_full"
        case .nameAllocationFailed: "name_allocation_failed"
        case .temporaryWriteFailed: "temporary_write_failed"
        case .atomicPublishUnsupported: "atomic_publish_unsupported"
        case .atomicPublishFailed: "atomic_publish_failed"
        }
    }
}

nonisolated enum ClipboardDeliveryFailure: Error, Sendable, Equatable {
    case noEncodableRepresentation
    case representationRejected
    case writeRejected

    var logCode: String {
        switch self {
        case .noEncodableRepresentation: "no_encodable_representation"
        case .representationRejected: "representation_rejected"
        case .writeRejected: "write_rejected"
        }
    }
}

nonisolated enum FileDeliveryOutcome: Sendable, Equatable {
    case notRequested
    case saved
    case failed(FileDeliveryFailure)
    case cancelledBeforeAttempt
    case cancelledDuringAttempt

    var isSuccessful: Bool {
        if case .saved = self { return true }
        return false
    }

    var isCancelledBeforeAttempt: Bool {
        if case .cancelledBeforeAttempt = self { return true }
        return false
    }

    var isPending: Bool {
        switch self {
        case .failed, .cancelledBeforeAttempt, .cancelledDuringAttempt: true
        case .notRequested, .saved: false
        }
    }

    var logCode: String {
        switch self {
        case .notRequested: "not_requested"
        case .saved: "saved"
        case let .failed(failure): "failed_\(failure.logCode)"
        case .cancelledBeforeAttempt: "cancelled_before_attempt"
        case .cancelledDuringAttempt: "cancelled_during_attempt"
        }
    }
}

nonisolated enum ClipboardDeliveryOutcome: Sendable, Equatable {
    case copied
    case failed(ClipboardDeliveryFailure)
    case cancelledBeforeAttempt

    var isSuccessful: Bool {
        if case .copied = self { return true }
        return false
    }

    var isCancelledBeforeAttempt: Bool {
        if case .cancelledBeforeAttempt = self { return true }
        return false
    }

    var isPending: Bool {
        switch self {
        case .failed, .cancelledBeforeAttempt: true
        case .copied: false
        }
    }

    var logCode: String {
        switch self {
        case .copied: "copied"
        case let .failed(failure): "failed_\(failure.logCode)"
        case .cancelledBeforeAttempt: "cancelled_before_attempt"
        }
    }
}

nonisolated enum DeliveryCompletion: String, Sendable, Equatable {
    case complete
    case partial
    case failed
    case cancelled
}

nonisolated struct DeliveryOutcome: Sendable, Equatable {
    let file: FileDeliveryOutcome
    let clipboard: ClipboardDeliveryOutcome
    let completion: DeliveryCompletion

    init(file: FileDeliveryOutcome, clipboard: ClipboardDeliveryOutcome, completion: DeliveryCompletion) {
        self.file = file
        self.clipboard = clipboard
        self.completion = completion
    }

    static func derive(
        policy: DeliveryPolicy,
        file: FileDeliveryOutcome,
        clipboard: ClipboardDeliveryOutcome
    ) -> DeliveryOutcome {
        let fileRequested = policy.fileOrganization != nil
        let requestedCount = fileRequested ? 2 : 1
        let successCount = (file.isSuccessful ? 1 : 0) + (clipboard.isSuccessful ? 1 : 0)
        let allCancelledBeforeAttempt = clipboard.isCancelledBeforeAttempt
            && (!fileRequested || file.isCancelledBeforeAttempt)

        let completion: DeliveryCompletion
        if allCancelledBeforeAttempt {
            completion = .cancelled
        } else if successCount == requestedCount {
            completion = .complete
        } else if successCount > 0 {
            completion = .partial
        } else {
            completion = .failed
        }

        return DeliveryOutcome(file: file, clipboard: clipboard, completion: completion)
    }

    var hasSuccessfulSink: Bool {
        file.isSuccessful || clipboard.isSuccessful
    }
}

nonisolated struct DeliveryRequest: Sendable {
    let correlationID: UUID
    let image: CaptureImage
    let capturedAt: CaptureTimestamp
    let policy: DeliveryPolicy
}