import Foundation

enum MailScanPhase: String, Equatable, Sendable {
    case metadata
    case content
}

struct MailScanProgress: Equatable, Sendable {
    var scanned = 0
    var total = 0
    var failures = 0
    var isFinished = false
    var phase: MailScanPhase = .metadata

    var statusText: String {
        if total == 0 && !isFinished { return "Starting email scan…" }
        let unit = phase == .metadata ? "emails scanned" : "email texts indexed"
        let base = "\(scanned.formatted()) / \(total.formatted()) \(unit)"
        if failures > 0 {
            return "\(base) · \(failures.formatted()) skipped"
        }
        return base
    }
}

struct MailScanCursor: Equatable, Sendable {
    var mailboxIndex: Int
    var messageIndex: Int
}

struct IndexedMailAttachment: Equatable, Sendable {
    let identifier: String
    let name: String
    let MIMEType: String
    let sizeBytes: Int64
    let isImage: Bool
    let isUsefulImage: Bool
    let isDownloaded: Bool
    var sourcePath: String = ""
}

struct IndexedMailMessage: Equatable, Sendable {
    let messageIdentifier: String
    let localIdentifier: String
    let sender: String
    let recipients: String
    let subject: String
    let body: String
    let receivedAt: Date?
    let sizeBytes: Int64
    let mailboxName: String
    let accountName: String
    let isSent: Bool
    let attachments: [IndexedMailAttachment]
    var bodyWasScanned: Bool = true
    var sourcePath: String = ""

    var key: String {
        if !messageIdentifier.isEmpty { return "message:\(messageIdentifier)" }
        return "local:\(accountName):\(localIdentifier)"
    }
}

struct IndexedMailAttachmentCandidate: Equatable, Sendable {
    let messageIdentifier: String
    let localIdentifier: String
    let sender: String
    let subject: String
    let preview: String
    let receivedAt: Date?
    let accountName: String
    let mailboxName: String
    let attachmentIdentifier: String
    let attachmentName: String
    let MIMEType: String
    let sizeBytes: Int64
    let kind: MailAttachmentKind
    var messageSourcePath: String = ""
    var sourcePath: String = ""
    var isPotentialParasite = false

    var message: MailMessageItem {
        MailMessageItem(
            reference: MailMessageReference(
                messageIdentifier: messageIdentifier,
                localIdentifier: localIdentifier,
                accountName: accountName,
                mailboxName: mailboxName,
                sourcePath: messageSourcePath
            ),
            sender: sender.isEmpty ? "Unknown sender" : sender,
            subject: subject.isEmpty ? "(No subject)" : subject,
            preview: preview,
            receivedAt: receivedAt,
            hasAttachment: true
        )
    }
}

struct DirectMailScanBatch: Equatable, Sendable {
    let messages: [IndexedMailMessage]
    let nextRowID: Int64
    let attemptedCount: Int
    let failureCount: Int
    let isFinished: Bool
}

struct DirectMailScanState: Equatable, Sendable {
    var indexProgress = MailScanProgress(phase: .metadata)
    var indexCursorRowID: Int64 = 0
    var contentProgress = MailScanProgress(phase: .content)
    var contentCursorRowID: Int64 = 0
}

struct MailScanBatch: Equatable, Sendable {
    let messages: [IndexedMailMessage]
    let nextCursor: MailScanCursor
    let attemptedCount: Int
    let failureCount: Int
    let isFinished: Bool
    var phase: MailScanPhase = .metadata
}

enum MailScanRecordParser {
    private static let recordSeparator: Character = "\u{1e}"
    private static let unitSeparator: Character = "\u{1f}"
    private static let attachmentSeparator: Character = "\u{1d}"
    private static let attachmentFieldSeparator: Character = "\u{1c}"

    static func parse(_ output: String) -> MailScanBatch? {
        let rows = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: recordSeparator, omittingEmptySubsequences: false)
            .map {
                $0.split(separator: unitSeparator, omittingEmptySubsequences: false).map(String.init)
            }
        guard let header = rows.first,
              (header.count == 6 || header.count == 7),
              header[0] == "H",
              let mailboxIndex = Int(header[1]),
              let messageIndex = Int(header[2]),
              let attemptedCount = Int(header[4]),
              let failureCount = Int(header[5]) else {
            return nil
        }

        let phase = header.count == 7 ? MailScanPhase(rawValue: header[6]) ?? .metadata : .metadata
        return MailScanBatch(
            messages: rows.dropFirst().compactMap(parseMessage),
            nextCursor: MailScanCursor(mailboxIndex: mailboxIndex, messageIndex: messageIndex),
            attemptedCount: attemptedCount,
            failureCount: failureCount,
            isFinished: header[3] == "true",
            phase: phase
        )
    }

    private static func parseMessage(_ fields: [String]) -> IndexedMailMessage? {
        guard (fields.count == 13 || fields.count == 14),
              fields[0] == "M",
              let sizeBytes = Int64(fields[7]) else {
            return nil
        }

        let hasBodyState = fields.count == 14
        return IndexedMailMessage(
            messageIdentifier: fields[1],
            localIdentifier: fields[2],
            sender: fields[3],
            recipients: fields[4],
            subject: fields[5],
            body: fields[6],
            receivedAt: mailDate(from: fields[8]),
            sizeBytes: sizeBytes,
            mailboxName: fields[9],
            accountName: fields[10],
            isSent: fields[11] == "true",
            attachments: parseAttachments(fields[hasBodyState ? 13 : 12]),
            bodyWasScanned: hasBodyState ? fields[12] == "true" : true
        )
    }

    private static func parseAttachments(_ value: String) -> [IndexedMailAttachment] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: attachmentSeparator).compactMap { rawAttachment in
            let fields = rawAttachment
                .split(separator: attachmentFieldSeparator, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 7, let sizeBytes = Int64(fields[3]) else { return nil }
            return IndexedMailAttachment(
                identifier: fields[0],
                name: fields[1],
                MIMEType: fields[2],
                sizeBytes: sizeBytes,
                isImage: fields[4] == "true",
                isUsefulImage: fields[5] == "true",
                isDownloaded: fields[6] == "true"
            )
        }
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
