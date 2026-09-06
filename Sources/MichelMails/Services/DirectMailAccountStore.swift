import Foundation

enum DirectMailProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case gmail
    case iCloud

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .iCloud: return "iCloud Mail"
        }
    }

    var IMAPServer: String {
        switch self {
        case .gmail: return "imap.gmail.com"
        case .iCloud: return "imap.mail.me.com"
        }
    }

    var defaultPort: UInt16 { 993 }
}

struct DirectMailAccountConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var provider: DirectMailProvider
    var emailAddress = ""
    var username = ""
    var appPassword = ""
    var accountNameHint = ""
    var isEnabled = true

    var loginName: String {
        let explicit = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        let email = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .iCloud, let at = email.firstIndex(of: "@") {
            return String(email[..<at])
        }
        return email
    }

    var isUsable: Bool {
        isEnabled &&
            !emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !loginName.isEmpty &&
            !appPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum DirectMailAccountStore {
    static let enabledDefaultsKey = "DirectMailDownloadsEnabled"
    private static let fileName = ".direct-mail-accounts.json"
    private static let accountMappingDefaultsKey = "DirectMailAccountMappings"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    static func loadAccounts() -> [DirectMailAccountConfiguration] {
        guard let URL = privateFileURL,
              let data = try? Data(contentsOf: URL),
              let decoded = try? JSONDecoder().decode(
                  [DirectMailAccountConfiguration].self,
                  from: data
              ) else { return [] }
        return decoded
    }

    static func save(
        accounts: [DirectMailAccountConfiguration],
        enabled: Bool
    ) throws {
        UserDefaults.standard.set(enabled, forKey: enabledDefaultsKey)
        guard let URL = privateFileURL else { throw CocoaError(.fileNoSuchFile) }
        let directory = URL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: URL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: URL.path
        )
    }

    static func orderedUsableAccounts(
        for candidate: IndexedMailAttachmentCandidate
    ) -> [DirectMailAccountConfiguration] {
        guard isEnabled else { return [] }
        let accounts = loadAccounts().filter(\.isUsable)
        guard accounts.count > 1 else { return accounts }
        let learnedID = learnedMappings[candidate.accountName]
        let normalizedAccountName = normalized(candidate.accountName)
        return accounts.enumerated().sorted { left, right in
            let leftScore = score(
                left.element,
                learnedID: learnedID,
                accountName: normalizedAccountName
            )
            let rightScore = score(
                right.element,
                learnedID: learnedID,
                accountName: normalizedAccountName
            )
            if leftScore != rightScore { return leftScore > rightScore }
            return left.offset < right.offset
        }.map(\.element)
    }

    static func rememberSuccessfulAccount(
        _ account: DirectMailAccountConfiguration,
        for candidate: IndexedMailAttachmentCandidate
    ) {
        guard !candidate.accountName.isEmpty else { return }
        var mappings = learnedMappings
        mappings[candidate.accountName] = account.id.uuidString
        UserDefaults.standard.set(mappings, forKey: accountMappingDefaultsKey)
    }

    private static var learnedMappings: [String: String] {
        UserDefaults.standard.dictionary(forKey: accountMappingDefaultsKey) as? [String: String] ?? [:]
    }

    private static func score(
        _ account: DirectMailAccountConfiguration,
        learnedID: String?,
        accountName: String
    ) -> Int {
        var result = learnedID == account.id.uuidString ? 10_000 : 0
        let hint = normalized(account.accountNameHint)
        if !hint.isEmpty, accountName.contains(hint) || hint.contains(accountName) { result += 1_000 }
        let email = normalized(account.emailAddress)
        if !email.isEmpty, accountName.contains(email) { result += 500 }
        switch account.provider {
        case .gmail:
            if accountName.contains("gmail") || accountName.contains("google") { result += 100 }
        case .iCloud:
            if accountName.contains("icloud") || accountName.contains("maccom") ||
                accountName.contains("mecom") { result += 100 }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
    }

    private static var privateFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Michel Mails", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
