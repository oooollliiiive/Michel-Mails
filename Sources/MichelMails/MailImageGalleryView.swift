import AppKit
import SwiftUI

struct MailImageGalleryView: View {
    let gallery: MailImageGallery
    @ObservedObject var indexController: MailIndexController
    let onOpenEmail: (MailMessageItem) -> Void
    let onClose: () -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var statusMessage = "Select files · drag them anywhere or copy and paste"

    private let columns = [
        GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 14)
    ]

    private var selectedItems: [MailImageItem] {
        gallery.items.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !indexController.progress.isFinished {
                scanNotice
            }
            Divider()

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(gallery.items) { item in
                        imageCard(item)
                    }
                }
                .padding(18)
            }
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

            Button(selectedIDs.count == gallery.items.count ? "Deselect All" : "Select All") {
                if selectedIDs.count == gallery.items.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(gallery.items.map(\.id))
                }
            }
            .disabled(gallery.items.isEmpty)

            Button("Copy", action: copySelected)
                .disabled(selectedIDs.isEmpty)

            Button("Open in Email") {
                if let item = selectedItems.first { onOpenEmail(item.message) }
            }
            .disabled(selectedItems.count != 1)

            Button(saveButtonTitle, action: saveSelected)
                .buttonStyle(.borderedProminent)
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

    private var saveButtonTitle: String {
        switch selectedIDs.count {
        case 0:
            return "Save…"
        case 1:
            return "Save File…"
        default:
            return "Save \(selectedIDs.count) Files…"
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
                    HStack(alignment: .top, spacing: 5) {
                        Text(item.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Spacer(minLength: 2)
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    }
                    .padding(7)

                    Spacer()

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sent by \(item.message.sender)")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(displayDate(item.message.receivedAt))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 6))
                    .padding(7)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
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
        .accessibilityLabel("\(item.displayName)\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ item: MailImageItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        statusMessage = "Drag files, copy them, or save them"
    }

    private func copySelected() {
        copy(selectedItems)
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

    private func saveSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }

        if items.count == 1, let item = items.first {
            saveSingle(item)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Save Selected Files"
        panel.message = "Choose a destination folder."
        panel.prompt = "Save Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            var savedURLs: [URL] = []
            for item in items {
                let destination = availableURL(in: directory, named: item.displayName)
                try FileManager.default.copyItem(at: item.cachedURL, to: destination)
                savedURLs.append(destination)
            }
            statusMessage = "\(savedURLs.count) files saved to \(directory.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        } catch {
            statusMessage = "Could not save the selected files."
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

    private func availableURL(in directory: URL, named fileName: String) -> URL {
        let proposed = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }

        let source = URL(fileURLWithPath: fileName)
        let extensionName = source.pathExtension
        let stem = source.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
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
