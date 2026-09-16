//
//  AICredentialKeychain.swift
//  Vitals - Screenshot module
//
//  独立的 Keychain 封装,专门存 MiniMax chat completions API Key。
//  Service 名:com.skyline.vitals.ocr.aikey,与 Vitals 现有的
//  MinimaxKeychain（存的是 MiniMax 接口的 API Key）互不干扰。
//

import Foundation
import Security

/// AI 凭据抽象协议。`OCRService` 通过该协议注入,让单元测试可以用 mock
/// 实现替换真实 Keychain 访问,避免污染用户 Keychain。生产代码走
/// `AICredentialKeychain` concrete 实现。
@MainActor
protocol AICredentialKeychainProtocol: AnyObject {
    /// 读取 API Key,如不存在返回 nil。
    func readAPIKey() -> String?
    /// 是否已配置有效的 API Key。
    var hasValidAPIKey: Bool { get }
}

/// 单一字段 Keychain 存 MiniMax chat completions API Key。
@MainActor
public final class AICredentialKeychain: AICredentialKeychainProtocol {
    static let shared = AICredentialKeychain()

    private let service = "com.skyline.vitals.ocr.aikey"
    private let account = "minimax_chat_api_key"

    private init() {}

    /// 读取 API Key,如不存在返回 nil。
    func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                NSLog("AICredentialKeychain read failed: status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// 写入或更新 API Key。
    @discardableResult
    func writeAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return deleteAPIKey()
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("AICredentialKeychain add failed: status=\(addStatus)")
                return false
            }
            return true
        }
        NSLog("AICredentialKeychain update failed: status=\(updateStatus)")
        return false
    }

    /// 删除 API Key。
    @discardableResult
    func deleteAPIKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    var hasValidAPIKey: Bool {
        guard let key = readAPIKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}