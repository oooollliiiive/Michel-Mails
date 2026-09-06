import Foundation

enum MailAttachmentIdentity {
    static func sourceIdentity(for candidate: IndexedMailAttachmentCandidate) -> String {
        let rawMessageIdentifier = candidate.messageIdentifier
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
        let messageIdentity: String
        if rawMessageIdentifier.contains("@") {
            messageIdentity = "message-id:\(rawMessageIdentifier.lowercased())"
        } else {
            let timestamp = candidate.receivedAt.map {
                String(Int64($0.timeIntervalSince1970.rounded()))
            } ?? "unknown-date"
            messageIdentity = [
                "message",
                canonicalText(candidate.sender),
                canonicalText(candidate.subject),
                timestamp
            ].joined(separator: "|")
        }

        let attachmentIdentity = canonicalMIMEPartIdentifier(for: candidate)
            .map { "part:\($0)" }
            ?? "file:\(candidate.attachmentIdentifier)|\(canonicalFileName(candidate.attachmentName))|\(candidate.sizeBytes)"
        return "\(messageIdentity)|\(attachmentIdentity)"
    }

    static func canonicalMIMEPartIdentifier(
        for candidate: IndexedMailAttachmentCandidate
    ) -> String? {
        if let identifier = canonicalMIMEPartIdentifier(candidate.attachmentIdentifier) {
            return identifier
        }
        guard !candidate.sourcePath.isEmpty else { return nil }
        let parent = URL(fileURLWithPath: candidate.sourcePath)
            .deletingLastPathComponent()
            .lastPathComponent
        return canonicalMIMEPartIdentifier(parent)
    }

    static func canonicalMIMEPartIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        // DirectEmlxReader numbers the MIME root as 1. Mail's Attachments
        // directory starts below that root (2.2 -> 1.2.2).
        if components.first == "1" { return components.joined(separator: ".") }
        return (["1"] + components.map(String.init)).joined(separator: ".")
    }

    static func canonicalFileName(_ value: String) -> String {
        value
            .precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func senderAddress(in value: String) -> String {
        if let start = value.lastIndex(of: "<"),
           let end = value[start...].firstIndex(of: ">"),
           start < end {
            return String(value[value.index(after: start)..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
        return value
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .first(where: { $0.contains("@") })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
            .lowercased() ?? ""
    }

    static func mailDateArguments(_ date: Date?) -> [String] {
        guard let date else { return Array(repeating: "0", count: 5) }
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        return [components.year, components.month, components.day, components.hour, components.minute]
            .map { String($0 ?? 0) }
    }

    private static func canonicalText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9@]+", with: "", options: .regularExpression)
    }
}
