import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var indexController: MailIndexController
    @ObservedObject var downloadManager: AttachmentDownloadManager
    @FocusState private var promptIsFocused: Bool
    @State private var latestImageCount = 20
    @State private var imageDirection: MailDirection = .any
    @State private var imageCorrespondent = ""
    @State private var quickFilterTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
            quickImageControls

            HStack(spacing: 12) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                TextField(
                    "e.g. Show me the 10 latest images received by email",
                    text: promptBinding
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .focused($promptIsFocused)
                .onSubmit(viewModel.submit)
                .disabled(viewModel.isWorking)

                if !viewModel.prompt.isEmpty {
                    Button {
                        viewModel.clearPrompt()
                        promptIsFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isWorking)
                    .help("Clear")
                }

                if viewModel.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: viewModel.submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(.white)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Search")
                }

                Button {
                    viewModel.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Settings")

                Button(action: viewModel.showDownloads) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                        if downloadManager.activeCount > 0 || downloadManager.queuedCount > 0 {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Show Downloads")
            }

            if viewModel.historyIsVisible {
                historySuggestions
            }

            HStack(spacing: 7) {
                if indexController.requiresFullDiskAccess {
                    Button("Grant Full Disk Access") {
                        indexController.openFullDiskAccessSettings()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .help("Add Michel Mails in Privacy & Security › Full Disk Access, then reopen Michel Mails if macOS asks.")
                }

                Text("AI Interpretation")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(viewModel.usesOpenAI ? "ON" : "OFF")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(viewModel.usesOpenAI ? Color.purple : Color.secondary)
                    .frame(width: 24, alignment: .trailing)
                Toggle(
                    "AI Interpretation",
                    isOn: Binding(
                        get: { viewModel.usesOpenAI },
                        set: viewModel.setAIInterpretation
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("ON uses OpenAI to understand prompts. OFF uses the fast local interpreter. Email contents always stay on this Mac.")

                Spacer()
                Text("Force Scan")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(indexController.forceScanEnabled ? "ON" : "OFF")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(indexController.forceScanEnabled ? Color.orange : Color.secondary)
                    .frame(width: 24, alignment: .trailing)
                Toggle(
                    "Force Scan",
                    isOn: Binding(
                        get: { indexController.forceScanEnabled },
                        set: indexController.setForceScan
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("ON scans continuously at maximum speed. It returns to OFF every time Michel Mails starts.")
            }
            .frame(height: 18)

            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .frame(width: 16)
                Text(viewModel.statusText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if viewModel.pendingCopy != nil {
                    Button("Cancel", action: viewModel.cancelCopy)
                        .controlSize(.small)
                    Button("Copy", action: viewModel.confirmCopy)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(viewModel.usesOpenAI ? "AI" : "LOCAL")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(viewModel.usesOpenAI ? Color.purple : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((viewModel.usesOpenAI ? Color.purple : Color.secondary).opacity(0.1))
                        )
                }
            }

            VStack(spacing: 4) {
                scanProgressRow(
                    title: "Email index",
                    progress: indexController.progress,
                    color: indexController.progress.isFinished ? .secondary : .orange
                )
                scanProgressRow(
                    title: "Full content scan",
                    progress: indexController.fullContentProgress,
                    color: indexController.fullContentProgress.isFinished ? .secondary : .purple
                )
            }

            HStack(spacing: 6) {
                Spacer(minLength: 24)
                Circle()
                    .fill(indexController.isAvailable ? Color.secondary.opacity(0.55) : Color.orange)
                    .frame(width: 5, height: 5)
                Text(scanDiagnosticText)
                    .font(.system(size: 9.5, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(scanDiagnosticText)
            }
            .frame(height: 12)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .frame(minWidth: 660, idealWidth: 720, maxWidth: 720)
            .frame(maxWidth: .infinity)

            if let gallery = viewModel.displayedGallery {
                Divider()
                MailImageGalleryView(
                    gallery: gallery,
                    indexController: indexController,
                    downloadManager: downloadManager,
                    showParasiteImages: Binding(
                        get: { viewModel.showParasiteImages },
                        set: viewModel.setShowParasiteImages
                    ),
                    showJunkImages: Binding(
                        get: { viewModel.showJunkImages },
                        set: viewModel.setShowJunkImages
                    ),
                    onOpenEmail: viewModel.openMessage,
                    onClose: viewModel.closeGallery
                )
                .id(gallery.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let results = viewModel.displayedResults {
                Divider()
                MailSearchResultsView(
                    results: results,
                    indexController: indexController,
                    downloadManager: downloadManager,
                    onOpenEmail: viewModel.openMessage,
                    onDownloadAttachments: viewModel.downloadAttachments,
                    onClose: viewModel.closeResults
                )
                .id(results.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 660)
        .background(.ultraThinMaterial)
        .onAppear {
            viewModel.refreshImageCorrespondents()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                promptIsFocused = true
            }
        }
        .onChange(of: imageCorrespondent) { _ in
            scheduleQuickImageRefresh()
        }
        .onChange(of: imageDirection) { _ in
            scheduleQuickImageRefresh(delayNanoseconds: 50_000_000)
        }
        .onChange(of: indexController.progress.scanned) { scanned in
            if scanned > 0 && scanned % 500 == 0 {
                viewModel.refreshImageCorrespondents()
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }

    private var quickImageControls: some View {
        HStack(spacing: 8) {
            Button {
                latestImageCount = max(1, latestImageCount - 1)
                scheduleQuickImageRefresh(delayNanoseconds: 50_000_000)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(latestImageCount <= 1 || viewModel.isWorking)
            .help("Show one fewer image")

            Button {
                viewModel.showLatestImages(
                    count: latestImageCount,
                    direction: imageDirection,
                    correspondent: imageCorrespondent
                )
            } label: {
                Text(latestImageCount == 1 ? "1 Last Image" : "\(latestImageCount) Last Images")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 104)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isWorking)
            .help("Show these images without using AI")

            Button {
                latestImageCount += 1
                scheduleQuickImageRefresh(delayNanoseconds: 50_000_000)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isWorking)
            .help("Show one more image")

            Divider()
                .frame(height: 20)

            Picker("Direction", selection: $imageDirection) {
                Text("Sent").tag(MailDirection.sent)
                Text("Received").tag(MailDirection.received)
                Text("Both").tag(MailDirection.any)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 105)
            .help("Choose sent emails, received emails, or both")

            CorrespondentComboBox(
                text: $imageCorrespondent,
                items: viewModel.imageCorrespondents,
                placeholder: "Everyone"
            )
            .frame(minWidth: 170, idealWidth: 220, maxWidth: 260, minHeight: 24, maxHeight: 24)
            .help("Type part of a name or email address")

            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    private func scheduleQuickImageRefresh(delayNanoseconds: UInt64 = 350_000_000) {
        guard viewModel.displayedGallery != nil else { return }
        quickFilterTask?.cancel()
        quickFilterTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            while viewModel.isWorking {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
            }
            viewModel.showLatestImages(
                count: latestImageCount,
                direction: imageDirection,
                correspondent: imageCorrespondent
            )
        }
    }

    private var statusSymbol: String {
        if viewModel.isWorking { return "ellipsis" }
        if viewModel.pendingCopy != nil { return "photo.stack" }
        if viewModel.statusText.localizedCaseInsensitiveContains("no ") ||
            viewModel.statusText.localizedCaseInsensitiveContains("error") ||
            viewModel.statusText.localizedCaseInsensitiveContains("unable") ||
            viewModel.statusText.localizedCaseInsensitiveContains("could not") ||
            viewModel.statusText.localizedCaseInsensitiveContains("failed") {
            return "exclamationmark.circle"
        }
        return "checkmark.circle"
    }

    private var statusColor: Color {
        statusSymbol == "exclamationmark.circle" ? .orange : .secondary
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { viewModel.prompt },
            set: viewModel.updatePrompt
        )
    }

    private var scanDiagnosticText: String {
        indexController.scanActivityText + " · Last issue: " + indexController.lastScanErrorText
    }

    private func scanProgressRow(
        title: String,
        progress: MailScanProgress,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .trailing)
            Text(scanCountText(progress))
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(minWidth: 172, alignment: .trailing)
        }
        .help(progress.isFinished
            ? "This scan is complete."
            : "This scan is not finished — results may be incomplete.")
    }

    private func scanCountText(_ progress: MailScanProgress) -> String {
        let totalText = progress.total == 0 ? "—" : progress.total.formatted()
        let base = "\(progress.scanned.formatted()) / \(totalText)"
        return progress.failures > 0 ? "\(base) · \(progress.failures.formatted()) skipped" : base
    }

    private var historySuggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recent searches")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 26)

            ForEach(viewModel.historySuggestions, id: \.self) { request in
                Button {
                    viewModel.chooseHistory(request)
                    promptIsFocused = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(request)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            }
        }
        .padding(.leading, 34)
        .padding(.trailing, 76)
    }
}

private struct CorrespondentComboBox: NSViewRepresentable {
    @Binding var text: String
    let items: [String]
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.delegate = context.coordinator
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.numberOfVisibleItems = 12
        comboBox.placeholderString = placeholder
        comboBox.font = .systemFont(ofSize: 12)
        comboBox.controlSize = .small
        comboBox.addItems(withObjectValues: items)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        let existing = comboBox.objectValues.compactMap { $0 as? String }
        if existing != items {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: items)
        }
        if comboBox.currentEditor() == nil && comboBox.stringValue != text {
            comboBox.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text = comboBox.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else { return }
            text = comboBox.stringValue
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Artificial Intelligence")
                        .font(.title2.weight(.semibold))
                    Text("Your key is stored privately on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Form {
                Toggle(
                    "Use OpenAI to understand searches",
                    isOn: Binding(
                        get: { viewModel.usesOpenAI },
                        set: viewModel.setAIInterpretation
                    )
                )
                SecureField("OpenAI API key", text: $viewModel.APIKeyDraft)
                TextField("Model", text: $viewModel.modelDraft)
            }
            .formStyle(.grouped)

            Text("When AI is on, only your prompt and the current date are sent to OpenAI. When it is off, interpretation stays local. Email contents always stay on this Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: viewModel.saveSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 330)
    }
}
