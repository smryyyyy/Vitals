import Foundation
import Security

/// Stores the three MiniMax credentials in the macOS Keychain so they
/// never end up in UserDefaults / on disk in plain text. The three values
/// share a single `kSecClassGenericPassword` item, encoded as JSON — one
/// read/write call per save. The service identifier is namespaced so
/// other apps on the system don't accidentally collide.
public struct MinimaxKeychain {
    public static let service = "com.somry.vitals.minimax"
    public static let account = "credentials"

    public static func save(_ credentials: MinimaxCredentials) throws {
        let data = try JSONEncoder().encode(Stored(credentials: credentials))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete any existing item first — SecItemUpdate is finicky about
        // matching the access policy exactly.
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    public static func load() -> MinimaxCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(Stored.self, from: data).credentials
    }

    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct Stored: Codable {
        public let credentials: MinimaxCredentials
    }

    public enum KeychainError: LocalizedError {
        case osStatus(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .osStatus(let s): return "Keychain error: \(s)"
            }
        }
    }
}
