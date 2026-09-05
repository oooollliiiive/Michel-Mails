import AppKit
import Foundation

@MainActor
final class MailIndexController: ObservableObject {
    @Published private(set) var progress = MailScanProgress(phase: .metadata)
    @Published private(set) var fullContentProgress = MailScanProgress(phase: .content)
    @Published private(set) var isAvailable = true
    @Published private(set) var requiresFullDiskAccess = false
    @Published private(set) var forceScanEnabled = false
    @Published private(set) var scanActivityText = "Preparing local Mail index…"
    @Published private(set) var lastScanErrorText = "No scan errors."

    private var scanTask: Task<Void, Never>?
    private var database: MailIndexDatabase?
    private var source: DirectMailSource?

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.runScan()
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
    }

    func setForceScan(_ enabled: Bool) {
        forceScanEnabled = enabled
        if scanTask == nil { start() }
    }

    func openFullDiskAccessSettings() {
        let URLs = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for value in URLs {
            if let URL = URL(string: value), NSWorkspace.shared.open(URL) { return }
        }
    }

    func searchMessages(_ query: MailQuery) async throws -> MailSearchResults? {
        guard let database, try await database.indexedMessageCount() > 0 else { return nil }
        return try await database.searchMessages(query)
    }

    func searchAttachments(
        _ query: MailQuery,
        includePotentialParasites: Bool = false,
        includeJunk: Bool = false
    ) async throws -> [IndexedMailAttachmentCandidate]? {
        guard let database, try await database.indexedMessageCount() > 0 else { return nil }
        return try await database.searchAttachments(
            query,
            includePotentialParasites: includePotentialParasites,
            includeJunk: includeJunk
        )
    }

    func latestImageAttachments(
        targetCount: Int,
        direction: MailDirection,
        correspondent: String,
        includePotentialParasites: Bool = false,
        includeJunk: Bool = false
    ) async throws -> [IndexedMailAttachmentCandidate]? {
        guard let database, try await database.indexedMessageCount() > 0 else { return nil }
        return try await database.latestImageAttachments(
            targetCount: targetCount,
            direction: direction,
            correspondent: correspondent,
            includePotentialParasites: includePotentialParasites,
            includeJunk: includeJunk
        )
    }

    func recentImageCorrespondents(limit: Int = 100) async throws -> [String] {
        guard let database, try await database.indexedMessageCount() > 0 else { return [] }
        return try await database.recentImageCorrespondents(limit: limit)
    }

    private func runScan() async {
        while !Task.isCancelled {
            do {
                let activeDatabase = try database ?? MailIndexDatabase()
                database = activeDatabase

                let activeSource: DirectMailSource
                if let source {
                    activeSource = source
                } else {
                    scanActivityText = "Opening Apple Mail's local index…"
                    let openedSource = try DirectMailSource()
                    source = openedSource
                    activeSource = openedSource
                }

                let total = try await activeSource.totalMessageCount()
                var state = try await activeDatabase.directState(total: total)
                progress = state.indexProgress
                fullContentProgress = state.contentProgress
                requiresFullDiskAccess = false
                isAvailable = true

                while !Task.isCancelled {
                    if !progress.isFinished {
                        let limit = forceScanEnabled ? 2_000 : 500
                        scanActivityText = "Reading the local email index…"
                        let batch = try await activeSource.metadataBatch(
                            after: state.indexCursorRowID,
                            maximumCount: limit
                        )
                        progress = try await activeDatabase.saveDirectMetadata(
                            batch,
                            total: total,
                            previous: progress
                        )
                        state.indexCursorRowID = batch.nextRowID
                        state.indexProgress = progress
                        scanActivityText = progressLine(
                            prefix: "Email index saved",
                            cursor: batch.nextRowID
                        )
                        await pause(after: .metadata)
                        continue
                    }

                    if !fullContentProgress.isFinished {
                        let limit = forceScanEnabled ? 50 : 10
                        scanActivityText = "Reading locally downloaded email contents…"
                        let batch = try await activeSource.contentBatch(
                            after: state.contentCursorRowID,
                            maximumCount: limit
                        )
                        fullContentProgress = try await activeDatabase.saveDirectContent(
                            batch,
                            total: total,
                            previous: fullContentProgress
                        )
                        state.contentCursorRowID = batch.nextRowID
                        state.contentProgress = fullContentProgress
                        if batch.failureCount > 0 {
                            lastScanErrorText = "\(batch.failureCount) local contents unavailable in the last batch; scan continued."
                        }
                        scanActivityText = progressLine(
                            prefix: "Full content saved",
                            cursor: batch.nextRowID
                        )
                        await pause(after: .content)
                        continue
                    }

                    scanActivityText = "Both scans complete · watching for new mail."
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    let latestTotal = try await activeSource.totalMessageCount()
                    state = try await activeDatabase.directState(total: latestTotal)
                    progress = state.indexProgress
                    fullContentProgress = state.contentProgress
                }
            } catch {
                if Task.isCancelled { break }
                source = nil
                let message = Self.shortError(error)
                lastScanErrorText = message
                if case DirectMailSourceError.fullDiskAccessRequired = error {
                    requiresFullDiskAccess = true
                    isAvailable = false
                    scanActivityText = "Full Disk Access required · add Michel Mails, then reopen it if macOS asks."
                } else {
                    requiresFullDiskAccess = false
                    isAvailable = false
                    scanActivityText = "Email index temporarily unavailable · retrying automatically."
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        scanTask = nil
    }

    private func pause(after phase: MailScanPhase) async {
        if forceScanEnabled {
            await Task.yield()
            return
        }
        let nanoseconds: UInt64 = phase == .metadata ? 150_000_000 : 350_000_000
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func progressLine(prefix: String, cursor: Int64) -> String {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        return "\(prefix) at \(time) · source row \(cursor.formatted())"
    }

    private static func shortError(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let singleLine = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(singleLine.prefix(180))
    }
}
