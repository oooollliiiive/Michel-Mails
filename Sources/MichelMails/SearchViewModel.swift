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
    var onGalleryReady: ((MailImageGallery) -> Void)?
    var onResultsReady: ((MailSearchResults) -> Void)?
    var onHistorySuggestionsChanged: ((Int) -> Void)?

    private let interpreter = AIQueryInterpreter()
    private let mailService = MailService()
    private let indexController: MailIndexController
    private let historyDefaultsKey = "recentSearchPrompts"
    private let AIInterpretationDefaultsKey = "AIInterpretationEnabled"

    init(indexController: MailIndexController) {
        self.indexController = indexController
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
                        statusText = scansAreIncomplete
                            ? "No emails found in the scanned messages yet."
                            : "No emails found."
                    } else {
                        onResultsReady?(results)
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
                        onGalleryReady?(gallery)
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
        isWorking = true
        statusText = "Copying images…"

        Task {
            defer { isWorking = false }
            let result = await mailService.copyAttachments(
                pendingCopy.candidates,
                to: destination
            )
            statusText = result.imageCount == 1
                ? "1 image copied to \(destination.lastPathComponent)."
                : "\(result.imageCount) images copied to \(destination.lastPathComponent)."
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
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
            return try await mailService.galleryFiles(query, candidates: candidates)
        }
        return try await mailService.galleryImages(query, candidates: candidates)
    }

    private func attachmentCandidates(
        for query: MailQuery
    ) async throws -> [IndexedMailAttachmentCandidate] {
        try await indexController.searchAttachments(query) ?? []
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
