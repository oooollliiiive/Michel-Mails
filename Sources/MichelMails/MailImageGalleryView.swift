import AppKit
import SwiftUI

struct MailImageGalleryView: View {
    let gallery: MailImageGallery
    @ObservedObject var indexController: MailIndexController
    @ObservedObject var downloadManager: AttachmentDownloadManager
    @Binding var showParasiteImages: Bool
    @Binding var showJunkImages: Bool
    let onOpenEmail: (MailMessageItem, @escaping (Bool, String) -> Void) -> Void
    let onClose: () -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionOrder: [UUID] = []
    @State private var selectionModeEnabled = false
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var statusMessage = "Select files · drag them anywhere or copy and paste"
    @State private var transientMessage: String?
    @State private var transientMessageTask: Task<Void, Never>?
    @State private var openingMailItemID: UUID?

    private let cardWidth: CGFloat = 200
    private let cardHeight: CGFloat = 174
    private let gridSpacing: CGFloat = 5
    private let gridPadding: CGFloat = 6

    private var selectedItems: [MailImageItem] {
        gallery.items.filter { selectedIDs.contains($0.id) }
    }

    private var lastSelectedItem: MailImageItem? {
        guard let ID = selectionOrder.last else { return nil }
        return gallery.items.first { $0.id == ID }
    }

    private var chronologicallyOrderedItems: [MailImageItem] {
        gallery.items.enumerated().sorted { left, right in
            let leftDate = left.element.message.receivedAt
            let rightDate = right.element.message.receivedAt
            switch (leftDate, rightDate) {
            case let (.some(leftDate), .some(rightDate)) where leftDate != rightDate:
                return gallery.query.sortOrder == .oldestFirst
                    ? leftDate < rightDate
                    : leftDate > rightDate
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return left.offset < right.offset
            }
        }.map(\.element)
    }

    private func galleryRows(for viewportHeight: CGFloat) -> [GridItem] {
        let usableHeight = max(cardHeight, viewportHeight - (gridPadding * 2))
        let rowCount = max(
            3,
            Int((usableHeight + gridSpacing) / (cardHeight + gridSpacing))
        )
        return Array(
            repeating: GridItem(.fixed(cardHeight), spacing: gridSpacing),
            count: rowCount
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !indexController.progress.isFinished {
                scanNotice
            }
            Divider()

            GeometryReader { viewport in
                ScrollView(.horizontal) {
                    LazyHGrid(
                        rows: galleryRows(for: viewport.size.height),
                        alignment: .top,
                        spacing: gridSpacing
                    ) {
                        ForEach(chronologicallyOrderedItems) { item in
                            imageCard(item)
                        }
                    }
                    .padding(gridPadding)
                    .background(HorizontalMouseWheelSupport())
                }
                .coordinateSpace(name: "MichelMailsGalleryScroll")
                .onPreferenceChange(GalleryCardFramePreferenceKey.self) { frames in
                    cardFrames = frames
                }
                .overlay {
                    if !selectedIDs.isEmpty {
                        selectionActionBar
                            .position(selectionBarPosition(in: viewport.size))
                            .transition(.scale(scale: 0.94).combined(with: .opacity))
                    }
                }
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let transientMessage {
                Text(transientMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.78), in: Capsule())
                    .shadow(radius: 5, y: 2)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var scanNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Email scan not finished — results may be incomplete")
            Spacer()
            Text(indexController.progress.statusText)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color.orange.opacity(0.08))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo, .purple, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(galleryTitle)
                    .font(.headline)
                Text(gallerySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Show Parasite Images")
                .font(.system(size: 11.5, weight: .semibold))
            Text(showParasiteImages ? "ON" : "OFF")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(showParasiteImages ? Color.red : Color.secondary)
                .frame(width: 24, alignment: .trailing)
            Toggle("Show Parasite Images", isOn: $showParasiteImages)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show suspected signatures, logos, icons, and tracking images. They are outlined in red.")

            Text("Junk")
                .font(.system(size: 11.5, weight: .semibold))
            Text(showJunkImages ? "ON" : "OFF")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(showJunkImages ? Color.orange : Color.secondary)
                .frame(width: 24, alignment: .trailing)
            Toggle("Junk", isOn: $showJunkImages)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Include images from Junk and Spam mailboxes.")

            Divider()
                .frame(height: 20)

            Button {
                toggleSelectionMode()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: selectionModeEnabled ? "checkmark.circle.fill" : "checkmark.circle")
                    Text(selectionModeEnabled ? "Select ON" : "Select")
                }
                .font(.system(size: 11.5, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(selectionModeEnabled ? Color.accentColor : Color.secondary)
            .help(selectionModeEnabled ? "Turn off multiple selection" : "Turn on multiple selection")

            if selectionModeEnabled {
                Button("Select All") {
                    selectedIDs = Set(gallery.items.map(\.id))
                    selectionOrder = gallery.items.map(\.id)
                }
                .disabled(gallery.items.isEmpty || selectedIDs.count == gallery.items.count)
            }

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close the gallery")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack {
            Image(systemName: selectedIDs.isEmpty ? "cursorarrow.click" : "checkmark.circle.fill")
                .foregroundStyle(selectedIDs.isEmpty ? Color.secondary : Color.accentColor)
            Text(statusMessage)
                .lineLimit(1)
            Spacer()
            Button(role: .destructive) {
                statusMessage = "Clearing thumbnails and cached originals…"
                downloadManager.resetPreviewCaches()
            } label: {
                Label(
                    downloadManager.isResettingCaches ? "Cancelling…" : "Cancel Thumbnails",
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderless)
            .disabled(downloadManager.isResettingCaches)
            .help("Cancel preview downloads, clear all cached thumbnails and cached originals, then restart this gallery. Files saved on the Desktop are not deleted.")

            if !selectedIDs.isEmpty {
                Text(selectedIDs.count == 1 ? "1 selected" : "\(selectedIDs.count) selected")
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 42)
        .onChange(of: downloadManager.isResettingCaches) { isResetting in
            if !isResetting {
                statusMessage = "Thumbnail cache cleared · previews restarted"
            }
        }
    }

    private var galleryTitle: String {
        let kinds = Set(gallery.items.map(\.kind))
        if kinds == Set([.image]) { return "Email images" }
        if kinds == Set([.pdf]) { return "Email PDFs" }
        if kinds == Set([.video]) { return "Email videos" }
        if kinds == Set([.document]) { return "Email documents" }
        return "Email files"
    }

    private var gallerySubtitle: String {
        let noun = gallery.items.count == 1 ? "file" : "files"
        let order = gallery.query.sortOrder == .oldestFirst ? "oldest first" : "newest first"
        return "\(gallery.items.count) \(noun) · \(order)"
    }

    private var selectionActionBar: some View {
        HStack(spacing: 8) {
            Text(selectedIDs.count == 1 ? "1 file" : "\(selectedIDs.count) files")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                )

            Button(action: saveSelectedToDesktop) {
                Text("Save to Desktop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            if selectedIDs.count == 1 {
                Button {
                    if let item = lastSelectedItem { openEmail(item) }
                } label: {
                    Text(openingMailItemID == lastSelectedItem?.id ? "Opening…" : "Open in Mail")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(openingMailItemID != nil)
            }

            Button(action: unselectAll) {
                Text("Unselect All")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(Color.accentColor.opacity(0.34), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
        .zIndex(20)
    }

    private func selectionBarPosition(in viewportSize: CGSize) -> CGPoint {
        let halfBarWidth: CGFloat = selectedIDs.count == 1 ? 260 : 215
        let barHalfHeight: CGFloat = 18
        let topY = barHalfHeight + 8
        guard let ID = selectionOrder.last,
              let frame = cardFrames[ID],
              frame.maxX > 0,
              frame.minX < viewportSize.width,
              frame.maxY > 0,
              frame.minY < viewportSize.height else {
            return CGPoint(x: viewportSize.width / 2, y: topY)
        }

        let x = min(
            max(frame.midX, halfBarWidth + 8),
            max(halfBarWidth + 8, viewportSize.width - halfBarWidth - 8)
        )
        return CGPoint(x: x, y: max(topY, frame.minY - barHalfHeight - 7))
    }

    private func imageCard(_ item: MailImageItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                GalleryThumbnail(item: item, downloadManager: downloadManager)
                    .frame(width: cardWidth, height: cardHeight)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Text(item.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .allowsTightening(true)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, selected && selectionModeEnabled ? 27 : 5)
                            .frame(maxWidth: .infinity)
                            .frame(height: 18, alignment: .center)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        if selected && selectionModeEnabled {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(2)
                        }
                    }
                    .padding(.horizontal, 3)

                    Spacer()

                    VStack(alignment: .center, spacing: 1) {
                        Text("Sent by \(item.message.sender)")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(displayDate(item.message.receivedAt))
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
                    .padding(.top, 2)
                    .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 3)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    item.isPotentialParasite ? Color.red : (selected ? Color.accentColor : Color.clear),
                    lineWidth: selected || item.isPotentialParasite ? 3 : 0
                )
        )
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: GalleryCardFramePreferenceKey.self,
                    value: [
                        item.id: geometry.frame(in: .named("MichelMailsGalleryScroll"))
                    ]
                )
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            toggle(item)
        }
        .onTapGesture(count: 2) {
            openFile(item)
        }
        .onDrag {
            guard let originalURL = completeOriginalURL(item) else {
                if let candidate = item.sourceCandidate {
                    downloadManager.downloadAttachmentsToDesktop([candidate])
                    showTransientMessage("Download queued in Files from Mails.")
                }
                return NSItemProvider()
            }
            return NSItemProvider(contentsOf: originalURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open File") {
                openFile(item)
            }
            Button("Open in Email") {
                openEmail(item)
            }
            Divider()
            Button("Copy File") {
                copy([item])
            }
            Button("Save to Desktop") {
                saveSingle(item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.displayName)\(item.isPotentialParasite ? ", suspected parasite image" : "")\(selected ? ", selected" : "")"
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ item: MailImageItem) {
        if !selectionModeEnabled {
            if selectedIDs == Set([item.id]) {
                selectedIDs.removeAll()
                selectionOrder.removeAll()
            } else {
                selectedIDs = [item.id]
                selectionOrder = [item.id]
            }
        } else if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
            selectionOrder.removeAll { $0 == item.id }
        } else {
            selectedIDs.insert(item.id)
            selectionOrder.removeAll { $0 == item.id }
            selectionOrder.append(item.id)
        }
        statusMessage = selectedIDs.isEmpty
            ? "Select a file"
            : "Drag files, copy them, or save them"
    }

    private func toggleSelectionMode() {
        selectionModeEnabled.toggle()
        if !selectionModeEnabled,
           selectedIDs.count > 1,
           let lastSelectedID = selectionOrder.last {
            selectedIDs = [lastSelectedID]
            selectionOrder = [lastSelectedID]
        }
        statusMessage = selectionModeEnabled
            ? "Multiple selection is on"
            : "Single selection is on"
    }

    private func unselectAll() {
        selectedIDs.removeAll()
        selectionOrder.removeAll()
        statusMessage = selectionModeEnabled
            ? "Multiple selection is on"
            : "Select a file"
    }

    private func saveSelectedToDesktop() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let candidates = items.compactMap(\.sourceCandidate)
        if !candidates.isEmpty {
            downloadManager.downloadAttachmentsToDesktop(candidates)
            showTransientMessage(
                candidates.count == 1
                    ? "Download queued in Desktop/Files from Mails."
                    : "\(candidates.count) downloads queued in Desktop/Files from Mails."
            )
            return
        }

        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            showTransientMessage("The Desktop folder is unavailable.")
            return
        }
        let destination = desktop.appendingPathComponent("Files from Mails", isDirectory: true)

        Task {
            do {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                let result = try await Task.detached(priority: .userInitiated) {
                    try DesktopFileSaver.save(items, to: destination)
                }.value
                let savedCount = result.savedURLs.count
                let duplicateCount = result.duplicateCount
                let incompleteCount = result.incompleteCount
                if incompleteCount > 0 {
                    showTransientMessage("Incomplete files were skipped.")
                    return
                }
                if savedCount == 0 && duplicateCount == 1 {
                    showTransientMessage("Already in Files from Mails — nothing copied.")
                } else if savedCount == 0 {
                    showTransientMessage("\(duplicateCount) files are already in Files from Mails.")
                } else if duplicateCount > 0 {
                    showTransientMessage(
                        "\(savedCount) saved · \(duplicateCount) already in Files from Mails."
                    )
                } else {
                    showTransientMessage(
                        savedCount == 1
                            ? "Saved in Desktop/Files from Mails."
                            : "\(savedCount) files saved in Desktop/Files from Mails."
                    )
                }
            } catch {
                showTransientMessage("Could not save in Files from Mails.")
            }
        }
    }

    private func showTransientMessage(
        _ message: String,
        durationNanoseconds: UInt64 = 2_400_000_000
    ) {
        transientMessageTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            transientMessage = message
        }
        transientMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: durationNanoseconds)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                transientMessage = nil
            }
        }
    }

    private func copy(_ items: [MailImageItem]) {
        guard !items.isEmpty else { return }
        let unavailable = items.filter {
            !hasCompleteOriginal($0)
        }
        if !unavailable.isEmpty {
            let candidates = unavailable.compactMap(\.sourceCandidate)
            downloadManager.downloadAttachmentsToDesktop(candidates)
            statusMessage = "Original file unavailable · download queued in Files from Mails"
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let didCopy: Bool
        if items.count == 1,
           let item = items.first,
           let originalURL = completeOriginalURL(item) {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(originalURL.absoluteString, forType: .fileURL)
            if let image = NSImage(contentsOf: originalURL),
               let TIFFData = image.tiffRepresentation {
                pasteboardItem.setData(TIFFData, forType: .tiff)
            }
            didCopy = pasteboard.writeObjects([pasteboardItem])
        } else {
            didCopy = pasteboard.writeObjects(
                items.compactMap(completeOriginalURL).map { $0 as NSURL }
            )
        }

        if didCopy {
            statusMessage = items.count == 1
                ? "File copied · paste it anywhere"
                : "\(items.count) files copied · paste them anywhere"
        } else {
            statusMessage = "Could not copy the selected files."
        }
    }

    private func saveSingle(_ item: MailImageItem) {
        if let candidate = item.sourceCandidate {
            downloadManager.downloadAttachmentsToDesktop([candidate])
            showTransientMessage("Download queued in Desktop/Files from Mails.")
            return
        }
        saveSelectedToDesktop()
    }

    private func openFile(_ item: MailImageItem) {
        if let originalURL = completeOriginalURL(item) {
            NSWorkspace.shared.open(originalURL)
        } else if let candidate = item.sourceCandidate {
            downloadManager.openAttachment(candidate)
            showTransientMessage("Downloading the original file…")
        }
    }

    private func openEmail(_ item: MailImageItem) {
        guard openingMailItemID == nil else { return }
        openingMailItemID = item.id
        transientMessageTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            transientMessage = "Opening email in Mail…"
        }
        onOpenEmail(item.message) { success, message in
            openingMailItemID = nil
            showTransientMessage(
                message,
                durationNanoseconds: success ? 1_800_000_000 : 5_000_000_000
            )
        }
    }

    private func hasCompleteOriginal(_ item: MailImageItem) -> Bool {
        completeOriginalURL(item) != nil
    }

    private func completeOriginalURL(_ item: MailImageItem) -> URL? {
        let originalURL: URL
        if let candidate = item.sourceCandidate,
           let managedURL = downloadManager.originalURL(for: candidate) {
            originalURL = managedURL
        } else {
            guard item.hasOriginalFile else { return nil }
            originalURL = item.cachedURL
        }
        guard FileManager.default.fileExists(atPath: originalURL.path),
              let size = try? originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else { return nil }
        guard let candidate = item.sourceCandidate else { return originalURL }
        return AttachmentMaterializer.isCompleteFile(at: originalURL, candidate: candidate)
            ? originalURL
            : nil
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let time = date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: "en_US"))
            )
            return "Today at \(time)"
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: Date())
        ).day ?? 0
        if days == 1 { return "1 day ago" }
        if days > 1 { return "\(days) days ago" }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(Locale(identifier: "en_US"))
        )
    }
}

private struct GalleryCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(
        value: inout [UUID: CGRect],
        nextValue: () -> [UUID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GalleryThumbnail: View {
    let item: MailImageItem
    @ObservedObject var downloadManager: AttachmentDownloadManager
    @State private var image: NSImage?
    @State private var isFallback = false

    private var candidate: IndexedMailAttachmentCandidate? {
        item.sourceCandidate
    }

    private var record: AttachmentTransferRecord? {
        candidate.flatMap(downloadManager.record)
    }

    private var displayURL: URL? {
        if item.hasOriginalFile,
           FileManager.default.fileExists(atPath: item.cachedURL.path) {
            return item.cachedURL
        }
        return candidate.flatMap(downloadManager.thumbnailURL)
            ?? candidate.flatMap(downloadManager.originalURL)
    }

    private var loadIdentifier: String {
        "\(downloadManager.cacheResetGeneration)|\(displayURL?.path ?? "missing")"
    }

    var body: some View {
        Group {
            if let image {
                ZStack {
                    if isFallback || (item.kind != .image && item.kind != .video) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(isFallback ? 20 : 3)
                    } else {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }

                    if item.kind == .video, !isFallback {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.48))
                            .shadow(radius: 2)
                    }

                    if isFallback {
                        VStack {
                            Spacer()
                            Text("Preview unavailable")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else if record?.state == .failed, let candidate {
                Button {
                    downloadManager.retry(candidate)
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 27, weight: .semibold))
                        Text("Retry download")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if let candidate,
                      record == nil || record?.state == .available {
                Button {
                    downloadManager.downloadForPreview(candidate)
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 30, weight: .medium))
                        Text("Download preview")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 7) {
                    AttachmentDownloadIndicator(state: record?.state ?? .available)
                        .frame(width: 34, height: 34)
                    Text(record?.state == .downloading ? "Preparing preview…" : "Waiting…")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: loadIdentifier) {
            guard let displayURL else {
                image = nil
                isFallback = false
                return
            }
            let result = await GalleryThumbnailService.thumbnail(
                at: displayURL,
                kind: item.kind,
                maximumDimension: 512
            )
            image = result.isFallback && item.kind == .image ? nil : result.image
            isFallback = result.isFallback
        }
    }
}
