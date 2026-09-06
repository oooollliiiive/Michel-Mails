import Foundation
import SQLite3
import Testing
@testable import MichelMails

@Test("The direct EMLX reader finds body text and attachment bytes")
func directEmlxParsing() throws {
    let boundary = "michel-boundary"
    let payload = """
    From: Michel <michel@example.com>\r
    Message-ID: <pictures-42@example.com>\r
    Subject: Pictures\r
    Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r
    \r
    --\(boundary)\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    A calico cat in the garden.\r
    --\(boundary)\r
    Content-Type: image/jpeg; name=\"cat.jpg\"\r
    Content-Disposition: attachment; filename=\"cat.jpg\"\r
    Content-Transfer-Encoding: base64\r
    \r
    AQIDBA==\r
    --\(boundary)--\r

    """
    let messageData = Data(payload.utf8)
    var emlx = Data("\(messageData.count)\n".utf8)
    emlx.append(messageData)
    emlx.append(Data("<?xml version=\"1.0\"?><plist/>".utf8))

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let URL = directory.appendingPathComponent("1.emlx")
    try emlx.write(to: URL)

    let parsed = try DirectEmlxReader.read(at: URL)
    #expect(parsed.body.contains("calico cat"))
    #expect(parsed.messageIdentifier == "pictures-42@example.com")
    #expect(parsed.attachments.count == 1)
    #expect(parsed.attachments[0].name == "cat.jpg")
    #expect(parsed.attachments[0].sizeBytes == 4)
    let extracted = try DirectEmlxReader.extractAttachment(
        identifier: parsed.attachments[0].identifier,
        from: URL
    )
    #expect(extracted == Data([1, 2, 3, 4]))
}

@Test("Downloaded MIME files replace zero-byte shadow attachments")
func downloadedMIMEFilesReplaceShadows() {
    let shadow = IndexedMailAttachment(
        identifier: "1.2.2",
        name: "Capture d_ecran . 2026-02-18 a 09.01.44.png",
        MIMEType: "image/png",
        sizeBytes: 0,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: false
    )
    let physical = IndexedMailAttachment(
        identifier: "1.2.2",
        name: "Capture d?ecran . 202 6-02-18 à 09.01.44.png",
        MIMEType: "image/png",
        sizeBytes: 748_272,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: true,
        sourcePath: "/Mail/Attachments/4119/2.2/Capture.png"
    )

    let reconciled = DirectMailSource.reconciledAttachments(
        parsed: [shadow],
        external: [physical]
    )

    #expect(reconciled == [physical])
}

@Test("Quoted attachment names may contain semicolons")
func directEmlxQuotedSemicolonFilename() throws {
    let boundary = "semicolon-boundary"
    let fileName = "5193ae;khg-khgc0-f287-4864-b111-f915058c833e.png"
    let payload = """
    Content-Type: multipart/mixed; boundary="\(boundary)"\r
    \r
    --\(boundary)\r
    Content-Type: image/png; name="\(fileName)"\r
    Content-Disposition: attachment; filename="\(fileName)"\r
    Content-Transfer-Encoding: base64\r
    \r
    AQIDBA==\r
    --\(boundary)--\r

    """
    let messageData = Data(payload.utf8)
    var emlx = Data("\(messageData.count)\n".utf8)
    emlx.append(messageData)

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let URL = directory.appendingPathComponent("1.emlx")
    try emlx.write(to: URL)

    let parsed = try DirectEmlxReader.read(at: URL)
    #expect(parsed.attachments.count == 1)
    #expect(parsed.attachments[0].name == fileName)
    #expect(parsed.attachments[0].sizeBytes == 4)
}

@Test("The direct Mail source exposes a fast index and a separate full-content pass")
func directMailTwoPassScan() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let versionDirectory = root.appendingPathComponent("V10", isDirectory: true)
    let dataDirectory = versionDirectory
        .appendingPathComponent("ACCOUNT/Inbox.mbox/STORE/Data", isDirectory: true)
    let messagesDirectory = dataDirectory.appendingPathComponent("Messages", isDirectory: true)
    try FileManager.default.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = """
    From: Michel <michel@example.com>\r
    Subject: Hello\r
    Content-Type: text/plain; charset=utf-8\r
    \r
    A uniquely searchable local message.\r

    """
    let payloadData = Data(payload.utf8)
    var emlx = Data("\(payloadData.count)\n".utf8)
    emlx.append(payloadData)
    try emlx.write(to: messagesDirectory.appendingPathComponent("1.emlx"))

    let databaseURL = root.appendingPathComponent("Envelope Index")
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    defer { if let database { sqlite3_close(database) } }
    let schema = """
    CREATE TABLE messages (
        ROWID INTEGER PRIMARY KEY, global_message_id INTEGER, sender INTEGER,
        subject INTEGER, subject_prefix TEXT, date_received REAL, size INTEGER,
        mailbox INTEGER, deleted INTEGER
    );
    CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id_header TEXT);
    CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
    CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
    CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
    CREATE TABLE attachments (ROWID INTEGER PRIMARY KEY, message INTEGER, name TEXT);
    CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER);
    INSERT INTO message_global_data VALUES (1, '<message-1@example.com>');
    INSERT INTO addresses VALUES (1, 'michel@example.com', 'Michel');
    INSERT INTO addresses VALUES (2, 'me@example.com', 'Me');
    INSERT INTO subjects VALUES (1, 'Garden');
    INSERT INTO mailboxes VALUES (1, 'imap://ACCOUNT/Inbox');
    INSERT INTO messages VALUES (1, 1, 1, 1, 'Re: ', 1750000000, 2048, 1, 0);
    INSERT INTO recipients VALUES (1, 1, 2);
    """
    var errorPointer: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(database, schema, nil, nil, &errorPointer)
    if let errorPointer { sqlite3_free(errorPointer) }
    #expect(status == SQLITE_OK)
    sqlite3_close(database)
    database = nil

    let source = try DirectMailSource(
        databaseURL: databaseURL,
        versionDirectory: versionDirectory
    )
    #expect(try await source.totalMessageCount() == 1)

    let metadata = try await source.metadataBatch(after: 0, maximumCount: 100)
    #expect(metadata.attemptedCount == 1)
    #expect(metadata.messages[0].sender == "Michel <michel@example.com>")
    #expect(metadata.messages[0].subject == "Re: Garden")
    #expect(metadata.messages[0].body.isEmpty)
    #expect(metadata.messages[0].bodyWasScanned == false)

    let content = try await source.contentBatch(after: 0, maximumCount: 100)
    #expect(content.attemptedCount == 1)
    #expect(content.failureCount == 0)
    #expect(content.messages[0].body.contains("uniquely searchable"))
    #expect(content.messages[0].bodyWasScanned)
    #expect(content.messages[0].sourcePath.hasSuffix("1.emlx"))
}

@Test("The direct Mail source adapts to an older minimal Envelope Index schema")
func directMailSchemaAdaptation() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let versionDirectory = root.appendingPathComponent("V9", isDirectory: true)
    try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let databaseURL = root.appendingPathComponent("Envelope Index")
    var database: OpaquePointer?
    #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
    let schema = """
    CREATE TABLE messages (
        ROWID INTEGER PRIMARY KEY, global_message_id INTEGER,
        date_sent REAL, deleted INTEGER
    );
    CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id INTEGER);
    INSERT INTO message_global_data VALUES (1, 730);
    INSERT INTO messages VALUES (1, 1, 1740000000, 0);
    INSERT INTO messages VALUES (2, 1, 1740000001, 1);
    """
    var errorPointer: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(database, schema, nil, nil, &errorPointer)
    if let errorPointer { sqlite3_free(errorPointer) }
    #expect(status == SQLITE_OK)
    if let database { sqlite3_close(database) }
    database = nil

    let source = try DirectMailSource(
        databaseURL: databaseURL,
        versionDirectory: versionDirectory
    )
    #expect(try await source.totalMessageCount() == 1)

    let metadata = try await source.metadataBatch(after: 0, maximumCount: 100)
    #expect(metadata.messages.count == 1)
    #expect(metadata.messages[0].messageIdentifier == "730")
    #expect(metadata.messages[0].sender.isEmpty)
    #expect(metadata.messages[0].subject.isEmpty)
    #expect(metadata.messages[0].receivedAt == Date(timeIntervalSince1970: 1_740_000_000))
}

@Test("The two direct scan counters persist independently")
func directScanCounters() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try MailIndexDatabase(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let initial = try await database.directState(total: 2)
    #expect(initial.indexProgress.scanned == 0)
    #expect(initial.contentProgress.scanned == 0)

    let message = IndexedMailMessage(
        messageIdentifier: "counter-message",
        localIdentifier: "1",
        sender: "Michel",
        recipients: "Me",
        subject: "Counters",
        body: "",
        receivedAt: Date(),
        sizeBytes: 100,
        mailboxName: "Inbox",
        accountName: "Account",
        isSent: false,
        attachments: [],
        bodyWasScanned: false
    )
    let batch = DirectMailScanBatch(
        messages: [message],
        nextRowID: 1,
        attemptedCount: 1,
        failureCount: 0,
        isFinished: false
    )
    _ = try await database.saveDirectMetadata(
        batch,
        total: 2,
        previous: initial.indexProgress
    )
    var resumed = try await database.directState(total: 2)
    #expect(resumed.indexProgress.scanned == 1)
    #expect(resumed.contentProgress.scanned == 0)

    _ = try await database.saveDirectContent(
        batch,
        total: 2,
        previous: resumed.contentProgress
    )
    resumed = try await database.directState(total: 2)
    #expect(resumed.indexProgress.scanned == 1)
    #expect(resumed.contentProgress.scanned == 1)
}
