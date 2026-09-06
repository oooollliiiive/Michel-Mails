import AppKit
import Testing
@testable import MichelMails

@Test("The gallery renders PNG files and the first page of PDFs")
@MainActor
func galleryNativeThumbnails() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let PNGURL = directory.appendingPathComponent("preview.png")
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    if let pixels = bitmap.bitmapData {
        for y in 0..<8 {
            for x in 0..<8 {
                let offset = (y * bitmap.bytesPerRow) + (x * 4)
                pixels[offset] = 120
                pixels[offset + 1] = 60
                pixels[offset + 2] = 220
                pixels[offset + 3] = 255
            }
        }
    }
    let PNGData = try #require(bitmap.representation(using: .png, properties: [:]))
    try PNGData.write(to: PNGURL)

    let PDFURL = directory.appendingPathComponent("preview.pdf")
    var pageBounds = CGRect(x: 0, y: 0, width: 320, height: 180)
    let consumer = try #require(CGDataConsumer(url: PDFURL as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &pageBounds, nil))
    context.beginPDFPage(nil)
    context.setFillColor(red: 1, green: 0.45, blue: 0, alpha: 1)
    context.fill(pageBounds)
    context.endPDFPage()
    context.closePDF()

    let PNGThumbnail = await GalleryThumbnailService.thumbnail(at: PNGURL, kind: .image)
    let PDFThumbnail = await GalleryThumbnailService.thumbnail(at: PDFURL, kind: .pdf)

    #expect(PNGThumbnail.isFallback == false)
    #expect(PNGThumbnail.image.size.width > 0)
    #expect(PDFThumbnail.isFallback == false)
    #expect(PDFThumbnail.image.size.width > 0)
}

@Test("Image and video formats are classified for the universal grid")
func universalGalleryFileClassification() {
    #expect(MailAttachmentKind.classify(name: "scan.PNG", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "camera.CR3", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "drawing.svg", MIMEType: "") == .image)
    #expect(MailAttachmentKind.classify(name: "clip.MOV", MIMEType: "") == .video)
    #expect(MailAttachmentKind.classify(name: "film.mkv", MIMEType: "") == .video)
    #expect(MailAttachmentKind.classify(name: "report.pdf", MIMEType: "") == .pdf)
}

@Test("Desktop saving skips a file with the same name, email date, and size")
func desktopDuplicateDetection() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
    let desktopDirectory = root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: desktopDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = sourceDirectory.appendingPathComponent("photo.jpg")
    try Data([1, 2, 3, 4, 5]).write(to: sourceURL)
    let receivedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let message = MailMessageItem(
        reference: MailMessageReference(messageIdentifier: "desktop-test", localIdentifier: "1"),
        sender: "Raffi",
        subject: "Photo",
        preview: "",
        receivedAt: receivedAt
    )
    let item = MailImageItem(
        cachedURL: sourceURL,
        displayName: "photo.jpg",
        MIMEType: "image/jpeg",
        kind: .image,
        message: message
    )

    let firstSave = try DesktopFileSaver.save([item], to: desktopDirectory)
    #expect(firstSave.savedURLs.count == 1)
    #expect(firstSave.duplicateCount == 0)
    let savedTags = try firstSave.savedURLs[0]
        .resourceValues(forKeys: [.tagNamesKey])
        .tagNames ?? []
    #expect(savedTags.contains("From Email"))
    #expect(abs(
        try #require(EmailDownloadMetadata.emailReceivedAt(for: firstSave.savedURLs[0]))
            .timeIntervalSince(receivedAt)
    ) < 0.01)

    let oldDownloadDate = Date(timeIntervalSince1970: 1_600_000_000)
    try EmailDownloadMetadata.markDownloaded(
        firstSave.savedURLs[0],
        emailReceivedAt: receivedAt,
        downloadedAt: oldDownloadDate
    )

    let secondSave = try DesktopFileSaver.save([item], to: desktopDirectory)
    #expect(secondSave.savedURLs.isEmpty)
    #expect(secondSave.duplicateCount == 1)
    #expect(
        DesktopFileSaver.isDuplicate(
            at: desktopDirectory.appendingPathComponent("photo.jpg"),
            expectedSize: 5,
            expectedDate: receivedAt
        )
    )
    let refreshedDownloadDate = try #require(
        EmailDownloadMetadata.downloadedAt(for: firstSave.savedURLs[0])
    )
    #expect(refreshedDownloadDate > oldDownloadDate)
    let refreshedModificationDate = try #require(
        firstSave.savedURLs[0]
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    )
    #expect(abs(refreshedModificationDate.timeIntervalSince(refreshedDownloadDate)) < 1.1)
}

@Test("Long email ages use years plus remaining days")
func longEmailAgeUsesYearsAndDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(calendar.date(from: DateComponents(
        year: 2026,
        month: 9,
        day: 6,
        hour: 12
    )))
    let received = try #require(calendar.date(from: DateComponents(
        year: 2025,
        month: 1,
        day: 29,
        hour: 12
    )))

    #expect(EmailRelativeDateFormatter.string(
        for: received,
        relativeTo: now,
        calendar: calendar
    ) == "1 year 220 days ago")
}

@Test("Incomplete zero-byte attachments are never copied")
func incompleteAttachmentIsSkipped() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
    let destinationDirectory = root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = sourceDirectory.appendingPathComponent("empty.jpg")
    try Data().write(to: sourceURL)
    let item = MailImageItem(
        cachedURL: sourceURL,
        displayName: "empty.jpg",
        MIMEType: "image/jpeg",
        kind: .image,
        message: MailMessageItem(
            reference: MailMessageReference(messageIdentifier: "empty", localIdentifier: "1"),
            sender: "Michel",
            subject: "Empty attachment",
            preview: "",
            receivedAt: nil
        )
    )

    let result = try DesktopFileSaver.save([item], to: destinationDirectory)
    #expect(result.savedURLs.isEmpty)
    #expect(result.duplicateCount == 0)
    #expect(result.incompleteCount == 1)
    #expect(!FileManager.default.fileExists(
        atPath: destinationDirectory.appendingPathComponent("empty.jpg").path
    ))
}

@Test("Grid thumbnails persist independently from original attachments")
@MainActor
func persistentAttachmentThumbnail() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("source.png")
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 32,
        pixelsHigh: 24,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ))
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: sourceURL)

    let candidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "thumbnail-message",
        localIdentifier: "42",
        sender: "Raffi",
        subject: "Picture",
        preview: "",
        receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
        accountName: "Google",
        mailboxName: "Inbox",
        attachmentIdentifier: "image-1",
        attachmentName: "source.png",
        MIMEType: "image/png",
        sizeBytes: Int64(data.count),
        kind: .image,
        sourcePath: sourceURL.path
    )
    let thumbnailRoot = root.appendingPathComponent("Thumbnails", isDirectory: true)
    let thumbnailURL = await PersistentThumbnailStore.createThumbnail(
        from: sourceURL,
        candidate: candidate,
        rootDirectory: thumbnailRoot
    )

    #expect(thumbnailURL != nil)
    #expect(PersistentThumbnailStore.existingThumbnailURL(
        for: candidate,
        rootDirectory: thumbnailRoot
    ) == thumbnailURL)
    #expect(AttachmentMaterializer.isCompleteFile(at: sourceURL, candidate: candidate))

    let materializedURL = root.appendingPathComponent("materialized.png")
    try await AttachmentMaterializer.materialize(
        candidate,
        to: materializedURL,
        allowMailDownload: false
    )
    #expect(try Data(contentsOf: materializedURL) == data)
}

@Test("Missing previews are queued automatically for Mail")
@MainActor
func missingPreviewStartsRemoteDownload() {
    let candidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "remote-message",
        localIdentifier: "900",
        sender: "Michel",
        subject: "Remote picture",
        preview: "",
        receivedAt: Date(),
        accountName: "Google",
        mailboxName: "Inbox",
        attachmentIdentifier: "index-1",
        attachmentName: "remote.jpg",
        MIMEType: "image/jpeg",
        sizeBytes: 12_000,
        kind: .image,
        sourcePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-indexed-preview.jpg")
            .path
    )
    let manager = AttachmentDownloadManager(startsTransfersAutomatically: false)

    manager.prepareThumbnails([candidate])

    #expect(manager.record(for: candidate)?.state == .queued)
    #expect(manager.record(for: candidate)?.allowsMailDownload == true)
    #expect(manager.record(for: candidate)?.isVisibleInDownloads == true)
    #expect(manager.activeCount == 0)
    #expect(manager.queuedCount == 1)
    #expect(manager.items.count == 1)
}

@Test("Dragging queues a missing original without opening or exporting it")
@MainActor
func missingDragOriginalIsPrepared() {
    let uniqueID = UUID().uuidString
    let candidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "drag-\(uniqueID)",
        localIdentifier: uniqueID,
        sender: "Michel",
        subject: "Drag picture",
        preview: "",
        receivedAt: Date(),
        accountName: "Google",
        mailboxName: "Inbox",
        attachmentIdentifier: "image-1",
        attachmentName: "drag.jpg",
        MIMEType: "image/jpeg",
        sizeBytes: 12_000,
        kind: .image,
        sourcePath: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-drag-\(uniqueID).jpg")
            .path
    )
    let manager = AttachmentDownloadManager(startsTransfersAutomatically: false)

    manager.prepareOriginalsForDragging([candidate])

    let record = manager.record(for: candidate)
    #expect(record?.state == .queued)
    #expect(record?.needsOriginal == true)
    #expect(record?.needsExport == false)
    #expect(record?.openWhenReady == false)
    #expect(record?.allowsMailDownload == true)
    #expect(record?.isVisibleInDownloads == true)
}

@Test("Download boost is opt-in and allows five Mail transfers")
@MainActor
func downloadBoostIsOptIn() {
    let manager = AttachmentDownloadManager(startsTransfersAutomatically: false)

    #expect(manager.boostDownloadsEnabled == false)
    #expect(manager.simultaneousMailDownloadLimit == 1)

    manager.setBoostDownloadsEnabled(true)

    #expect(manager.boostDownloadsEnabled == true)
    #expect(manager.simultaneousMailDownloadLimit == 5)
}

@Test("Download Now keeps selected downloads newest first")
@MainActor
func selectedDownloadsArePrioritizedNewestFirst() {
    let uniqueID = UUID().uuidString
    let oldCandidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "old-\(uniqueID)",
        localIdentifier: "old-\(uniqueID)",
        sender: "Michel",
        subject: "Old",
        preview: "",
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
        accountName: "Mail",
        mailboxName: "Inbox",
        attachmentIdentifier: "old-image",
        attachmentName: "old.jpg",
        MIMEType: "image/jpeg",
        sizeBytes: 12_000,
        kind: .image,
        sourcePath: "/missing/old-\(uniqueID).jpg"
    )
    let newCandidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "new-\(uniqueID)",
        localIdentifier: "new-\(uniqueID)",
        sender: "Michel",
        subject: "New",
        preview: "",
        receivedAt: Date(timeIntervalSince1970: 1_800_000_000),
        accountName: "Mail",
        mailboxName: "Inbox",
        attachmentIdentifier: "new-image",
        attachmentName: "new.jpg",
        MIMEType: "image/jpeg",
        sizeBytes: 12_000,
        kind: .image,
        sourcePath: "/missing/new-\(uniqueID).jpg"
    )
    let manager = AttachmentDownloadManager(startsTransfersAutomatically: false)

    manager.prepareThumbnails([oldCandidate, newCandidate])
    manager.retry(oldCandidate)
    manager.stopAll()
    #expect(manager.isPaused)
    manager.downloadNow([newCandidate])

    #expect(!manager.isPaused)
    #expect(manager.items.map(\.candidate.attachmentName) == ["new.jpg", "old.jpg"])
    #expect(manager.items.allSatisfy { $0.state == .queued })
}

@Test("Original attachment cache expires files after seven days")
func temporaryOriginalRetention() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sourceURL = root.appendingPathComponent("source.pdf")
    let sourceData = Data(repeating: 7, count: 512)
    try sourceData.write(to: sourceURL)
    let cacheRoot = root.appendingPathComponent("Originals", isDirectory: true)
    let candidate = IndexedMailAttachmentCandidate(
        messageIdentifier: "cached-message",
        localIdentifier: "901",
        sender: "Raffi",
        subject: "Document",
        preview: "",
        receivedAt: Date(),
        accountName: "Google",
        mailboxName: "Inbox",
        attachmentIdentifier: "index-1",
        attachmentName: "source.pdf",
        MIMEType: "application/pdf",
        sizeBytes: Int64(sourceData.count),
        kind: .pdf
    )

    let cachedURL = try PersistentAttachmentStore.store(
        sourceURL,
        candidate: candidate,
        rootDirectory: cacheRoot
    )
    #expect(try Data(contentsOf: cachedURL) == sourceData)

    let oldDate = Date().addingTimeInterval(-PersistentAttachmentStore.retentionInterval - 60)
    try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: cachedURL.path
    )
    try PersistentAttachmentStore.cleanupExpired(rootDirectory: cacheRoot)

    #expect(!FileManager.default.fileExists(atPath: cachedURL.path))
}
