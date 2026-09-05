import Foundation
import SQLite3

enum DirectMailSourceError: LocalizedError {
    case fullDiskAccessRequired
    case databaseNotFound
    case incompatibleDatabase(String)

    var errorDescription: String? {
        switch self {
        case .fullDiskAccessRequired:
            return "Full Disk Access is required to read the local Mail index."
        case .databaseNotFound:
            return "Apple Mail's local index was not found."
        case .incompatibleDatabase(let detail):
            return "Apple Mail's local index could not be read: \(detail)"
        }
    }
}

actor DirectMailSource {
    private var database: OpaquePointer?
    private let versionDirectory: URL
    private var mailboxStoreDirectories: [String: [URL]] = [:]

    init() throws {
        let located = try Self.discoverIndex()
        try self.init(databaseURL: located.database, versionDirectory: located.versionDirectory)
    }

    init(databaseURL: URL, versionDirectory: URL) throws {
        self.versionDirectory = versionDirectory
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error \(status)"
            if let connection { sqlite3_close_v2(connection) }
            if status == SQLITE_CANTOPEN || status == SQLITE_PERM || status == SQLITE_AUTH {
                throw DirectMailSourceError.fullDiskAccessRequired
            }
            throw DirectMailSourceError.incompatibleDatabase(detail)
        }
        database = connection
        sqlite3_busy_timeout(connection, 1_000)
        sqlite3_exec(connection, "PRAGMA query_only = 1", nil, nil, nil)
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func totalMessageCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM messages WHERE deleted = 0")
    }

    func metadataBatch(after rowID: Int64, maximumCount: Int) throws -> DirectMailScanBatch {
        let sourceRows = try rows(after: rowID, limit: max(1, maximumCount))
        let messages = sourceRows.map { sourceRow -> IndexedMailMessage in
            var message = metadataMessage(sourceRow)
            message.sourcePath = (try? emlxURL(for: sourceRow))?.path ?? ""
            return message
        }
        return DirectMailScanBatch(
            messages: messages,
            nextRowID: sourceRows.last?.rowID ?? rowID,
            attemptedCount: sourceRows.count,
            failureCount: 0,
            isFinished: sourceRows.count < max(1, maximumCount)
        )
    }

    func contentBatch(after rowID: Int64, maximumCount: Int) throws -> DirectMailScanBatch {
        let sourceRows = try rows(after: rowID, limit: max(1, maximumCount))
        var messages: [IndexedMailMessage] = []
        var failures = 0

        for sourceRow in sourceRows {
            do {
                guard let emlxURL = try emlxURL(for: sourceRow) else {
                    failures += 1
                    continue
                }
                let parsed = try DirectEmlxReader.read(at: emlxURL)
                let externalFiles = externalAttachmentFiles(
                    messageRowID: sourceRow.rowID,
                    emlxURL: emlxURL
                )
                var attachments = parsed.attachments.map {
                    Self.indexedAttachment($0, sourcePath: "")
                }
                if !externalFiles.isEmpty {
                    let externalNames = Set(externalFiles.map { $0.name.lowercased() })
                    attachments.removeAll { externalNames.contains($0.name.lowercased()) }
                    attachments.append(contentsOf: externalFiles)
                }
                var message = metadataMessage(sourceRow)
                message = IndexedMailMessage(
                    messageIdentifier: message.messageIdentifier,
                    localIdentifier: message.localIdentifier,
                    sender: message.sender,
                    recipients: message.recipients,
                    subject: message.subject,
                    body: parsed.body,
                    receivedAt: message.receivedAt,
                    sizeBytes: message.sizeBytes,
                    mailboxName: message.mailboxName,
                    accountName: message.accountName,
                    isSent: message.isSent,
                    attachments: attachments,
                    bodyWasScanned: true,
                    sourcePath: emlxURL.path
                )
                messages.append(message)
            } catch {
                failures += 1
            }
        }

        return DirectMailScanBatch(
            messages: messages,
            nextRowID: sourceRows.last?.rowID ?? rowID,
            attemptedCount: sourceRows.count,
            failureCount: failures,
            isFinished: sourceRows.count < max(1, maximumCount)
        )
    }

    private struct SourceRow {
        let rowID: Int64
        let messageIdentifier: String
        let senderAddress: String
        let senderName: String
        let recipients: String
        let subject: String
        let receivedAt: Double?
        let sizeBytes: Int64
        let mailboxURL: String
        let attachmentNames: [String]
    }

    private func rows(after rowID: Int64, limit: Int) throws -> [SourceRow] {
        let SQL = """
        SELECT m.ROWID,
               COALESCE(g.message_id_header, ''),
               COALESCE(sender.address, ''),
               COALESCE(sender.comment, ''),
               COALESCE((
                   SELECT group_concat(
                       CASE WHEN COALESCE(recipient.comment, '') = ''
                            THEN COALESCE(recipient.address, '')
                            ELSE recipient.comment || ' <' || recipient.address || '>' END,
                       char(29)
                   )
                   FROM recipients r
                   JOIN addresses recipient ON r.address = recipient.ROWID
                   WHERE r.message = m.ROWID
               ), ''),
               COALESCE(m.subject_prefix, '') || COALESCE(subjects.subject, ''),
               m.date_received,
               COALESCE(m.size, 0),
               COALESCE(mailboxes.url, ''),
               COALESCE((
                   SELECT group_concat(replace(COALESCE(att.name, ''), char(29), ' '), char(29))
                   FROM attachments att WHERE att.message = m.ROWID
               ), '')
        FROM messages m
        LEFT JOIN message_global_data g ON m.global_message_id = g.ROWID
        LEFT JOIN addresses sender ON m.sender = sender.ROWID
        LEFT JOIN subjects subjects ON m.subject = subjects.ROWID
        LEFT JOIN mailboxes mailboxes ON m.mailbox = mailboxes.ROWID
        WHERE m.deleted = 0 AND m.ROWID > ?
        ORDER BY m.ROWID ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, SQL, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, rowID)
        sqlite3_bind_int64(statement, 2, Int64(limit))

        var result: [SourceRow] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw databaseError() }
            let receivedAt = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 6)
            let names = text(at: 9, in: statement)
                .split(separator: "\u{1d}")
                .map(String.init)
                .filter { !$0.isEmpty }
            result.append(
                SourceRow(
                    rowID: sqlite3_column_int64(statement, 0),
                    messageIdentifier: text(at: 1, in: statement),
                    senderAddress: text(at: 2, in: statement),
                    senderName: text(at: 3, in: statement),
                    recipients: text(at: 4, in: statement).replacingOccurrences(of: "\u{1d}", with: ", "),
                    subject: text(at: 5, in: statement),
                    receivedAt: receivedAt,
                    sizeBytes: sqlite3_column_int64(statement, 7),
                    mailboxURL: text(at: 8, in: statement),
                    attachmentNames: names
                )
            )
        }
        return result
    }

    private func metadataMessage(_ row: SourceRow) -> IndexedMailMessage {
        let mailbox = Self.mailboxParts(from: row.mailboxURL)
        let sender = row.senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? row.senderAddress
            : "\(row.senderName) <\(row.senderAddress)>"
        let attachments = row.attachmentNames.enumerated().map { index, name in
            Self.indexedAttachment(
                DirectEmlxAttachment(
                    identifier: "index-\(index + 1)",
                    name: name,
                    MIMEType: Self.inferredMIMEType(for: name),
                    sizeBytes: 0
                ),
                sourcePath: ""
            )
        }
        return IndexedMailMessage(
            messageIdentifier: Self.normalizedMessageIdentifier(row.messageIdentifier),
            localIdentifier: String(row.rowID),
            sender: sender,
            recipients: row.recipients,
            subject: row.subject,
            body: "",
            receivedAt: row.receivedAt.map { Date(timeIntervalSince1970: $0) },
            sizeBytes: row.sizeBytes,
            mailboxName: mailbox.name,
            accountName: mailbox.account,
            isSent: Self.isSentMailbox(mailbox.name),
            attachments: attachments,
            bodyWasScanned: false,
            sourcePath: ""
        )
    }

    private static func indexedAttachment(
        _ attachment: DirectEmlxAttachment,
        sourcePath: String
    ) -> IndexedMailAttachment {
        let MIMEType = attachment.MIMEType.isEmpty
            ? inferredMIMEType(for: attachment.name)
            : attachment.MIMEType
        let isImage = MIMEType.hasPrefix("image/") || imageExtensions.contains(
            URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        )
        let lowerName = attachment.name.lowercased()
        let isDecoration = ["signature", "logo", "spacer", "tracking", "icon"]
            .contains { lowerName.contains($0) }
        let useful = isImage && !isDecoration &&
            (attachment.sizeBytes == 0 || attachment.sizeBytes >= 5_000)
        return IndexedMailAttachment(
            identifier: attachment.identifier,
            name: attachment.name,
            MIMEType: MIMEType,
            sizeBytes: attachment.sizeBytes,
            isImage: isImage,
            isUsefulImage: useful,
            isDownloaded: !sourcePath.isEmpty,
            sourcePath: sourcePath
        )
    }

    private func emlxURL(for row: SourceRow) throws -> URL? {
        let mailbox = Self.mailboxParts(from: row.mailboxURL)
        guard !mailbox.account.isEmpty, !mailbox.components.isEmpty else { return nil }
        let storeDirectories: [URL]
        if let cached = mailboxStoreDirectories[row.mailboxURL] {
            storeDirectories = cached
        } else {
            var mailboxDirectory = versionDirectory.appendingPathComponent(mailbox.account)
            for component in mailbox.components {
                mailboxDirectory = mailboxDirectory.appendingPathComponent(component + ".mbox")
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: mailboxDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            storeDirectories = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            mailboxStoreDirectories[row.mailboxURL] = storeDirectories
        }

        let subpath = Self.emlxSubpath(for: row.rowID)
        for storeDirectory in storeDirectories {
            var messagesDirectory = storeDirectory.appendingPathComponent("Data")
            for component in subpath {
                messagesDirectory = messagesDirectory.appendingPathComponent(component)
            }
            messagesDirectory = messagesDirectory.appendingPathComponent("Messages")
            for name in ["\(row.rowID).emlx", "\(row.rowID).partial.emlx"] {
                let candidate = messagesDirectory.appendingPathComponent(name)
                if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    private func externalAttachmentFiles(
        messageRowID: Int64,
        emlxURL: URL
    ) -> [IndexedMailAttachment] {
        let partitionDirectory = emlxURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidateRoots = [
            partitionDirectory.appendingPathComponent("Attachments/\(messageRowID)"),
            partitionDirectory.deletingLastPathComponent().appendingPathComponent("Attachments/\(messageRowID)")
        ]
        var result: [IndexedMailAttachment] = []
        var seenPaths: Set<String> = []
        for root in candidateRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                guard seenPaths.insert(fileURL.path).inserted,
                      let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                result.append(
                    Self.indexedAttachment(
                        DirectEmlxAttachment(
                            identifier: "file",
                            name: fileURL.lastPathComponent,
                            MIMEType: Self.inferredMIMEType(for: fileURL.lastPathComponent),
                            sizeBytes: Int64(values.fileSize ?? 0)
                        ),
                        sourcePath: fileURL.path
                    )
                )
            }
        }
        return result
    }

    private func scalarInt(_ SQL: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, SQL, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func databaseError() -> DirectMailSourceError {
        let detail = database
            .flatMap { sqlite3_errmsg($0) }
            .map { String(cString: $0) } ?? "Unknown SQLite error"
        return .incompatibleDatabase(detail)
    }

    private func text(at index: Int32, in statement: OpaquePointer) -> String {
        guard let raw = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: raw)
    }

    private static func discoverIndex() throws -> (database: URL, versionDirectory: URL) {
        let mailDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mail", isDirectory: true)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: mailDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw DirectMailSourceError.fullDiskAccessRequired
        }
        let versions = entries.compactMap { URL -> (number: Int, URL: URL)? in
            guard URL.lastPathComponent.hasPrefix("V"),
                  let number = Int(URL.lastPathComponent.dropFirst()) else { return nil }
            return (number, URL)
        }.sorted { $0.number > $1.number }
        for version in versions {
            let database = version.URL.appendingPathComponent("MailData/Envelope Index")
            if FileManager.default.isReadableFile(atPath: database.path) {
                return (database, version.URL)
            }
        }
        if versions.isEmpty { throw DirectMailSourceError.fullDiskAccessRequired }
        throw DirectMailSourceError.databaseNotFound
    }

    private static func mailboxParts(from URLString: String) -> (
        account: String,
        components: [String],
        name: String
    ) {
        guard let separator = URLString.range(of: "://") else { return ("", [], "") }
        var components = String(URLString[separator.upperBound...])
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        let account = components.isEmpty ? "" : components.removeFirst()
        components = components.filter { !$0.isEmpty }
        return (account, components, components.last ?? "")
    }

    private static func emlxSubpath(for rowID: Int64) -> [String] {
        var quotient = rowID / 1_000
        var components: [String] = []
        while quotient > 0 {
            components.append(String(quotient % 10))
            quotient /= 10
        }
        return components
    }

    private static func normalizedMessageIdentifier(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("<") { result.removeFirst() }
        if result.hasSuffix(">") { result.removeLast() }
        return result
    }

    private static func isSentMailbox(_ name: String) -> Bool {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        return ["sent", "envoy", "gesendet", "inviati", "enviados"]
            .contains { folded.contains($0) }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"
    ]

    private static func inferredMIMEType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "zip": return "application/zip"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}
