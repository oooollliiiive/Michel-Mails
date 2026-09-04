import Foundation
import Security

enum KeychainStore {
    private static let service = "com.michelos.michelmails"
    private static let account = "openai-api-key"
    private static let fileName = ".openai-api-key"
    private static let migrationDefaultsKey = "didMigrateLegacyAPIKey"

    static func readAPIKey() -> String? {
        if let stored = readPrivateFile() {
            return stored
        }
        guard !UserDefaults.standard.bool(forKey: migrationDefaultsKey) else {
            return nil
        }

        guard let legacyValue = readLegacyKeychainItem() else {
            return nil
        }

        // Ad-hoc development builds get a new Keychain partition hash after
        // every compilation. Migrate the existing item once to a private,
        // user-only file so future app updates never trigger a password dialog.
        if (try? writePrivateFile(legacyValue)) != nil {
            UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
        }
        return legacyValue
    }

    static func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if let URL = privateFileURL, FileManager.default.fileExists(atPath: URL.path) {
                try FileManager.default.removeItem(at: URL)
            }
            UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
            return
        }

        try writePrivateFile(trimmed)
        UserDefaults.standard.set(true, forKey: migrationDefaultsKey)
    }

    private static var legacyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static var privateFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Michel Mails", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    private static func readPrivateFile() -> String? {
        guard let URL = privateFileURL,
              let data = try? Data(contentsOf: URL),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func writePrivateFile(_ value: String) throws {
        guard let URL = privateFileURL else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = URL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(value.utf8).write(to: URL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: URL.path
        )
    }

    private static func readLegacyKeychainItem() -> String? {
        var query = legacyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
