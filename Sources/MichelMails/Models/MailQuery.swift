import Foundation

enum MailAction: String, Codable, Sendable {
    case search
    case showImages = "show_images"
    case copyImages = "copy_images"
}

enum MailDirection: String, Codable, Sendable {
    case any
    case received
    case sent
}

struct MailQuery: Codable, Equatable, Sendable {
    var action: MailAction = .search
    var direction: MailDirection = .any
    var sender: String?
    var keywords: [String] = []
    var startDate: Date?
    var endDate: Date?
    var hasImage = false
    var hasAttachment = false
    var limit = 25
    var allResults = false
    var destinationFolder: String?
    var language = "fr"
    var confidence = 0.5

    var needsSenderResolution: Bool {
        guard let sender else { return false }
        return !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MailMessageReference: Equatable, Sendable {
    let messageIdentifier: String
    let localIdentifier: String
}

struct MailMessageItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reference: MailMessageReference
    let sender: String
    let subject: String
    let preview: String
    let receivedAt: Date?
}

struct MailSearchResults: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [MailMessageItem]
    let query: MailQuery
}

struct MailImageItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let cachedURL: URL
    let displayName: String
    let message: MailMessageItem
}

struct MailImageGallery: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [MailImageItem]
    let query: MailQuery
}

struct MailMatchSummary: Equatable, Sendable {
    let messageCount: Int
    let imageCount: Int
}

struct PendingCopy: Identifiable, Equatable, Sendable {
    let id = UUID()
    let query: MailQuery
    let summary: MailMatchSummary
}

enum MailScriptRecordParser {
    private static let recordSeparator: Character = "\u{1e}"
    private static let unitSeparator: Character = "\u{1f}"

    static func messages(from output: String) -> [MailMessageItem] {
        rows(from: output).compactMap { fields in
            guard fields.count == 6 else { return nil }
            return message(from: fields, offset: 0)
        }
    }

    static func images(from output: String, in directory: URL) -> [MailImageItem] {
        rows(from: output).compactMap { fields in
            guard fields.count == 8,
                  let message = message(from: fields, offset: 2) else { return nil }
            let cachedURL = directory.appendingPathComponent(fields[0])
            guard FileManager.default.fileExists(atPath: cachedURL.path) else { return nil }
            return MailImageItem(
                cachedURL: cachedURL,
                displayName: fields[1].nilIfEmpty ?? fields[0],
                message: message
            )
        }
    }

    private static func rows(from output: String) -> [[String]] {
        output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: recordSeparator)
            .map {
                $0.split(separator: unitSeparator, omittingEmptySubsequences: false).map(String.init)
            }
    }

    private static func message(from fields: [String], offset: Int) -> MailMessageItem? {
        guard fields.count >= offset + 6 else { return nil }
        let messageIdentifier = fields[offset]
        let localIdentifier = fields[offset + 1]
        guard !messageIdentifier.isEmpty || !localIdentifier.isEmpty else { return nil }

        return MailMessageItem(
            reference: MailMessageReference(
                messageIdentifier: messageIdentifier,
                localIdentifier: localIdentifier
            ),
            sender: fields[offset + 2].nilIfEmpty ?? "Unknown sender",
            subject: fields[offset + 3].nilIfEmpty ?? "(No subject)",
            preview: fields[offset + 4],
            receivedAt: mailDate(from: fields[offset + 5])
        )
    }

    private static func mailDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum MichelMailsError: LocalizedError {
    case missingAPIKey
    case invalidAPIResponse
    case openAI(String)
    case mail(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add an OpenAI API key in Settings."
        case .invalidAPIResponse:
            return "The AI response could not be understood."
        case .openAI(let message):
            return "OpenAI error: \(message)"
        case .mail(let message):
            return "Mail error: \(message)"
        case .keychain(let status):
            return "macOS Keychain returned error \(status)."
        }
    }
}
