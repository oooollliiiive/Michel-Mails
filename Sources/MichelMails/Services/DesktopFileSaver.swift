import Foundation

struct DesktopSaveResult: Equatable, Sendable {
    let savedURLs: [URL]
    let duplicateCount: Int
    let incompleteCount: Int
}

enum DesktopFileSaver {
    static func save(
        _ items: [MailImageItem],
        to directory: URL
    ) throws -> DesktopSaveResult {
        let manager = FileManager.default
        var savedURLs: [URL] = []
        var duplicateCount = 0
        var incompleteCount = 0

        for item in items {
            let fileName = safeFileName(item.displayName)
            let proposedURL = directory.appendingPathComponent(fileName)
            let sourceValues = try item.cachedURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            let sourceSize = Int64(sourceValues.fileSize ?? 0)
            guard item.hasOriginalFile,
                  sourceSize > 0,
                  item.sourceCandidate.map({ candidate in
                      AttachmentMaterializer.isCompleteFile(
                          at: item.cachedURL,
                          candidate: candidate
                      )
                  }) ?? true else {
                incompleteCount += 1
                continue
            }
            let referenceDate = item.message.receivedAt ?? sourceValues.contentModificationDate
            let sourceIdentity = item.sourceCandidate?.sourceIdentity

            if let duplicateURL = duplicateURL(
                at: proposedURL,
                in: directory,
                expectedSize: sourceSize,
                expectedDate: referenceDate,
                expectedSourceIdentity: sourceIdentity
            ) {
                try FinderTagger.addFromEmailTag(to: duplicateURL)
                try EmailDownloadMetadata.markDownloaded(
                    duplicateURL,
                    emailReceivedAt: referenceDate,
                    sourceIdentity: sourceIdentity
                )
                duplicateCount += 1
                continue
            }

            let destination = availableURL(for: proposedURL)
            try manager.copyItem(at: item.cachedURL, to: destination)
            try FinderTagger.addFromEmailTag(to: destination)
            try EmailDownloadMetadata.markDownloaded(
                destination,
                emailReceivedAt: referenceDate,
                sourceIdentity: sourceIdentity
            )
            savedURLs.append(destination)
        }

        return DesktopSaveResult(
            savedURLs: savedURLs,
            duplicateCount: duplicateCount,
            incompleteCount: incompleteCount
        )
    }

    static func isDuplicate(
        at URL: URL,
        expectedSize: Int64,
        expectedDate: Date?,
        expectedSourceIdentity: String? = nil
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: URL.path),
              let values = try? URL.resourceValues(
                  forKeys: [.fileSizeKey, .contentModificationDateKey]
              ),
              Int64(values.fileSize ?? -1) == expectedSize else {
            return false
        }

        if let expectedSourceIdentity, !expectedSourceIdentity.isEmpty,
           let storedIdentity = EmailDownloadMetadata.sourceIdentity(for: URL) {
            if storedIdentity == expectedSourceIdentity { return true }
        }

        guard let expectedDate else { return true }
        let storedEmailDate = EmailDownloadMetadata.emailReceivedAt(for: URL)
            ?? values.contentModificationDate
        guard let storedEmailDate else { return false }
        // APFS stores sub-second dates, while email indexes can round to a
        // whole second. Treat those representations as the same date.
        return abs(storedEmailDate.timeIntervalSince(expectedDate)) < 1.1
    }

    static func duplicateURL(
        at proposedURL: URL,
        in directory: URL,
        expectedSize: Int64,
        expectedDate: Date?,
        expectedSourceIdentity: String?
    ) -> URL? {
        if isDuplicate(
            at: proposedURL,
            expectedSize: expectedSize,
            expectedDate: expectedDate,
            expectedSourceIdentity: expectedSourceIdentity
        ) {
            return proposedURL
        }
        guard let expectedSourceIdentity, !expectedSourceIdentity.isEmpty,
              let URLs = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else { return nil }
        return URLs.first { candidate in
            guard candidate != proposedURL,
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  Int64(values.fileSize ?? -1) == expectedSize else { return false }
            return EmailDownloadMetadata.sourceIdentity(for: candidate) == expectedSourceIdentity
        }
    }

    private static func safeFileName(_ value: String) -> String {
        let lastComponent = URL(fileURLWithPath: value).lastPathComponent
        let cleaned = lastComponent
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "Untitled file" : String(cleaned.prefix(180))
    }

    private static func availableURL(for proposedURL: URL) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else { return proposedURL }

        let extensionName = proposedURL.pathExtension
        let stem = proposedURL.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let candidateName = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            let candidate = proposedURL.deletingLastPathComponent().appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }
}

enum FinderTagger {
    static let fromEmail = "From Email"

    static func addFromEmailTag(to fileURL: URL) throws {
        let existingTags = try fileURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
        guard !existingTags.contains(fromEmail) else { return }
        try (fileURL as NSURL).setResourceValue(
            existingTags + [fromEmail],
            forKey: .tagNamesKey
        )
    }
}
