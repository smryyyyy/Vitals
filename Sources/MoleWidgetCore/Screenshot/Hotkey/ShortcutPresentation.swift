//
//  ShortcutPresentation.swift
//  Mio
//
//  Converts layout-independent shortcut identity into user-facing text.
//

import Carbon.HIToolbox
import Foundation

nonisolated struct ShortcutPresentation: Equatable, Sendable {
    let compactLabel: String
    let accessibilityLabel: String
}

@MainActor
final class ShortcutLabelFormatter {
    func presentation(for shortcut: Shortcut) -> ShortcutPresentation {
        let keyLabel = specialKeyLabel(for: shortcut.keyCode)
            ?? translatedKeyLabel(for: shortcut.keyCode)
            ?? fallbackKeyLabel(for: shortcut.keyCode)

        let compactLabel = modifierSymbols(for: shortcut.modifiers) + keyLabel
        let accessibilityLabel: String
        if shortcut.keyCode == 114 {
            accessibilityLabel = "按 \(accessibilityModifierPrefix(for: shortcut.modifiers))Help 键(在 PC 键盘上为 Insert)"
        } else {
            accessibilityLabel = accessibilityModifierPrefix(for: shortcut.modifiers) + keyLabel
        }

        return ShortcutPresentation(
            compactLabel: compactLabel,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func modifierSymbols(for modifiers: ShortcutModifiers) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private func accessibilityModifierPrefix(for modifiers: ShortcutModifiers) -> String {
        var names: [String] = []
        if modifiers.contains(.control) {
            names.append("Control")
        }
        if modifiers.contains(.option) {
            names.append("Option")
        }
        if modifiers.contains(.shift) {
            names.append("Shift")
        }
        if modifiers.contains(.command) {
            names.append("Command")
        }
        guard !names.isEmpty else { return "" }
        return names.joined(separator: ", ") + ", "
    }

    private func specialKeyLabel(for keyCode: UInt16) -> String? {
        if keyCode == 114 {
            return "Insert"
        }

        if let functionKey = Self.functionKeyLabels[keyCode] {
            return functionKey
        }

        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "空格"
        case 51: return "Delete"
        case 53: return "Esc"
        case 117: return "Forward Delete"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return nil
        }
    }

    private func translatedKeyLabel(for keyCode: UInt16) -> String? {
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
            )
        else {
            return nil
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let keyboardLayout = UnsafeRawPointer(bytes)
            .assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &length,
            &characters
        )

        guard status == noErr, length > 0 else { return nil }
        let value = String(utf16CodeUnits: characters, count: length).uppercased()
        guard
            !value.isEmpty,
            value.unicodeScalars.allSatisfy(Self.isPresentable)
        else {
            return nil
        }
        return value
    }

    private func fallbackKeyLabel(for keyCode: UInt16) -> String {
        "按键 \(keyCode)"
    }

    private static func isPresentable(_ scalar: Unicode.Scalar) -> Bool {
        guard !CharacterSet.controlCharacters.contains(scalar) else { return false }
        return !(0xE000...0xF8FF).contains(scalar.value)
            && !(0xF0000...0xFFFFD).contains(scalar.value)
            && !(0x100000...0x10FFFD).contains(scalar.value)
    }

    private static let functionKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
}
