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
        try? Self.execute(
            "ALTER TABLE messages ADD COLUMN body_indexed INTEGER NOT NULL DEFAULT 0",
            on: connection
        )
        try? Self.execute(
            "ALTER TABLE scan_state ADD COLUMN phase TEXT NOT NULL DEFAULT 'metadata'",
            on: connection
        )
        try? Self.execute(
            "ALTER TABLE messages ADD COLUMN source_path TEXT NOT NULL DEFAULT ''",
            on: connection
        )
        try? Self.execute(
            "ALTER TABLE attachments ADD COLUMN source_path TEXT NOT NULL DEFAULT ''",
            on: connection
        )
        try Self.execute(
            "UPDATE messages SET body_indexed = 1 WHERE body_indexed = 0 AND body <> ''",
            on: connection
        )
        try Self.reclassifyStoredPreviews(on: connection)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func state(total latestTotal: Int) throws -> (progress: MailScanProgress, cursor: MailScanCursor) {
        guard let statement = try prepare(
            "SELECT total, scanned, failures, cursor_mailbox, cursor_message, finished, phase FROM scan_state WHERE id = 1"
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
        var phase = MailScanPhase(rawValue: Self.text(at: 6, in: statement)) ?? .metadata

        if total == 0 {
            total = latestTotal
            try updateState(
                total: total,
                scanned: 0,
                failures: 0,
                cursor: MailScanCursor(mailboxIndex: 1, messageIndex: 1),
                finished: total == 0,
                phase: .metadata
            )
        } else if latestTotal > total && finished {
            // A new full pass discovers new messages while retaining every
            // previously indexed row. Upserts make the pass safe and resumable.
            total = latestTotal
            scanned = 0
            mailboxIndex = 1
            messageIndex = 1
            finished = false
            phase = .metadata
            try updateState(
                total: total,
                scanned: scanned,
                failures: failures,
                cursor: MailScanCursor(mailboxIndex: mailboxIndex, messageIndex: messageIndex),
                finished: false,
                phase: phase
            )
        } else if latestTotal > total {
            total = latestTotal
            try execute("UPDATE scan_state SET total = \(total) WHERE id = 1")
        }

        return (
            MailScanProgress(
                scanned: scanned,
                total: total,
                failures: failures,
                isFinished: finished,
                phase: phase
            ),
            MailScanCursor(mailboxIndex: mailboxIndex, messageIndex: messageIndex)
        )
    }

    func beginContentPass(total: Int) throws -> (progress: MailScanProgress, cursor: MailScanCursor) {
        let cursor = MailScanCursor(mailboxIndex: 1, messageIndex: 1)
        try updateState(
            total: total,
            scanned: 0,
            failures: 0,
            cursor: cursor,
            finished: total == 0,
            phase: .content
        )
        return (
            MailScanProgress(
                scanned: 0,
                total: total,
                failures: 0,
                isFinished: total == 0,
                phase: .content
            ),
            cursor
        )
    }

    func save(_ batch: MailScanBatch, total: Int, previous: MailScanProgress) throws -> MailScanProgress {
        try execute("BEGIN IMMEDIATE")
        do {
            var isolatedWriteFailures = 0
            for message in batch.messages {
                try execute("SAVEPOINT message_write")
                do {
                    if batch.phase == .metadata {
                        try upsertMetadata(message)
                    } else {
                        try updateBody(message)
                    }
                    try execute("RELEASE message_write")
                } catch {
                    try? execute("ROLLBACK TO message_write")
                    try? execute("RELEASE message_write")
                    isolatedWriteFailures += 1
                }
            }
            let scanned = min(total, previous.scanned + batch.attemptedCount)
            let failures = previous.failures + batch.failureCount + isolatedWriteFailures
            let finished = batch.isFinished || scanned >= total
            try updateState(
                total: total,
                scanned: scanned,
                failures: failures,
                cursor: batch.nextCursor,
                finished: finished,
                phase: batch.phase
            )
            try execute("COMMIT")
            return MailScanProgress(
                scanned: scanned,
                total: total,
                failures: failures,
                isFinished: finished,
                phase: batch.phase
            )
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func directState(total latestTotal: Int) throws -> DirectMailScanState {
        guard let statement = try prepare(
            """
            SELECT total, index_scanned, index_failures, index_cursor, index_finished,
                   content_scanned, content_failures, content_cursor, content_finished
            FROM direct_scan_state WHERE id = 1
            """
        ) else {
            throw MichelMailsError.index("The direct email scan state is unavailable.")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MichelMailsError.index("The direct email scan state is unavailable.")
        }

        var total = Int(sqlite3_column_int64(statement, 0))
        var indexScanned = Int(sqlite3_column_int64(statement, 1))
        let indexFailures = Int(sqlite3_column_int64(statement, 2))
        let indexCursor = sqlite3_column_int64(statement, 3)
        var indexFinished = sqlite3_column_int(statement, 4) == 1
        var contentScanned = Int(sqlite3_column_int64(statement, 5))
        let contentFailures = Int(sqlite3_column_int64(statement, 6))
        let contentCursor = sqlite3_column_int64(statement, 7)
        var contentFinished = sqlite3_column_int(statement, 8) == 1

        if total == 0 {
            total = latestTotal
            indexScanned = 0
            contentScanned = 0
            indexFinished = latestTotal == 0
            contentFinished = latestTotal == 0
            try run(
                """
                UPDATE direct_scan_state
                SET total = ?, index_scanned = 0, index_failures = 0, index_cursor = 0,
                    index_finished = ?, content_scanned = 0, content_failures = 0,
                    content_cursor = 0, content_finished = ?, updated_at = ?
                WHERE id = 1
                """,
                bindings: [
                    .integer(Int64(total)), .integer(indexFinished ? 1 : 0),
                    .integer(contentFinished ? 1 : 0), .double(Date().timeIntervalSince1970)
                ]
            )
        } else if latestTotal > total {
            total = latestTotal
            indexFinished = false
            contentFinished = false
            try run(
                """
                UPDATE direct_scan_state
                SET total = ?, index_finished = 0, content_finished = 0, updated_at = ?
                WHERE id = 1
                """,
                bindings: [.integer(Int64(total)), .double(Date().timeIntervalSince1970)]
            )
        } else if latestTotal > 0 && latestTotal < total {
            total = latestTotal
            indexScanned = min(indexScanned, total)
            contentScanned = min(contentScanned, total)
            try run(
                """
                UPDATE direct_scan_state
                SET total = ?, index_scanned = ?, content_scanned = ?, updated_at = ?
                WHERE id = 1
                """,
                bindings: [
                    .integer(Int64(total)), .integer(Int64(indexScanned)),
                    .integer(Int64(contentScanned)), .double(Date().timeIntervalSince1970)
                ]
            )
        }

        return DirectMailScanState(
            indexProgress: MailScanProgress(
                scanned: indexScanned,
                total: total,
                failures: indexFailures,
                isFinished: indexFinished,
                phase: .metadata
            ),
            indexCursorRowID: indexCursor,
            contentProgress: MailScanProgress(
                scanned: contentScanned,
                total: total,
                failures: contentFailures,
                isFinished: contentFinished,
                phase: .content
            ),
            contentCursorRowID: contentCursor
        )
    }

    func saveDirectMetadata(
        _ batch: DirectMailScanBatch,
        total: Int,
        previous: MailScanProgress
    ) throws -> MailScanProgress {
        try saveDirectBatch(batch, total: total, previous: previous, phase: .metadata)
    }

    func saveDirectContent(
        _ batch: DirectMailScanBatch,
        total: Int,
        previous: MailScanProgress
    ) throws -> MailScanProgress {
        try saveDirectBatch(batch, total: total, previous: previous, phase: .content)
    }

    private func saveDirectBatch(
        _ batch: DirectMailScanBatch,
        total: Int,
        previous: MailScanProgress,
        phase: MailScanPhase
    ) throws -> MailScanProgress {
        try execute("BEGIN IMMEDIATE")
        do {
            var writeFailures = 0
            for message in batch.messages {
                try execute("SAVEPOINT direct_message_write")
                do {
                    try upsertMetadata(message)
                    try execute("RELEASE direct_message_write")
                } catch {
                    try? execute("ROLLBACK TO direct_message_write")
                    try? execute("RELEASE direct_message_write")
                    writeFailures += 1
                }
            }
            let scanned = min(total, previous.scanned + batch.attemptedCount)
            let failures = previous.failures + batch.failureCount + writeFailures
            let finished = batch.isFinished || scanned >= total
            let prefix = phase == .metadata ? "index" : "content"
            try run(
                """
                UPDATE direct_scan_state
                SET \(prefix)_scanned = ?, \(prefix)_failures = ?, \(prefix)_cursor = ?,
                    \(prefix)_finished = ?, updated_at = ? WHERE id = 1
                """,
                bindings: [
                    .integer(Int64(scanned)), .integer(Int64(failures)),
                    .integer(batch.nextRowID), .integer(finished ? 1 : 0),
                    .double(Date().timeIntervalSince1970)
                ]
            )
            try execute("COMMIT")
            return MailScanProgress(
                scanned: scanned,
                total: total,
                failures: failures,
                isFinished: finished,
                phase: phase
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
            conditions.append(Self.nonJunkMailboxCondition)
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
        let fetchMaximum = query.allResults ? maximumResults : min(maximumResults * 4, 400)
        bindings.append(.integer(Int64(fetchMaximum)))

        let SQL = """
        SELECT m.message_identifier, m.local_identifier, m.sender, m.subject,
               substr(m.body, 1, 240), m.received_at,
               m.account_name, m.mailbox_name, m.source_path,
               m.message_key, m.has_attachment
        FROM messages m
        \(whereClause)
        ORDER BY m.received_at \(order), m.message_key \(order)
        LIMIT ?
        """
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The local email search could not be prepared.")
        }
        var items: [MailMessageItem] = []
        var messageKeys: [String] = []
        do {
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            while sqlite3_step(statement) == SQLITE_ROW {
                let receivedAt = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                let sender = Self.text(at: 2, in: statement)
                let subject = Self.text(at: 3, in: statement)
                messageKeys.append(Self.text(at: 9, in: statement))
                items.append(
                    MailMessageItem(
                        reference: MailMessageReference(
                            messageIdentifier: Self.text(at: 0, in: statement),
                            localIdentifier: Self.text(at: 1, in: statement),
                            accountName: Self.text(at: 6, in: statement),
                            mailboxName: Self.text(at: 7, in: statement),
                            sourcePath: Self.text(at: 8, in: statement)
                        ),
                        sender: sender.isEmpty ? "Unknown sender" : sender,
                        subject: subject.isEmpty ? "(No subject)" : subject,
                        preview: Self.text(at: 4, in: statement)
                            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
                        receivedAt: receivedAt,
                        hasAttachment: sqlite3_column_int(statement, 10) != 0
                    )
                )
            }
        }

        let attachments = try attachments(forMessageKeys: messageKeys)
        for index in items.indices {
            items[index].attachments = attachments[messageKeys[index]] ?? []
        }
        let deduplicated = MailResultDeduplicator.messages(items)
        return MailSearchResults(items: Array(deduplicated.prefix(maximumResults)), query: query)
    }

    func searchAttachments(
        _ query: MailQuery,
        includePotentialParasites: Bool = false,
        includeJunk: Bool = false
    ) throws -> [IndexedMailAttachmentCandidate] {
        var conditions: [String] = ["a.size_bytes >= 0"]
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
        if !includePotentialParasites && (query.hasImage || requestedKinds == [.image]) {
            conditions.append("a.is_useful_image = 1")
        }
        if !includeJunk && (query.hasImage || requestedKinds.contains(.image)) {
            conditions.append(Self.nonJunkMailboxCondition)
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
        let isImageSearch = query.hasImage || requestedKinds.contains(.image)
        let fetchMaximum = includePotentialParasites && isImageSearch
            ? 100_000
            : (query.allResults ? maximumResults : min(maximumResults * 4, 400))
        bindings.append(.integer(Int64(fetchMaximum)))
        let SQL = """
        SELECT m.message_identifier, m.local_identifier, m.sender, m.subject,
               substr(m.body, 1, 240), m.received_at, m.account_name, m.mailbox_name,
               m.source_path, a.attachment_identifier, a.name, a.mime_type, a.size_bytes, a.kind,
               CASE WHEN a.source_path <> '' THEN a.source_path ELSE m.source_path END,
               a.is_useful_image
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
            candidates.append(Self.attachmentCandidate(from: statement))
        }
        let deduplicated = MailResultDeduplicator.attachments(candidates)
        return Self.limitedAttachmentCandidates(
            deduplicated,
            targetCount: maximumResults,
            includePotentialParasites: includePotentialParasites && isImageSearch
        )
    }

    /// Returns at least `targetCount` recent images without ever cutting an
    /// email in half. If the boundary email contains 27 images, all 27 are
    /// returned even when the requested target is 20.
    func latestImageAttachments(
        targetCount: Int,
        direction: MailDirection,
        correspondent: String,
        includePotentialParasites: Bool = false,
        includeJunk: Bool = false
    ) throws -> [IndexedMailAttachmentCandidate] {
        var conditions = [
            "a.kind = 'image'"
        ]
        if !includePotentialParasites {
            conditions.append("a.is_useful_image = 1")
        }
        if !includeJunk {
            conditions.append(Self.nonJunkMailboxCondition)
        }
        var bindings: [Binding] = []

        switch direction {
        case .any:
            break
        case .received:
            conditions.append("m.is_sent = 0")
        case .sent:
            conditions.append("m.is_sent = 1")
        }

        let trimmedCorrespondent = correspondent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCorrespondent.isEmpty {
            conditions.append("lower(m.sender || ' ' || m.recipients) LIKE lower(?)")
            bindings.append(.text("%\(trimmedCorrespondent)%"))
        }

        let SQL = """
        SELECT m.message_key,
               m.message_identifier, m.local_identifier, m.sender, m.subject,
               substr(m.body, 1, 240), m.received_at, m.account_name, m.mailbox_name,
               m.source_path, a.attachment_identifier, a.name, a.mime_type, a.size_bytes, a.kind,
               CASE WHEN a.source_path <> '' THEN a.source_path ELSE m.source_path END,
               a.is_useful_image
        FROM attachments a
        JOIN messages m ON m.message_key = a.message_key
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY m.received_at DESC, m.message_key DESC, a.attachment_key ASC
        """
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The recent image search could not be prepared.")
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var candidates: [IndexedMailAttachmentCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            candidates.append(Self.attachmentCandidate(from: statement, offset: 1))
        }
        return Self.limitedAttachmentCandidates(
            MailResultDeduplicator.attachments(candidates),
            targetCount: max(targetCount, 1),
            includePotentialParasites: includePotentialParasites
        )
    }

    private static func limitedAttachmentCandidates(
        _ candidates: [IndexedMailAttachmentCandidate],
        targetCount: Int,
        includePotentialParasites: Bool
    ) -> [IndexedMailAttachmentCandidate] {
        let target = max(targetCount, 1)
        var result: [IndexedMailAttachmentCandidate] = []
        var index = 0
        var countedImages = 0

        while index < candidates.count {
            let key = MailResultDeduplicator.logicalMessageKey(candidates[index])
            let start = index
            while index < candidates.count,
                  MailResultDeduplicator.logicalMessageKey(candidates[index]) == key {
                index += 1
            }
            let group = Array(candidates[start..<index])
            let usefulImages = includePotentialParasites
                ? group.filter { !$0.isPotentialParasite }
                : group
            guard !usefulImages.isEmpty else { continue }
            result.append(contentsOf: group)
            countedImages += usefulImages.count
            if countedImages >= target { break }
        }
        return result
    }

    private func attachments(
        forMessageKeys messageKeys: [String]
    ) throws -> [String: [IndexedMailAttachmentCandidate]] {
        guard !messageKeys.isEmpty else { return [:] }
        var result: [String: [IndexedMailAttachmentCandidate]] = [:]
        for start in stride(from: 0, to: messageKeys.count, by: 500) {
            let end = min(start + 500, messageKeys.count)
            let chunk = Array(messageKeys[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let SQL = """
            SELECT m.message_key,
                   m.message_identifier, m.local_identifier, m.sender, m.subject,
                   substr(m.body, 1, 240), m.received_at, m.account_name, m.mailbox_name,
                   m.source_path, a.attachment_identifier, a.name, a.mime_type, a.size_bytes, a.kind,
                   CASE WHEN a.source_path <> '' THEN a.source_path ELSE m.source_path END,
                   a.is_useful_image
            FROM attachments a
            JOIN messages m ON m.message_key = a.message_key
            WHERE a.message_key IN (\(placeholders))
            ORDER BY a.attachment_key ASC
            """
            guard let statement = try prepare(SQL) else {
                throw MichelMailsError.index("Email attachment previews could not be prepared.")
            }
            do {
                defer { sqlite3_finalize(statement) }
                try bind(chunk.map(Binding.text), to: statement)
                while sqlite3_step(statement) == SQLITE_ROW {
                    result[Self.text(at: 0, in: statement), default: []].append(
                        Self.attachmentCandidate(from: statement, offset: 1)
                    )
                }
            }
        }
        return result
    }

    func recentImageCorrespondents(limit: Int) throws -> [String] {
        let SQL = """
        SELECT m.sender, m.recipients
        FROM messages m
        WHERE EXISTS (
            SELECT 1 FROM attachments a
            WHERE a.message_key = m.message_key
              AND a.kind = 'image'
              AND a.is_useful_image = 1
        )
          AND \(Self.nonJunkMailboxCondition)
        ORDER BY m.received_at DESC, m.message_key DESC
        LIMIT ?
        """
        guard let statement = try prepare(SQL) else {
            throw MichelMailsError.index("The correspondent list could not be prepared.")
        }
        defer { sqlite3_finalize(statement) }
        try bind([.integer(Int64(max(limit, 1)))], to: statement)

        var result: [String] = []
        var seen: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0...1 {
                for identity in Self.contactIdentities(in: Self.text(at: Int32(column), in: statement)) {
                    let key = identity.folding(
                        options: [.diacriticInsensitive, .caseInsensitive],
                        locale: .current
                    )
                    if seen.insert(key).inserted { result.append(identity) }
                }
            }
        }
        return result
    }

    private func upsertMetadata(_ message: IndexedMailMessage) throws {
        try run(
            """
            INSERT INTO messages (
                message_key, message_identifier, local_identifier, sender, recipients,
                subject, body, received_at, size_bytes, mailbox_name, account_name,
                is_sent, has_attachment, has_useful_image, indexed_at, body_indexed, source_path
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_key) DO UPDATE SET
                message_identifier = excluded.message_identifier,
                local_identifier = excluded.local_identifier,
                sender = excluded.sender,
                recipients = excluded.recipients,
                subject = excluded.subject,
                body = CASE WHEN excluded.body_indexed = 1 THEN excluded.body ELSE messages.body END,
                received_at = excluded.received_at,
                size_bytes = excluded.size_bytes,
                mailbox_name = excluded.mailbox_name,
                account_name = excluded.account_name,
                is_sent = excluded.is_sent,
                has_attachment = excluded.has_attachment,
                has_useful_image = excluded.has_useful_image,
                indexed_at = excluded.indexed_at,
                body_indexed = MAX(messages.body_indexed, excluded.body_indexed),
                source_path = CASE WHEN excluded.source_path <> '' THEN excluded.source_path ELSE messages.source_path END
            """,
            bindings: [
                .text(message.key), .text(message.messageIdentifier), .text(message.localIdentifier),
                .text(message.sender), .text(message.recipients), .text(message.subject), .text(message.body),
                message.receivedAt.map { .double($0.timeIntervalSince1970) } ?? .null,
                .integer(message.sizeBytes), .text(message.mailboxName), .text(message.accountName),
                .integer(message.isSent ? 1 : 0), .integer(message.attachments.isEmpty ? 0 : 1),
                .integer(message.attachments.contains(where: \.isUsefulImage) ? 1 : 0),
                .double(Date().timeIntervalSince1970), .integer(message.bodyWasScanned ? 1 : 0),
                .text(message.sourcePath)
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
                    size_bytes, is_image, is_useful_image, is_downloaded, kind, source_path
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(attachmentKey), .text(message.key), .text(attachment.identifier),
                    .text(attachment.name), .text(attachment.MIMEType), .integer(attachment.sizeBytes),
                    .integer(attachment.isImage ? 1 : 0), .integer(attachment.isUsefulImage ? 1 : 0),
                    .integer(attachment.isDownloaded ? 1 : 0), .text(Self.kind(of: attachment).rawValue),
                    .text(attachment.sourcePath)
                ]
            )
        }

        try refreshFTS(messageKey: message.key)
    }

    private func updateBody(_ message: IndexedMailMessage) throws {
        guard message.bodyWasScanned else { return }
        try run(
            "UPDATE messages SET body = ?, body_indexed = 1, indexed_at = ? WHERE message_key = ?",
            bindings: [
                .text(message.body), .double(Date().timeIntervalSince1970), .text(message.key)
            ]
        )
        try refreshFTS(messageKey: message.key)
    }

    private func refreshFTS(messageKey: String) throws {
        try run("DELETE FROM messages_fts WHERE message_key = ?", bindings: [.text(messageKey)])
        try run(
            """
            INSERT INTO messages_fts (message_key, sender, recipients, subject, body, attachment_names)
            SELECT m.message_key, m.sender, m.recipients, m.subject, m.body,
                   COALESCE((SELECT group_concat(a.name, ' ') FROM attachments a WHERE a.message_key = m.message_key), '')
            FROM messages m WHERE m.message_key = ?
            """,
            bindings: [.text(messageKey)]
        )
    }

    private func updateState(
        total: Int,
        scanned: Int,
        failures: Int,
        cursor: MailScanCursor,
        finished: Bool,
        phase: MailScanPhase
    ) throws {
        try run(
            """
            UPDATE scan_state SET total = ?, scanned = ?, failures = ?, cursor_mailbox = ?,
                cursor_message = ?, finished = ?, updated_at = ?, phase = ? WHERE id = 1
            """,
            bindings: [
                .integer(Int64(total)), .integer(Int64(scanned)), .integer(Int64(failures)),
                .integer(Int64(cursor.mailboxIndex)), .integer(Int64(cursor.messageIndex)),
                .integer(finished ? 1 : 0), .double(Date().timeIntervalSince1970), .text(phase.rawValue)
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

    private static func reclassifyStoredPreviews(on database: OpaquePointer?) throws {
        func extensionCondition(_ extensions: Set<String>) -> String {
            extensions.sorted().map { "lower(name) LIKE '%.\($0)'" }.joined(separator: " OR ")
        }

        let images = extensionCondition(MailAttachmentKind.imageExtensions)
        try execute(
            """
            UPDATE attachments
            SET kind = 'image',
                is_image = 1,
                is_useful_image = CASE
                    WHEN lower(name) LIKE '%signature%'
                      OR lower(name) LIKE '%logo%'
                      OR lower(name) LIKE '%spacer%'
                      OR lower(name) LIKE '%tracking%'
                      OR lower(name) LIKE '%icon%' THEN 0
                    WHEN size_bytes = 0 OR size_bytes >= 5000 THEN 1
                    ELSE 0
                END
            WHERE lower(mime_type) LIKE 'image/%' OR \(images)
            """,
            on: database
        )

        let videos = extensionCondition(MailAttachmentKind.videoExtensions)
        try execute(
            "UPDATE attachments SET kind = 'video' WHERE lower(mime_type) LIKE 'video/%' OR \(videos)",
            on: database
        )
        try execute(
            "UPDATE attachments SET kind = 'pdf' WHERE lower(mime_type) = 'application/pdf' OR lower(name) LIKE '%.pdf'",
            on: database
        )
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

    private static func attachmentCandidate(
        from statement: OpaquePointer,
        offset: Int32 = 0
    ) -> IndexedMailAttachmentCandidate {
        let receivedAt = sqlite3_column_type(statement, offset + 5) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 5))
        let kind = MailAttachmentKind(rawValue: text(at: offset + 13, in: statement)) ?? .other
        return IndexedMailAttachmentCandidate(
            messageIdentifier: text(at: offset, in: statement),
            localIdentifier: text(at: offset + 1, in: statement),
            sender: text(at: offset + 2, in: statement),
            subject: text(at: offset + 3, in: statement),
            preview: text(at: offset + 4, in: statement)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression),
            receivedAt: receivedAt,
            accountName: text(at: offset + 6, in: statement),
            mailboxName: text(at: offset + 7, in: statement),
            attachmentIdentifier: text(at: offset + 9, in: statement),
            attachmentName: text(at: offset + 10, in: statement),
            MIMEType: text(at: offset + 11, in: statement),
            sizeBytes: sqlite3_column_int64(statement, offset + 12),
            kind: kind,
            messageSourcePath: text(at: offset + 8, in: statement),
            sourcePath: text(at: offset + 14, in: statement),
            isPotentialParasite: sqlite3_column_int(statement, offset + 15) == 0
        )
    }

    private static func contactIdentities(in rawValue: String) -> [String] {
        let rawValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return [] }

        var identities: [String] = []
        var pending = ""
        for piece in rawValue.split(separator: ",", omittingEmptySubsequences: true) {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = pending.isEmpty ? text : pending + ", " + text

            // A display name may itself contain a comma. Keep accumulating
            // until its <address> is complete.
            if pending.contains("<") && !pending.contains(">") { continue }
            if pending.contains("@") || !pending.contains("<") {
                identities.append(pending)
                pending = ""
            }
        }
        if !pending.isEmpty { identities.append(pending) }
        return identities
    }

    private static let nonJunkMailboxCondition = """
    (lower(m.mailbox_name) NOT LIKE '%junk%'
     AND lower(m.mailbox_name) NOT LIKE '%spam%'
     AND lower(m.mailbox_name) NOT LIKE '%indésirable%'
     AND lower(m.mailbox_name) NOT LIKE '%indesirable%'
     AND lower(m.mailbox_name) NOT LIKE '%bulk mail%'
     AND lower(m.mailbox_name) NOT LIKE '%unwanted%')
    """

    private static func searchTokens(in value: String) -> [String] {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func kind(of attachment: IndexedMailAttachment) -> MailAttachmentKind {
        MailAttachmentKind.classify(
            name: attachment.name,
            MIMEType: attachment.MIMEType,
            declaredImage: attachment.isImage
        )
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
        indexed_at REAL NOT NULL,
        body_indexed INTEGER NOT NULL DEFAULT 0,
        source_path TEXT NOT NULL DEFAULT ''
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
        kind TEXT NOT NULL DEFAULT 'other',
        source_path TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS attachments_message_key ON attachments(message_key);
    CREATE INDEX IF NOT EXISTS attachments_size_bytes ON attachments(size_bytes);
    CREATE INDEX IF NOT EXISTS attachments_kind_useful ON attachments(kind, is_useful_image, message_key);
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
        updated_at REAL NOT NULL DEFAULT 0,
        phase TEXT NOT NULL DEFAULT 'metadata'
    );
    INSERT OR IGNORE INTO scan_state(id) VALUES(1);
    CREATE TABLE IF NOT EXISTS direct_scan_state (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        total INTEGER NOT NULL DEFAULT 0,
        index_scanned INTEGER NOT NULL DEFAULT 0,
        index_failures INTEGER NOT NULL DEFAULT 0,
        index_cursor INTEGER NOT NULL DEFAULT 0,
        index_finished INTEGER NOT NULL DEFAULT 0,
        content_scanned INTEGER NOT NULL DEFAULT 0,
        content_failures INTEGER NOT NULL DEFAULT 0,
        content_cursor INTEGER NOT NULL DEFAULT 0,
        content_finished INTEGER NOT NULL DEFAULT 0,
        updated_at REAL NOT NULL DEFAULT 0
    );
    INSERT OR IGNORE INTO direct_scan_state(id) VALUES(1);
    """
}
