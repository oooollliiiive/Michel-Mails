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
    private let schema: EnvelopeSchema
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
        sqlite3_busy_timeout(connection, 1_000)
        sqlite3_exec(connection, "PRAGMA query_only = 1", nil, nil, nil)
        do {
            schema = try EnvelopeSchema(connection: connection)
            database = connection
        } catch {
            sqlite3_close_v2(connection)
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func totalMessageCount() throws -> Int {
        try scalarInt(schema.countSQL)
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
                let parsedAttachments = parsed.attachments.enumerated().map { index, attachment in
                    Self.indexedAttachment(
                        DirectEmlxAttachment(
                            identifier: attachment.identifier.isEmpty
                                ? "index-\(index + 1)"
                                : attachment.identifier,
                            name: attachment.name,
                            MIMEType: attachment.MIMEType,
                            sizeBytes: attachment.sizeBytes
                        ),
                        sourcePath: ""
                    )
                }
                let attachments = Self.reconciledAttachments(
                    parsed: parsedAttachments,
                    external: externalFiles
                )
                var message = metadataMessage(sourceRow)
                message = IndexedMailMessage(
                    messageIdentifier: parsed.messageIdentifier.contains("@")
                        ? parsed.messageIdentifier
                        : message.messageIdentifier,
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
                    sourcePath: emlxURL.path,
                    storageKey: message.key
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

    /// Apple changes the private Envelope Index schema between macOS releases.
    /// Build a query only from columns found in the database instead of pinning
    /// the scanner to one OS version.
    private struct EnvelopeSchema {
        let countSQL: String
        let rowsSQL: String

        init(connection: OpaquePointer) throws {
            let messages = try Self.columns(in: "messages", connection: connection)
            guard !messages.isEmpty else {
                throw DirectMailSourceError.incompatibleDatabase("the messages table is missing")
            }

            let globalData = try Self.columns(in: "message_global_data", connection: connection)
            let addresses = try Self.columns(in: "addresses", connection: connection)
            let subjects = try Self.columns(in: "subjects", connection: connection)
            let mailboxes = try Self.columns(in: "mailboxes", connection: connection)
            let recipients = try Self.columns(in: "recipients", connection: connection)
            let attachments = try Self.columns(in: "attachments", connection: connection)

            var joins: [String] = []

            var messageIdentifier = "''"
            if messages.contains("global_message_id"),
               let identifierColumn = Self.first(
                   ["message_id_header", "message_identifier", "internet_message_id", "message_id"],
                   in: globalData
               ) {
                joins.append("LEFT JOIN message_global_data g ON m.global_message_id = g.ROWID")
                messageIdentifier = "COALESCE(CAST(g.\(identifierColumn) AS TEXT), '')"
            } else if let identifierColumn = Self.first(
                ["message_id_header", "message_identifier", "internet_message_id", "document_id", "remote_id"],
                in: messages
            ) {
                messageIdentifier = "COALESCE(CAST(m.\(identifierColumn) AS TEXT), '')"
            }

            var senderAddress = "''"
            var senderName = "''"
            if messages.contains("sender"),
               addresses.contains("address") {
                joins.append("LEFT JOIN addresses sender ON m.sender = sender.ROWID")
                senderAddress = "COALESCE(sender.address, '')"
                if addresses.contains("comment") {
                    senderName = "COALESCE(sender.comment, '')"
                }
            }

            var subject = messages.contains("subject_prefix")
                ? "COALESCE(m.subject_prefix, '')"
                : "''"
            if messages.contains("subject"), subjects.contains("subject") {
                joins.append("LEFT JOIN subjects subjects ON m.subject = subjects.ROWID")
                subject += " || COALESCE(subjects.subject, '')"
            } else if let directSubject = Self.first(["subject_text", "subject_string"], in: messages) {
                subject += " || COALESCE(CAST(m.\(directSubject) AS TEXT), '')"
            }

            var mailboxURL = "''"
            if messages.contains("mailbox"), mailboxes.contains("url") {
                joins.append("LEFT JOIN mailboxes mailboxes ON m.mailbox = mailboxes.ROWID")
                mailboxURL = "COALESCE(mailboxes.url, '')"
            }

            let recipientsSQL: String
            if recipients.contains("message"),
               recipients.contains("address"),
               addresses.contains("address") {
                let recipientName = addresses.contains("comment")
                    ? "COALESCE(recipient.comment, '')"
                    : "''"
                recipientsSQL = """
                COALESCE((
                    SELECT group_concat(
                        CASE WHEN \(recipientName) = ''
                             THEN COALESCE(recipient.address, '')
                             ELSE \(recipientName) || ' <' || recipient.address || '>' END,
                        char(29)
                    )
                    FROM recipients r
                    JOIN addresses recipient ON r.address = recipient.ROWID
                    WHERE r.message = m.ROWID
                ), '')
                """
            } else {
                recipientsSQL = "''"
            }

            let attachmentNamesSQL: String
            if attachments.contains("message"), attachments.contains("name") {
                attachmentNamesSQL = """
                COALESCE((
                    SELECT group_concat(replace(COALESCE(att.name, ''), char(29), ' '), char(29))
                    FROM attachments att WHERE att.message = m.ROWID
                ), '')
                """
            } else {
                attachmentNamesSQL = "''"
            }

            let receivedAt = Self.first(
                ["date_received", "date_sent", "display_date"],
                in: messages
            ).map { "m.\($0)" } ?? "NULL"
            let size = Self.first(["size", "message_size"], in: messages)
                .map { "COALESCE(m.\($0), 0)" } ?? "0"
            let visibleCondition = messages.contains("deleted") ? "m.deleted = 0 AND " : ""

            countSQL = "SELECT COUNT(*) FROM messages m WHERE \(visibleCondition)1 = 1"
            rowsSQL = """
            SELECT m.ROWID,
                   \(messageIdentifier),
                   \(senderAddress),
                   \(senderName),
                   \(recipientsSQL),
                   \(subject),
                   \(receivedAt),
                   \(size),
                   \(mailboxURL),
                   \(attachmentNamesSQL)
            FROM messages m
            \(joins.joined(separator: "\n"))
            WHERE \(visibleCondition)m.ROWID > ?
            ORDER BY m.ROWID ASC
            LIMIT ?
            """
        }

        private static func first(_ candidates: [String], in columns: Set<String>) -> String? {
            candidates.first { columns.contains($0) }
        }

        private static func columns(
            in table: String,
            connection: OpaquePointer
        ) throws -> Set<String> {
            // Table names are internal constants, never input from an email or the user.
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                let detail = String(cString: sqlite3_errmsg(connection))
                throw DirectMailSourceError.incompatibleDatabase(detail)
            }
            defer { sqlite3_finalize(statement) }
            var result: Set<String> = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else {
                    let detail = String(cString: sqlite3_errmsg(connection))
                    throw DirectMailSourceError.incompatibleDatabase(detail)
                }
                if let value = sqlite3_column_text(statement, 1) {
                    result.insert(String(cString: value).lowercased())
                }
            }
            return result
        }
    }

    private func rows(after rowID: Int64, limit: Int) throws -> [SourceRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, schema.rowsSQL, -1, &statement, nil) == SQLITE_OK,
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
        let isImage = MIMEType.hasPrefix("image/") || MailAttachmentKind.imageExtensions.contains(
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
                            identifier: Self.externalMIMEIdentifier(
                                for: fileURL,
                                relativeTo: root
                            ) ?? "file",
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

    static func reconciledAttachments(
        parsed: [IndexedMailAttachment],
        external: [IndexedMailAttachment]
    ) -> [IndexedMailAttachment] {
        guard !external.isEmpty else { return parsed }
        var unmatchedExternal = external
        var result: [IndexedMailAttachment] = []

        for parsedAttachment in parsed {
            let parsedPart = MailAttachmentIdentity.canonicalMIMEPartIdentifier(
                parsedAttachment.identifier
            )
            let parsedName = MailAttachmentIdentity.canonicalFileName(parsedAttachment.name)
            let matchIndex = unmatchedExternal.firstIndex { externalAttachment in
                let externalPart = MailAttachmentIdentity.canonicalMIMEPartIdentifier(
                    externalAttachment.identifier
                )
                if let parsedPart, let externalPart, parsedPart == externalPart { return true }
                return !parsedName.isEmpty && parsedName == MailAttachmentIdentity.canonicalFileName(
                    externalAttachment.name
                )
            }
            if let matchIndex {
                result.append(unmatchedExternal.remove(at: matchIndex))
            } else {
                result.append(parsedAttachment)
            }
        }
        result.append(contentsOf: unmatchedExternal)
        return result
    }

    private static func externalMIMEIdentifier(for fileURL: URL, relativeTo root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count + 1,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        let partDirectory = fileComponents[rootComponents.count]
        return MailAttachmentIdentity.canonicalMIMEPartIdentifier(partDirectory)
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

    private static func inferredMIMEType(for name: String) -> String {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "tif", "tiff": return "image/tiff"
        case "bmp": return "image/bmp"
        case "svg", "svgz": return "image/svg+xml"
        case "avif": return "image/avif"
        case "jp2", "j2k": return "image/jp2"
        case "dng": return "image/x-adobe-dng"
        case "cr2", "cr3": return "image/x-canon-cr2"
        case "nef": return "image/x-nikon-nef"
        case "arw": return "image/x-sony-arw"
        case "raf": return "image/x-fuji-raf"
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
        case "m4v": return "video/x-m4v"
        case "avi": return "video/x-msvideo"
        case "mpg", "mpeg": return "video/mpeg"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
