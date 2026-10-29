import Foundation
import Security

/// Saves API keys in the macOS Keychain (never in a file or in settings).
enum Keychain {
    private static let service = "com.troyhomenchuk.DeskDash"

    static func read(_ account: String) -> String? {
        readData(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Any app's saved item by its service name, e.g. "Claude Code-credentials". macOS asks the user once
    /// before handing another app's item to DeskDash.
    static func readData(service: String, account: String? = nil) -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Saves `value`, or removes the key when it's empty.
    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
