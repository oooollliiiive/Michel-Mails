import Foundation
import SQLite3

private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor MailIndexDatabase {
    private var database: OpaquePointer?

    init(databaseURL suppliedDatabaseURL: URL? = nil) throws {
        let manager = FileManager.default
        let databaseURL: URL
        let supportDirectory: URL
        if let suppliedDatabaseURL {
            databaseURL = suppliedDatabaseURL
            supportDirectory = suppliedDatabaseURL.deletingLastPathComponent()
        } else {
            supportDirectory = try manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Michel Mails", isDirectory: true)
            databaseURL = supportDirectory.appendingPathComponent("mail-index.sqlite")
        }
        try manager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var connection: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw MichelMailsError.index("The local email index could not be opened.")
        }
        database = connection
        try Self.execute(Self.schema, on: connection)
        // Migration for databases created by early local development builds.
        try? Self.execute(
            "ALTER TABLE attachments ADD COLUMN kind TEXT NOT NULL DEFAULT 'other'",
            on: connection
        )
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func state(total latestTotal: Int) throws -> (progress: MailScanProgress, cursor: MailScanCursor) {
        guard let statement = try prepare(
            "SELECT total, scanned, failures, cursor_mailbox, cursor_message, finished FROM scan_state WHERE id = 1"
        ) else {
            throw MichelMailsError.index("The email scan state is unavailable.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MichelMailsError.index("The email scan state is unavailable.")
        }

        var total = Int(sqlite3_column_int64(statement, 0))
        var scanned = Int(sqlite3_column_int64(statement, 1))
        let failures = Int(sqlite3_column_int64(statement, 2))
        var mailboxIndex = Int(sqlite3_column_int64(statement, 3))
        var messageIndex = Int(sqlite3_column_int64(statement, 4))
        var finished = sqlite3_column_int(statement, 5) == 1

        if total == 0 {
            total = latestTotal
            try updateState(
                total: total,
                scanned: 0,
                failures: 0,
                cursor: MailScanCursor(mailboxIndex: 1, messageIndex: 1),
                finished: total == 0
            )
        } else if latestTotal > total && finished {
            // A new full pass discovers new messages while retaining every
            // previously indexed row. Upserts make the pass safe and resumable.
            total = latestTotal
            scanned = 0
            mailboxIndex = 1
            messageIndex = 1
            finished = false
            try updateState(
                total: total,
                scanned: scanned,
                failures: failures,
                cursor: MailScanCursor(mailboxIndex: mailboxIndex, messageIndex: messageIndex),
                finished: false
            )
        } else if latestTotal > total {
            total = latestTotal
            try execute("UPDATE scan_state SET total = \(total) WHERE id = 1")
        }

        return (
            MailScanProgress(scanned: scanned, total: total, failures: failures, isFinished: finished),
            MailScanCursor(mailboxIndex: mailboxIndex, messageIndex: messageIndex)
        )
    }

    func save(_ batch: MailScanBatch, total: Int, previous: MailScanProgress) throws -> MailScanProgress {
        try execute("BEGIN IMMEDIATE")
        do {
            for message in batch.messages {
                try upsert(message)
            }
            let scanned = min(total, previous.scanned + batch.attemptedCount)
            let failures = previous.failures + batch.failureCount
            let finished = batch.isFinished || scanned >= total
            try updateState(
                total: total,
                scanned: scanned,
                failures: failures,
                cursor: batch.nextCursor,
                finished: finished
            )
            try execute("COMMIT")
            return MailScanProgress(
                scanned: scanned,
                total: total,
                failures: failures,
                isFinished: finished
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func indexedMessageCount() throws -> Int {
        guard let statement = try prepare("SELECT COUNT(*) FROM messages") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func searchMessages(_ query: MailQuery) throws -> MailSearchResults {
        var conditions: [String] = []
        var bindings: [Binding] = []

        switch query.direction {
        case .any:
            break
        case .received:
            conditions.append("m.is_sent = 0")
        case .sent:
            conditions.append("m.is_sent = 1")
        }

        if let sender = query.sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            conditions.append("lower(m.sender) LIKE lower(?)")
            bindings.append(.text("%\(sender)%"))
        }
        if let startDate = query.startDate {
            conditions.append("m.received_at >= ?")
            bindings.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = query.endDate {
            conditions.append("m.received_at < ?")
            bindings.append(.double(endDate.timeIntervalSince1970))
        }
        if query.hasAttachment {
            conditions.append("m.has_attachment = 1")
        }
        if query.hasImage {
            conditions.append("m.has_useful_image = 1")
        }
        if !query.attachmentKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: query.attachmentKinds.count)
                .joined(separator: ", ")
            conditions.append(
                "EXISTS (SELECT 1 FROM attachments a WHERE a.message_key = m.message_key AND a.kind IN (\(placeholders)))"
            )
            bindings.append(contentsOf: query.attachmentKinds.map { .text($0.rawValue) })
        }

        let searchTokens = query.keywords.flatMap(Self.searchTokens)
        if !searchTokens.isEmpty {
            let FTSQuery = searchTokens
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
                .joined(separator: " AND ")
            conditions.append(
                "m.message_key IN (SELECT message_key FROM messages_fts WHERE messages_fts MATCH ?)"
            )
            bindings.append(.text(FTSQuery))
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let order = query.sortOrder == .oldestFirst ? "ASC" : "DESC"
        let maximumResults = query.allResults ? 100_000 : min(max(query.limit, 1), 100)
        bindings.append(.integer(Int64(maximumResults)))

        let SQL = """
        SELECT m.message_identifier, m.local_identifier, m.sender, m.subject,
               substr(m.body, 1, 240), m.received_at
        FROM messages m
        \(whereClause)
        ORDER BY m.received_at \(order), m.message_key \(order)
        LIMIT ?
        """
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The local email search could not be prepared.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var items: [MailMessageItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let receivedAt = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let sender = Self.text(at: 2, in: statement)
            let subject = Self.text(at: 3, in: statement)
            items.append(
                MailMessageItem(
                    reference: MailMessageReference(
                        messageIdentifier: Self.text(at: 0, in: statement),
                        localIdentifier: Self.text(at: 1, in: statement)
                    ),
                    sender: sender.isEmpty ? "Unknown sender" : sender,
                    subject: subject.isEmpty ? "(No subject)" : subject,
                    preview: Self.text(at: 4, in: statement)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                    receivedAt: receivedAt
                )
            )
        }
        return MailSearchResults(items: items, query: query)
    }

    func searchAttachments(_ query: MailQuery) throws -> [IndexedMailAttachmentCandidate] {
        var conditions: [String] = ["a.size_bytes > 0"]
        var bindings: [Binding] = []

        switch query.direction {
        case .any:
            break
        case .received:
            conditions.append("m.is_sent = 0")
        case .sent:
            conditions.append("m.is_sent = 1")
        }
        if let sender = query.sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            conditions.append("lower(m.sender) LIKE lower(?)")
            bindings.append(.text("%\(sender)%"))
        }
        if let startDate = query.startDate {
            conditions.append("m.received_at >= ?")
            bindings.append(.double(startDate.timeIntervalSince1970))
        }
        if let endDate = query.endDate {
            conditions.append("m.received_at < ?")
            bindings.append(.double(endDate.timeIntervalSince1970))
        }

        let requestedKinds = query.attachmentKinds.isEmpty && query.hasImage
            ? [MailAttachmentKind.image]
            : query.attachmentKinds
        if !requestedKinds.isEmpty {
            let placeholders = Array(repeating: "?", count: requestedKinds.count)
                .joined(separator: ", ")
            conditions.append("a.kind IN (\(placeholders))")
            bindings.append(contentsOf: requestedKinds.map { .text($0.rawValue) })
        }
        if query.hasImage || requestedKinds == [.image] {
            conditions.append("a.is_useful_image = 1")
        }

        let searchTokens = query.keywords.flatMap(Self.searchTokens)
        if !searchTokens.isEmpty {
            let FTSQuery = searchTokens
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
                .joined(separator: " AND ")
            conditions.append(
                "m.message_key IN (SELECT message_key FROM messages_fts WHERE messages_fts MATCH ?)"
            )
            bindings.append(.text(FTSQuery))
        }

        let order = query.sortOrder == .oldestFirst ? "ASC" : "DESC"
        let maximumResults = query.allResults ? 100_000 : min(max(query.limit, 1), 100)
        bindings.append(.integer(Int64(maximumResults)))
        let SQL = """
        SELECT m.message_identifier, m.local_identifier, m.sender, m.subject,
               substr(m.body, 1, 240), m.received_at, m.account_name, m.mailbox_name,
               a.attachment_identifier, a.name, a.mime_type, a.size_bytes, a.kind
        FROM attachments a
        JOIN messages m ON m.message_key = a.message_key
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.received_at \(order), a.attachment_key \(order)
        LIMIT ?
        """
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The local attachment search could not be prepared.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var candidates: [IndexedMailAttachmentCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let receivedAt = sqlite3_column_type(statement, 5) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let kind = MailAttachmentKind(rawValue: Self.text(at: 12, in: statement)) ?? .other
            candidates.append(
                IndexedMailAttachmentCandidate(
                    messageIdentifier: Self.text(at: 0, in: statement),
                    localIdentifier: Self.text(at: 1, in: statement),
                    sender: Self.text(at: 2, in: statement),
                    subject: Self.text(at: 3, in: statement),
                    preview: Self.text(at: 4, in: statement)
                        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                    receivedAt: receivedAt,
                    accountName: Self.text(at: 6, in: statement),
                    mailboxName: Self.text(at: 7, in: statement),
                    attachmentIdentifier: Self.text(at: 8, in: statement),
                    attachmentName: Self.text(at: 9, in: statement),
                    MIMEType: Self.text(at: 10, in: statement),
                    sizeBytes: sqlite3_column_int64(statement, 11),
                    kind: kind
                )
            )
        }
        return candidates
    }

    private func upsert(_ message: IndexedMailMessage) throws {
        let attachmentNames = message.attachments.map(\.name).joined(separator: " ")
        try run(
            """
            INSERT INTO messages (
                message_key, message_identifier, local_identifier, sender, recipients,
                subject, body, received_at, size_bytes, mailbox_name, account_name,
                is_sent, has_attachment, has_useful_image, indexed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_key) DO UPDATE SET
                message_identifier = excluded.message_identifier,
                local_identifier = excluded.local_identifier,
                sender = excluded.sender,
                recipients = excluded.recipients,
                subject = excluded.subject,
                body = excluded.body,
                received_at = excluded.received_at,
                size_bytes = excluded.size_bytes,
                mailbox_name = excluded.mailbox_name,
                account_name = excluded.account_name,
                is_sent = excluded.is_sent,
                has_attachment = excluded.has_attachment,
                has_useful_image = excluded.has_useful_image,
                indexed_at = excluded.indexed_at
            """,
            bindings: [
                .text(message.key), .text(message.messageIdentifier), .text(message.localIdentifier),
                .text(message.sender), .text(message.recipients), .text(message.subject), .text(message.body),
                message.receivedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .integer(message.sizeBytes), .text(message.mailboxName), .text(message.accountName),
                .integer(message.isSent ? 1 : 0), .integer(message.attachments.isEmpty ? 0 : 1),
                .integer(message.attachments.contains(where: \.isUsefulImage) ? 1 : 0),
                .double(Date().timeIntervalSince1970)
            ]
        )

        try run("DELETE FROM attachments WHERE message_key = ?", bindings: [.text(message.key)])
        for (index, attachment) in message.attachments.enumerated() {
            let attachmentKey = attachment.identifier.isEmpty
                ? "\(message.key):\(index):\(attachment.name)"
                : "\(message.key):\(attachment.identifier)"
            try run(
                """
                INSERT OR REPLACE INTO attachments (
                    attachment_key, message_key, attachment_identifier, name, mime_type,
                    size_bytes, is_image, is_useful_image, is_downloaded, kind
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(attachmentKey), .text(message.key), .text(attachment.identifier),
                    .text(attachment.name), .text(attachment.MIMEType), .integer(attachment.sizeBytes),
                    .integer(attachment.isImage ? 1 : 0), .integer(attachment.isUsefulImage ? 1 : 0),
                    .integer(attachment.isDownloaded ? 1 : 0), .text(Self.kind(of: attachment).rawValue)
                ]
            )
        }

        try run("DELETE FROM messages_fts WHERE message_key = ?", bindings: [.text(message.key)])
        try run(
            "INSERT INTO messages_fts (message_key, sender, recipients, subject, body, attachment_names) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [
                .text(message.key), .text(message.sender), .text(message.recipients),
                .text(message.subject), .text(message.body), .text(attachmentNames)
            ]
        )
    }

    private func updateState(
        total: Int,
        scanned: Int,
        failures: Int,
        cursor: MailScanCursor,
        finished: Bool
    ) throws {
        try run(
            """
            UPDATE scan_state SET total = ?, scanned = ?, failures = ?, cursor_mailbox = ?,
                cursor_message = ?, finished = ?, updated_at = ? WHERE id = 1
            """,
            bindings: [
                .integer(Int64(total)), .integer(Int64(scanned)), .integer(Int64(failures)),
                .integer(Int64(cursor.mailboxIndex)), .integer(Int64(cursor.messageIndex)),
                .integer(finished ? 1 : 0), .double(Date().timeIntervalSince1970)
            ]
        )
    }

    private enum Binding {
        case text(String)
        case integer(Int64)
        case double(Double)
        case null
    }

    private func run(_ SQL: String, bindings: [Binding] = []) throws {
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The local email index could not prepare a statement.")
        }
        defer { sqlite3_finalize(statement) }

        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError()
        }
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, SQLiteTransient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw databaseError()
            }
        }
    }

    private func prepare(_ SQL: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, SQL, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ SQL: String) throws {
        try Self.execute(SQL, on: database)
    }

    private static func execute(_ SQL: String, on database: OpaquePointer?) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, SQL, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "Unknown SQLite error"
            sqlite3_free(errorPointer)
            throw MichelMailsError.index(message)
        }
    }

    private func databaseError() -> MichelMailsError {
        let message = database
            .flatMap { sqlite3_errmsg($0) }
            .map { String(cString: $0) } ?? "Unknown SQLite error"
        return .index(message)
    }

    private static func text(at index: Int32, in statement: OpaquePointer) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func searchTokens(in value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func kind(of attachment: IndexedMailAttachment) -> MailAttachmentKind {
        let MIME = attachment.MIMEType.lowercased()
        let extensionName = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        if attachment.isImage || MIME.hasPrefix("image/") { return .image }
        if MIME == "application/pdf" || extensionName == "pdf" { return .pdf }
        if ["doc", "docx", "rtf", "txt", "pages"].contains(extensionName) { return .document }
        if ["xls", "xlsx", "csv", "numbers"].contains(extensionName) { return .spreadsheet }
        if ["ppt", "pptx", "key"].contains(extensionName) { return .presentation }
        if ["zip", "rar", "7z", "tar", "gz"].contains(extensionName) { return .archive }
        if MIME.hasPrefix("audio/") { return .audio }
        if MIME.hasPrefix("video/") { return .video }
        return .other
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous = NORMAL;
    CREATE TABLE IF NOT EXISTS messages (
        message_key TEXT PRIMARY KEY,
        message_identifier TEXT NOT NULL,
        local_identifier TEXT NOT NULL,
        sender TEXT NOT NULL,
        recipients TEXT NOT NULL,
        subject TEXT NOT NULL,
        body TEXT NOT NULL,
        received_at REAL,
        size_bytes INTEGER NOT NULL,
        mailbox_name TEXT NOT NULL,
        account_name TEXT NOT NULL,
        is_sent INTEGER NOT NULL,
        has_attachment INTEGER NOT NULL,
        has_useful_image INTEGER NOT NULL,
        indexed_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS messages_received_at ON messages(received_at);
    CREATE INDEX IF NOT EXISTS messages_size_bytes ON messages(size_bytes);
    CREATE INDEX IF NOT EXISTS messages_sender ON messages(sender COLLATE NOCASE);
    CREATE TABLE IF NOT EXISTS attachments (
        attachment_key TEXT PRIMARY KEY,
        message_key TEXT NOT NULL REFERENCES messages(message_key) ON DELETE CASCADE,
        attachment_identifier TEXT NOT NULL,
        name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        is_image INTEGER NOT NULL,
        is_useful_image INTEGER NOT NULL,
        is_downloaded INTEGER NOT NULL,
        kind TEXT NOT NULL DEFAULT 'other'
    );
    CREATE INDEX IF NOT EXISTS attachments_message_key ON attachments(message_key);
    CREATE INDEX IF NOT EXISTS attachments_size_bytes ON attachments(size_bytes);
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
        message_key UNINDEXED,
        sender,
        recipients,
        subject,
        body,
        attachment_names,
        tokenize = 'unicode61 remove_diacritics 2'
    );
    CREATE TABLE IF NOT EXISTS scan_state (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        total INTEGER NOT NULL DEFAULT 0,
        scanned INTEGER NOT NULL DEFAULT 0,
        failures INTEGER NOT NULL DEFAULT 0,
        cursor_mailbox INTEGER NOT NULL DEFAULT 1,
        cursor_message INTEGER NOT NULL DEFAULT 1,
        finished INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0
    );
    INSERT OR IGNORE INTO scan_state(id) VALUES(1);
    """
}
