import AppKit
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var statusText = "Ask me to find an email."
    @Published var isWorking = false
    @Published var pendingCopy: PendingCopy?
    @Published var showSettings = false
    @Published var APIKeyDraft = ""
    @Published var modelDraft: String
    @Published private(set) var AIInterpretationEnabled: Bool
    @Published var historyIsVisible = false
    @Published private(set) var recentPrompts: [String] = []
    @Published private(set) var displayedGallery: MailImageGallery?
    @Published private(set) var displayedResults: MailSearchResults?
    @Published private(set) var showParasiteImages = false
    @Published private(set) var showJunkImages = false
    @Published private(set) var imageCorrespondents: [String] = []
    @Published private(set) var downloadsSidebarIsVisible = false
    var onContentVisibilityChanged: ((Bool) -> Void)?
    var onHistorySuggestionsChanged: ((Int) -> Void)?
    var onDownloadsVisibilityChanged: ((Bool) -> Void)?

    private let interpreter = AIQueryInterpreter()
    private let mailService = MailService()
    private let indexController: MailIndexController
    let downloadManager: AttachmentDownloadManager
    private let historyDefaultsKey = "recentSearchPrompts"
    private let AIInterpretationDefaultsKey = "AIInterpretationEnabled"
    private var displayedGalleryRequest: DisplayedGalleryRequest?

    private enum DisplayedGalleryRequest {
        case quick(count: Int, direction: MailDirection, correspondent: String)
        case query(MailQuery)
    }

    init(
        indexController: MailIndexController,
        downloadManager: AttachmentDownloadManager
    ) {
        self.indexController = indexController
        self.downloadManager = downloadManager
        let storedKey = KeychainStore.readAPIKey() ?? ""
        APIKeyDraft = storedKey
        modelDraft = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-5.4-mini"
        AIInterpretationEnabled = UserDefaults.standard.object(forKey: AIInterpretationDefaultsKey) as? Bool
            ?? !storedKey.isEmpty
        recentPrompts = UserDefaults.standard.stringArray(forKey: historyDefaultsKey) ?? []
    }

    var usesOpenAI: Bool {
        AIInterpretationEnabled && hasOpenAIKey
    }

    var hasOpenAIKey: Bool {
        !APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historySuggestions: [String] {
        SearchHistory.suggestions(for: prompt, in: recentPrompts)
    }

    func updatePrompt(_ value: String) {
        prompt = value
        updateHistoryVisibility()
    }

    func clearPrompt() {
        prompt = ""
        hideHistory()
    }

    func chooseHistory(_ request: String) {
        prompt = request
        hideHistory()
    }

    func submit() {
        let requestText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty, !isWorking else { return }

        recordInHistory(requestText)
        hideHistory()
        pendingCopy = nil
        isWorking = true
        statusText = usesOpenAI ? "Understanding your request…" : "Understanding your request locally…"

        Task {
            defer { isWorking = false }
            do {
                let parsedQuery = try await interpreter.interpret(
                    requestText,
                    APIKey: usesOpenAI ? APIKeyDraft.nilIfBlank : nil,
                    model: modelDraft.nilIfBlank ?? "gpt-5.4-mini"
                )
                statusText = "Searching the local email index…"

                switch parsedQuery.action {
                case .search:
                    let results = try await searchWithFuzzyFallback(parsedQuery)
                    if results.items.isEmpty {
                        closeDisplayedContent()
                        statusText = scansAreIncomplete
                            ? "No emails found in the scanned messages yet."
                            : "No emails found."
                    } else {
                        displayResults(results)
                        statusText = results.items.count == 1
                            ? "1 email displayed."
                            : "\(results.items.count) emails displayed."
                    }

                case .showImages, .showFiles:
                    statusText = parsedQuery.action == .showImages ? "Preparing images…" : "Preparing files…"
                    let gallery = try await galleryWithFuzzyFallback(parsedQuery)
                    if gallery.items.isEmpty {
                        if gallery.attemptedCount > 0 {
                            let noun = parsedQuery.action == .showImages ? "images" : "files"
                            statusText = "\(gallery.attemptedCount) matching \(noun) found, but none could be displayed."
                        } else if scansAreIncomplete {
                            statusText = parsedQuery.action == .showImages
                                ? "No images found in scanned emails yet."
                                : "No files found in scanned emails yet."
                        } else {
                            statusText = parsedQuery.action == .showImages ? "No images found." : "No files found."
                        }
                    } else {
                        displayGallery(gallery, request: .query(gallery.query))
                        let noun = parsedQuery.action == .showImages ? "image" : "file"
                        statusText = gallery.items.count == 1
                            ? "1 \(noun) displayed."
                            : "\(gallery.items.count) \(noun)s displayed."
                    }

                case .copyImages:
                    let result = try await imageSummaryWithFuzzyFallback(parsedQuery)
                    let summary = result.summary
                    if summary.imageCount == 0 {
                        statusText = scansAreIncomplete
                            ? "No images found in scanned emails yet."
                            : "No images found."
                    } else {
                        pendingCopy = PendingCopy(
                            query: result.query,
                            summary: summary,
                            candidates: result.candidates
                        )
                        statusText = copyConfirmationText(for: result.query, summary: summary)
                    }
                }
            } catch {
                statusText = userFacingMessage(for: error)
            }
        }
    }

    func showLatestImages(
        count: Int,
        direction: MailDirection,
        correspondent: String
    ) {
        guard !isWorking else { return }
        hideHistory()
        pendingCopy = nil
        isWorking = true
        statusText = "Preparing the latest images from the local index…"

        Task {
            defer { isWorking = false }
            do {
                let requestedCount = max(count, 1)
                let fetchCount = requestedCount + max(20, requestedCount / 2)
                let candidates = try await indexController.latestImageAttachments(
                    targetCount: fetchCount,
                    direction: direction,
                    correspondent: correspondent,
                    includePotentialParasites: showParasiteImages,
                    includeJunk: showJunkImages
                ) ?? []
                var query = MailQuery()
                query.action = .showImages
                query.direction = direction
                query.sender = correspondent.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                query.hasImage = true
                query.hasAttachment = true
                query.limit = requestedCount
                query.attachmentKinds = [.image]
                query.sortOrder = .newestFirst

                let preparedGallery = try await mailService.galleryImages(
                    query,
                    candidates: candidates,
                    includePotentialParasites: showParasiteImages
                )
                let gallery = Self.trimmingGallery(
                    preparedGallery,
                    toAtLeast: requestedCount
                )
                guard !gallery.items.isEmpty else {
                    closeDisplayedContent()
                    if gallery.attemptedCount > 0 {
                        statusText = "Images were indexed, but their local files are not available yet."
                    } else {
                        statusText = scansAreIncomplete
                            ? "No images found in scanned emails yet."
                            : "No images found."
                    }
                    refreshImageCorrespondents()
                    return
                }

                displayGallery(
                    gallery,
                    request: .quick(
                        count: requestedCount,
                        direction: direction,
                        correspondent: correspondent
                    )
                )
                statusText = gallery.items.count == 1
                    ? "1 image displayed."
                    : "\(gallery.items.count) images displayed."
                refreshImageCorrespondents()
            } catch {
                statusText = userFacingMessage(for: error)
            }
        }
    }

    func closeGallery() {
        closeDisplayedContent()
    }

    func closeResults() {
        closeDisplayedContent()
    }

    func closeDisplayedContent() {
        guard displayedGallery != nil || displayedResults != nil else { return }
        displayedGallery = nil
        displayedResults = nil
        displayedGalleryRequest = nil
        onContentVisibilityChanged?(false)
    }

    func setShowParasiteImages(_ enabled: Bool) {
        showParasiteImages = enabled
        guard !isWorking, let request = displayedGalleryRequest else { return }
        switch request {
        case let .quick(count, direction, correspondent):
            showLatestImages(count: count, direction: direction, correspondent: correspondent)
        case let .query(query):
            reloadGallery(query)
        }
    }

    func setShowJunkImages(_ enabled: Bool) {
        showJunkImages = enabled
        guard !isWorking, let request = displayedGalleryRequest else { return }
        switch request {
        case let .quick(count, direction, correspondent):
            showLatestImages(count: count, direction: direction, correspondent: correspondent)
        case let .query(query):
            reloadGallery(query)
        }
    }

    func showDownloads() {
        guard !downloadsSidebarIsVisible else { return }
        downloadsSidebarIsVisible = true
        onDownloadsVisibilityChanged?(true)
    }

    func hideDownloads() {
        guard downloadsSidebarIsVisible else { return }
        downloadsSidebarIsVisible = false
        onDownloadsVisibilityChanged?(false)
    }

    func toggleDownloads() {
        downloadsSidebarIsVisible ? hideDownloads() : showDownloads()
    }

    func downloadAttachments(_ message: MailMessageItem) {
        guard !message.attachments.isEmpty else {
            statusText = "This email has no downloadable attachments."
            return
        }
        downloadManager.downloadAttachmentsToDesktop(message.attachments)
        statusText = message.attachments.count == 1
            ? "1 attachment queued for Desktop/Files from Mails."
            : "\(message.attachments.count) attachments queued for Desktop/Files from Mails."
    }

    func refreshImageCorrespondents() {
        Task {
            if let correspondents = try? await indexController.recentImageCorrespondents(limit: 100) {
                imageCorrespondents = correspondents
            }
        }
    }

    func confirmCopy() {
        guard let pendingCopy, !isWorking else { return }
        guard let destination = destinationURL(for: pendingCopy.query) else { return }

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            statusText = "Could not create the folder."
            return
        }

        self.pendingCopy = nil
        downloadManager.downloadAttachments(pendingCopy.candidates, to: destination)
        statusText = pendingCopy.candidates.count == 1
            ? "1 image queued for \(destination.lastPathComponent)."
            : "\(pendingCopy.candidates.count) images queued for \(destination.lastPathComponent)."
    }

    func cancelCopy() {
        pendingCopy = nil
        statusText = "Copy cancelled."
    }

    func openMessage(_ message: MailMessageItem) {
        statusText = "Opening email in Mail…"
        Task {
            do {
                try await mailService.openMessage(message)
                statusText = "Email opened in Mail."
            } catch {
                statusText = userFacingMessage(for: error)
            }
        }
    }

    func saveSettings() {
        do {
            try KeychainStore.saveAPIKey(APIKeyDraft)
            if !hasOpenAIKey {
                AIInterpretationEnabled = false
            }
            UserDefaults.standard.set(AIInterpretationEnabled, forKey: AIInterpretationDefaultsKey)
            let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(model.isEmpty ? "gpt-5.4-mini" : model, forKey: "openAIModel")
            modelDraft = model.isEmpty ? "gpt-5.4-mini" : model
            showSettings = false
            statusText = usesOpenAI
                ? "OpenAI is enabled."
                : "Local mode is enabled."
        } catch {
            statusText = userFacingMessage(for: error)
        }
    }

    func setAIInterpretation(_ enabled: Bool) {
        guard !enabled || hasOpenAIKey else {
            AIInterpretationEnabled = false
            showSettings = true
            statusText = "Add an OpenAI API key to turn on AI interpretation."
            return
        }
        AIInterpretationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AIInterpretationDefaultsKey)
        statusText = enabled
            ? "OpenAI interpretation is enabled."
            : "Local interpretation is enabled."
    }

    private func copyConfirmationText(for query: MailQuery, summary: MailMatchSummary) -> String {
        let folder = query.destinationFolder?.nilIfBlank ?? "a folder you choose"
        let emailWord = summary.messageCount == 1 ? "email" : "emails"
        let imageWord = summary.imageCount == 1 ? "image" : "images"
        return "\(summary.messageCount) \(emailWord) · \(summary.imageCount) \(imageWord) → \(folder)"
    }

    private func searchWithFuzzyFallback(_ query: MailQuery) async throws -> MailSearchResults {
        let exactResults = try await searchMessages(query)
        guard exactResults.items.isEmpty, query.needsSenderResolution else { return exactResults }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return exactResults }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        return try await searchMessages(resolved)
    }

    private func searchMessages(_ query: MailQuery) async throws -> MailSearchResults {
        if let indexedResults = try await indexController.searchMessages(query) {
            return indexedResults
        }
        return MailSearchResults(items: [], query: query)
    }

    private func imageSummaryWithFuzzyFallback(
        _ query: MailQuery
    ) async throws -> (
        query: MailQuery,
        summary: MailMatchSummary,
        candidates: [IndexedMailAttachmentCandidate]
    ) {
        let exactCandidates = try await attachmentCandidates(for: query)
        let exactSummary = summary(for: exactCandidates)
        guard exactSummary.imageCount == 0, query.needsSenderResolution else {
            return (query, exactSummary, exactCandidates)
        }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return (query, exactSummary, exactCandidates) }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        let resolvedCandidates = try await attachmentCandidates(for: resolved)
        return (resolved, summary(for: resolvedCandidates), resolvedCandidates)
    }

    private func galleryWithFuzzyFallback(_ query: MailQuery) async throws -> MailImageGallery {
        let exactGallery = try await gallery(for: query)
        guard exactGallery.items.isEmpty, query.needsSenderResolution else {
            return exactGallery
        }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return exactGallery }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        return try await gallery(for: resolved)
    }

    private func gallery(for query: MailQuery) async throws -> MailImageGallery {
        let candidates = try await attachmentCandidates(for: query)
        if query.action == .showFiles {
            return try await mailService.galleryFiles(
                query,
                candidates: candidates,
                includePotentialParasites: showParasiteImages
            )
        }
        return try await mailService.galleryImages(
            query,
            candidates: candidates,
            includePotentialParasites: showParasiteImages
        )
    }

    private func attachmentCandidates(
        for query: MailQuery
    ) async throws -> [IndexedMailAttachmentCandidate] {
        try await indexController.searchAttachments(
            query,
            includePotentialParasites: showParasiteImages,
            includeJunk: showJunkImages
        ) ?? []
    }

    private func summary(
        for candidates: [IndexedMailAttachmentCandidate]
    ) -> MailMatchSummary {
        let messageKeys = Set(candidates.map { $0.messageIdentifier + "|" + $0.localIdentifier })
        return MailMatchSummary(messageCount: messageKeys.count, imageCount: candidates.count)
    }

    private func destinationURL(for query: MailQuery) -> URL? {
        if let requestedFolder = query.destinationFolder?.nilIfBlank {
            if requestedFolder.hasPrefix("/") {
                return URL(fileURLWithPath: requestedFolder).standardizedFileURL
            }
            let safeFolderName = URL(fileURLWithPath: requestedFolder).lastPathComponent
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                return documents.appendingPathComponent(safeFolderName, isDirectory: true)
            }
        }

        let panel = NSOpenPanel()
        panel.title = "Choose an Image Folder"
        panel.message = "The images will be copied to this folder."
        panel.prompt = "Copy Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func userFacingMessage(for error: Error) -> String {
        (error as? MichelMailsError)?.errorDescription ?? "Something went wrong."
    }

    private func displayGallery(
        _ gallery: MailImageGallery,
        request: DisplayedGalleryRequest
    ) {
        displayedResults = nil
        displayedGallery = gallery
        displayedGalleryRequest = request
        downloadManager.prepareThumbnails(
            gallery.items.compactMap(\.sourceCandidate)
        )
        onContentVisibilityChanged?(true)
    }

    private func displayResults(_ results: MailSearchResults) {
        displayedGallery = nil
        displayedGalleryRequest = nil
        displayedResults = results
        downloadManager.prepareThumbnails(
            results.items.flatMap(\.imageAttachments)
        )
        onContentVisibilityChanged?(true)
    }

    private func reloadGallery(_ query: MailQuery) {
        guard !isWorking else { return }
        isWorking = true
        statusText = "Updating image filters…"
        Task {
            defer { isWorking = false }
            do {
                let gallery = try await gallery(for: query)
                displayGallery(gallery, request: .query(query))
                statusText = gallery.items.count == 1
                    ? "1 image displayed."
                    : "\(gallery.items.count) images displayed."
            } catch {
                statusText = userFacingMessage(for: error)
            }
        }
    }

    private static func trimmingGallery(
        _ gallery: MailImageGallery,
        toAtLeast targetCount: Int
    ) -> MailImageGallery {
        guard gallery.items.count > targetCount else { return gallery }
        var kept: [MailImageItem] = []
        var index = 0
        while index < gallery.items.count {
            let messageKey = gallery.items[index].message.reference.stableKey
            let groupStart = index
            while index < gallery.items.count,
                  gallery.items[index].message.reference.stableKey == messageKey {
                index += 1
            }
            kept.append(contentsOf: gallery.items[groupStart..<index])
            if kept.count >= targetCount { break }
        }
        return MailImageGallery(
            items: kept,
            query: gallery.query,
            attemptedCount: gallery.attemptedCount
        )
    }

    private func recordInHistory(_ request: String) {
        recentPrompts = SearchHistory.adding(request, to: recentPrompts)
        UserDefaults.standard.set(recentPrompts, forKey: historyDefaultsKey)
    }

    private func updateHistoryVisibility() {
        let count = isWorking ? 0 : historySuggestions.count
        historyIsVisible = count > 0
        onHistorySuggestionsChanged?(count)
    }

    private func hideHistory() {
        historyIsVisible = false
        onHistorySuggestionsChanged?(0)
    }

    private var scansAreIncomplete: Bool {
        !indexController.progress.isFinished || !indexController.fullContentProgress.isFinished
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
