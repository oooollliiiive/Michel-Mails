import AppKit
import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: AttachmentDownloadManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.items) { record in
                            downloadRow(record)
                            Divider().padding(.leading, 58)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloads")
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Files from Mails") {
                manager.showDestinationFolder()
            }
            Button("Clear Finished") {
                manager.clearFinished()
            }
            .disabled(!manager.items.contains { $0.state == .ready })
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var summary: String {
        if manager.activeCount > 0 || manager.queuedCount > 0 {
            return "\(manager.activeCount) active · \(manager.queuedCount) queued · newest first"
        }
        let completed = manager.items.filter { $0.state == .ready }.count
        return completed == 1 ? "1 completed download" : "\(completed) completed downloads"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.headline)
            Text("Downloaded attachments are saved in Desktop/Files from Mails.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func downloadRow(_ record: AttachmentTransferRecord) -> some View {
        HStack(spacing: 12) {
            AttachmentDownloadIndicator(state: record.state)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.candidate.attachmentName.isEmpty
                    ? "Untitled attachment"
                    : record.candidate.attachmentName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text("\(record.candidate.sender) · \(statusText(record))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if record.state == .failed {
                Button("Retry") {
                    manager.retry(record.candidate)
                }
            } else if let exportedURL = record.exportedURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func statusText(_ record: AttachmentTransferRecord) -> String {
        switch record.state {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading…"
        case .ready:
            return record.exportedURL == nil
                ? "Thumbnail ready"
                : "Saved in Files from Mails"
        case .failed:
            return record.errorMessage ?? "Download failed"
        }
    }
}

struct AttachmentDownloadIndicator: View {
    let state: AttachmentTransferState
    @State private var growth = 0.2

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: ringAmount)
                .stroke(
                    state == .failed ? Color.red : Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(state == .failed ? Color.red : Color.accentColor)
        }
        .onAppear(perform: startAnimation)
        .onChange(of: state) { _ in startAnimation() }
        .accessibilityLabel(accessibilityText)
    }

    private var ringAmount: CGFloat {
        switch state {
        case .queued: return 0.22
        case .downloading: return growth
        case .ready: return 1
        case .failed: return 0.82
        }
    }

    private var symbolName: String {
        switch state {
        case .queued, .downloading: return "arrow.down"
        case .ready: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .queued: return "Download queued"
        case .downloading: return "Downloading"
        case .ready: return "Download ready"
        case .failed: return "Download failed"
        }
    }

    private func startAnimation() {
        growth = 0.2
        guard state == .downloading else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            growth = 0.88
        }
    }
}
