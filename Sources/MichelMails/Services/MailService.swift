import AppKit
import Darwin
import Foundation
import ImageIO

@MainActor
final class MailService {
    private let contactResolver = ContactResolver()

    func resolvingSender(in query: MailQuery) async throws -> MailQuery {
        guard let requested = query.sender, !requested.isEmpty else { return query }
        var resolved = query

        if let contact = await contactResolver.resolve(requested) {
            resolved.sender = contact
            return resolved
        }

        let name = requested.components(separatedBy: "<").first ?? requested
        let firstToken = name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .first
            .map(String.init) ?? requested
        if firstToken.count >= 4 {
            resolved.sender = String(firstToken.dropLast())
        }
        return resolved
    }

    func galleryImages(
        _ query: MailQuery,
        candidates: [IndexedMailAttachmentCandidate]
    ) async throws -> MailImageGallery {
        var imageQuery = query
        imageQuery.hasImage = true
        imageQuery.hasAttachment = true
        if imageQuery.attachmentKinds.isEmpty {
            imageQuery.attachmentKinds = [.image]
        }
        return try await galleryFiles(imageQuery, candidates: candidates)
    }

    func galleryFiles(
        _ query: MailQuery,
        candidates: [IndexedMailAttachmentCandidate]
    ) async throws -> MailImageGallery {
        var fileQuery = query
        fileQuery.hasAttachment = true

        let cacheDirectory = try prepareGalleryCache()
        var items: [MailImageItem] = []
        let indexedCandidates = Array(candidates.enumerated())
        for chunkStart in stride(from: 0, to: indexedCandidates.count, by: 12) {
            let chunkEnd = min(chunkStart + 12, indexedCandidates.count)
            let chunk = Array(indexedCandidates[chunkStart..<chunkEnd])
            let chunkItems = await withTaskGroup(
                of: (Int, MailImageItem?).self,
                returning: [(Int, MailImageItem?)].self
            ) { group in
                for (offset, candidate) in chunk {
                    group.addTask { @MainActor in
                        let targetURL = cacheDirectory.appendingPathComponent(
                            Self.cacheFileName(for: candidate, position: offset + 1)
                        )
                        guard await Self.extract(candidate, to: targetURL) else {
                            return (offset, nil)
                        }
                        let item = MailImageItem(
                            cachedURL: targetURL,
                            displayName: candidate.attachmentName.isEmpty
                                ? "Untitled file"
                                : candidate.attachmentName,
                            MIMEType: candidate.MIMEType,
                            kind: candidate.kind,
                            message: candidate.message
                        )
                        guard item.kind != .image || Self.isUsefulVisualAttachment(at: targetURL) else {
                            return (offset, nil)
                        }
                        return (offset, item)
                    }
                }
                var results: [(Int, MailImageItem?)] = []
                for await result in group { results.append(result) }
                return results
            }
            items.append(contentsOf: chunkItems.sorted { $0.0 < $1.0 }.compactMap(\.1))
        }
        return MailImageGallery(
            items: items,
            query: fileQuery,
            attemptedCount: candidates.count
        )
    }

    func copyAttachments(
        _ candidates: [IndexedMailAttachmentCandidate],
        to destination: URL
    ) async -> MailMatchSummary {
        var copiedCount = 0
        var messageKeys: Set<String> = []
        for (offset, candidate) in candidates.enumerated() {
            let requestedName = candidate.attachmentName.isEmpty ? "Untitled file" : candidate.attachmentName
            let proposedURL = destination.appendingPathComponent(requestedName)
            let targetURL = availableURL(for: proposedURL, position: offset + 1)
            if await Self.extract(candidate, to: targetURL) {
                copiedCount += 1
                messageKeys.insert(candidate.messageIdentifier + "|" + candidate.localIdentifier)
            }
        }
        return MailMatchSummary(messageCount: messageKeys.count, imageCount: copiedCount)
    }

    func openMessage(_ message: MailMessageItem) async throws {
        let output = try await Self.runAppleScript(
            Self.openMessageScript,
            arguments: [
                message.reference.messageIdentifier,
                message.reference.localIdentifier
            ]
        )
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            return
        }

        let identifier = message.reference.messageIdentifier
        if !identifier.isEmpty,
           let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
           let messageURL = URL(string: "message://\(encoded)"),
           NSWorkspace.shared.open(messageURL) {
            return
        }
        throw MichelMailsError.mail("The original email could not be opened.")
    }

    private nonisolated static func extract(
        _ candidate: IndexedMailAttachmentCandidate,
        to destination: URL
    ) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard !candidate.sourcePath.isEmpty else { return false }
            let sourceURL = URL(fileURLWithPath: candidate.sourcePath)
            do {
                let lowerName = sourceURL.lastPathComponent.lowercased()
                if candidate.attachmentIdentifier == "file" ||
                    (!lowerName.hasSuffix(".emlx") && !lowerName.hasSuffix(".partial.emlx")) {
                    try FileManager.default.copyItem(at: sourceURL, to: destination)
                } else {
                    guard let data = try DirectEmlxReader.extractAttachment(
                        identifier: candidate.attachmentIdentifier,
                        preferredName: candidate.attachmentName,
                        from: sourceURL
                    ) else { return false }
                    try data.write(to: destination, options: .atomic)
                }
                return FileManager.default.fileExists(atPath: destination.path)
            } catch {
                // Missing or malformed local attachments never block the other results.
                return false
            }
        }.value
    }

    private static func cacheFileName(
        for candidate: IndexedMailAttachmentCandidate,
        position: Int
    ) -> String {
        let originalName = candidate.attachmentName.isEmpty ? "Untitled file" : candidate.attachmentName
        let cleaned = originalName
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let limited = String((cleaned.isEmpty ? "Untitled file" : cleaned).prefix(120))
        return String(format: "%04d-%@", position, limited)
    }

    private func availableURL(for proposedURL: URL, position: Int) -> URL {
        guard FileManager.default.fileExists(atPath: proposedURL.path) else { return proposedURL }
        let extensionName = proposedURL.pathExtension
        let stem = proposedURL.deletingPathExtension().lastPathComponent
        var suffix = max(position, 2)
        while true {
            let name = extensionName.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(extensionName)"
            let candidate = proposedURL.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }

    private func prepareGalleryCache() throws -> URL {
        let cacheRoot = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("com.michelos.michelmails", isDirectory: true)
        .appendingPathComponent("Gallery", isDirectory: true)

        if FileManager.default.fileExists(atPath: cacheRoot.path) {
            try FileManager.default.removeItem(at: cacheRoot)
        }
        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )
        return cacheRoot
    }

    private static func isUsefulVisualAttachment(at URL: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(URL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0,
              height > 0 else {
            return true
        }

        let shortEdge = min(width, height)
        let longEdge = max(width, height)
        let byteCount = (try? URL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // Email signatures are usually tiny, extremely wide, or short lightweight
        // banners. Combining dimensions and bytes avoids rejecting ordinary photos.
        if longEdge < 160 || shortEdge < 64 { return false }
        if longEdge / shortEdge > 10 { return false }
        if height < 180 && width < 1_000 && byteCount < 100_000 { return false }
        return true
    }

    private static func runAppleScript(
        _ script: String,
        arguments: [String],
        timeout: TimeInterval = 20
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--"] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                        if process.isRunning {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                        }
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                    throw MichelMailsError.mail(
                        "Allow Michel Mails to control Mail in System Settings › Privacy & Security › Automation."
                    )
                }
                throw MichelMailsError.mail("Apple Mail did not respond.")
            }
            return output
        }.value
    }

    private static let openMessageScript = #"""
    on run argv
        set targetMessageIdentifier to item 1 of argv
        set targetLocalIdentifier to item 2 of argv

        tell application "Mail"
            activate
            if (count of message viewers) is 0 then return "0"
            set targetViewer to message viewer 1
            repeat with aMessage in visible messages of targetViewer
                set isMatch to false
                if targetMessageIdentifier is not "" then
                    try
                        set isMatch to (message id of aMessage as text) is targetMessageIdentifier
                    end try
                end if
                if not isMatch and targetLocalIdentifier is not "" then
                    try
                        set isMatch to (id of aMessage as text) is targetLocalIdentifier
                    end try
                end if
                if isMatch then
                    try
                        open contents of aMessage
                    on error
                        set selected messages of targetViewer to {contents of aMessage}
                    end try
                    return "1"
                end if
            end repeat
        end tell
        return "0"
    end run
    """#

    private static let backgroundAttachmentScript = #"""
    on run argv
        tell application "Mail" to launch
        set targetAccountName to item 1 of argv
        set targetMailboxName to item 2 of argv
        set targetMessageIdentifier to item 3 of argv
        set targetLocalIdentifier to item 4 of argv
        set targetAttachmentIdentifier to item 5 of argv
        set targetAttachmentName to item 6 of argv
        set destinationPath to item 7 of argv

        tell application "Mail"
            set accountCandidates to every account
            repeat with anAccount in accountCandidates
                set accountMatches to targetAccountName is ""
                try
                    set accountMatches to accountMatches or ((name of anAccount as text) is targetAccountName)
                end try
                if accountMatches then
                    set mailboxCandidates to my flattenedMailboxes(contents of anAccount)
                    repeat with aMailbox in mailboxCandidates
                        set mailboxMatches to targetMailboxName is ""
                        try
                            set mailboxMatches to mailboxMatches or ((name of aMailbox as text) is targetMailboxName)
                        end try
                        if mailboxMatches and my saveMatchingAttachment(contents of aMailbox, targetMessageIdentifier, targetLocalIdentifier, targetAttachmentIdentifier, targetAttachmentName, destinationPath) then return "1"
                    end repeat
                end if
            end repeat

            -- The message may have moved since it was indexed. Fall back to all
            -- mailboxes without ever activating Mail or opening a viewer.
            repeat with anAccount in accountCandidates
                set mailboxCandidates to my flattenedMailboxes(contents of anAccount)
                repeat with aMailbox in mailboxCandidates
                    if my saveMatchingAttachment(contents of aMailbox, targetMessageIdentifier, targetLocalIdentifier, targetAttachmentIdentifier, targetAttachmentName, destinationPath) then return "1"
                end repeat
            end repeat
        end tell
        return "0"
    end run

    on saveMatchingAttachment(aMailbox, targetMessageIdentifier, targetLocalIdentifier, targetAttachmentIdentifier, targetAttachmentName, destinationPath)
        tell application "Mail"
            set messageCandidates to {}
            if targetLocalIdentifier is not "" then
                try
                    set localNumber to targetLocalIdentifier as integer
                    set messageCandidates to every message of aMailbox whose id is localNumber
                end try
            end if
            if (count of messageCandidates) is 0 and targetMessageIdentifier is not "" then
                try
                    set messageCandidates to every message of aMailbox whose message id is targetMessageIdentifier
                end try
            end if

            repeat with aMessage in messageCandidates
                try
                    repeat with anAttachment in every mail attachment of aMessage
                        set attachmentMatches to false
                        if targetAttachmentIdentifier is not "" then
                            try
                                set attachmentMatches to (id of anAttachment as text) is targetAttachmentIdentifier
                            end try
                        end if
                        if not attachmentMatches and targetAttachmentName is not "" then
                            try
                                set attachmentMatches to (name of anAttachment as text) is targetAttachmentName
                            end try
                        end if
                        if attachmentMatches then
                            save anAttachment in POSIX file destinationPath
                            return true
                        end if
                    end repeat
                end try
            end repeat
        end tell
        return false
    end saveMatchingAttachment

    on flattenedMailboxes(aContainer)
        set collectedMailboxes to {}
        tell application "Mail"
            try
                repeat with aMailbox in every mailbox of aContainer
                    set end of collectedMailboxes to contents of aMailbox
                    try
                        set collectedMailboxes to collectedMailboxes & my flattenedMailboxes(contents of aMailbox)
                    end try
                end repeat
            end try
        end tell
        return collectedMailboxes
    end flattenedMailboxes
    """#

    private static let filterScript = #"""
    on run argv
        set operationMode to item 1 of argv
        set startAge to (item 2 of argv) as integer
        set endAge to (item 3 of argv) as integer
        set needsAttachment to (item 4 of argv) is "true"
        set needsImage to (item 5 of argv) is "true"
        set maximumResults to (item 6 of argv) as integer
        set destinationFolder to item 7 of argv
        set directionMode to item 8 of argv
        set attachmentKindsText to item 9 of argv
        set sortOrderText to item 10 of argv
        set unitSeparator to ASCII character 31
        set recordSeparator to ASCII character 30

        if startAge < 0 then
            set startCutoff to missing value
        else
            set startCutoff to (current date) - startAge
        end if
        if endAge < 0 then
            set endCutoff to missing value
        else
            set endCutoff to (current date) - endAge
        end if

        set resultRows to {}
        set imageRows to {}
        set matchedCount to 0
        set imageCount to 0
        set copiedCount to 0

        tell application "Mail"
            if (count of message viewers) is 0 then return "0|0"
            set targetViewer to message viewer 1
            set originalSortColumn to missing value
            set originalSortAscending to missing value
            try
                set originalSortColumn to sort column of targetViewer
                set originalSortAscending to sorted ascending of targetViewer
                set sort column of targetViewer to date received column
                set sorted ascending of targetViewer to (sortOrderText is "oldest_first")
            end try
            set candidates to visible messages of targetViewer

            repeat with aMessage in candidates
                if my messageMatches(aMessage, startCutoff, endCutoff, needsAttachment, needsImage, directionMode) then
                    set matchedCount to matchedCount + 1
                    set usefulImages to my usefulImageAttachments(aMessage)
                    set imageCount to imageCount + (count of usefulImages)
                    set galleryAttachments to usefulImages
                    if operationMode is "gallery_files" then
                        set galleryAttachments to my usefulFileAttachments(aMessage, attachmentKindsText)
                    end if

                    if operationMode is "list_messages" then
                        set end of resultRows to my messageRow(aMessage, unitSeparator, recordSeparator)
                    else if operationMode is "copy_images" then
                        repeat with anAttachment in usefulImages
                            try
                                set copiedCount to copiedCount + 1
                                set safeSubject to my safeFileName(subject of aMessage)
                                set safeAttachmentName to my safeFileName(name of anAttachment)
                                set targetName to my paddedNumber(copiedCount) & "-" & safeSubject & "-" & safeAttachmentName
                                save anAttachment in POSIX file (destinationFolder & "/" & targetName)
                            on error
                                set copiedCount to copiedCount - 1
                            end try
                        end repeat
                    else if operationMode is "gallery_images" or operationMode is "gallery_files" then
                        repeat with anAttachment in galleryAttachments
                            if copiedCount ≥ maximumResults then exit repeat
                            try
                                set copiedCount to copiedCount + 1
                                set safeSubject to my safeFileName(subject of aMessage)
                                set safeAttachmentName to my safeFileName(name of anAttachment)
                                set targetName to my paddedNumber(copiedCount) & "-" & safeSubject & "-" & safeAttachmentName
                                save anAttachment in POSIX file (destinationFolder & "/" & targetName)
                                set attachmentName to my cleanField(name of anAttachment, unitSeparator, recordSeparator)
                                set attachmentMIME to ""
                                try
                                    set attachmentMIME to my cleanField(MIME type of anAttachment, unitSeparator, recordSeparator)
                                end try
                                set messageData to my messageRow(aMessage, unitSeparator, recordSeparator)
                                set end of imageRows to my cleanField(targetName, unitSeparator, recordSeparator) & unitSeparator & attachmentName & unitSeparator & attachmentMIME & unitSeparator & messageData
                            on error
                                set copiedCount to copiedCount - 1
                            end try
                        end repeat
                    end if
                end if
                if operationMode is "list_messages" and (count of resultRows) ≥ maximumResults then exit repeat
                if (operationMode is "gallery_images" or operationMode is "gallery_files") and copiedCount ≥ maximumResults then exit repeat
                if (operationMode is "copy_images" or operationMode is "count_images") and matchedCount ≥ maximumResults then exit repeat
            end repeat

            if originalSortColumn is not missing value then
                try
                    set sort column of targetViewer to originalSortColumn
                    set sorted ascending of targetViewer to originalSortAscending
                end try
            end if
        end tell

        if operationMode is "list_messages" then
            return my joinRows(resultRows, recordSeparator)
        else if operationMode is "gallery_images" or operationMode is "gallery_files" then
            return my joinRows(imageRows, recordSeparator)
        else if operationMode is "copy_images" then
            return matchedCount & "|" & copiedCount
        end if
        return matchedCount & "|" & imageCount
    end run

    on messageRow(aMessage, unitSeparator, recordSeparator)
        set messageIdentifier to ""
        set localIdentifier to ""
        set senderText to ""
        set subjectText to ""
        set previewText to ""
        set receivedText to ""

        tell application "Mail"
            try
                set messageIdentifier to message id of aMessage as text
            end try
            try
                set localIdentifier to id of aMessage as text
            end try
            try
                set senderText to sender of aMessage as text
            end try
            try
                set subjectText to subject of aMessage as text
            end try
            try
                set previewText to content of aMessage as text
            end try
            try
                set receivedText to my ISODateText(date received of aMessage)
            end try
        end tell

        set senderText to my cleanField(senderText, unitSeparator, recordSeparator)
        set subjectText to my cleanField(subjectText, unitSeparator, recordSeparator)
        set previewText to my cleanField(previewText, unitSeparator, recordSeparator)
        if (count of previewText) > 240 then set previewText to text 1 thru 240 of previewText & "…"
        return my cleanField(messageIdentifier, unitSeparator, recordSeparator) & unitSeparator & my cleanField(localIdentifier, unitSeparator, recordSeparator) & unitSeparator & senderText & unitSeparator & subjectText & unitSeparator & previewText & unitSeparator & receivedText
    end messageRow

    on ISODateText(aDate)
        set yearText to year of aDate as integer as text
        set monthText to my paddedPair(month of aDate as integer)
        set dayText to my paddedPair(day of aDate as integer)
        set hourText to my paddedPair(hours of aDate as integer)
        set minuteText to my paddedPair(minutes of aDate as integer)
        set secondText to my paddedPair(seconds of aDate as integer)
        return yearText & "-" & monthText & "-" & dayText & "T" & hourText & ":" & minuteText & ":" & secondText
    end ISODateText

    on paddedPair(valueNumber)
        if valueNumber < 10 then return "0" & (valueNumber as text)
        return valueNumber as text
    end paddedPair

    on cleanField(sourceText, unitSeparator, recordSeparator)
        if sourceText is missing value then return ""
        set cleaned to sourceText as text
        repeat with invalidCharacter in {unitSeparator, recordSeparator, return, linefeed, tab}
            set cleaned to my replaceText(cleaned, contents of invalidCharacter, " ")
        end repeat
        repeat while cleaned contains "  "
            set cleaned to my replaceText(cleaned, "  ", " ")
        end repeat
        return cleaned
    end cleanField

    on joinRows(rowsToJoin, recordSeparator)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to recordSeparator
        set joined to rowsToJoin as text
        set AppleScript's text item delimiters to previousDelimiters
        return joined
    end joinRows

    on messageMatches(aMessage, startCutoff, endCutoff, needsAttachment, needsImage, directionMode)
        tell application "Mail"
            try
                set receivedAt to date received of aMessage
                if startCutoff is not missing value and receivedAt < startCutoff then return false
                if endCutoff is not missing value and receivedAt ≥ endCutoff then return false
                if directionMode is "received" and my messageLooksSent(aMessage) then return false
                if directionMode is "sent" and not my messageLooksSent(aMessage) then return false

                set attachmentList to every mail attachment of aMessage
                if needsAttachment and (count of attachmentList) is 0 then return false
                if needsImage and (count of my usefulImageAttachments(aMessage)) is 0 then return false
                return true
            on error
                return false
            end try
        end tell
    end messageMatches

    on messageLooksSent(aMessage)
        tell application "Mail"
            try
                set senderText to sender of aMessage as text
                repeat with anAccount in every account
                    try
                        repeat with accountAddress in email addresses of anAccount
                            ignoring case
                                if senderText contains (accountAddress as text) then return true
                            end ignoring
                        end repeat
                    end try
                end repeat
            end try

            try
                set mailboxName to name of mailbox of aMessage as text
                ignoring case
                    if mailboxName contains "sent" or mailboxName contains "envoy" or mailboxName contains "gesendet" or mailboxName contains "inviati" or mailboxName contains "enviados" then return true
                end ignoring
            end try
        end tell
        return false
    end messageLooksSent

    on usefulImageAttachments(aMessage)
        set imageAttachments to {}
        tell application "Mail"
            try
                repeat with anAttachment in every mail attachment of aMessage
                    set MIMEText to ""
                    set attachmentName to ""
                    set attachmentSize to 0
                    try
                        set MIMEText to MIME type of anAttachment
                    end try
                    try
                        set attachmentName to name of anAttachment
                    end try
                    try
                        set attachmentSize to file size of anAttachment
                    end try

                    ignoring case
                        set looksLikeImage to MIMEText starts with "image/" or attachmentName ends with ".jpg" or attachmentName ends with ".jpeg" or attachmentName ends with ".png" or attachmentName ends with ".heic" or attachmentName ends with ".gif" or attachmentName ends with ".webp"
                        set looksLikeDecoration to attachmentName contains "signature" or attachmentName contains "logo" or attachmentName contains "spacer" or attachmentName contains "tracking" or attachmentName contains "icon"
                    end ignoring

                    if looksLikeImage and not looksLikeDecoration and attachmentSize ≥ 5000 then
                        set end of imageAttachments to contents of anAttachment
                    end if
                end repeat
            end try
        end tell
        return imageAttachments
    end usefulImageAttachments

    on usefulFileAttachments(aMessage, attachmentKindsText)
        set selectedAttachments to {}
        tell application "Mail"
            try
                repeat with anAttachment in every mail attachment of aMessage
                    set attachmentName to ""
                    set MIMEText to ""
                    set attachmentSize to 0
                    try
                        set attachmentName to name of anAttachment as text
                    end try
                    try
                        set MIMEText to MIME type of anAttachment as text
                    end try
                    try
                        set attachmentSize to file size of anAttachment
                    end try

                    set attachmentKind to my fileKind(attachmentName, MIMEText)
                    ignoring case
                        set looksLikeDecoration to attachmentName contains "signature" or attachmentName contains "logo" or attachmentName contains "spacer" or attachmentName contains "tracking" or attachmentName contains "icon"
                    end ignoring
                    set requestedKind to attachmentKindsText is "" or ("," & attachmentKindsText & ",") contains ("," & attachmentKind & ",")
                    set usefulFile to not looksLikeDecoration and attachmentSize > 0
                    if attachmentKind is "image" and attachmentSize < 5000 then set usefulFile to false

                    if requestedKind and usefulFile then set end of selectedAttachments to contents of anAttachment
                end repeat
            end try
        end tell
        return selectedAttachments
    end usefulFileAttachments

    on fileKind(attachmentName, MIMEText)
        ignoring case
            if MIMEText starts with "image/" or attachmentName ends with ".jpg" or attachmentName ends with ".jpeg" or attachmentName ends with ".png" or attachmentName ends with ".heic" or attachmentName ends with ".gif" or attachmentName ends with ".webp" or attachmentName ends with ".tif" or attachmentName ends with ".tiff" then return "image"
            if MIMEText is "application/pdf" or attachmentName ends with ".pdf" then return "pdf"
            if attachmentName ends with ".doc" or attachmentName ends with ".docx" or attachmentName ends with ".rtf" or attachmentName ends with ".txt" or attachmentName ends with ".pages" then return "document"
            if attachmentName ends with ".xls" or attachmentName ends with ".xlsx" or attachmentName ends with ".csv" or attachmentName ends with ".numbers" then return "spreadsheet"
            if attachmentName ends with ".ppt" or attachmentName ends with ".pptx" or attachmentName ends with ".key" then return "presentation"
            if attachmentName ends with ".zip" or attachmentName ends with ".rar" or attachmentName ends with ".7z" or attachmentName ends with ".tar" or attachmentName ends with ".gz" then return "archive"
            if MIMEText starts with "audio/" then return "audio"
            if MIMEText starts with "video/" then return "video"
        end ignoring
        return "other"
    end fileKind

    on safeFileName(sourceText)
        if sourceText is missing value or sourceText is "" then set sourceText to "file"
        set invalidCharacters to {"/", ":", return, linefeed, tab}
        set cleaned to sourceText as text
        repeat with invalidCharacter in invalidCharacters
            set cleaned to my replaceText(cleaned, contents of invalidCharacter, "-")
        end repeat
        if (count of cleaned) > 80 then set cleaned to text 1 thru 80 of cleaned
        return cleaned
    end safeFileName

    on replaceText(sourceText, searchText, replacementText)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to searchText
        set pieces to every text item of sourceText
        set AppleScript's text item delimiters to replacementText
        set joined to pieces as text
        set AppleScript's text item delimiters to previousDelimiters
        return joined
    end replaceText

    on paddedNumber(valueNumber)
        set valueText to valueNumber as text
        repeat while (count of valueText) < 4
            set valueText to "0" & valueText
        end repeat
        return valueText
    end paddedNumber
    """#
}
