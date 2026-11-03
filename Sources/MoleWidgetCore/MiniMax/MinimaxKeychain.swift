import Foundation
import Security

/// Keychain 存取器。service / account 可注入 —— 测试必须用**独立的 service**,
/// 否则会动到用户真实凭据。
///
/// 为什么要有实例版(2026-11-03 实测踩坑):
/// `SecItemDelete` 在跨应用场景下会**静默失败** —— 测试进程删不掉
/// /Applications 里 Vitals.app 创建的记录。于是测试里那句「clear 一下再断言
/// .notFound」实际没清掉,而 `save()` 里的 `SecItemUpdate` 却把**真实凭据覆盖成
/// 假数据**,最后 `clear()` 再把记录删掉 —— 用户配置两头落空。
/// 换成独立 service 后,测试在自己的 namespace 里操作,碰不到真实记录。
public struct MinimaxKeychainStore {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    /// 写入(或更新)凭据。
    ///
    /// 优先走 update,**不先删**。
    ///
    /// 为什么:自动续期(`MinimaxTokenRenewer`)会定期把新 token 写回这里。
    /// 旧的「先 SecItemDelete 再 SecItemAdd」一旦 add 失败(钥匙串锁着、
    /// 权限被拒、系统繁忙),用户配置就两头落空 —— 记录被删了、新值没写进去,
    /// 相当于「续期把配置搞没了」。先 update 就没有这个窗口:
    /// update 失败(通常是记录不存在,errSecItemNotFound)才退回 delete + add。
    public func save(_ credentials: MinimaxCredentials) throws {
        let data = try JSONEncoder().encode(Stored(credentials: credentials))
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw MinimaxKeychain.KeychainError.osStatus(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MinimaxKeychain.KeychainError.osStatus(status)
        }
    }

    /// 读取结果。区分"确实没配过"和"暂时读不了" ——
    /// 之前所有非 success 状态都返回 nil,屏幕锁定时(`kSecAttrAccessibleWhenUnlocked`)
    /// 会把已经保存好的 cookie 误报成"未配置",用户白填一遍。
    public func load() -> MinimaxKeychain.LoadResult {
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

    public func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 凭据在 Keychain 里的存储格式(两个字段打包成一条 generic password)。
private struct Stored: Codable {
    let credentials: MinimaxCredentials
}

/// 生产用的 Keychain 入口。固定 service / account,只存 MiniMax 用量凭据。
///
/// 存的是 `_token` + `minimax_group_id_v2` 两个值 —— `HERTZ-SESSION` 已移除
/// (实测用量接口不带它也返回 200),它原本是最先过期的那个。
public struct MinimaxKeychain {
    public static let service = "com.somry.vitals.minimax"
    public static let account = "credentials"

    private static var store: MinimaxKeychainStore {
        MinimaxKeychainStore(service: service, account: account)
    }

    public static func save(_ credentials: MinimaxCredentials) throws {
        try store.save(credentials)
    }

    public static func load() -> LoadResult {
        store.load()
    }

    public static func clear() {
        store.clear()
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

    public enum KeychainError: LocalizedError {
        case osStatus(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .osStatus(let s): return "Keychain error: \(s)"
            }
        }
    }
}
