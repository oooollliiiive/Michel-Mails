import AppKit
import ApplicationServices
import Foundation

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

    func searchAndOpen(_ query: MailQuery) async throws -> Int {
        try await performMailSearch(query)
        let output = try await Self.runAppleScript(
            Self.filterScript,
            arguments: scriptArguments(mode: "open", query: query, destination: "")
        )
        return parseSummary(output).messageCount
    }

    func countImages(_ query: MailQuery) async throws -> MailMatchSummary {
        try await performMailSearch(query)
        let output = try await Self.runAppleScript(
            Self.filterScript,
            arguments: scriptArguments(mode: "count_images", query: query, destination: "")
        )
        NSApp.activate(ignoringOtherApps: true)
        return parseSummary(output)
    }

    func galleryImages(_ query: MailQuery) async throws -> MailImageGallery {
        var imageQuery = query
        imageQuery.hasImage = true
        imageQuery.hasAttachment = true

        let cacheDirectory = try prepareGalleryCache()
        try await performMailSearch(imageQuery)
        _ = try await Self.runAppleScript(
            Self.filterScript,
            arguments: scriptArguments(
                mode: "gallery_images",
                query: imageQuery,
                destination: cacheDirectory.path
            )
        )
        NSApp.activate(ignoringOtherApps: true)

        let URLs = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let items = URLs
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(MailImageItem.init(cachedURL:))
        return MailImageGallery(items: items, query: imageQuery)
    }

    func copyImages(_ query: MailQuery, to destination: URL) async throws -> MailMatchSummary {
        try await performMailSearch(query)
        let output = try await Self.runAppleScript(
            Self.filterScript,
            arguments: scriptArguments(mode: "copy_images", query: query, destination: destination.path)
        )
        NSApp.activate(ignoringOtherApps: true)
        return parseSummary(output)
    }

    private func performMailSearch(_ query: MailQuery) async throws {
        let accessibilityOptions = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
            throw MichelMailsError.mail(
                "Autorisez Michel Mails dans Réglages Système › Confidentialité et sécurité › Accessibilité, puis relancez la recherche."
            )
        }

        let bundleIdentifier = "com.apple.mail"
        let MailApplication: NSRunningApplication
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            MailApplication = running
            running.activate(options: [.activateAllWindows])
        } else {
            let MailURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
            guard NSWorkspace.shared.open(MailURL) else {
                throw MichelMailsError.mail("Impossible d’ouvrir Apple Mail.")
            }
            try await Task.sleep(nanoseconds: 700_000_000)
            guard let launched = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first else {
                throw MichelMailsError.mail("Apple Mail ne s’est pas lancé.")
            }
            MailApplication = launched
            launched.activate(options: [.activateAllWindows])
        }

        _ = try? await Self.runAppleScript(Self.searchScopeScript, arguments: [])
        try await Task.sleep(nanoseconds: 450_000_000)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MichelMailsError.mail("Impossible de contrôler le champ de recherche de Mail.")
        }

        postCommandKey(3, source: source, processIdentifier: MailApplication.processIdentifier)
        try await Task.sleep(nanoseconds: 250_000_000)
        postCommandKey(0, source: source, processIdentifier: MailApplication.processIdentifier)
        postText(nativeSearchText(for: query), source: source, processIdentifier: MailApplication.processIdentifier)
        postKey(36, source: source, processIdentifier: MailApplication.processIdentifier)
        try await waitForMailSearchToSettle()
    }

    private func waitForMailSearchToSettle() async throws {
        try await Task.sleep(nanoseconds: 800_000_000)
        var previousCount: Int?
        var stableChecks = 0

        for _ in 0..<8 {
            let rawCount = try? await Self.runAppleScript(Self.visibleCountScript, arguments: [])
            let currentCount = rawCount.flatMap {
                Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let currentCount, currentCount == previousCount {
                stableChecks += 1
                if stableChecks >= 2 { return }
            } else {
                stableChecks = 0
                previousCount = currentCount
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func nativeSearchText(for query: MailQuery) -> String {
        var pieces: [String] = []
        if let sender = query.sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            let displayName = sender.components(separatedBy: "<").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? sender
            pieces.append(displayName.contains(" ") ? "from:\"\(displayName)\"" : "from:\(displayName)")
        }
        pieces.append(contentsOf: query.keywords.map { $0.contains(" ") ? "\"\($0)\"" : $0 })
        if pieces.isEmpty && (query.hasAttachment || query.hasImage) {
            pieces.append("attachment")
        }
        return pieces.joined(separator: " ")
    }

    private func scriptArguments(mode: String, query: MailQuery, destination: String) -> [String] {
        let now = Date()
        let startAge = query.startDate.map { max(0, Int(now.timeIntervalSince($0))) } ?? -1
        let endAge = query.endDate.map { max(0, Int(now.timeIntervalSince($0))) } ?? -1
        let effectiveLimit = query.allResults ? 100_000 : min(max(query.limit, 1), 100)
        return [
            mode,
            String(startAge),
            String(endAge),
            query.hasAttachment ? "true" : "false",
            query.hasImage ? "true" : "false",
            String(effectiveLimit),
            destination,
            query.direction.rawValue
        ]
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

    private func parseSummary(_ output: String) -> MailMatchSummary {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        return MailMatchSummary(
            messageCount: parts.first.flatMap { Int($0) } ?? 0,
            imageCount: parts.dropFirst().first.flatMap { Int($0) } ?? 0
        )
    }

    private func postCommandKey(
        _ keyCode: CGKeyCode,
        source: CGEventSource,
        processIdentifier: pid_t
    ) {
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.postToPid(processIdentifier)
        keyUp?.postToPid(processIdentifier)
    }

    private func postKey(
        _ keyCode: CGKeyCode,
        source: CGEventSource,
        processIdentifier: pid_t
    ) {
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?
            .postToPid(processIdentifier)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?
            .postToPid(processIdentifier)
    }

    private func postText(
        _ text: String,
        source: CGEventSource,
        processIdentifier: pid_t
    ) {
        let UTF16Text = Array(text.utf16)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        UTF16Text.withUnsafeBufferPointer { buffer in
            keyDown?.keyboardSetUnicodeString(
                stringLength: UTF16Text.count,
                unicodeString: buffer.baseAddress
            )
        }
        keyDown?.postToPid(processIdentifier)
        CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?
            .postToPid(processIdentifier)
    }

    private static func runAppleScript(_ script: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--"] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            try process.run()
            process.waitUntilExit()

            let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if message.contains("-1743") || message.localizedCaseInsensitiveContains("not authorized") {
                    throw MichelMailsError.mail(
                        "Autorisez Michel Mails dans Réglages Système › Confidentialité et sécurité › Automatisation."
                    )
                }
                throw MichelMailsError.mail(message.isEmpty ? "Apple Mail n’a pas répondu." : message)
            }
            return output
        }.value
    }

    private static let searchScopeScript = #"""
    tell application "Mail"
        if (count of message viewers) is 0 then return
        set searchBoxes to {}
        repeat with anAccount in every account
            try
                set searchBoxes to searchBoxes & every mailbox of anAccount
            end try
        end repeat
        if (count of searchBoxes) > 0 then
            try
                set selected mailboxes of message viewer 1 to searchBoxes
            end try
        end if
    end tell
    """#

    private static let visibleCountScript = #"""
    tell application "Mail"
        if (count of message viewers) is 0 then return 0
        return count of visible messages of message viewer 1
    end tell
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

        set matchingMessages to {}
        set matchedCount to 0
        set imageCount to 0
        set copiedCount to 0

        tell application "Mail"
            if (count of message viewers) is 0 then return "0|0"
            set targetViewer to message viewer 1
            set originalSortColumn to missing value
            set originalSortAscending to missing value
            if operationMode is "gallery_images" then
                try
                    set originalSortColumn to sort column of targetViewer
                    set originalSortAscending to sorted ascending of targetViewer
                    set sort column of targetViewer to date received column
                    set sorted ascending of targetViewer to false
                end try
            end if
            set candidates to visible messages of targetViewer

            repeat with aMessage in candidates
                if my messageMatches(aMessage, startCutoff, endCutoff, needsAttachment, needsImage, directionMode) then
                    set matchedCount to matchedCount + 1
                    set usefulImages to my usefulImageAttachments(aMessage)
                    set imageCount to imageCount + (count of usefulImages)

                    if operationMode is "open" then
                        if (count of matchingMessages) < maximumResults then
                            set end of matchingMessages to contents of aMessage
                        end if
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
                    else if operationMode is "gallery_images" then
                        repeat with anAttachment in usefulImages
                            if copiedCount ≥ maximumResults then exit repeat
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
                    end if
                end if
                if operationMode is "gallery_images" and copiedCount ≥ maximumResults then exit repeat
            end repeat

            if operationMode is "gallery_images" and originalSortColumn is not missing value then
                try
                    set sort column of targetViewer to originalSortColumn
                    set sorted ascending of targetViewer to originalSortAscending
                end try
            end if

            if operationMode is "open" and (count of matchingMessages) > 0 then
                set selected messages of targetViewer to matchingMessages
                activate
            end if
        end tell

        if operationMode is "copy_images" or operationMode is "gallery_images" then
            return matchedCount & "|" & copiedCount
        end if
        return matchedCount & "|" & imageCount
    end run

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

    on safeFileName(sourceText)
        if sourceText is missing value or sourceText is "" then set sourceText to "image"
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
