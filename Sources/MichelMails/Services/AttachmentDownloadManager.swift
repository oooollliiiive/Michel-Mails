import AppKit
import Foundation

@MainActor
final class AttachmentDownloadManager: ObservableObject {
    @Published private(set) var records: [String: AttachmentTransferRecord] = [:]
    @Published private(set) var orderedKeys: [String] = []

    var onPresentDownloads: (() -> Void)?

    private let maximumConcurrentTransfers = 4
    private let startsTransfersAutomatically: Bool
    private var queue: [String] = []
    private var activeKeys: Set<String> = []
    private var activeMailKeys: Set<String> = []
    private var highPriorityKeys: Set<String> = []
    private var mailCooldown = false
    private var presentedAutomaticDownloads = false
    private var finishedRowTasks: [String: Task<Void, Never>] = [:]

    init(startsTransfersAutomatically: Bool = true) {
        self.startsTransfersAutomatically = startsTransfersAutomatically
        Task.detached(priority: .utility) {
            try? PersistentAttachmentStore.cleanupExpired()
        }
    }

    var items: [AttachmentTransferRecord] {
        orderedKeys
            .compactMap { records[$0] }
            .filter(\.isVisibleInDownloads)
            .sorted {
                ($0.candidate.receivedAt ?? .distantPast) >
                    ($1.candidate.receivedAt ?? .distantPast)
            }
    }

    var activeCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .downloading }.count
    }

    var queuedCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .queued }.count
    }

    func record(for candidate: IndexedMailAttachmentCandidate) -> AttachmentTransferRecord? {
        records[candidate.stableKey]
    }

    func thumbnailURL(for candidate: IndexedMailAttachmentCandidate) -> URL? {
        records[candidate.stableKey]?.thumbnailURL
            ?? PersistentThumbnailStore.existingThumbnailURL(for: candidate)
    }

    func originalURL(for candidate: IndexedMailAttachmentCandidate) -> URL? {
        PersistentAttachmentStore.existingOriginalURL(for: candidate)
            ?? AttachmentMaterializer.directlyAvailableFile(for: candidate)
    }

    func prepareThumbnails(_ candidates: [IndexedMailAttachmentCandidate]) {
        presentedAutomaticDownloads = false
        let orderedCandidates = candidates.sorted {
            ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast)
        }
        var updatedRecords = records
        var updatedKeys = orderedKeys
        var knownKeys = Set(updatedKeys)
        var queuedKeys = Set(queue)
        var queuedRemoteDownload = false
        for candidate in orderedCandidates {
            let key = candidate.stableKey
            let existingThumbnail = PersistentThumbnailStore.existingThumbnailURL(for: candidate)
            let hasLocallyAvailableSource = PersistentAttachmentStore.existingOriginalURL(
                for: candidate
            ) != nil || !candidate.sourcePath.isEmpty
            var record = updatedRecords[key] ?? AttachmentTransferRecord(
                candidate: candidate,
                state: existingThumbnail == nil && !hasLocallyAvailableSource ? .available : .queued,
                thumbnailURL: existingThumbnail,
                exportedURL: nil,
                exportDirectoryURL: nil,
                needsThumbnail: existingThumbnail == nil,
                needsExport: false
            )
            let localSourceBecameAvailable = record.candidate.sourcePath.isEmpty &&
                !candidate.sourcePath.isEmpty
            record.candidate = candidate
            if let existingThumbnail { record.thumbnailURL = existingThumbnail }
            record.needsThumbnail = record.thumbnailURL == nil
            record.automaticallyDownloadIfNeeded = record.needsThumbnail
            record.shouldCacheOriginal = record.shouldCacheOriginal || record.needsThumbnail
            if record.needsThumbnail,
               hasLocallyAvailableSource,
               !activeKeys.contains(key),
               record.state != .failed,
               (record.state != .available || localSourceBecameAvailable) {
                record.state = .queued
                if queuedKeys.insert(key).inserted { queue.append(key) }
            } else if record.needsThumbnail,
                      !hasLocallyAvailableSource,
                      !activeKeys.contains(key),
                      record.state != .failed {
                record.state = .queued
                record.allowsMailDownload = true
                record.isVisibleInDownloads = true
                if queuedKeys.insert(key).inserted { queue.append(key) }
                queuedRemoteDownload = true
            } else if !record.needsThumbnail && !record.needsExport {
                record.state = .ready
            }
            updatedRecords[key] = record
            if knownKeys.insert(key).inserted { updatedKeys.append(key) }
        }
        records = updatedRecords
        orderedKeys = updatedKeys
        if queuedRemoteDownload { presentAutomaticDownloadsIfNeeded() }
        pumpQueue()
    }

    func downloadAttachmentsToDesktop(_ candidates: [IndexedMailAttachmentCandidate]) {
        downloadAttachments(candidates, to: nil)
    }

    func downloadAttachments(
        _ candidates: [IndexedMailAttachmentCandidate],
        to destinationDirectory: URL
    ) {
        downloadAttachments(candidates, to: Optional(destinationDirectory))
    }

    private func downloadAttachments(
        _ candidates: [IndexedMailAttachmentCandidate],
        to destinationDirectory: URL?
    ) {
        guard !candidates.isEmpty else { return }
        onPresentDownloads?()
        for candidate in candidates.reversed() {
            enqueue(
                candidate,
                needsThumbnail: candidate.kind == .image,
                needsExport: true,
                priority: true,
                allowsMailDownload: true,
                visibleInDownloads: true,
                exportDirectoryURL: destinationDirectory
            )
        }
        pumpQueue()
    }

    func openAttachment(_ candidate: IndexedMailAttachmentCandidate) {
        onPresentDownloads?()
        enqueue(
            candidate,
            needsThumbnail: candidate.kind == .image,
            needsExport: false,
            priority: true,
            allowsMailDownload: true,
            visibleInDownloads: true,
            exportDirectoryURL: nil,
            openWhenReady: true
        )
        pumpQueue()
    }

    func downloadForPreview(_ candidate: IndexedMailAttachmentCandidate) {
        onPresentDownloads?()
        enqueue(
            candidate,
            needsThumbnail: true,
            needsExport: false,
            priority: true,
            allowsMailDownload: true,
            visibleInDownloads: true,
            exportDirectoryURL: nil
        )
        pumpQueue()
    }

    func retry(_ candidate: IndexedMailAttachmentCandidate) {
        guard var record = records[candidate.stableKey], !activeKeys.contains(candidate.stableKey) else {
            return
        }
        finishedRowTasks.removeValue(forKey: candidate.stableKey)?.cancel()
        record.state = .queued
        record.errorMessage = nil
        record.allowsMailDownload = true
        record.isVisibleInDownloads = true
        if !record.needsThumbnail && record.thumbnailURL == nil {
            record.needsThumbnail = candidate.kind == .image
        }
        records[candidate.stableKey] = record
        queue.removeAll { $0 == candidate.stableKey }
        highPriorityKeys.insert(candidate.stableKey)
        queue.insert(candidate.stableKey, at: 0)
        onPresentDownloads?()
        pumpQueue()
    }

    func clearFinished() {
        let removable = Set(records.values.filter {
            $0.isVisibleInDownloads && $0.state == .ready && !activeKeys.contains($0.id)
        }.map(\.id))
        for key in removable { records.removeValue(forKey: key) }
        for key in removable { finishedRowTasks.removeValue(forKey: key)?.cancel() }
        orderedKeys.removeAll { removable.contains($0) }
        queue.removeAll { removable.contains($0) }
        highPriorityKeys.subtract(removable)
    }

    func showDestinationFolder() {
        guard let directory = try? Self.destinationDirectory() else { return }
        NSWorkspace.shared.open(directory)
    }

    private func enqueue(
        _ candidate: IndexedMailAttachmentCandidate,
        needsThumbnail: Bool,
        needsExport: Bool,
        priority: Bool,
        allowsMailDownload: Bool,
        visibleInDownloads: Bool,
        exportDirectoryURL: URL?,
        openWhenReady: Bool = false
    ) {
        let key = candidate.stableKey
        finishedRowTasks.removeValue(forKey: key)?.cancel()
        var record = records[key] ?? AttachmentTransferRecord(
            candidate: candidate,
            state: .queued,
            thumbnailURL: PersistentThumbnailStore.existingThumbnailURL(for: candidate),
            exportedURL: nil,
            exportDirectoryURL: nil,
            needsThumbnail: false,
            needsExport: false
        )
        record.candidate = candidate
        record.needsThumbnail = record.needsThumbnail || (needsThumbnail && record.thumbnailURL == nil)
        record.needsExport = record.needsExport || needsExport
        if let exportDirectoryURL { record.exportDirectoryURL = exportDirectoryURL }
        record.allowsMailDownload = record.allowsMailDownload || allowsMailDownload
        record.shouldCacheOriginal = true
        record.isVisibleInDownloads = record.isVisibleInDownloads || visibleInDownloads
        record.openWhenReady = record.openWhenReady || openWhenReady
        record.errorMessage = nil

        let hasWork = record.needsThumbnail || record.needsExport || record.openWhenReady
        if hasWork && !activeKeys.contains(key) {
            record.state = .queued
            queue.removeAll { $0 == key }
            if priority {
                highPriorityKeys.insert(key)
                queue.insert(key, at: 0)
            } else {
                queue.append(key)
            }
        } else if !hasWork {
            record.state = .ready
        }
        records[key] = record
        if !orderedKeys.contains(key) { orderedKeys.append(key) }
    }

    private func pumpQueue() {
        guard startsTransfersAutomatically else { return }
        while activeKeys.count < maximumConcurrentTransfers, !queue.isEmpty {
            let eligibleIndices = queue.indices.filter { index in
                guard let record = records[queue[index]] else { return false }
                return !record.allowsMailDownload ||
                    (activeMailKeys.isEmpty && !mailCooldown)
            }
            guard !eligibleIndices.isEmpty else { return }
            let selectedIndex = eligibleIndices.first { highPriorityKeys.contains(queue[$0]) }
                ?? eligibleIndices.max { left, right in
                    let leftDate = records[queue[left]]?.candidate.receivedAt ?? .distantPast
                    let rightDate = records[queue[right]]?.candidate.receivedAt ?? .distantPast
                    return leftDate < rightDate
                }
                ?? eligibleIndices[0]
            let key = queue.remove(at: selectedIndex)
            highPriorityKeys.remove(key)
            guard var record = records[key], !activeKeys.contains(key) else { continue }
            record.state = .downloading
            records[key] = record
            activeKeys.insert(key)
            if record.allowsMailDownload { activeMailKeys.insert(key) }
            let candidate = record.candidate
            let attemptAllowsMailDownload = record.allowsMailDownload

            Task { [weak self] in
                do {
                    let existingOriginal = PersistentAttachmentStore.existingOriginalURL(
                        for: candidate
                    )
                    let temporaryURL = existingOriginal == nil
                        ? try AttachmentMaterializer.temporaryDestination(for: candidate)
                        : nil
                    defer {
                        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
                    }
                    let materializedURL: URL
                    if let existingOriginal {
                        materializedURL = existingOriginal
                    } else if let temporaryURL {
                        try await AttachmentMaterializer.materialize(
                            candidate,
                            to: temporaryURL,
                            allowMailDownload: attemptAllowsMailDownload
                        )
                        materializedURL = temporaryURL
                    } else {
                        throw AttachmentMaterializerError.unavailable
                    }
                    await self?.finishSuccessfulTransfer(
                        key: key,
                        candidate: candidate,
                        materializedURL: materializedURL
                    )
                } catch {
                    self?.finishFailedTransfer(
                        key: key,
                        error: error,
                        attemptAllowedMailDownload: attemptAllowsMailDownload
                    )
                }
            }
        }
    }

    private func finishSuccessfulTransfer(
        key: String,
        candidate: IndexedMailAttachmentCandidate,
        materializedURL: URL
    ) async {
        guard var record = records[key] else {
            releaseActiveTransfer(key)
            pumpQueue()
            return
        }

        var durableURL = materializedURL
        if record.shouldCacheOriginal || record.allowsMailDownload || record.isVisibleInDownloads {
            do {
                durableURL = try await Task.detached(priority: .utility) {
                    try PersistentAttachmentStore.store(
                        materializedURL,
                        candidate: candidate
                    )
                }.value
            } catch {
                finishFailedTransfer(
                    key: key,
                    error: error,
                    attemptAllowedMailDownload: true
                )
                return
            }
        }

        if record.needsThumbnail {
            record.thumbnailURL = await PersistentThumbnailStore.createThumbnail(
                from: durableURL,
                candidate: candidate
            )
            if candidate.kind == .image, record.thumbnailURL == nil {
                finishFailedTransfer(
                    key: key,
                    error: AttachmentMaterializerError.incomplete,
                    attemptAllowedMailDownload: record.allowsMailDownload
                )
                return
            }
            record.needsThumbnail = false
        }

        if record.needsExport {
            do {
                let destination = try record.exportDirectoryURL ?? Self.destinationDirectory()
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                let exportedURL = try AttachmentExportSaver.save(
                    candidate,
                    materializedURL: durableURL,
                    to: destination
                )
                record.exportedURL = exportedURL
                record.needsExport = false
            } catch {
                finishFailedTransfer(
                    key: key,
                    error: error,
                    attemptAllowedMailDownload: record.allowsMailDownload
                )
                return
            }
        }
        if record.openWhenReady {
            NSWorkspace.shared.open(durableURL)
            record.openWhenReady = false
        }

        record.state = .ready
        record.errorMessage = nil
        records[key] = record
        releaseActiveTransfer(key)
        scheduleFinishedRowHiding(key)
        pumpQueue()
    }

    private func finishFailedTransfer(
        key: String,
        error: Error,
        attemptAllowedMailDownload: Bool
    ) {
        guard var record = records[key] else { return }
        finishedRowTasks.removeValue(forKey: key)?.cancel()
        releaseActiveTransfer(key)
        if !attemptAllowedMailDownload,
           (record.allowsMailDownload || record.automaticallyDownloadIfNeeded) {
            record.state = .queued
            record.allowsMailDownload = true
            record.isVisibleInDownloads = true
            records[key] = record
            queue.removeAll { $0 == key }
            highPriorityKeys.insert(key)
            queue.insert(key, at: 0)
            presentAutomaticDownloadsIfNeeded()
            pumpQueue()
            return
        }
        if !attemptAllowedMailDownload,
           error is AttachmentMaterializerError {
            record.state = .available
            record.errorMessage = nil
            records[key] = record
            pumpQueue()
            return
        }
        record.state = .failed
        record.errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "The attachment could not be downloaded."
        records[key] = record
        pumpQueue()
    }

    private func releaseActiveTransfer(_ key: String) {
        activeKeys.remove(key)
        let releasedMailTransfer = activeMailKeys.remove(key) != nil
        guard releasedMailTransfer else { return }
        mailCooldown = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard let self else { return }
            self.mailCooldown = false
            self.pumpQueue()
        }
    }

    private func presentAutomaticDownloadsIfNeeded() {
        guard !presentedAutomaticDownloads else { return }
        presentedAutomaticDownloads = true
        onPresentDownloads?()
    }

    private func scheduleFinishedRowHiding(_ key: String) {
        finishedRowTasks.removeValue(forKey: key)?.cancel()
        finishedRowTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self, var record = self.records[key],
                  record.state == .ready else { return }
            record.isVisibleInDownloads = false
            self.records[key] = record
            self.finishedRowTasks[key] = nil
        }
    }

    private static func destinationDirectory() throws -> URL {
        guard let desktop = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else { throw AttachmentMaterializerError.unavailable }
        let directory = desktop.appendingPathComponent("Files from Mails", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}

enum AttachmentExportSaver {
    static func save(
        _ candidate: IndexedMailAttachmentCandidate,
        materializedURL: URL,
        to directory: URL
    ) throws -> URL {
        guard AttachmentMaterializer.isCompleteFile(
            at: materializedURL,
            candidate: candidate
        ) else { throw AttachmentMaterializerError.incomplete }

        let manager = FileManager.default
        let fileName = safeFileName(candidate.attachmentName)
        let proposedURL = directory.appendingPathComponent(fileName)
        let sourceValues = try materializedURL.resourceValues(forKeys: [.fileSizeKey])
        let sourceSize = Int64(sourceValues.fileSize ?? 0)
        let referenceDate = candidate.receivedAt
        if FileManager.default.fileExists(atPath: proposedURL.path),
           let existingSize = try? proposedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existingSize == 0 {
            try FileManager.default.removeItem(at: proposedURL)
        }
        if DesktopFileSaver.isDuplicate(
            at: proposedURL,
            expectedSize: sourceSize,
            expectedDate: referenceDate
        ) {
            return proposedURL
        }

        let destination = availableURL(for: proposedURL)
        try manager.copyItem(at: materializedURL, to: destination)
        if let referenceDate {
            try manager.setAttributes(
                [.modificationDate: referenceDate],
                ofItemAtPath: destination.path
            )
        }
        guard AttachmentMaterializer.isCompleteFile(at: destination, candidate: candidate) else {
            try? manager.removeItem(at: destination)
            throw AttachmentMaterializerError.incomplete
        }
        return destination
    }

    private static func safeFileName(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
        let cleaned = lastComponent
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "Untitled file" : String(cleaned.prefix(180))
    }

    private static func availableURL(for proposedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else { return proposedURL }
        let extensionName = proposedURL.pathExtension
        let stem = proposedURL.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let name = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            let candidate = proposedURL.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}
