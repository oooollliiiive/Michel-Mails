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
