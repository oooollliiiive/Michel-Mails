import AppKit
import Foundation

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var prompt = ""
    @Published var statusText = "Demandez-moi de retrouver un email."
    @Published var isWorking = false
    @Published var pendingCopy: PendingCopy?
    @Published var showSettings = false
    @Published var APIKeyDraft = ""
    @Published var modelDraft: String

    private let interpreter = AIQueryInterpreter()
    private let mailService = MailService()

    init() {
        APIKeyDraft = KeychainStore.readAPIKey() ?? ""
        modelDraft = UserDefaults.standard.string(forKey: "openAIModel") ?? "gpt-5.4-mini"
        if APIKeyDraft.isEmpty {
            statusText = "Mode local · ajoutez une clé OpenAI avec ⚙︎ pour activer l’IA."
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
        statusText = usesOpenAI ? "Je comprends la demande…" : "J’interprète la demande en mode local…"

        Task {
            defer { isWorking = false }
            do {
                let parsedQuery = try await interpreter.interpret(
                    requestText,
                    APIKey: APIKeyDraft.nilIfBlank,
                    model: modelDraft.nilIfBlank ?? "gpt-5.4-mini"
                )
                statusText = "Je cherche dans Mail…"

                switch parsedQuery.action {
                case .search:
                    let count = try await searchWithFuzzyFallback(parsedQuery)
                    if count == 0 {
                        statusText = "Aucun email trouvé."
                    } else {
                        statusText = count == 1
                            ? "1 email ouvert dans Mail."
                            : "\(count) emails trouvés · ouverts dans Mail."
                    }

                case .copyImages:
                    let result = try await imageSummaryWithFuzzyFallback(parsedQuery)
                    let summary = result.summary
                    if summary.imageCount == 0 {
                        statusText = "Aucune image trouvée."
                    } else {
                        pendingCopy = PendingCopy(query: result.query, summary: summary)
                        statusText = copyConfirmationText(for: result.query, summary: summary)
                    }
                }
            } catch {
                statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
            statusText = "Impossible de créer le dossier : \(error.localizedDescription)"
            return
        }

        self.pendingCopy = nil
        isWorking = true
        statusText = "Copie des images…"

        Task {
            defer { isWorking = false }
            do {
                let result = try await mailService.copyImages(pendingCopy.query, to: destination)
                statusText = result.imageCount == 1
                    ? "1 image copiée dans \(destination.lastPathComponent)."
                    : "\(result.imageCount) images copiées dans \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    func cancelCopy() {
        pendingCopy = nil
        statusText = "Copie annulée."
    }

    func saveSettings() {
        do {
            try KeychainStore.saveAPIKey(APIKeyDraft)
            let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(model.isEmpty ? "gpt-5.4-mini" : model, forKey: "openAIModel")
            modelDraft = model.isEmpty ? "gpt-5.4-mini" : model
            showSettings = false
            statusText = usesOpenAI
                ? "IA OpenAI activée."
                : "Mode local activé."
        } catch {
            statusText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func copyConfirmationText(for query: MailQuery, summary: MailMatchSummary) -> String {
        let folder = query.destinationFolder?.nilIfBlank ?? "un dossier à choisir"
        let emailWord = summary.messageCount == 1 ? "email" : "emails"
        let imageWord = summary.imageCount == 1 ? "image" : "images"
        return "\(summary.messageCount) \(emailWord) · \(summary.imageCount) \(imageWord) → \(folder)"
    }

    private func searchWithFuzzyFallback(_ query: MailQuery) async throws -> Int {
        let exactCount = try await mailService.searchAndOpen(query)
        guard exactCount == 0, query.needsSenderResolution else { return exactCount }

        statusText = "Je cherche une orthographe proche du contact…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return 0 }

        statusText = "Contact probable : \(resolved.sender ?? query.sender ?? "") · nouvelle recherche…"
        return try await mailService.searchAndOpen(resolved)
    }

    private func imageSummaryWithFuzzyFallback(
        _ query: MailQuery
    ) async throws -> (query: MailQuery, summary: MailMatchSummary) {
        let exactSummary = try await mailService.countImages(query)
        guard exactSummary.imageCount == 0, query.needsSenderResolution else {
            return (query, exactSummary)
        }

        statusText = "Je cherche une orthographe proche du contact…"
        let resolved = try await mailService.resolvingSender(in: query)
        guard resolved.sender != query.sender else { return (query, exactSummary) }

        statusText = "Contact probable : \(resolved.sender ?? query.sender ?? "") · nouvelle recherche…"
        return (resolved, try await mailService.countImages(resolved))
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
        panel.title = "Choisir le dossier des images"
        panel.message = "Les images seront copiées dans ce dossier."
        panel.prompt = "Copier ici"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
