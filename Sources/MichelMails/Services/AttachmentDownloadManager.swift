import AppKit
import Foundation

@MainActor
final class AttachmentDownloadManager: ObservableObject {
    @Published private(set) var records: [String: AttachmentTransferRecord] = [:]
    @Published private(set) var orderedKeys: [String] = []
    @Published private(set) var cacheResetGeneration = 0
    @Published private(set) var isResettingCaches = false
    @Published private(set) var isPaused = false
    @Published private(set) var boostDownloadsEnabled = false
    @Published private(set) var completedCount = 0

    var onPresentDownloads: (() -> Void)?

    private let maximumConcurrentTransfers = 5
    private let maximumAutomaticMailAttempts = 2
    private let startsTransfersAutomatically: Bool
    private var queue: [String] = []
    private var activeKeys: Set<String> = []
    private var activeMailKeys: Set<String> = []
    private var highPriorityKeys: Set<String> = []
    private var downloadNowKeys: Set<String> = []
    private var deferredRetryKeys: Set<String> = []
    private var mailCooldown = false
    private var presentedAutomaticDownloads = false
    private var finishedRowTasks: [String: Task<Void, Never>] = [:]
    private var transferTasks: [String: Task<Void, Never>] = [:]
    private var deferredRetryTasks: [String: Task<Void, Never>] = [:]
    private var mailAttemptCounts: [String: Int] = [:]
    private var transferGeneration = 0
    private var lastPreparedCandidates: [IndexedMailAttachmentCandidate] = []
    private let memoryThumbnailCache = NSCache<NSString, NSImage>()

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
                let leftPriority = Self.displayPriority(for: $0.state)
                let rightPriority = Self.displayPriority(for: $1.state)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                let leftIsDownloadNow = downloadNowKeys.contains($0.id)
                let rightIsDownloadNow = downloadNowKeys.contains($1.id)
                if leftIsDownloadNow != rightIsDownloadNow {
                    return leftIsDownloadNow
                }
                let leftWasRequestedNow = highPriorityKeys.contains($0.id)
                let rightWasRequestedNow = highPriorityKeys.contains($1.id)
                if leftWasRequestedNow != rightWasRequestedNow {
                    return leftWasRequestedNow
                }
                return ($0.candidate.receivedAt ?? .distantPast) >
                    ($1.candidate.receivedAt ?? .distantPast)
            }
    }

    var activeCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .downloading }.count
    }

    var queuedCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .queued }.count
    }

    var deferredCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .deferred }.count
    }

    var failedCount: Int {
        records.values.filter { $0.isVisibleInDownloads && $0.state == .failed }.count
    }

    var hasPendingTransfers: Bool {
        activeCount > 0 || queuedCount > 0 || deferredCount > 0
    }

    var simultaneousMailDownloadLimit: Int {
        boostDownloadsEnabled ? 5 : 1
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

    func cachedImage(at URL: URL) -> NSImage? {
        let key = URL.path as NSString
        if let image = memoryThumbnailCache.object(forKey: key) { return image }
        guard FileManager.default.fileExists(atPath: URL.path),
              let image = NSImage(contentsOf: URL) else { return nil }
        memoryThumbnailCache.setObject(image, forKey: key)
        return image
    }

    func rememberImage(_ image: NSImage, at URL: URL) {
        memoryThumbnailCache.setObject(image, forKey: URL.path as NSString)
    }

    func prepareThumbnails(_ candidates: [IndexedMailAttachmentCandidate]) {
        lastPreparedCandidates = candidates
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
            ) != nil || AttachmentMaterializer.hasLocallyAvailableSource(for: candidate)
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
            } else if !record.needsThumbnail && !record.needsExport && !record.needsOriginal {
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

    func downloadNow(_ candidates: [IndexedMailAttachmentCandidate]) {
        let orderedCandidates = candidates.sorted {
            ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast)
        }
        guard !orderedCandidates.isEmpty else { return }
        onPresentDownloads?()
        preemptActiveTransfers()
        isPaused = false

        for candidate in orderedCandidates {
            let key = candidate.stableKey
            guard !activeKeys.contains(key) else { continue }
            finishedRowTasks.removeValue(forKey: key)?.cancel()
            deferredRetryTasks.removeValue(forKey: key)?.cancel()
            deferredRetryKeys.remove(key)
            mailAttemptCounts[key] = 0

            if var record = records[key] {
                record.candidate = candidate
                record.state = .queued
                record.errorMessage = nil
                record.activeRoute = nil
                record.failedRoute = nil
                record.allowsMailDownload = true
                record.isVisibleInDownloads = true
                if record.thumbnailURL == nil {
                    record.needsThumbnail = candidate.kind == .image
                }
                if originalURL(for: candidate) == nil {
                    record.needsOriginal = true
                }
                records[key] = record
                queue.removeAll { $0 == key }
                queue.append(key)
                highPriorityKeys.remove(key)
                downloadNowKeys.insert(key)
            } else {
                enqueue(
                    candidate,
                    needsThumbnail: candidate.kind == .image,
                    needsExport: false,
                    needsOriginal: true,
                    priority: true,
                    allowsMailDownload: true,
                    visibleInDownloads: true,
                    exportDirectoryURL: nil
                )
                highPriorityKeys.remove(key)
                downloadNowKeys.insert(key)
            }
        }
        pumpQueue()
    }

    func isWaitingForDownload(_ candidate: IndexedMailAttachmentCandidate) -> Bool {
        guard let state = records[candidate.stableKey]?.state else {
            return originalURL(for: candidate) == nil
        }
        switch state {
        case .available, .queued, .deferred, .failed:
            return true
        case .downloading, .ready:
            return false
        }
    }

    func prepareOriginalsForDragging(_ candidates: [IndexedMailAttachmentCandidate]) {
        guard !candidates.isEmpty else { return }
        onPresentDownloads?()
        for candidate in candidates.reversed() {
            enqueue(
                candidate,
                needsThumbnail: false,
                needsExport: false,
                needsOriginal: true,
                priority: true,
                allowsMailDownload: true,
                visibleInDownloads: true,
                exportDirectoryURL: nil
            )
        }
        pumpQueue()
    }

    func retry(_ candidate: IndexedMailAttachmentCandidate) {
        guard var record = records[candidate.stableKey], !activeKeys.contains(candidate.stableKey) else {
            return
        }
        finishedRowTasks.removeValue(forKey: candidate.stableKey)?.cancel()
        deferredRetryTasks.removeValue(forKey: candidate.stableKey)?.cancel()
        deferredRetryKeys.remove(candidate.stableKey)
        mailAttemptCounts[candidate.stableKey] = 0
        record.state = .queued
        record.errorMessage = nil
        record.allowsMailDownload = true
        record.activeRoute = nil
        record.failedRoute = nil
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

    func setBoostDownloadsEnabled(_ enabled: Bool) {
        guard boostDownloadsEnabled != enabled else { return }
        boostDownloadsEnabled = enabled
        pumpQueue()
    }

    func stopAll() {
        guard !isPaused else { return }
        isPaused = true
        transferGeneration &+= 1

        let interruptedKeys = activeKeys
        transferTasks.values.forEach { $0.cancel() }
        transferTasks.removeAll()
        deferredRetryTasks.values.forEach { $0.cancel() }
        deferredRetryTasks.removeAll()
        deferredRetryKeys.removeAll()
        activeKeys.removeAll()
        activeMailKeys.removeAll()
        mailCooldown = false

        var pendingKeys = Set(queue)
        for key in orderedKeys {
            guard var record = records[key] else { continue }
            if record.state == .downloading || record.state == .deferred {
                record.state = .queued
                record.errorMessage = nil
                record.activeRoute = nil
                records[key] = record
                if pendingKeys.insert(key).inserted { queue.append(key) }
            }
        }
        for key in interruptedKeys { mailAttemptCounts.removeValue(forKey: key) }
    }

    func resumeAll() {
        guard isPaused else { return }
        isPaused = false
        pumpQueue()
    }

    func retryAllFailed() {
        let failedKeys = orderedKeys.filter { records[$0]?.state == .failed }
        guard !failedKeys.isEmpty else { return }
        var queuedKeys = Set(queue)
        for key in failedKeys {
            guard var record = records[key] else { continue }
            finishedRowTasks.removeValue(forKey: key)?.cancel()
            deferredRetryTasks.removeValue(forKey: key)?.cancel()
            deferredRetryKeys.remove(key)
            mailAttemptCounts[key] = 0
            record.state = .queued
            record.errorMessage = nil
            record.allowsMailDownload = true
            record.isVisibleInDownloads = true
            record.activeRoute = nil
            record.failedRoute = nil
            records[key] = record
            highPriorityKeys.insert(key)
            if queuedKeys.insert(key).inserted { queue.insert(key, at: 0) }
        }
        isPaused = false
        onPresentDownloads?()
        pumpQueue()
    }

    func hideFailed() {
        for key in orderedKeys {
            guard var record = records[key], record.state == .failed else { continue }
            record.isVisibleInDownloads = false
            records[key] = record
        }
    }

    func clearFinished() {
        completedCount = 0
        let removable = Set(records.values.filter {
            $0.isVisibleInDownloads && $0.state == .ready && !activeKeys.contains($0.id)
        }.map(\.id))
        for key in removable { records.removeValue(forKey: key) }
        for key in removable { finishedRowTasks.removeValue(forKey: key)?.cancel() }
        for key in removable { deferredRetryTasks.removeValue(forKey: key)?.cancel() }
        deferredRetryKeys.subtract(removable)
        for key in removable { mailAttemptCounts.removeValue(forKey: key) }
        orderedKeys.removeAll { removable.contains($0) }
        queue.removeAll { removable.contains($0) }
        highPriorityKeys.subtract(removable)
        downloadNowKeys.subtract(removable)
    }

    func resetPreviewCaches() {
        guard !isResettingCaches else { return }
        isResettingCaches = true
        transferGeneration &+= 1
        let interruptedTasks = Array(transferTasks.values)
        interruptedTasks.forEach { $0.cancel() }
        transferTasks.removeAll()
        finishedRowTasks.values.forEach { $0.cancel() }
        finishedRowTasks.removeAll()
        deferredRetryTasks.values.forEach { $0.cancel() }
        deferredRetryTasks.removeAll()
        deferredRetryKeys.removeAll()
        mailAttemptCounts.removeAll()
        completedCount = 0
        isPaused = false
        queue.removeAll()
        activeKeys.removeAll()
        activeMailKeys.removeAll()
        highPriorityKeys.removeAll()
        downloadNowKeys.removeAll()
        mailCooldown = false
        records.removeAll()
        orderedKeys.removeAll()
        memoryThumbnailCache.removeAllObjects()
        cacheResetGeneration &+= 1
        let candidates = lastPreparedCandidates

        Task { [weak self] in
            for task in interruptedTasks { await task.value }
            await Task.detached(priority: .utility) {
                try? PersistentThumbnailStore.clearAll()
                try? PersistentAttachmentStore.clearAll()
                try? AttachmentMaterializer.clearTemporaryFiles()
            }.value
            guard let self else { return }
            self.cacheResetGeneration &+= 1
            self.isResettingCaches = false
            self.prepareThumbnails(candidates)
        }
    }

    func showDestinationFolder() {
        guard let directory = try? Self.destinationDirectory() else { return }
        NSWorkspace.shared.open(directory)
    }

    private func enqueue(
        _ candidate: IndexedMailAttachmentCandidate,
        needsThumbnail: Bool,
        needsExport: Bool,
        needsOriginal: Bool = false,
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
        record.needsOriginal = record.needsOriginal || (
            needsOriginal && originalURL(for: candidate) == nil
        )
        if let exportDirectoryURL { record.exportDirectoryURL = exportDirectoryURL }
        record.allowsMailDownload = record.allowsMailDownload || allowsMailDownload
        record.shouldCacheOriginal = true
        record.isVisibleInDownloads = record.isVisibleInDownloads || visibleInDownloads
        record.openWhenReady = record.openWhenReady || openWhenReady
        record.errorMessage = nil

        let hasWork = record.needsThumbnail || record.needsExport || record.needsOriginal || record.openWhenReady
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

    private func preemptActiveTransfers() {
        guard !activeKeys.isEmpty else { return }
        transferGeneration &+= 1
        let interruptedKeys = activeKeys
        transferTasks.values.forEach { $0.cancel() }
        transferTasks.removeAll()
        activeKeys.removeAll()
        activeMailKeys.removeAll()
        mailCooldown = false

        var queuedKeys = Set(queue)
        for key in interruptedKeys {
            guard var record = records[key] else { continue }
            record.state = .queued
            record.activeRoute = nil
            record.errorMessage = nil
            records[key] = record
            mailAttemptCounts.removeValue(forKey: key)
            if queuedKeys.insert(key).inserted {
                queue.append(key)
            }
        }
    }

    private func pumpQueue() {
        guard startsTransfersAutomatically, !isPaused else { return }
        while activeKeys.count < maximumConcurrentTransfers, !queue.isEmpty {
            let eligibleIndices = queue.indices.filter { index in
                guard let record = records[queue[index]] else { return false }
                return !record.allowsMailDownload ||
                    (activeMailKeys.count < simultaneousMailDownloadLimit && !mailCooldown)
            }
            guard !eligibleIndices.isEmpty else { return }
            let regularIndices = eligibleIndices.filter {
                !deferredRetryKeys.contains(queue[$0]) || downloadNowKeys.contains(queue[$0])
            }
            let normalPool = regularIndices.isEmpty ? eligibleIndices : regularIndices
            let downloadNowPool = normalPool.filter {
                downloadNowKeys.contains(queue[$0])
            }
            let priorityPool = normalPool.filter {
                highPriorityKeys.contains(queue[$0])
            }
            let selectionPool = !downloadNowPool.isEmpty
                ? downloadNowPool
                : (priorityPool.isEmpty ? normalPool : priorityPool)
            let selectedIndex = selectionPool.max { left, right in
                    let leftDate = records[queue[left]]?.candidate.receivedAt ?? .distantPast
                    let rightDate = records[queue[right]]?.candidate.receivedAt ?? .distantPast
                    return leftDate < rightDate
                }
                ?? eligibleIndices[0]
            let key = queue.remove(at: selectedIndex)
            highPriorityKeys.remove(key)
            deferredRetryKeys.remove(key)
            guard var record = records[key], !activeKeys.contains(key) else { continue }
            let attemptUsesAppleMail = record.allowsMailDownload
            record.state = .downloading
            record.activeRoute = attemptUsesAppleMail ? .appleMail : .local
            records[key] = record
            activeKeys.insert(key)
            if attemptUsesAppleMail { activeMailKeys.insert(key) }
            let candidate = record.candidate
            let mailAttempt: Int
            if attemptUsesAppleMail {
                mailAttempt = (mailAttemptCounts[key] ?? 0) + 1
                mailAttemptCounts[key] = mailAttempt
            } else {
                mailAttempt = 0
            }
            let mailDownloadTimeout: TimeInterval = mailAttempt <= 1 ? 8 : 20
            let generation = transferGeneration

            let task = Task { [weak self] in
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
                            allowMailDownload: attemptUsesAppleMail,
                            mailDownloadTimeout: mailDownloadTimeout
                        )
                        materializedURL = temporaryURL
                    } else {
                        throw AttachmentMaterializerError.unavailable
                    }
                    await self?.finishSuccessfulTransfer(
                        key: key,
                        candidate: candidate,
                        materializedURL: materializedURL,
                        generation: generation
                    )
                } catch {
                    self?.finishFailedTransfer(
                        key: key,
                        error: error,
                        attemptUsedAppleMail: attemptUsesAppleMail,
                        generation: generation
                    )
                }
            }
            transferTasks[key] = task
        }
    }

    private func finishSuccessfulTransfer(
        key: String,
        candidate: IndexedMailAttachmentCandidate,
        materializedURL: URL,
        generation: Int
    ) async {
        guard generation == transferGeneration else { return }
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
                    attemptUsedAppleMail: record.activeRoute == .appleMail,
                    generation: generation
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
                    attemptUsedAppleMail: record.activeRoute == .appleMail,
                    generation: generation
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
                    attemptUsedAppleMail: record.activeRoute == .appleMail,
                    generation: generation
                )
                return
            }
        }
        record.needsOriginal = false
        if record.openWhenReady {
            NSWorkspace.shared.open(durableURL)
            record.openWhenReady = false
        }

        record.state = .ready
        record.activeRoute = nil
        record.failedRoute = nil
        record.errorMessage = nil
        records[key] = record
        completedCount += 1
        downloadNowKeys.remove(key)
        mailAttemptCounts.removeValue(forKey: key)
        deferredRetryTasks.removeValue(forKey: key)?.cancel()
        deferredRetryKeys.remove(key)
        releaseActiveTransfer(key)
        scheduleFinishedRowHiding(key)
        pumpQueue()
    }

    private func finishFailedTransfer(
        key: String,
        error: Error,
        attemptUsedAppleMail: Bool,
        generation: Int
    ) {
        guard generation == transferGeneration else { return }
        guard var record = records[key] else { return }
        finishedRowTasks.removeValue(forKey: key)?.cancel()
        releaseActiveTransfer(key)

        if !attemptUsedAppleMail,
           (record.allowsMailDownload || record.automaticallyDownloadIfNeeded) {
            record.state = .queued
            record.activeRoute = nil
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
        if !attemptUsedAppleMail,
           error is AttachmentMaterializerError {
            record.state = .available
            record.activeRoute = nil
            record.errorMessage = nil
            records[key] = record
            pumpQueue()
            return
        }
        if attemptUsedAppleMail,
           shouldRetryAutomatically(error),
           (mailAttemptCounts[key] ?? 0) < maximumAutomaticMailAttempts {
            record.state = .deferred
            record.activeRoute = nil
            record.errorMessage = "Retrying automatically after the queue advances"
            records[key] = record
            scheduleDeferredRetry(key, attempt: mailAttemptCounts[key] ?? 1)
            pumpQueue()
            return
        }
        record.state = .failed
        record.activeRoute = nil
        record.failedRoute = attemptUsedAppleMail ? .appleMail : .local
        deferredRetryKeys.remove(key)
        downloadNowKeys.remove(key)
        mailAttemptCounts.removeValue(forKey: key)
        record.errorMessage = (error as? LocalizedError)?.errorDescription
            ?? "The attachment could not be downloaded."
        records[key] = record
        pumpQueue()
    }

    private func scheduleDeferredRetry(_ key: String, attempt: Int) {
        deferredRetryTasks.removeValue(forKey: key)?.cancel()
        let delay = min(12.0, 2.0 * pow(2.0, Double(max(0, attempt - 1))))
        deferredRetryTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  var record = self.records[key],
                  record.state == .deferred else { return }
            record.state = .queued
            record.errorMessage = nil
            self.records[key] = record
            self.queue.removeAll { $0 == key }
            self.queue.append(key)
            self.deferredRetryKeys.insert(key)
            self.deferredRetryTasks[key] = nil
            self.pumpQueue()
        }
    }

    private func shouldRetryAutomatically(_ error: Error) -> Bool {
        guard let error = error as? AttachmentMaterializerError else { return false }
        switch error {
        case .mailDidNotRespond, .mailDownloadFailed, .incomplete:
            return true
        case .unavailable:
            return false
        }
    }

    private func releaseActiveTransfer(_ key: String) {
        transferTasks.removeValue(forKey: key)
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

    private static func displayPriority(for state: AttachmentTransferState) -> Int {
        switch state {
        case .downloading: return 0
        case .queued: return 1
        case .deferred: return 2
        case .failed: return 3
        case .available: return 4
        case .ready: return 5
        }
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
            try FinderTagger.addFromEmailTag(to: proposedURL)
            try EmailDownloadMetadata.markDownloaded(
                proposedURL,
                emailReceivedAt: referenceDate
            )
            return proposedURL
        }

        let destination = availableURL(for: proposedURL)
        try manager.copyItem(at: materializedURL, to: destination)
        guard AttachmentMaterializer.isCompleteFile(at: destination, candidate: candidate) else {
            try? manager.removeItem(at: destination)
            throw AttachmentMaterializerError.incomplete
        }
        try FinderTagger.addFromEmailTag(to: destination)
        try EmailDownloadMetadata.markDownloaded(
            destination,
            emailReceivedAt: referenceDate
        )
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
