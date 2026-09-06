import Foundation

enum MailResultDeduplicator {
    static func messages(_ items: [MailMessageItem]) -> [MailMessageItem] {
        var orderedKeys: [String] = []
        var groups: [String: [MailMessageItem]] = [:]
        for item in items {
            let key = logicalMessageKey(
                reference: item.reference,
                sender: item.sender,
                subject: item.subject,
                receivedAt: item.receivedAt
            )
            if groups[key] == nil { orderedKeys.append(key) }
            groups[key, default: []].append(item)
        }

        return orderedKeys.compactMap { key in
            groups[key]?.max { messageScore($0) < messageScore($1) }
        }
    }

    static func attachments(
        _ candidates: [IndexedMailAttachmentCandidate]
    ) -> [IndexedMailAttachmentCandidate] {
        var orderedKeys: [String] = []
        var groups: [String: [String: [IndexedMailAttachmentCandidate]]] = [:]

        for candidate in candidates where isPlausible(candidate) {
            let messageKey = logicalMessageKey(candidate)
            if groups[messageKey] == nil { orderedKeys.append(messageKey) }
            let variantKey = candidate.message.reference.stableKey
            groups[messageKey, default: [:]][variantKey, default: []].append(candidate)
        }

        return orderedKeys.reduce(into: [IndexedMailAttachmentCandidate]()) { result, messageKey in
            guard let variants = groups[messageKey],
                  let best = variants.values.max(by: { attachmentScore($0) < attachmentScore($1) }) else {
                return
            }
            result.append(contentsOf: best)
        }
    }

    static func logicalMessageKey(_ candidate: IndexedMailAttachmentCandidate) -> String {
        logicalMessageKey(
            reference: candidate.message.reference,
            sender: candidate.sender,
            subject: candidate.subject,
            receivedAt: candidate.receivedAt
        )
    }

    static func isPlausible(_ candidate: IndexedMailAttachmentCandidate) -> Bool {
        let name = candidate.attachmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUnclosedQuote = name.hasPrefix("\"") && !name.dropFirst().contains("\"")
        return !(candidate.sizeBytes == 0 && hasUnclosedQuote)
    }

    private static func logicalMessageKey(
        reference: MailMessageReference,
        sender: String,
        subject: String,
        receivedAt: Date?
    ) -> String {
        guard let receivedAt else { return reference.stableKey }
        return [
            normalized(sender),
            normalized(subject),
            String(Int64(receivedAt.timeIntervalSince1970.rounded()))
        ].joined(separator: "|")
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attachmentScore(
        _ candidates: [IndexedMailAttachmentCandidate]
    ) -> Int {
        let locallyAvailable = candidates.filter { !$0.sourcePath.isEmpty }.count
        let completeMetadata = candidates.filter { $0.sizeBytes > 0 }.count
        let messageSource = candidates.first?.messageSourcePath.isEmpty == false ? 1 : 0
        let RFCIdentifier = candidates.first?.messageIdentifier.contains("@") == true ? 1 : 0
        return (locallyAvailable * 10_000)
            + (messageSource * 1_000)
            + (completeMetadata * 100)
            + (candidates.count * 10)
            + RFCIdentifier
    }

    private static func messageScore(_ item: MailMessageItem) -> Int {
        let locallyAvailable = item.attachments.filter { !$0.sourcePath.isEmpty }.count
        let completeMetadata = item.attachments.filter { $0.sizeBytes > 0 }.count
        let messageSource = item.reference.sourcePath.isEmpty ? 0 : 1
        let RFCIdentifier = item.reference.messageIdentifier.contains("@") ? 1 : 0
        return (locallyAvailable * 10_000)
            + (messageSource * 1_000)
            + (completeMetadata * 100)
            + (item.attachments.count * 10)
            + RFCIdentifier
    }
}
