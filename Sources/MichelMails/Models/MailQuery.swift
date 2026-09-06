import Foundation

enum MailAction: String, Codable, Sendable {
    case search
    case showImages = "show_images"
    case showFiles = "show_files"
    case copyImages = "copy_images"
}

enum MailDirection: String, Codable, Sendable {
    case any
    case received
    case sent
}

enum MailSortOrder: String, Codable, Sendable {
    case newestFirst = "newest_first"
    case oldestFirst = "oldest_first"
}

enum MailAttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case pdf
    case document
    case spreadsheet
    case presentation
    case archive
    case audio
    case video
    case other

    static func classify(name: String, MIMEType: String, declaredImage: Bool = false) -> Self {
        let MIME = MIMEType.lowercased()
        let extensionName = URL(fileURLWithPath: name).pathExtension.lowercased()
        if declaredImage || MIME.hasPrefix("image/") || imageExtensions.contains(extensionName) {
            return .image
        }
        if MIME == "application/pdf" || extensionName == "pdf" { return .pdf }
        if documentExtensions.contains(extensionName) { return .document }
        if spreadsheetExtensions.contains(extensionName) { return .spreadsheet }
        if presentationExtensions.contains(extensionName) { return .presentation }
        if archiveExtensions.contains(extensionName) { return .archive }
        if MIME.hasPrefix("audio/") || audioExtensions.contains(extensionName) { return .audio }
        if MIME.hasPrefix("video/") || videoExtensions.contains(extensionName) { return .video }
        return .other
    }

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp",
        "svg", "svgz", "avif", "jp2", "j2k", "raw", "dng", "cr2", "cr3", "nef", "arw",
        "raf", "orf", "rw2", "pef"
    ]
    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg", "webm", "mkv", "3gp"
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"
    ]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "rtf", "txt", "pages", "odt"
    ]
    private static let spreadsheetExtensions: Set<String> = [
        "xls", "xlsx", "csv", "numbers", "ods"
    ]
    private static let presentationExtensions: Set<String> = [
        "ppt", "pptx", "key", "odp"
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz"
    ]
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
    var attachmentKinds: [MailAttachmentKind] = []
    var sortOrder: MailSortOrder = .newestFirst
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
    var accountName: String = ""
    var mailboxName: String = ""
    var sourcePath: String = ""

    var stableKey: String {
        if !messageIdentifier.isEmpty { return "message:\(messageIdentifier)" }
        return "local:\(accountName):\(localIdentifier)"
    }
}

struct MailMessageItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reference: MailMessageReference
    let sender: String
    let subject: String
    let preview: String
    let receivedAt: Date?
    var hasAttachment = false
    var attachments: [IndexedMailAttachmentCandidate] = []

    var imageAttachments: [IndexedMailAttachmentCandidate] {
        attachments.filter { $0.kind == .image }
    }
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
    let MIMEType: String
    let kind: MailAttachmentKind
    let message: MailMessageItem
    var sourceCandidate: IndexedMailAttachmentCandidate?
    var hasOriginalFile = true
    var isPotentialParasite = false
}

enum AttachmentTransferState: String, Equatable, Sendable {
    case available
    case queued
    case downloading
    case deferred
    case ready
    case failed
}

struct AttachmentTransferRecord: Identifiable, Equatable, Sendable {
    var id: String { candidate.stableKey }
    var candidate: IndexedMailAttachmentCandidate
    var state: AttachmentTransferState
    var thumbnailURL: URL?
    var exportedURL: URL?
    var exportDirectoryURL: URL?
    var needsThumbnail: Bool
    var needsExport: Bool
    var needsOriginal = false
    var allowsMailDownload = false
    var automaticallyDownloadIfNeeded = false
    var shouldCacheOriginal = false
    var isVisibleInDownloads = false
    var openWhenReady = false
    var errorMessage: String?
}

struct MailImageGallery: Identifiable, Equatable, Sendable {
    let id = UUID()
    let items: [MailImageItem]
    let query: MailQuery
    var attemptedCount = 0
}

struct MailMatchSummary: Equatable, Sendable {
    let messageCount: Int
    let imageCount: Int
}

struct PendingCopy: Identifiable, Equatable, Sendable {
    let id = UUID()
    let query: MailQuery
    let summary: MailMatchSummary
    let candidates: [IndexedMailAttachmentCandidate]
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

    static func files(from output: String, in directory: URL) -> [MailImageItem] {
        rows(from: output).compactMap { fields in
            guard fields.count == 9,
                  let message = message(from: fields, offset: 3) else { return nil }
            let cachedURL = directory.appendingPathComponent(fields[0])
            guard FileManager.default.fileExists(atPath: cachedURL.path) else { return nil }
            return MailImageItem(
                cachedURL: cachedURL,
                displayName: fields[1].nilIfEmpty ?? fields[0],
                MIMEType: fields[2],
                kind: attachmentKind(name: fields[1], MIMEType: fields[2]),
                message: message
            )
        }
    }

    static func images(from output: String, in directory: URL) -> [MailImageItem] {
        files(from: output, in: directory)
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

    private static func attachmentKind(name: String, MIMEType: String) -> MailAttachmentKind {
        MailAttachmentKind.classify(name: name, MIMEType: MIMEType)
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
    case index(String)
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
        case .index(let message):
            return "Email index error: \(message)"
        case .keychain(let status):
            return "macOS Keychain returned error \(status)."
        }
    }
}
