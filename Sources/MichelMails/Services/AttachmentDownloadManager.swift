import AppKit
import Foundation

@MainActor
final class AttachmentDownloadManager: ObservableObject {
    @Published private(set) var records: [String: AttachmentTransferRecord] = [:]
    @Published private(set) var orderedKeys: [String] = []

    private let maximumConcurrentDownloads = 4
    private var queue: [String] = []
    private var activeKeys: Set<String> = []
    private var highPriorityKeys: Set<String> = []

    var items: [AttachmentTransferRecord] {
        orderedKeys.compactMap { records[$0] }
    }

    var activeCount: Int {
        records.values.filter { $0.state == .downloading }.count
    }

    var queuedCount: Int {
        records.values.filter { $0.state == .queued }.count
    }

    func record(for candidate: IndexedMailAttachmentCandidate) -> AttachmentTransferRecord? {
        records[candidate.stableKey]
    }

    func thumbnailURL(for candidate: IndexedMailAttachmentCandidate) -> URL? {
        records[candidate.stableKey]?.thumbnailURL
            ?? PersistentThumbnailStore.existingThumbnailURL(for: candidate)
    }

    func prepareThumbnails(_ candidates: [IndexedMailAttachmentCandidate]) {
        let orderedCandidates = candidates.sorted {
            ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast)
        }
        var updatedRecords = records
        var updatedKeys = orderedKeys
        var knownKeys = Set(updatedKeys)
        var queuedKeys = Set(queue)
        for candidate in orderedCandidates {
            let key = candidate.stableKey
            var record = updatedRecords[key] ?? AttachmentTransferRecord(
                candidate: candidate,
                state: .queued,
                thumbnailURL: PersistentThumbnailStore.existingThumbnailURL(for: candidate),
                exportedURL: nil,
                needsThumbnail: false,
                needsExport: false
            )
            record.candidate = candidate
            record.needsThumbnail = record.thumbnailURL == nil
            if record.needsThumbnail && !activeKeys.contains(key) {
                record.state = .queued
                if queuedKeys.insert(key).inserted { queue.append(key) }
            } else if !record.needsThumbnail && !record.needsExport {
                record.state = .ready
            }
            updatedRecords[key] = record
            if knownKeys.insert(key).inserted { updatedKeys.append(key) }
        }
        records = updatedRecords
        orderedKeys = updatedKeys
        pumpQueue()
    }

    func downloadAttachmentsToDesktop(_ candidates: [IndexedMailAttachmentCandidate]) {
        for candidate in candidates.reversed() {
            enqueue(
                candidate,
                needsThumbnail: candidate.kind == .image,
                needsExport: true,
                priority: true
            )
        }
        pumpQueue()
    }

    func openAttachment(_ candidate: IndexedMailAttachmentCandidate) {
        enqueue(
            candidate,
            needsThumbnail: candidate.kind == .image,
            needsExport: true,
            priority: true,
            openWhenReady: true
        )
        pumpQueue()
    }

    func retry(_ candidate: IndexedMailAttachmentCandidate) {
        guard var record = records[candidate.stableKey], !activeKeys.contains(candidate.stableKey) else {
            return
        }
        record.state = .queued
        record.errorMessage = nil
        if !record.needsThumbnail && record.thumbnailURL == nil {
            record.needsThumbnail = candidate.kind == .image
        }
        records[candidate.stableKey] = record
        queue.removeAll { $0 == candidate.stableKey }
        highPriorityKeys.insert(candidate.stableKey)
        queue.insert(candidate.stableKey, at: 0)
        pumpQueue()
    }

    func clearFinished() {
        let removable = Set(records.values.filter {
            $0.state == .ready && !activeKeys.contains($0.id)
        }.map(\.id))
        for key in removable { records.removeValue(forKey: key) }
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
        openWhenReady: Bool = false
    ) {
        let key = candidate.stableKey
        var record = records[key] ?? AttachmentTransferRecord(
            candidate: candidate,
            state: .queued,
            thumbnailURL: PersistentThumbnailStore.existingThumbnailURL(for: candidate),
            exportedURL: nil,
            needsThumbnail: false,
            needsExport: false
        )
        record.candidate = candidate
        record.needsThumbnail = record.needsThumbnail || (needsThumbnail && record.thumbnailURL == nil)
        record.needsExport = record.needsExport || needsExport
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
        while activeKeys.count < maximumConcurrentDownloads, !queue.isEmpty {
            let selectedIndex = queue.firstIndex { highPriorityKeys.contains($0) }
                ?? queue.indices.max { left, right in
                    let leftDate = records[queue[left]]?.candidate.receivedAt ?? .distantPast
                    let rightDate = records[queue[right]]?.candidate.receivedAt ?? .distantPast
                    return leftDate < rightDate
                }
                ?? queue.startIndex
            let key = queue.remove(at: selectedIndex)
            highPriorityKeys.remove(key)
            guard var record = records[key], !activeKeys.contains(key) else { continue }
            record.state = .downloading
            records[key] = record
            activeKeys.insert(key)
            let candidate = record.candidate

            Task { [weak self] in
                do {
                    let temporaryURL = try AttachmentMaterializer.temporaryDestination(for: candidate)
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }
                    try await AttachmentMaterializer.materialize(
                        candidate,
                        to: temporaryURL,
                        allowMailDownload: true
                    )
                    await self?.finishSuccessfulTransfer(
                        key: key,
                        candidate: candidate,
                        materializedURL: temporaryURL
                    )
                } catch {
                    self?.finishFailedTransfer(key: key, error: error)
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
            activeKeys.remove(key)
            pumpQueue()
            return
        }

        if record.needsThumbnail {
            record.thumbnailURL = await PersistentThumbnailStore.createThumbnail(
                from: materializedURL,
                candidate: candidate
            )
            if candidate.kind == .image, record.thumbnailURL == nil {
                finishFailedTransfer(
                    key: key,
                    error: AttachmentMaterializerError.incomplete
                )
                return
            }
            record.needsThumbnail = false
        }

        if record.needsExport || record.openWhenReady {
            do {
                let destination = try Self.destinationDirectory()
                let exportedURL = try AttachmentExportSaver.save(
                    candidate,
                    materializedURL: materializedURL,
                    to: destination
                )
                record.exportedURL = exportedURL
                record.needsExport = false
                if record.openWhenReady {
                    NSWorkspace.shared.open(exportedURL)
                    record.openWhenReady = false
                }
            } catch {
                finishFailedTransfer(key: key, error: error)
                return
            }
        }

        record.state = .ready
        record.errorMessage = nil
        records[key] = record
        activeKeys.remove(key)
        pumpQueue()
    }

    private func finishFailedTransfer(key: String, error: Error) {
        guard var record = records[key] else { return }
        record.state = .failed
        record.errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "The attachment could not be downloaded."
        records[key] = record
        activeKeys.remove(key)
        pumpQueue()
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
