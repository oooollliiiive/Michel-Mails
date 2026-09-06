import AppKit
import SwiftUI

struct MailSearchResultsView: View {
    let results: MailSearchResults
    @ObservedObject var indexController: MailIndexController
    @ObservedObject var downloadManager: AttachmentDownloadManager
    let onOpenEmail: (MailMessageItem) -> Void
    let onDownloadAttachments: (MailMessageItem) -> Void
    let onClose: () -> Void

    @State private var selectedItem: MailMessageItem?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !indexController.progress.isFinished {
                scanNotice
            }
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results.items) { item in
                        resultRow(item)
                        if item.id != results.items.last?.id {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))

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
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Email results")
                    .font(.headline)
                Text(resultSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open in Mail") {
                if let selectedItem { onOpenEmail(selectedItem) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItem == nil)

            Button("Download Attachments to Desktop") {
                if let selectedItem { onDownloadAttachments(selectedItem) }
            }
            .disabled(selectedItem?.attachments.isEmpty != false)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close email results")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var resultSummary: String {
        let count = results.items.count == 1 ? "1 email" : "\(results.items.count) emails"
        let order = results.query.sortOrder == .oldestFirst ? "oldest first" : "newest first"
        return "\(count) · \(order)"
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "cursorarrow.click.2")
            Text(selectedItem == nil
                ? "Select an email · double-click to open it in Mail"
                : "Double-click or press Open in Mail")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .frame(height: 42)
    }

    private func resultRow(_ item: MailMessageItem) -> some View {
        let selected = selectedItem?.id == item.id
        let previews = item.imageAttachments

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor.opacity(selected ? 0.14 : 0.07)))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.sender)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if let receivedAt = item.receivedAt {
                        Text(displayDate(receivedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 6) {
                    Text(item.subject)
                        .font(.system(size: 13.5, weight: .medium))
                        .lineLimit(1)
                    if item.hasAttachment {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .help("This email has attachments")
                    }
                }

                if !item.preview.isEmpty {
                    Text(item.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.primary.opacity(0.78))
                        .lineLimit(2)
                }
            }

            if !previews.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(previews, id: \.stableKey) { preview in
                            EmailAttachmentThumbnail(
                                candidate: preview,
                                downloadManager: downloadManager
                            )
                        }
                    }
                }
                .frame(
                    width: min(CGFloat(previews.count) * 95, 470),
                    height: 78
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            selected
                ? Color.accentColor.opacity(0.10)
                : Color(nsColor: .textBackgroundColor)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedItem = item
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                selectedItem = item
                onOpenEmail(item)
            }
        )
        .contextMenu {
            Button("Open in Mail") {
                onOpenEmail(item)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.sender), \(item.subject)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func displayDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

private struct EmailAttachmentThumbnail: View {
    let candidate: IndexedMailAttachmentCandidate
    @ObservedObject var downloadManager: AttachmentDownloadManager
    @State private var image: NSImage?

    private var record: AttachmentTransferRecord? {
        downloadManager.record(for: candidate)
    }

    private var thumbnailURL: URL? {
        downloadManager.thumbnailURL(for: candidate)
    }

    private var loadIdentifier: String {
        "\(downloadManager.cacheResetGeneration)|\(thumbnailURL?.path ?? "missing")"
    }

    private var immediatelyAvailableImage: NSImage? {
        thumbnailURL.flatMap(downloadManager.cachedImage)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if downloadManager.isResettingCaches {
                ProgressView()
                    .controlSize(.small)
            } else if let renderedImage = image ?? immediatelyAvailableImage {
                Image(nsImage: renderedImage)
                    .resizable()
                    .scaledToFill()
            } else if record?.state == .failed {
                Button {
                    downloadManager.retry(candidate)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Retry")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if record == nil || record?.state == .available {
                Button {
                    downloadManager.downloadForPreview(candidate)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 24, weight: .medium))
                        Text("Download")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else {
                AttachmentDownloadIndicator(state: record?.state ?? .available)
                    .frame(width: 30, height: 30)
            }
        }
        .frame(width: 90, height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    candidate.isPotentialParasite ? Color.red : Color.primary.opacity(0.12),
                    lineWidth: candidate.isPotentialParasite ? 2 : 1
                )
        )
        .help(candidate.attachmentName)
        .task(id: loadIdentifier) {
            image = nil
            guard !downloadManager.isResettingCaches else { return }
            guard let thumbnailURL else {
                return
            }
            image = downloadManager.cachedImage(at: thumbnailURL)
        }
    }
}
