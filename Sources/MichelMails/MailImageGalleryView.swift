import AppKit
import SwiftUI

struct MailImageGalleryView: View {
    let gallery: MailImageGallery
    let onOpenEmail: (MailMessageItem) -> Void

    @State private var selectedIDs: Set<UUID> = []
    @State private var statusMessage = "Select images · drag them anywhere or copy and paste"

    private let columns = [
        GridItem(.adaptive(minimum: 165, maximum: 240), spacing: 14)
    ]

    private var selectedItems: [MailImageItem] {
        gallery.items.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .frame(minWidth: 690, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
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
                Text("Images received by email")
                    .font(.headline)
                Text(gallery.items.count == 1 ? "1 image" : "\(gallery.items.count) images · newest first")
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

            Button("Open in Mail") {
                if let item = selectedItems.first { onOpenEmail(item.message) }
            }
            .disabled(selectedItems.count != 1)

            Button(saveButtonTitle, action: saveSelected)
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
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
            return "Save Image…"
        default:
            return "Save \(selectedIDs.count) Images…"
        }
    }

    private func imageCard(_ item: MailImageItem) -> some View {
        let selected = selectedIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                GalleryThumbnail(URL: item.cachedURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: 156)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(8)
                }
            }

            Text(item.displayName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
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
            Button("Open Image") {
                NSWorkspace.shared.open(item.cachedURL)
            }
            Button("Open in Mail") {
                onOpenEmail(item.message)
            }
            Divider()
            Button("Copy Image") {
                copy([item])
            }
            Button("Save This Image…") {
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
        statusMessage = "Drag images, copy them, or save them"
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
                ? "Image copied · paste it anywhere"
                : "\(items.count) images copied · paste them anywhere"
        } else {
            statusMessage = "Could not copy the selected images."
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
        panel.title = "Save Selected Images"
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
            statusMessage = "\(savedURLs.count) images saved to \(directory.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        } catch {
            statusMessage = "Could not save the selected images."
        }
    }

    private func saveSingle(_ item: MailImageItem) {
        let panel = NSSavePanel()
        panel.title = "Save Image"
        panel.prompt = "Save"
        panel.nameFieldStringValue = item.displayName

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.cachedURL, to: destination)
            statusMessage = "Image saved: \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            statusMessage = "Could not save the image."
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
}

private struct GalleryThumbnail: View {
    let URL: URL

    var body: some View {
        if let image = NSImage(contentsOf: URL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .padding(5)
        } else {
            VStack(spacing: 7) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title)
                Text("Preview unavailable")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}
