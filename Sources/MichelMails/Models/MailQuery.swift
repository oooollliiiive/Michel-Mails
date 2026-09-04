import Foundation

enum MailAction: String, Codable, Sendable {
    case search
    case copyImages = "copy_images"
}

struct MailQuery: Codable, Equatable, Sendable {
    var action: MailAction = .search
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
