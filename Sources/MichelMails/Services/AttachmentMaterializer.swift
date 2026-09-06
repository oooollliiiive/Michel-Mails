import Darwin
import Foundation
import ImageIO

enum AttachmentMaterializerError: LocalizedError {
    case unavailable
    case incomplete
    case mailDidNotRespond
    case mailDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The attachment is not available locally or from Mail."
        case .incomplete:
            return "Mail returned an incomplete attachment."
        case .mailDidNotRespond:
            return "Mail did not finish downloading the attachment."
        case .mailDownloadFailed(let detail):
            return detail.isEmpty
                ? "Mail could not download the attachment."
                : "Mail could not download the attachment: \(detail)"
        }
    }
}

enum AttachmentMaterializer {
    static func directlyAvailableFile(
        for candidate: IndexedMailAttachmentCandidate
    ) -> URL? {
        guard !candidate.sourcePath.isEmpty else { return nil }
        let sourceURL = URL(fileURLWithPath: candidate.sourcePath)
        let lowerName = sourceURL.lastPathComponent.lowercased()
        guard candidate.attachmentIdentifier == "file" ||
                (!lowerName.hasSuffix(".emlx") && !lowerName.hasSuffix(".partial.emlx")),
              isCompleteFile(at: sourceURL, candidate: candidate) else {
            return nil
        }
        return sourceURL
    }

    static func materialize(
        _ candidate: IndexedMailAttachmentCandidate,
        to destination: URL,
        allowMailDownload: Bool
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if await extractLocal(candidate, to: destination),
           isCompleteFile(at: destination, candidate: candidate) {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        guard allowMailDownload else { throw AttachmentMaterializerError.unavailable }

        let output = try await runAppleScript(
            downloadScript,
            arguments: [
                candidate.accountName,
                candidate.mailboxName,
                candidate.messageIdentifier,
                candidate.localIdentifier,
                candidate.attachmentIdentifier,
                candidate.attachmentName,
                destination.path
            ],
            timeout: 75
        )
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == "1" else {
            try? FileManager.default.removeItem(at: destination)
            if result.hasPrefix("ERROR|") {
                throw AttachmentMaterializerError.mailDownloadFailed(
                    String(result.dropFirst("ERROR|".count))
                )
            }
            throw AttachmentMaterializerError.mailDidNotRespond
        }
        guard isCompleteFile(at: destination, candidate: candidate) else {
            try? FileManager.default.removeItem(at: destination)
            throw AttachmentMaterializerError.incomplete
        }
    }

    static func isCompleteFile(
        at URL: URL,
        candidate: IndexedMailAttachmentCandidate
    ) -> Bool {
        guard let values = try? URL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return false }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { return false }
        if candidate.sizeBytes > 0, size < candidate.sizeBytes { return false }

        guard candidate.kind == .image else { return true }
        if URL.pathExtension.lowercased() == "svg" {
            guard let data = try? Data(contentsOf: URL, options: [.mappedIfSafe]),
                  !data.isEmpty else { return false }
            return String(decoding: data.prefix(16_384), as: UTF8.self)
                .localizedCaseInsensitiveContains("<svg")
        }
        guard let source = CGImageSourceCreateWithURL(URL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            // Camera RAW formats are not supported by every ImageIO version.
            return true
        }
        guard CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }

    static func temporaryDestination(
        for candidate: IndexedMailAttachmentCandidate
    ) throws -> URL {
        let root = try temporaryRootDirectory()
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let extensionName = URL(fileURLWithPath: candidate.attachmentName).pathExtension
        let suffix = extensionName.isEmpty ? "" : ".\(extensionName)"
        return root.appendingPathComponent(UUID().uuidString + suffix)
    }

    static func clearTemporaryFiles() throws {
        let root = try temporaryRootDirectory()
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private static func temporaryRootDirectory() throws -> URL {
        try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("com.michelos.michelmails", isDirectory: true)
        .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static func extractLocal(
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
                    ), !data.isEmpty else { return false }
                    try data.write(to: destination, options: .atomic)
                }
                return true
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return false
            }
        }.value
    }

    private static func runAppleScript(
        _ script: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> String {
        let worker = Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, "--"] + arguments
            process.standardOutput = standardOutput
            process.standardError = standardError
            try process.run()
            defer {
                if process.isRunning { stop(process) }
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled {
                    stop(process)
                    throw CancellationError()
                }
                if Date() >= deadline {
                    stop(process)
                    throw AttachmentMaterializerError.mailDidNotRespond
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let output = String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            guard process.terminationStatus == 0 else {
                let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized") {
                    throw MichelMailsError.mail(
                        "Allow Michel Mails to control Mail in System Settings › Privacy & Security › Automation."
                    )
                }
                throw AttachmentMaterializerError.mailDidNotRespond
            }
            return output
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    static let downloadScript = #"""
    on run argv
        set targetAccountName to item 1 of argv
        set targetMailboxName to item 2 of argv
        set targetMessageIdentifier to item 3 of argv
        set targetLocalIdentifier to item 4 of argv
        set targetAttachmentIdentifier to item 5 of argv
        set targetAttachmentName to item 6 of argv
        set destinationPath to item 7 of argv

        tell application "Mail"
            set accountCandidates to every account

            -- The indexed mailbox is the fast path and avoids traversing the
            -- complete Mail library for nearly every attachment.
            if targetMailboxName is not "" then
                repeat with anAccount in accountCandidates
                    repeat with aMailbox in my flattenedMailboxes(contents of anAccount)
                        try
                            if (name of aMailbox as text) is targetMailboxName then
                                set attemptResult to my saveMatchingAttachment(contents of aMailbox, targetMessageIdentifier, targetLocalIdentifier, targetAttachmentIdentifier, targetAttachmentName, destinationPath)
                                if attemptResult is not "0" then return attemptResult
                            end if
                        end try
                    end repeat
                end repeat
            end if

            -- The message may have moved after indexing.
            repeat with anAccount in accountCandidates
                repeat with aMailbox in my flattenedMailboxes(contents of anAccount)
                    set attemptResult to my saveMatchingAttachment(contents of aMailbox, targetMessageIdentifier, targetLocalIdentifier, targetAttachmentIdentifier, targetAttachmentName, destinationPath)
                    if attemptResult is not "0" then return attemptResult
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
                        if targetAttachmentIdentifier is not "" and targetAttachmentIdentifier does not start with "index-" then
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
                            return "1"
                        end if
                    end repeat
                on error errorMessage number errorNumber
                    return "ERROR|" & errorNumber & " · " & errorMessage
                end try
            end repeat
        end tell
        return "0"
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
}
