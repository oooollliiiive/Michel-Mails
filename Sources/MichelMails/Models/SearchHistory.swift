import Foundation

struct SearchHistory {
    static let maximumEntries = 10

    static func adding(_ request: String, to entries: [String]) -> [String] {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }

        let deduplicated = entries.filter {
            $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
        }
        return Array(([trimmed] + deduplicated).prefix(maximumEntries))
    }

    static func suggestions(for input: String, in entries: [String], limit: Int = 5) -> [String] {
        let needle = normalized(input)
        guard !needle.isEmpty else { return [] }

        return Array(entries.filter { normalized($0).contains(needle) }.prefix(max(0, limit)))
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
