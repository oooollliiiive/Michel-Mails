import Foundation
import Testing
@testable import MichelMails

@Test("Mail URLs preserve the complete RFC Message-ID")
func mailMessageURL() throws {
    let identifier = "07D262EA-F821-43C1-B8D7-AA09F03EFB44@mac.com"
    let URL = try #require(MailService.messageURL(for: identifier))
    #expect(
        URL.absoluteString ==
            "message://%3C07D262EA%2DF821%2D43C1%2DB8D7%2DAA09F03EFB44%40mac%2Ecom%3E"
    )
    #expect(MailService.messageURL(for: "<\(identifier)>") == URL)
    #expect(MailService.messageURL(for: "730") == nil)
}

@Test("The targeted Apple Mail fallback script compiles")
@MainActor
func openMessageScriptCompiles() throws {
    let script = try #require(NSAppleScript(source: MailService.openMessageScript))
    var error: NSDictionary?
    #expect(script.compileAndReturnError(&error))
    #expect(error == nil)
}

@Test("The background attachment download script compiles")
@MainActor
func attachmentDownloadScriptCompiles() throws {
    let script = try #require(NSAppleScript(source: AttachmentMaterializer.downloadScript))
    var error: NSDictionary?
    #expect(script.compileAndReturnError(&error))
    #expect(error == nil)
    #expect(AttachmentMaterializer.downloadScript.contains("set attemptResult to my saveMatchingAttachment"))
    #expect(AttachmentMaterializer.downloadScript.contains("if attemptResult is not \"0\" then return attemptResult"))
    #expect(!AttachmentMaterializer.downloadScript.contains("if my saveMatchingAttachment"))
}

@Test("French copy prompt extracts sender, images, all results, and destination")
func frenchPromptWithTypoAndImageCopy() {
    let query = LocalQueryInterpreter().interpret(
        "Copie toutes les images des emails de raffo dans un dossier toto"
    )

    #expect(query.action == .copyImages)
    #expect(query.sender?.lowercased() == "raffo")
    #expect(query.hasImage)
    #expect(query.hasAttachment)
    #expect(query.allResults)
    #expect(query.destinationFolder?.lowercased() == "toto")
}

@Test("Mixed French and English prompt is understood")
func mixedLanguagePrompt() {
    let query = LocalQueryInterpreter().interpret(
        "Show me les 5 derniers emails from Sarah with photos"
    )

    #expect(query.action == .search)
    #expect(query.sender?.lowercased() == "sarah")
    #expect(query.limit == 5)
    #expect(query.hasImage)
    #expect(query.language == "mixed")
}

@Test("A one-letter sender typo resolves to the real correspondent")
func fuzzySenderResolution() {
    let senders = [
        "Raffi Cohen <raffi@example.com>",
        "Sophie Martin <sophie@example.com>"
    ]

    let resolved = SenderResolver().resolve("raffo", among: senders)
    #expect(resolved == "Raffi Cohen <raffi@example.com>")
}

@Test("A request for recent received images opens the gallery")
func receivedImagesGalleryPrompt() {
    let query = LocalQueryInterpreter().interpret(
        "montre moi les 10 dernières images reçues par emails"
    )

    #expect(query.action == .showImages)
    #expect(query.direction == .received)
    #expect(query.limit == 10)
    #expect(query.hasImage)
    #expect(query.sender == nil)
    #expect(query.keywords.isEmpty)
}

@Test("A French latest-email request keeps the sender and limit")
func latestEmailsFromSenderPrompt() {
    let query = LocalQueryInterpreter().interpret("10 derniers mails de Michel")

    #expect(query.action == .search)
    #expect(query.sender == "Michel")
    #expect(query.limit == 10)
    #expect(query.keywords.isEmpty)
}

@Test("Search history keeps recent unique requests and filters suggestions")
func searchHistorySuggestions() {
    var entries: [String] = []
    entries = SearchHistory.adding("10 derniers emails de Michel", to: entries)
    entries = SearchHistory.adding("Show me recent photos", to: entries)
    entries = SearchHistory.adding("10 derniers emails de Michel", to: entries)

    #expect(entries == ["10 derniers emails de Michel", "Show me recent photos"])
    #expect(SearchHistory.suggestions(for: "michel", in: entries) == ["10 derniers emails de Michel"])
    #expect(SearchHistory.suggestions(for: "PHOTOS", in: entries) == ["Show me recent photos"])
}

@Test("Mail records keep the original message reference and metadata")
func mailRecordParsing() {
    let unit = "\u{1f}"
    let record = "\u{1e}"
    let first = ["message-1", "101", "Michel Gondry", "Pictures", "Here are the files", "2026-09-04T12:34:56"]
        .joined(separator: unit)
    let second = ["message-2", "102", "Raffi", "Hello", "A short preview", "2026-09-03T09:00:00"]
        .joined(separator: unit)

    let items = MailScriptRecordParser.messages(from: first + record + second)

    #expect(items.count == 2)
    #expect(items[0].reference.messageIdentifier == "message-1")
    #expect(items[0].reference.localIdentifier == "101")
    #expect(items[0].sender == "Michel Gondry")
    #expect(items[0].subject == "Pictures")
    #expect(items[0].preview == "Here are the files")
    #expect(items[0].receivedAt != nil)
}

@Test("Image records preserve the source email for Open in Mail")
func imageRecordParsing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileName = "0001-Holiday-photo.jpg"
    try Data().write(to: directory.appendingPathComponent(fileName))
    let unit = "\u{1f}"
    let output = [
        fileName, "photo.jpg", "image/jpeg", "message-7", "707", "Raffi", "Holiday", "A photo from the trip",
        "2026-09-04T08:15:00"
    ].joined(separator: unit)

    let items = MailScriptRecordParser.images(from: output, in: directory)

    #expect(items.count == 1)
    #expect(items[0].displayName == "photo.jpg")
    #expect(items[0].kind == .image)
    #expect(items[0].message.reference.messageIdentifier == "message-7")
    #expect(items[0].message.subject == "Holiday")
}

@Test("An oldest-email request becomes a semantic sort, not a keyword")
func oldestEmailsFromSenderPrompt() {
    let query = LocalQueryInterpreter().interpret("10 plus vieux emails de Michel")

    #expect(query.action == .search)
    #expect(query.sender == "Michel")
    #expect(query.limit == 10)
    #expect(query.sortOrder == .oldestFirst)
    #expect(query.keywords.isEmpty)
}

@Test("A PDF request opens the universal file grid")
func PDFGalleryPrompt() {
    let query = LocalQueryInterpreter().interpret("Montre-moi les 12 derniers PDF reçus par email")

    #expect(query.action == .showFiles)
    #expect(query.direction == .received)
    #expect(query.limit == 12)
    #expect(query.attachmentKinds == [.pdf])
    #expect(query.keywords.isEmpty)
}

@Test("Progressive scan records keep full text and attachment bytes")
func scanRecordParsing() {
    let unit = "\u{1f}"
    let record = "\u{1e}"
    let attachment = "\u{1d}"
    let attachmentField = "\u{1c}"
    let firstAttachment = ["a1", "invoice.pdf", "application/pdf", "2300000", "false", "false", "true"]
        .joined(separator: attachmentField)
    let secondAttachment = ["a2", "cat.jpg", "image/jpeg", "640000", "true", "true", "true"]
        .joined(separator: attachmentField)
    let message = [
        "M", "message-9", "909", "Michel", "me@example.com", "Files",
        "Every word of the complete email body remains searchable", "3123456",
        "2026-09-04T10:11:12", "Inbox", "Google", "false",
        "true",
        firstAttachment + attachment + secondAttachment
    ].joined(separator: unit)
    let header = ["H", "2", "18", "false", "1", "0", "metadata"].joined(separator: unit)

    let batch = MailScanRecordParser.parse(header + record + message)

    #expect(batch?.messages.count == 1)
    #expect(batch?.messages[0].body.contains("complete email body") == true)
    #expect(batch?.messages[0].sizeBytes == 3_123_456)
    #expect(batch?.messages[0].attachments[0].sizeBytes == 2_300_000)
    #expect(batch?.messages[0].attachments[1].isUsefulImage == true)
    #expect(batch?.messages[0].bodyWasScanned == true)
    #expect(batch?.phase == .metadata)
}

@Test("Metadata becomes searchable immediately and later body indexing preserves attachments")
func splitMetadataAndBodyIndexing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try MailIndexDatabase(databaseURL: directory.appendingPathComponent("split.sqlite"))
    let attachment = IndexedMailAttachment(
        identifier: "photo-1",
        name: "garden.jpg",
        MIMEType: "image/jpeg",
        sizeBytes: 900_000,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: false
    )
    let metadata = IndexedMailMessage(
        messageIdentifier: "split-message",
        localIdentifier: "77",
        sender: "Michel <michel@example.com>",
        recipients: "me@example.com",
        subject: "Garden pictures",
        body: "",
        receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
        sizeBytes: 1_000_000,
        mailboxName: "Inbox",
        accountName: "Google",
        isSent: false,
        attachments: [attachment],
        bodyWasScanned: false,
        sourcePath: "/private/tmp/fixture-message.emlx"
    )
    let metadataProgress = try await database.save(
        MailScanBatch(
            messages: [metadata],
            nextCursor: MailScanCursor(mailboxIndex: 1, messageIndex: 2),
            attemptedCount: 1,
            failureCount: 0,
            isFinished: true,
            phase: .metadata
        ),
        total: 1,
        previous: MailScanProgress(total: 1, phase: .metadata)
    )
    #expect(metadataProgress.isFinished)
    #expect(metadataProgress.phase == .metadata)

    var subjectQuery = MailQuery(sender: "Michel", keywords: ["garden"])
    let immediateResults = try await database.searchMessages(subjectQuery).items
    #expect(immediateResults.count == 1)
    #expect(immediateResults[0].reference.sourcePath == "/private/tmp/fixture-message.emlx")
    #expect(immediateResults[0].hasAttachment)
    #expect(immediateResults[0].imageAttachments.map(\.attachmentName) == ["garden.jpg"])

    let contentState = try await database.beginContentPass(total: 1)
    #expect(contentState.progress.phase == .content)
    let content = IndexedMailMessage(
        messageIdentifier: "split-message",
        localIdentifier: "77",
        sender: "",
        recipients: "",
        subject: "",
        body: "A uniquely searchable calico cat is sleeping.",
        receivedAt: nil,
        sizeBytes: 0,
        mailboxName: "Inbox",
        accountName: "Google",
        isSent: false,
        attachments: [],
        bodyWasScanned: true
    )
    _ = try await database.save(
        MailScanBatch(
            messages: [content],
            nextCursor: MailScanCursor(mailboxIndex: 2, messageIndex: 1),
            attemptedCount: 1,
            failureCount: 0,
            isFinished: true,
            phase: .content
        ),
        total: 1,
        previous: contentState.progress
    )

    subjectQuery.sender = nil
    subjectQuery.keywords = ["calico"]
    #expect(try await database.searchMessages(subjectQuery).items.count == 1)
    var imageQuery = MailQuery(action: .showImages, hasImage: true, hasAttachment: true)
    imageQuery.attachmentKinds = [.image]
    let imageResults = try await database.searchAttachments(imageQuery)
    #expect(imageResults.count == 1)
    #expect(imageResults[0].message.reference.sourcePath == "/private/tmp/fixture-message.emlx")
}

@Test("Latest images keep a boundary email whole and filter either side of correspondence")
func latestImageShortcutSearch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try MailIndexDatabase(databaseURL: directory.appendingPathComponent("quick.sqlite"))
    func images(_ count: Int, prefix: String) -> [IndexedMailAttachment] {
        (1...count).map { number in
            IndexedMailAttachment(
                identifier: "\(prefix)-\(number)",
                name: "\(prefix)-\(number).jpg",
                MIMEType: "image/jpeg",
                sizeBytes: 400_000,
                isImage: true,
                isUsefulImage: true,
                isDownloaded: true,
                sourcePath: "/tmp/\(prefix)-\(number).jpg"
            )
        }
    }
    let messages = [
        IndexedMailMessage(
            messageIdentifier: "junk",
            localIdentifier: "4",
            sender: "Junk Sender <junk@example.com>",
            recipients: "Michel <michel@example.com>",
            subject: "Junk album",
            body: "",
            receivedAt: Date(timeIntervalSince1970: 400),
            sizeBytes: 4_000_000,
            mailboxName: "Junk",
            accountName: "Google",
            isSent: false,
            attachments: images(4, prefix: "junk")
        ),
        IndexedMailMessage(
            messageIdentifier: "latest",
            localIdentifier: "3",
            sender: "Raffi Adlan <raffi@example.com>",
            recipients: "Michel <michel@example.com>",
            subject: "Latest album",
            body: "",
            receivedAt: Date(timeIntervalSince1970: 300),
            sizeBytes: 3_000_000,
            mailboxName: "Inbox",
            accountName: "Google",
            isSent: false,
            attachments: images(3, prefix: "latest") + [
                IndexedMailAttachment(
                    identifier: "signature-image",
                    name: "signature-logo.png",
                    MIMEType: "image/png",
                    sizeBytes: 2_000,
                    isImage: true,
                    isUsefulImage: false,
                    isDownloaded: true,
                    sourcePath: "/tmp/signature-logo.png"
                )
            ]
        ),
        IndexedMailMessage(
            messageIdentifier: "sent",
            localIdentifier: "2",
            sender: "Michel <michel@example.com>",
            recipients: "Raffi Adlan <raffi@example.com>",
            subject: "Sent album",
            body: "",
            receivedAt: Date(timeIntervalSince1970: 200),
            sizeBytes: 2_000_000,
            mailboxName: "Sent",
            accountName: "Google",
            isSent: true,
            attachments: images(2, prefix: "sent")
        )
    ]
    _ = try await database.saveDirectMetadata(
        DirectMailScanBatch(
            messages: messages,
            nextRowID: 4,
            attemptedCount: 3,
            failureCount: 0,
            isFinished: true
        ),
        total: 3,
        previous: MailScanProgress(total: 3, phase: .metadata)
    )

    let boundaryResults = try await database.latestImageAttachments(
        targetCount: 2,
        direction: .any,
        correspondent: ""
    )
    #expect(boundaryResults.count == 3)
    #expect(Set(boundaryResults.map(\.messageIdentifier)) == ["latest"])

    let sentToRaffi = try await database.latestImageAttachments(
        targetCount: 20,
        direction: .sent,
        correspondent: "raf"
    )
    #expect(sentToRaffi.count == 2)
    #expect(Set(sentToRaffi.map(\.messageIdentifier)) == ["sent"])

    var regularImageQuery = MailQuery(action: .showImages, hasImage: true, hasAttachment: true)
    regularImageQuery.attachmentKinds = [.image]
    regularImageQuery.allResults = true
    let regularResults = try await database.searchAttachments(regularImageQuery)
    #expect(!regularResults.contains { $0.messageIdentifier == "junk" })
    #expect(!regularResults.contains { $0.attachmentIdentifier == "signature-image" })

    let resultsIncludingParasites = try await database.searchAttachments(
        regularImageQuery,
        includePotentialParasites: true
    )
    #expect(resultsIncludingParasites.contains {
        $0.attachmentIdentifier == "signature-image" && $0.isPotentialParasite
    })
    #expect(!resultsIncludingParasites.contains { $0.messageIdentifier == "junk" })

    let resultsIncludingJunk = try await database.searchAttachments(
        regularImageQuery,
        includeJunk: true
    )
    #expect(resultsIncludingJunk.contains { $0.messageIdentifier == "junk" })

    let latestIncludingParasites = try await database.latestImageAttachments(
        targetCount: 4,
        direction: .received,
        correspondent: "raf",
        includePotentialParasites: true
    )
    #expect(latestIncludingParasites.count == 4)
    #expect(latestIncludingParasites.last?.isPotentialParasite == true)

    let correspondents = try await database.recentImageCorrespondents(limit: 100)
    #expect(correspondents.contains("Raffi Adlan <raffi@example.com>"))
    #expect(!correspondents.contains("Junk Sender <junk@example.com>"))
}

@Test("Duplicate mailbox identities and malformed shadow attachments collapse to one email")
func duplicateMailIdentityDeduplication() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try MailIndexDatabase(databaseURL: directory.appendingPathComponent("dedup.sqlite"))
    let date = Date(timeIntervalSince1970: 1_788_500_222)
    let legacyAttachment = IndexedMailAttachment(
        identifier: "2",
        name: "5193ae;khg-khgc0-f287-4864-b111-f915058c833e.png",
        MIMEType: "image/png",
        sizeBytes: 8_005_587,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: true
    )
    let phantomAttachment = IndexedMailAttachment(
        identifier: "1.2",
        name: "\"5193ae",
        MIMEType: "image/png",
        sizeBytes: 0,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: false
    )
    let localAttachment = IndexedMailAttachment(
        identifier: "file",
        name: legacyAttachment.name,
        MIMEType: "image/png",
        sizeBytes: legacyAttachment.sizeBytes,
        isImage: true,
        isUsefulImage: true,
        isDownloaded: true,
        sourcePath: "/private/tmp/real-image.png"
    )
    let sharedValues = (
        sender: "Michel Gondry <mgondry@mac.com>",
        recipients: "Me <me@example.com>",
        subject: "Re: cozy room"
    )
    let messages = [
        IndexedMailMessage(
            messageIdentifier: "07D262EA-F821-43C1-B8D7-AA09F03EFB44@mac.com",
            localIdentifier: "19",
            sender: sharedValues.sender,
            recipients: sharedValues.recipients,
            subject: sharedValues.subject,
            body: "Same message",
            receivedAt: date,
            sizeBytes: 8_100_000,
            mailboxName: "Important",
            accountName: "Google",
            isSent: false,
            attachments: [legacyAttachment]
        ),
        IndexedMailMessage(
            messageIdentifier: "831252581694405420",
            localIdentifier: "19",
            sender: sharedValues.sender,
            recipients: sharedValues.recipients,
            subject: sharedValues.subject,
            body: "Same message",
            receivedAt: date,
            sizeBytes: 8_100_000,
            mailboxName: "All Mail",
            accountName: "ACCOUNT-ID",
            isSent: false,
            attachments: [phantomAttachment, localAttachment],
            sourcePath: "/private/tmp/19.partial.emlx"
        )
    ]
    _ = try await database.saveDirectMetadata(
        DirectMailScanBatch(
            messages: messages,
            nextRowID: 19,
            attemptedCount: 2,
            failureCount: 0,
            isFinished: true
        ),
        total: 2,
        previous: MailScanProgress(total: 2, phase: .metadata)
    )

    var imageQuery = MailQuery(action: .showImages, hasImage: true, hasAttachment: true)
    imageQuery.attachmentKinds = [.image]
    imageQuery.allResults = true
    let attachments = try await database.searchAttachments(
        imageQuery,
        includePotentialParasites: true
    )
    #expect(attachments.count == 1)
    #expect(attachments[0].attachmentName == legacyAttachment.name)
    #expect(attachments[0].sourcePath == localAttachment.sourcePath)

    let emails = try await database.searchMessages(MailQuery(keywords: ["cozy"]))
    #expect(emails.items.count == 1)
    #expect(emails.items[0].reference.mailboxName == "All Mail")
}

@Test("The partial local index searches words, file kinds, and oldest order")
func partialLocalIndexSearch() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let database = try MailIndexDatabase(databaseURL: directory.appendingPathComponent("test.sqlite"))
    let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newDate = Date(timeIntervalSince1970: 1_750_000_000)
    let PDF = IndexedMailAttachment(
        identifier: "pdf-1",
        name: "invoice.pdf",
        MIMEType: "application/pdf",
        sizeBytes: 2_400_000,
        isImage: false,
        isUsefulImage: false,
        isDownloaded: true
    )
    let messages = [
        IndexedMailMessage(
            messageIdentifier: "old-message",
            localIdentifier: "1",
            sender: "Michel Gondry <michel@example.com>",
            recipients: "me@example.com",
            subject: "Old invoice",
            body: "The complete invoice archive is attached.",
            receivedAt: oldDate,
            sizeBytes: 2_600_000,
            mailboxName: "Inbox",
            accountName: "Google",
            isSent: false,
            attachments: [PDF]
        ),
        IndexedMailMessage(
            messageIdentifier: "new-message",
            localIdentifier: "2",
            sender: "Michel Gondry <michel@example.com>",
            recipients: "me@example.com",
            subject: "New photograph",
            body: "A photograph from the summer trip.",
            receivedAt: newDate,
            sizeBytes: 800_000,
            mailboxName: "Inbox",
            accountName: "Google",
            isSent: false,
            attachments: []
        )
    ]
    _ = try await database.save(
        MailScanBatch(
            messages: messages,
            nextCursor: MailScanCursor(mailboxIndex: 1, messageIndex: 3),
            attemptedCount: 2,
            failureCount: 0,
            isFinished: false
        ),
        total: 20,
        previous: MailScanProgress(scanned: 0, total: 20, failures: 0, isFinished: false)
    )
    let resumedState = try await database.state(total: 0)
    #expect(resumedState.progress.total == 20)
    #expect(resumedState.progress.scanned == 2)
    #expect(resumedState.cursor == MailScanCursor(mailboxIndex: 1, messageIndex: 3))

    var query = MailQuery(
        direction: .received,
        sender: "Michel",
        keywords: ["invoice"],
        hasAttachment: true,
        limit: 10,
        attachmentKinds: [.pdf],
        sortOrder: .oldestFirst
    )
    let PDFResults = try await database.searchMessages(query)
    #expect(PDFResults.items.map(\.reference.messageIdentifier) == ["old-message"])
    #expect(PDFResults.items[0].attachments.map(\.attachmentName) == ["invoice.pdf"])

    var attachmentQuery = query
    attachmentQuery.action = .showFiles
    attachmentQuery.keywords = []
    let attachments = try await database.searchAttachments(attachmentQuery)
    #expect(attachments.count == 1)
    #expect(attachments[0].attachmentName == "invoice.pdf")
    #expect(attachments[0].sizeBytes == 2_400_000)
    #expect(attachments[0].kind == .pdf)

    query.keywords = []
    query.hasAttachment = false
    query.attachmentKinds = []
    let orderedResults = try await database.searchMessages(query)
    #expect(orderedResults.items.map(\.reference.messageIdentifier) == ["old-message", "new-message"])
}
