import Foundation
import Security

/// A saved SMB share. Password lives in the Keychain, everything else in defaults.
struct ShareConfig: Codable, Equatable {
    var server: String
    var share: String
    var username: String

    var keychainAccount: String { "\(username)@\(server)/\(share)" }
}

enum ShareStore {
    private static let defaultsKey = "savedShare"
    private static let keychainService = "dev.mediaplayer.smb"

    static func load() -> ShareConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(ShareConfig.self, from: data)
    }

    static func save(_ config: ShareConfig, password: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(config), forKey: defaultsKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: config.keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(for config: ShareConfig) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: config.keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
