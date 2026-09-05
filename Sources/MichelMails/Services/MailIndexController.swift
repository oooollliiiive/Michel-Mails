import Foundation

@MainActor
final class MailIndexController: ObservableObject {
    @Published private(set) var progress = MailScanProgress()
    @Published private(set) var isAvailable = true
    @Published private(set) var forceScanEnabled = false

    private var scanTask: Task<Void, Never>?
    private var database: MailIndexDatabase?
    private let source = MailScanSource()

    func start() {
        guard scanTask == nil else { return }
        scanTask = Task(priority: .utility) { [weak self] in
            await self?.runScan()
        }
    }

    func stop() {
        scanTask?.cancel()
        scanTask = nil
        Task { await source.cancelCurrentBatch() }
    }

    func setForceScan(_ enabled: Bool) {
        forceScanEnabled = enabled
        Task { await source.cancelCurrentBatch() }
        if enabled {
            if scanTask == nil {
                isAvailable = true
                start()
            }
        }
    }

    func searchMessages(_ query: MailQuery) async throws -> MailSearchResults? {
        guard let database, try await database.indexedMessageCount() > 0 else { return nil }
        return try await database.searchMessages(query)
    }

    func searchAttachments(_ query: MailQuery) async throws -> [IndexedMailAttachmentCandidate]? {
        guard let database, try await database.indexedMessageCount() > 0 else { return nil }
        return try await database.searchAttachments(query)
    }

    private func runScan() async {
        do {
            let database = try MailIndexDatabase()
            self.database = database
            while !Task.isCancelled {
                let total = try await source.totalMessageCount()
                var state = try await database.state(total: total)
                progress = state.progress
                var consecutiveBatchFailures = 0

                while !Task.isCancelled && !progress.isFinished {
                    do {
                        let forceScan = forceScanEnabled
                        let batch = try await source.batch(
                            from: state.cursor,
                            maximumCount: forceScan ? 20 : 6,
                            perMessageTimeout: forceScan ? 2 : 8,
                            processTimeout: forceScan ? 50 : 60
                        )
                        progress = try await database.save(batch, total: progress.total, previous: progress)
                        state.cursor = batch.nextCursor
                        consecutiveBatchFailures = 0
                    } catch {
                        consecutiveBatchFailures += 1
                        if consecutiveBatchFailures >= 1 {
                            // A broken message must never stop the queue. Advance one
                            // position after bounded retries and continue immediately.
                            let nextCursor = MailScanCursor(
                                mailboxIndex: state.cursor.mailboxIndex,
                                messageIndex: state.cursor.messageIndex + 1
                            )
                            let skipped = MailScanBatch(
                                messages: [],
                                nextCursor: nextCursor,
                                attemptedCount: 1,
                                failureCount: 1,
                                isFinished: false
                            )
                            progress = try await database.save(
                                skipped,
                                total: progress.total,
                                previous: progress
                            )
                            state.cursor = nextCursor
                            consecutiveBatchFailures = 0
                        }
                        try? await Task.sleep(nanoseconds: forceScanEnabled ? 20_000_000 : 500_000_000)
                    }

                    if !forceScanEnabled {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                    }
                }

                // Keep watching for newly arrived mail while Michel Mails stays open.
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        } catch {
            isAvailable = false
        }
        scanTask = nil
    }
}

private actor MailScanSource {
    private var currentProcess: Process?

    func cancelCurrentBatch() {
        if currentProcess?.isRunning == true {
            currentProcess?.terminate()
        }
    }

    func totalMessageCount() async throws -> Int {
        let output = try await runAppleScript(Self.totalCountScript, arguments: [])
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MichelMailsError.index("Mail did not return its message count.")
        }
        return count
    }

    func batch(
        from cursor: MailScanCursor,
        maximumCount: Int,
        perMessageTimeout: Int,
        processTimeout: TimeInterval
    ) async throws -> MailScanBatch {
        let output = try await runAppleScript(
            Self.batchScript,
            arguments: [
                String(cursor.mailboxIndex),
                String(cursor.messageIndex),
                String(max(maximumCount, 1)),
                String(max(perMessageTimeout, 1))
            ],
            timeout: processTimeout
        )
        guard let batch = MailScanRecordParser.parse(output) else {
            throw MichelMailsError.index("Mail returned an unreadable scan batch.")
        }
        return batch
    }

    private func runAppleScript(
        _ script: String,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, "--"] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        currentProcess = process
        defer {
            if currentProcess === process { currentProcess = nil }
        }

        return try await Task.detached(priority: .utility) {
            try process.run()
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout,
                execute: timeoutWorkItem
            )
            async let outputData = Task.detached {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }.value
            async let errorData = Task.detached {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }.value
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            let output = String(data: await outputData, encoding: .utf8) ?? ""
            let error = String(data: await errorData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
                if detail.contains("-1743") || detail.localizedCaseInsensitiveContains("not authorized") {
                    throw MichelMailsError.mail(
                        "Allow Michel Mails to control Mail in System Settings › Privacy & Security › Automation."
                    )
                }
                throw MichelMailsError.index("Mail skipped an unreadable scan batch.")
            }
            return output
        }.value
    }

    private static let totalCountScript = #"""
    tell application "Mail" to launch
    set totalCount to 0
    tell application "Mail"
        repeat with anAccount in every account
            repeat with aMailbox in every mailbox of anAccount
                try
                    set totalCount to totalCount + (count of every message of aMailbox)
                end try
            end repeat
        end repeat
    end tell
    return totalCount as text
    """#

    private static let batchScript = #"""
    on run argv
        tell application "Mail" to launch
        set mailboxIndex to (item 1 of argv) as integer
        set messageIndex to (item 2 of argv) as integer
        set maximumCount to (item 3 of argv) as integer
        set perMessageTimeout to (item 4 of argv) as integer
        set unitSeparator to ASCII character 31
        set recordSeparator to ASCII character 30
        set attachmentSeparator to ASCII character 29
        set attachmentFieldSeparator to ASCII character 28
        set outputRows to {}
        set attemptedCount to 0
        set failureCount to 0
        set finishedScan to false

        set mailboxRecords to {}
        tell application "Mail"
            repeat with anAccount in every account
                set accountName to ""
                try
                    set accountName to name of anAccount as text
                end try
                repeat with aMailbox in every mailbox of anAccount
                    set end of mailboxRecords to {contents of aMailbox, accountName}
                end repeat
            end repeat
        end tell

        repeat while attemptedCount < maximumCount
            if mailboxIndex > (count of mailboxRecords) then
                set finishedScan to true
                exit repeat
            end if

            set mailboxRecord to item mailboxIndex of mailboxRecords
            set targetMailbox to item 1 of mailboxRecord
            set accountName to item 2 of mailboxRecord
            set mailboxName to ""
            set messageCount to 0
            tell application "Mail"
                try
                    set mailboxName to name of targetMailbox as text
                    set messageCount to count of every message of targetMailbox
                on error
                    set failureCount to failureCount + 1
                    set mailboxIndex to mailboxIndex + 1
                    set messageIndex to 1
                end try
            end tell

            if messageCount is 0 or messageIndex > messageCount then
                set mailboxIndex to mailboxIndex + 1
                set messageIndex to 1
            else
                set attemptedCount to attemptedCount + 1
                tell application "Mail"
                    try
                        with timeout of perMessageTimeout seconds
                            set aMessage to message messageIndex of targetMailbox
                            set end of outputRows to my messageRow(aMessage, mailboxName, accountName, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator)
                        end timeout
                    on error
                        set failureCount to failureCount + 1
                    end try
                end tell
                set messageIndex to messageIndex + 1
            end if
        end repeat

        if mailboxIndex > (count of mailboxRecords) then set finishedScan to true
        set headerRow to "H" & unitSeparator & mailboxIndex & unitSeparator & messageIndex & unitSeparator & (finishedScan as text) & unitSeparator & attemptedCount & unitSeparator & failureCount
        if (count of outputRows) is 0 then return headerRow
        return headerRow & recordSeparator & my joinRows(outputRows, recordSeparator)
    end run

    on messageRow(aMessage, mailboxName, accountName, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator)
        set messageIdentifier to ""
        set localIdentifier to ""
        set senderText to ""
        set recipientText to ""
        set subjectText to ""
        set bodyText to ""
        set receivedText to ""
        set sizeBytes to 0
        set isSentMessage to false
        set attachmentRows to {}

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
                set recipientRows to {}
                repeat with aRecipient in (every to recipient of aMessage)
                    try
                        set end of recipientRows to address of aRecipient as text
                    end try
                end repeat
                repeat with aRecipient in (every cc recipient of aMessage)
                    try
                        set end of recipientRows to address of aRecipient as text
                    end try
                end repeat
                set recipientText to my joinRows(recipientRows, ", ")
            end try
            try
                set subjectText to subject of aMessage as text
            end try
            try
                with timeout of 5 seconds
                    set bodyText to content of aMessage as text
                end timeout
            end try
            try
                set receivedText to my ISODateText(date received of aMessage)
            end try
            try
                set sizeBytes to message size of aMessage as integer
            end try
            set isSentMessage to my messageLooksSent(aMessage, mailboxName)

            try
                with timeout of 5 seconds
                    set messageAttachments to every mail attachment of aMessage
                end timeout
                repeat with anAttachment in messageAttachments
                    set attachmentIdentifier to ""
                    set attachmentName to ""
                    set MIMEText to ""
                    set attachmentSize to 0
                    set downloadedState to false
                    try
                        set attachmentIdentifier to id of anAttachment as text
                    end try
                    try
                        set attachmentName to name of anAttachment as text
                    end try
                    try
                        set MIMEText to MIME type of anAttachment as text
                    end try
                    try
                        set attachmentSize to file size of anAttachment as integer
                    end try
                    try
                        set downloadedState to downloaded of anAttachment as boolean
                    end try

                    ignoring case
                        set imageState to MIMEText starts with "image/" or attachmentName ends with ".jpg" or attachmentName ends with ".jpeg" or attachmentName ends with ".png" or attachmentName ends with ".heic" or attachmentName ends with ".gif" or attachmentName ends with ".webp"
                        set decorationState to attachmentName contains "signature" or attachmentName contains "logo" or attachmentName contains "spacer" or attachmentName contains "tracking" or attachmentName contains "icon"
                    end ignoring
                    set usefulImageState to imageState and not decorationState and attachmentSize ≥ 5000

                    set attachmentRow to my cleanField(attachmentIdentifier, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & attachmentFieldSeparator & my cleanField(attachmentName, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & attachmentFieldSeparator & my cleanField(MIMEText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & attachmentFieldSeparator & attachmentSize & attachmentFieldSeparator & (imageState as text) & attachmentFieldSeparator & (usefulImageState as text) & attachmentFieldSeparator & (downloadedState as text)
                    set end of attachmentRows to attachmentRow
                end repeat
            end try
        end tell

        return "M" & unitSeparator & my cleanField(messageIdentifier, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(localIdentifier, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(senderText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(recipientText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(subjectText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(bodyText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & sizeBytes & unitSeparator & receivedText & unitSeparator & my cleanField(mailboxName, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & my cleanField(accountName, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator) & unitSeparator & (isSentMessage as text) & unitSeparator & my joinRows(attachmentRows, attachmentSeparator)
    end messageRow

    on messageLooksSent(aMessage, mailboxName)
        ignoring case
            if mailboxName contains "sent" or mailboxName contains "envoy" or mailboxName contains "gesendet" or mailboxName contains "inviati" or mailboxName contains "enviados" then return true
        end ignoring
        tell application "Mail"
            try
                set senderText to sender of aMessage as text
                repeat with anAccount in every account
                    repeat with accountAddress in email addresses of anAccount
                        ignoring case
                            if senderText contains (accountAddress as text) then return true
                        end ignoring
                    end repeat
                end repeat
            end try
        end tell
        return false
    end messageLooksSent

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

    on cleanField(sourceText, unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator)
        if sourceText is missing value then return ""
        set cleaned to sourceText as text
        repeat with invalidCharacter in {unitSeparator, recordSeparator, attachmentSeparator, attachmentFieldSeparator, return, linefeed, tab}
            set cleaned to my replaceText(cleaned, contents of invalidCharacter, " ")
        end repeat
        return cleaned
    end cleanField

    on replaceText(sourceText, searchText, replacementText)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to searchText
        set pieces to every text item of sourceText
        set AppleScript's text item delimiters to replacementText
        set joined to pieces as text
        set AppleScript's text item delimiters to previousDelimiters
        return joined
    end replaceText

    on joinRows(rowsToJoin, rowSeparator)
        set previousDelimiters to AppleScript's text item delimiters
        set AppleScript's text item delimiters to rowSeparator
        set joined to rowsToJoin as text
        set AppleScript's text item delimiters to previousDelimiters
        return joined
    end joinRows
    """#
}
