import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var indexController: MailIndexController
    @FocusState private var promptIsFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
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
            }

            if viewModel.historyIsVisible {
                historySuggestions
            }

            HStack(spacing: 7) {
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

                if indexController.isAvailable {
                    Text(indexController.progress.statusText)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(indexController.progress.isFinished ? Color.secondary : Color.orange)
                        .lineLimit(1)
                        .help(indexController.progress.isFinished
                            ? "Email scan complete"
                            : "Email scan not finished — results may be incomplete")
                } else {
                    Text("Email scan reconnecting…")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

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
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(minWidth: 660, idealWidth: 720, maxWidth: 720)
        .background(.ultraThinMaterial)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                promptIsFocused = true
            }
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsView(viewModel: viewModel)
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
                SecureField("OpenAI API key", text: $viewModel.APIKeyDraft)
                TextField("Model", text: $viewModel.modelDraft)
            }
            .formStyle(.grouped)

            Text("Only your prompt and the current date are sent to OpenAI. Email contents stay on this Mac.")
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
        .frame(width: 500, height: 290)
    }
}
