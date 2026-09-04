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
    var onGalleryReady: ((MailImageGallery) -> Void)?

    private let interpreter = AIQueryInterpreter()
    private let mailService = MailService()

    init() {
        APIKeyDraft = KeychainStore.readAPIKey() ?? ""
        modelDraft = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-5.4-mini"
        if APIKeyDraft.isEmpty {
            statusText = "Local mode · add an OpenAI key in Settings to enable AI."
            showSettings = true
        }
    }

    var usesOpenAI: Bool {
        !APIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() {
        let requestText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestText.isEmpty, !isWorking else { return }

        pendingCopy = nil
        isWorking = true
        statusText = usesOpenAI ? "Understanding your request…" : "Understanding your request locally…"

        Task {
            defer { isWorking = false }
            do {
                let parsedQuery = try await interpreter.interpret(
                    requestText,
                    APIKey: APIKeyDraft.nilIfBlank,
                    model: modelDraft.nilIfBlank ?? "gpt-5.4-mini"
                )
                statusText = "Searching in Mail…"

                switch parsedQuery.action {
                case .search:
                    let count = try await searchWithFuzzyFallback(parsedQuery)
                    if count == 0 {
                        statusText = "No emails found."
                    } else {
                        statusText = count == 1
                            ? "1 email opened in Mail."
                            : "\(count) emails found · opened in Mail."
                    }

                case .showImages:
                    statusText = "Preparing images…"
                    let gallery = try await galleryWithFuzzyFallback(parsedQuery)
                    if gallery.items.isEmpty {
                        statusText = "No images found."
                    } else {
                        onGalleryReady?(gallery)
                        statusText = gallery.items.count == 1
                            ? "1 image displayed."
                            : "\(gallery.items.count) images displayed."
                    }

                case .copyImages:
                    let result = try await imageSummaryWithFuzzyFallback(parsedQuery)
                    let summary = result.summary
                    if summary.imageCount == 0 {
                        statusText = "No images found."
                    } else {
                        pendingCopy = PendingCopy(query: result.query, summary: summary)
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
            do {
                let result = try await mailService.copyImages(pendingCopy.query, to: destination)
                statusText = result.imageCount == 1
                    ? "1 image copied to \(destination.lastPathComponent)."
                    : "\(result.imageCount) images copied to \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                statusText = userFacingMessage(for: error)
            }
        }
    }

    func cancelCopy() {
        pendingCopy = nil
        statusText = "Copy cancelled."
    }

    func saveSettings() {
        do {
            try KeychainStore.saveAPIKey(APIKeyDraft)
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

    private func copyConfirmationText(for query: MailQuery, summary: MailMatchSummary) -> String {
        let folder = query.destinationFolder?.nilIfBlank ?? "a folder you choose"
        let emailWord = summary.messageCount == 1 ? "email" : "emails"
        let imageWord = summary.imageCount == 1 ? "image" : "images"
        return "\(summary.messageCount) \(emailWord) · \(summary.imageCount) \(imageWord) → \(folder)"
    }

    private func searchWithFuzzyFallback(_ query: MailQuery) async throws -> Int {
        let exactCount = try await mailService.searchAndOpen(query)
        guard exactCount == 0, query.needsSenderResolution else { return exactCount }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return 0 }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        return try await mailService.searchAndOpen(resolved)
    }

    private func imageSummaryWithFuzzyFallback(
        _ query: MailQuery
    ) async throws -> (query: MailQuery, summary: MailMatchSummary) {
        let exactSummary = try await mailService.countImages(query)
        guard exactSummary.imageCount == 0, query.needsSenderResolution else {
            return (query, exactSummary)
        }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return (query, exactSummary) }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        return (resolved, try await mailService.countImages(resolved))
    }

    private func galleryWithFuzzyFallback(_ query: MailQuery) async throws -> MailImageGallery {
        let exactGallery = try await mailService.galleryImages(query)
        guard exactGallery.items.isEmpty, query.needsSenderResolution else {
            return exactGallery
        }

        statusText = "Looking for a similar contact name…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return exactGallery }

        statusText = "Likely contact: \(resolved.sender ?? query.sender ?? "") · searching again…"
        return try await mailService.galleryImages(resolved)
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
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
