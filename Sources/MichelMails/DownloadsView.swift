import AppKit
import SwiftUI

struct DownloadsSidebarView: View {
    @ObservedObject var manager: AttachmentDownloadManager
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    if !activeItems.isEmpty {
                        ForEach(activeItems) { record in
                            downloadRow(record)
                            Divider().padding(.leading, 42)
                        }
                        .background(Color.accentColor.opacity(0.06))
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(waitingItems) { record in
                                downloadRow(record)
                                Divider().padding(.leading, 42)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                manager.showDestinationFolder()
            } label: {
                Label("Files", systemImage: "folder")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Open Desktop/Files from Mails")

            Spacer()

            Button {
                manager.clearFinished()
            } label: {
                Label("Clear", systemImage: "checkmark.circle")
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!manager.items.contains { $0.state == .ready })
            .help("Clear finished downloads")
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloads")
                        .font(.system(size: 12.5, weight: .bold))
                    Text(summary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if manager.isPaused {
                    Button("Resume", systemImage: "play.fill") {
                        manager.resumeAll()
                    }
                    .help("Resume Downloads")
                } else if manager.hasPendingTransfers {
                    Button("Stop", systemImage: "stop.fill") {
                        manager.stopAll()
                    }
                    .help("Stop Downloads")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Downloads")
            }

            if manager.failedCount > 0 {
                HStack(spacing: 7) {
                    Button("Retry Failed", systemImage: "arrow.clockwise") {
                        manager.retryAllFailed()
                    }
                    Button("Hide Failed", systemImage: "eye.slash") {
                        manager.hideFailed()
                    }
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var summary: String {
        if manager.activeCount > 0 || manager.queuedCount > 0 || manager.deferredCount > 0 {
            var parts = ["\(manager.activeCount) active", "\(manager.queuedCount) queued"]
            if manager.deferredCount > 0 { parts.append("\(manager.deferredCount) deferred") }
            if manager.failedCount > 0 { parts.append("\(manager.failedCount) failed") }
            return parts.joined(separator: " · ")
        }
        let completed = manager.items.filter { $0.state == .ready }.count
        return completed == 1 ? "1 completed download" : "\(completed) completed downloads"
    }

    private var activeItems: [AttachmentTransferRecord] {
        manager.items.filter { $0.state == .downloading }
    }

    private var waitingItems: [AttachmentTransferRecord] {
        manager.items.filter { $0.state != .downloading }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No downloads yet")
                .font(.system(size: 11.5, weight: .semibold))
            Text("Image downloads will appear here.")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func downloadRow(_ record: AttachmentTransferRecord) -> some View {
        HStack(spacing: 8) {
            AttachmentDownloadIndicator(state: record.state)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.candidate.attachmentName.isEmpty
                    ? "Untitled attachment"
                    : record.candidate.attachmentName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusText(record))
                    .font(.system(size: 9.5))
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if record.state == .failed {
                Button {
                    manager.retry(record.candidate)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Retry")
            } else if let exportedURL = record.exportedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .help("\(record.candidate.attachmentName)\n\(record.candidate.sender)\n\(statusText(record))")
    }

    private func statusText(_ record: AttachmentTransferRecord) -> String {
        switch record.state {
        case .available:
            return "Ready to download"
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading…"
        case .deferred:
            return record.errorMessage ?? "Retrying automatically"
        case .ready:
            return record.exportedURL == nil
                ? "Available offline"
                : "Saved in \(record.exportedURL?.deletingLastPathComponent().lastPathComponent ?? "folder")"
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
                    indicatorColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(indicatorColor)
        }
        .onAppear(perform: startAnimation)
        .onChange(of: state) { _ in startAnimation() }
        .accessibilityLabel(accessibilityText)
    }

    private var ringAmount: CGFloat {
        switch state {
        case .available: return 1
        case .queued: return 0.22
        case .downloading: return growth
        case .deferred: return 0.45
        case .ready: return 1
        case .failed: return 0.82
        }
    }

    private var symbolName: String {
        switch state {
        case .available: return "arrow.down"
        case .queued, .downloading: return "arrow.down"
        case .deferred: return "clock.arrow.circlepath"
        case .ready: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .available: return "Download available"
        case .queued: return "Download queued"
        case .downloading: return "Downloading"
        case .deferred: return "Download deferred for automatic retry"
        case .ready: return "Download ready"
        case .failed: return "Download failed"
        }
    }

    private var indicatorColor: Color {
        switch state {
        case .failed: return .red
        case .deferred: return .orange
        default: return .accentColor
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
