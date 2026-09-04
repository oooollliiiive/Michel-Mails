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

struct MailImageItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let cachedURL: URL

    init(cachedURL: URL) {
        self.id = UUID()
        self.cachedURL = cachedURL
    }

    var displayName: String {
        let name = cachedURL.lastPathComponent
        guard name.count > 5,
              name.prefix(4).allSatisfy(\.isNumber),
              name[name.index(name.startIndex, offsetBy: 4)] == "-" else {
            return name
        }
        return String(name.dropFirst(5))
    }
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

enum MichelMailsError: LocalizedError {
    case missingAPIKey
    case invalidAPIResponse
    case openAI(String)
    case mail(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Ajoutez une clé API OpenAI dans les réglages."
        case .invalidAPIResponse:
            return "La réponse de l’IA n’a pas pu être interprétée."
        case .openAI(let message):
            return "Erreur OpenAI : \(message)"
        case .mail(let message):
            return "Erreur Mail : \(message)"
        case .keychain(let status):
            return "Le trousseau macOS a retourné l’erreur \(status)."
        }
    }
}
