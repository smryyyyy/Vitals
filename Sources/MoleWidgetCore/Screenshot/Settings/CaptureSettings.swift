//
//  CaptureSettings.swift
//  Vitals - Screenshot module
//
//  Vitals 简化版 CaptureSettings。Mio 原版有完整外框（captureFrame）+ 主题
//  + 文本签名,Vitals 砍掉外框功能,只保留声音开关。
//

import Foundation
import OSLog

/// Frozen once when a capture command is accepted. Vitals 不落盘、不画外框。
nonisolated public struct CapturePreferencesSnapshot: Sendable, Equatable {
    let playSoundOnCapture: Bool
    let saveToFile: Bool
    let organizeByMonth: Bool
    let frame: CaptureFramePreference
}

nonisolated public enum CaptureFrameTheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case alwaysLight
    case alwaysDark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .auto:        "跟随系统"
        case .alwaysLight: "始终浅色"
        case .alwaysDark:  "始终深色"
        }
    }
}

nonisolated struct CaptureFramePreference: Sendable, Equatable {
    let isEnabled: Bool
    let signature: String
    let theme: CaptureFrameTheme
}

@MainActor
@Observable
public final class CaptureSettings {
    private enum Keys {
        static let saveToFile = "saveToFile"
        static let organizeByMonth = "organizeByMonth"
        static let captureFrameEnabled = "captureFrameEnabled"
        static let captureFrameCustomText = "captureFrameCustomText"
        static let captureFrameTheme = "captureFrameTheme"
    }

    private static let signatureLimit = 40
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.skyline.vitals",
        category: "Settings.Capture"
    )
    @ObservationIgnored private let defaults: UserDefaults

    public var saveToFile: Bool {
        didSet { persistIfChanged(saveToFile, oldValue: oldValue, key: Keys.saveToFile, field: "save_to_file") }
    }

    public var organizeByMonth: Bool {
        didSet { persistIfChanged(organizeByMonth, oldValue: oldValue, key: Keys.organizeByMonth, field: "organize_by_month") }
    }

    public var captureFrameEnabled: Bool {
        didSet { persistIfChanged(captureFrameEnabled, oldValue: oldValue, key: Keys.captureFrameEnabled, field: "frame_enabled") }
    }

    public private(set) var captureFrameCustomText: String

    public var captureFrameTheme: CaptureFrameTheme {
        didSet {
            guard captureFrameTheme != oldValue else { return }
            defaults.set(captureFrameTheme.rawValue, forKey: Keys.captureFrameTheme)
            logChange(field: "frame_theme")
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.saveToFile = defaults.object(forKey: Keys.saveToFile) as? Bool ?? false
        self.organizeByMonth = defaults.object(forKey: Keys.organizeByMonth) as? Bool ?? false
        self.captureFrameEnabled = defaults.object(forKey: Keys.captureFrameEnabled) as? Bool ?? false

        let storedSignature = defaults.string(forKey: Keys.captureFrameCustomText) ?? ""
        self.captureFrameCustomText = Self.canonicalSignature(storedSignature)

        let storedTheme = defaults.string(forKey: Keys.captureFrameTheme)
        self.captureFrameTheme = storedTheme.flatMap(CaptureFrameTheme.init(rawValue:)) ?? .auto
    }

    public func snapshot() -> CapturePreferencesSnapshot {
        CapturePreferencesSnapshot(
            // 「截屏后播放音效」开关已经在 UI 移除,这里固定 false → CaptureFeedbackPresenter
            // 的 `shouldPlaySound = source == .directCapture && soundEnabled && ...` 永远
            // false,等价于整个功能下线。
            playSoundOnCapture: false,
            saveToFile: saveToFile,
            organizeByMonth: organizeByMonth,
            frame: CaptureFramePreference(
                isEnabled: captureFrameEnabled,
                signature: Self.canonicalSignature(captureFrameCustomText),
                theme: captureFrameTheme
            )
        )
    }

    func setCaptureFrameCustomText(_ value: String) {
        let canonical = Self.canonicalSignature(value)
        guard canonical != captureFrameCustomText else { return }
        captureFrameCustomText = canonical
        defaults.set(canonical, forKey: Keys.captureFrameCustomText)
        logChange(field: "frame_signature")
    }

    /// 把用户偏好解析成最终的 FrameApplication。
    /// Vitals 不画外框,固定返回 .none。
    func resolvedFrameApplication(from preference: CaptureFramePreference) -> FrameApplication {
        guard preference.isEnabled else { return .none }
        let resolvedTheme: ResolvedFrameTheme = switch preference.theme {
        case .auto:        ResolvedFrameTheme.light  // Vitals 默认 light
        case .alwaysLight: .light
        case .alwaysDark:  .dark
        }
        return .apply(ResolvedFrameConfiguration(theme: resolvedTheme, signature: preference.signature))
    }

    private func persistIfChanged(_ value: Bool, oldValue: Bool, key: String, field: StaticString) {
        guard value != oldValue else { return }
        defaults.set(value, forKey: key)
        logChange(field: field)
    }

    private static func canonicalSignature(_ value: String) -> String {
        String(value.prefix(signatureLimit))
    }

    private func logChange(field: StaticString) {
        Self.logger.info("event=settings.capture.changed field=\(field, privacy: .public) result=persisted")
    }
}