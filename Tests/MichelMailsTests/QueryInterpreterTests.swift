import Foundation
import Testing
@testable import MichelMails

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
        fileName, "photo.jpg", "message-7", "707", "Raffi", "Holiday", "A photo from the trip",
        "2026-09-04T08:15:00"
    ].joined(separator: unit)

    let items = MailScriptRecordParser.images(from: output, in: directory)

    #expect(items.count == 1)
    #expect(items[0].displayName == "photo.jpg")
    #expect(items[0].message.reference.messageIdentifier == "message-7")
    #expect(items[0].message.subject == "Holiday")
}
