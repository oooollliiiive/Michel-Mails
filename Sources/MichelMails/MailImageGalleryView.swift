import AppKit
import SwiftUI

struct MailImageGalleryView: View {
    let gallery: MailImageGallery

    @State private var selectedIDs: Set<UUID> = []
    @State private var statusMessage = "Cliquez pour sélectionner · double-cliquez pour ouvrir"

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
                Text("Images reçues par email")
                    .font(.headline)
                Text(gallery.items.count == 1 ? "1 image" : "\(gallery.items.count) images · plus récentes en premier")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(selectedIDs.count == gallery.items.count ? "Tout désélectionner" : "Tout sélectionner") {
                if selectedIDs.count == gallery.items.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(gallery.items.map(\.id))
                }
            }
            .disabled(gallery.items.isEmpty)

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
                Text(selectedIDs.count == 1 ? "1 sélectionnée" : "\(selectedIDs.count) sélectionnées")
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
            return "Enregistrer…"
        case 1:
            return "Enregistrer l’image…"
        default:
            return "Enregistrer \(selectedIDs.count) images…"
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
        .contextMenu {
            Button("Ouvrir") {
                NSWorkspace.shared.open(item.cachedURL)
            }
            Button("Enregistrer cette image…") {
                saveSingle(item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName)\(selected ? ", sélectionnée" : "")")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggle(_ item: MailImageItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        statusMessage = "Sélectionnez une ou plusieurs images à enregistrer"
    }

    private func saveSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }

        if items.count == 1, let item = items.first {
            saveSingle(item)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Enregistrer les images sélectionnées"
        panel.message = "Choisissez le dossier de destination."
        panel.prompt = "Enregistrer ici"
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
            statusMessage = "\(savedURLs.count) images enregistrées dans \(directory.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        } catch {
            statusMessage = "Impossible d’enregistrer : \(error.localizedDescription)"
        }
    }

    private func saveSingle(_ item: MailImageItem) {
        let panel = NSSavePanel()
        panel.title = "Enregistrer l’image"
        panel.prompt = "Enregistrer"
        panel.nameFieldStringValue = item.displayName

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: item.cachedURL, to: destination)
            statusMessage = "Image enregistrée : \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            statusMessage = "Impossible d’enregistrer : \(error.localizedDescription)"
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
                Text("Aperçu indisponible")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
    }
}
