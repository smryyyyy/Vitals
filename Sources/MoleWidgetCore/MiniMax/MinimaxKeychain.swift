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

    /// 读取结果。区分"确实没配过"和"暂时读不了" ——
    /// 之前所有非 success 状态都返回 nil,屏幕锁定时(`kSecAttrAccessibleWhenUnlocked`)
    /// 会把已经保存好的 cookie 误报成"未配置",用户白填一遍。
    public enum LoadResult: Equatable {
        /// Keychain 里根本没有这条记录
        case notFound
        /// 记录存在但当前读不出来(锁屏 / 未解锁 / 权限拒绝 / 数据损坏)
        case unavailable(OSStatus)
        /// 读到了
        case found(MinimaxCredentials)
    }

    public static func load() -> LoadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
                // 有记录但内容坏了 —— 归到"读不出来",让用户知道要重新填
                return .unavailable(errSecDecode)
            }
            return .found(stored.credentials)
        case errSecItemNotFound:
            return .notFound
        default:
            // errSecInteractionNotAllowed(锁屏)、errSecAuthFailed、errSecMissingEntitlement 等
            return .unavailable(status)
        }
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
