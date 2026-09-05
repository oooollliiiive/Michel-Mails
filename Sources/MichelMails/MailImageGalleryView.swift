import AppKit
import SwiftUI

struct MailImageGalleryView: View {
    let gallery: MailImageGallery
    @ObservedObject var indexController: MailIndexController
    @Binding var showParasiteImages: Bool
    let onOpenEmail: (MailMessageItem) -> Void
    let onClose: () -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var selectionOrder: [UUID] = []
    @State private var cardFrames: [UUID: CGRect] = [:]
    @State private var statusMessage = "Select files · drag them anywhere or copy and paste"
    @State private var transientMessage: String?
    @State private var transientMessageTask: Task<Void, Never>?

    private let cardWidth: CGFloat = 184
    private let cardHeight: CGFloat = 156
    private let gridSpacing: CGFloat = 8
    private let gridPadding: CGFloat = 12
    private let selectionControlWidth: CGFloat = 118

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
            1,
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

            Divider()
                .frame(height: 20)

            Button("Select All") {
                selectedIDs = Set(gallery.items.map(\.id))
                selectionOrder = gallery.items.map(\.id)
            }
            .disabled(gallery.items.isEmpty || selectedIDs.count == gallery.items.count)

            Button("Unselect All") {
                selectedIDs.removeAll()
                selectionOrder.removeAll()
            }
            .disabled(selectedIDs.isEmpty)

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
            if !selectedIDs.isEmpty {
                Text(selectedIDs.count == 1 ? "1 selected" : "\(selectedIDs.count) selected")
                    .fontWeight(.medium)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 42)
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
                .frame(width: selectionControlWidth, height: 30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                )

            Button(action: saveSelectedToDesktop) {
                Text("Save to Desktop")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: selectionControlWidth, height: 30)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            if selectedIDs.count == 1 {
                Button {
                    if let item = lastSelectedItem { onOpenEmail(item.message) }
                } label: {
                    Text("Open in Mail")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: selectionControlWidth, height: 30)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
        .zIndex(20)
    }

    private func selectionBarPosition(in viewportSize: CGSize) -> CGPoint {
        let halfBarWidth: CGFloat = 190
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
                GalleryThumbnail(item: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 156)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        Text(item.displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.62)
                            .allowsTightening(true)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, selected ? 29 : 7)
                            .frame(maxWidth: .infinity)
                            .frame(height: 25, alignment: .bottom)
                            .padding(.bottom, 3)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(4)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.top, 10)

                    Spacer()

                    VStack(alignment: .center, spacing: 1) {
                        Text("Sent by \(item.message.sender)")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(displayDate(item.message.receivedAt))
                            .font(.system(size: 9.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
                    .padding(.top, 3)
                    .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 7)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
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
            NSWorkspace.shared.open(item.cachedURL)
        }
        .onDrag {
            NSItemProvider(contentsOf: item.cachedURL) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Open File") {
                NSWorkspace.shared.open(item.cachedURL)
            }
            Button("Open in Email") {
                onOpenEmail(item.message)
            }
            Divider()
            Button("Copy File") {
                copy([item])
            }
            Button("Save This File…") {
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
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
            selectionOrder.removeAll { $0 == item.id }
        } else {
            selectedIDs.insert(item.id)
            selectionOrder.removeAll { $0 == item.id }
            selectionOrder.append(item.id)
        }
        statusMessage = "Drag files, copy them, or save them"
    }

    private func saveSelectedToDesktop() {
        let items = selectedItems
        guard !items.isEmpty,
              let desktop = FileManager.default.urls(
                  for: .desktopDirectory,
                  in: .userDomainMask
              ).first else {
            showTransientMessage("The Desktop folder is unavailable.")
            return
        }

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try DesktopFileSaver.save(items, to: desktop)
                }.value
                let savedCount = result.savedURLs.count
                let duplicateCount = result.duplicateCount
                if savedCount == 0 && duplicateCount == 1 {
                    showTransientMessage("Already on Desktop — nothing copied.")
                } else if savedCount == 0 {
                    showTransientMessage("\(duplicateCount) files are already on Desktop — nothing copied.")
                } else if duplicateCount > 0 {
                    showTransientMessage(
                        "\(savedCount) saved to Desktop · \(duplicateCount) already there."
                    )
                } else {
                    showTransientMessage(
                        savedCount == 1 ? "Saved to Desktop." : "\(savedCount) files saved to Desktop."
                    )
                }
            } catch {
                showTransientMessage("Could not save to Desktop.")
            }
        }
    }

    private func showTransientMessage(_ message: String) {
        transientMessageTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            transientMessage = message
        }
        transientMessageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                transientMessage = nil
            }
        }
    }

    private func copy(_ items: [MailImageItem]) {
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let didCopy: Bool
        if items.count == 1, let item = items.first {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.cachedURL.absoluteString, forType: .fileURL)
            if let image = NSImage(contentsOf: item.cachedURL),
               let TIFFData = image.tiffRepresentation {
                pasteboardItem.setData(TIFFData, forType: .tiff)
            }
            didCopy = pasteboard.writeObjects([pasteboardItem])
        } else {
            didCopy = pasteboard.writeObjects(items.map { $0.cachedURL as NSURL })
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
        let panel = NSSavePanel()
        panel.title = "Save File"
        panel.prompt = "Save"
        panel.nameFieldStringValue = item.displayName

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.cachedURL, to: destination)
            statusMessage = "File saved: \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            statusMessage = "Could not save the file."
        }
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
    @State private var image: NSImage?
    @State private var isFallback = false

    var body: some View {
        Group {
            if let image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(isFallback ? 24 : 5)

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
            } else {
                VStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing preview…")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .task(id: item.cachedURL) {
            let result = await GalleryThumbnailService.thumbnail(
                at: item.cachedURL,
                kind: item.kind,
                maximumDimension: 512
            )
            image = result.image
            isFallback = result.isFallback
        }
    }
}
