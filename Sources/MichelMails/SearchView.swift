import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
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
                    "Ex. Trouve les derniers emails de Raffi avec une photo",
                    text: $viewModel.prompt
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium))
                .focused($promptIsFocused)
                .onSubmit(viewModel.submit)
                .disabled(viewModel.isWorking)

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
                    .help("Lancer la recherche")
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
                .help("Réglages")
            }

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
                    Button("Annuler", action: viewModel.cancelCopy)
                        .controlSize(.small)
                    Button("Copier", action: viewModel.confirmCopy)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(viewModel.usesOpenAI ? "IA" : "LOCAL")
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
        if viewModel.statusText.localizedCaseInsensitiveContains("aucun") ||
            viewModel.statusText.localizedCaseInsensitiveContains("erreur") ||
            viewModel.statusText.localizedCaseInsensitiveContains("impossible") {
            return "exclamationmark.circle"
        }
        return "checkmark.circle"
    }

    private var statusColor: Color {
        statusSymbol == "exclamationmark.circle" ? .orange : .secondary
    }
}

private struct SettingsView: View {
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Intelligence artificielle")
                        .font(.title2.weight(.semibold))
                    Text("La clé est conservée dans le trousseau de ce Mac.")
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
                SecureField("Clé API OpenAI", text: $viewModel.APIKeyDraft)
                TextField("Modèle", text: $viewModel.modelDraft)
            }
            .formStyle(.grouped)

            Text("Seuls le prompt et la date courante sont envoyés à OpenAI. Le contenu des emails reste sur le Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer", action: viewModel.saveSettings)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 290)
    }
}
