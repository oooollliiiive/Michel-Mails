import SwiftUI

struct MailSearchResultsView: View {
    let results: MailSearchResults
    let onOpenEmail: (MailMessageItem) -> Void

    @State private var selectedID: UUID?

    private var selectedItem: MailMessageItem? {
        results.items.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
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
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()
            footer
        }
        .frame(minWidth: 680, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
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
                Text(results.items.count == 1 ? "1 email" : "\(results.items.count) emails · newest first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Open in Mail") {
                if let selectedItem { onOpenEmail(selectedItem) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedItem == nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
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
        let selected = selectedID == item.id

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 16))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
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

                Text(item.subject)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)

                if !item.preview.isEmpty {
                    Text(item.preview)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(selected ? Color.accentColor.opacity(0.09) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedID = item.id
            onOpenEmail(item)
        }
        .onTapGesture {
            selectedID = item.id
        }
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
