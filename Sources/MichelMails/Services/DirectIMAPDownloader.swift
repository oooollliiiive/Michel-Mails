import Foundation
import Network

enum DirectIMAPDownloadError: LocalizedError, Equatable {
    case noConfiguredAccount
    case authenticationFailed(String)
    case connectionFailed(String)
    case timedOut
    case messageNotFound
    case attachmentNotFound
    case messageTooLarge
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noConfiguredAccount:
            return "Add a direct Gmail or iCloud account in Settings."
        case .authenticationFailed(let account):
            return "Direct sign-in failed for \(account). Check its app-specific password in Settings."
        case .connectionFailed(let detail):
            return detail.isEmpty
                ? "The direct mail server connection failed."
                : "The direct mail server connection failed: \(detail)"
        case .timedOut:
            return "The direct mail server did not respond in time."
        case .messageNotFound:
            return "The email was not found on the direct mail server."
        case .attachmentNotFound:
            return "The attachment was not found in the server copy of this email."
        case .messageTooLarge:
            return "The server email is too large for direct download."
        case .invalidResponse(let detail):
            return detail.isEmpty
                ? "The direct mail server returned an invalid response."
                : "The direct mail server returned an invalid response: \(detail)"
        }
    }

    var isTransient: Bool {
        switch self {
        case .connectionFailed, .timedOut: return true
        default: return false
        }
    }

    var requiresConfiguration: Bool {
        switch self {
        case .noConfiguredAccount, .authenticationFailed: return true
        default: return false
        }
    }
}

actor DirectIMAPDownloader {
    static let shared = DirectIMAPDownloader()

    func download(
        _ candidate: IndexedMailAttachmentCandidate,
        to destination: URL
    ) async throws {
        let messageIdentifier = candidate.messageIdentifier
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !messageIdentifier.isEmpty else {
            throw DirectIMAPDownloadError.messageNotFound
        }
        let accounts = DirectMailAccountStore.orderedUsableAccounts(for: candidate)
        guard !accounts.isEmpty else { throw DirectIMAPDownloadError.noConfiguredAccount }

        var lastAuthenticationError: DirectIMAPDownloadError?
        var lastConnectionError: DirectIMAPDownloadError?
        var foundMessageWithoutAttachment = false

        for account in accounts {
            let session = IMAPSession(account: account)
            do {
                let messageData = try await withTaskCancellationHandler {
                    try await session.message(
                        identifiedBy: messageIdentifier,
                        preferredMailbox: candidate.mailboxName
                    )
                } onCancel: {
                    session.cancel()
                }
                guard let attachment = try DirectEmlxReader.extractAttachment(
                    identifier: candidate.attachmentIdentifier,
                    preferredName: candidate.attachmentName,
                    fromMessageData: messageData
                ), !attachment.isEmpty else {
                    foundMessageWithoutAttachment = true
                    continue
                }
                try attachment.write(to: destination, options: .atomic)
                DirectMailAccountStore.rememberSuccessfulAccount(account, for: candidate)
                return
            } catch let error as DirectIMAPDownloadError {
                switch error {
                case .authenticationFailed:
                    lastAuthenticationError = error
                case .connectionFailed, .timedOut:
                    lastConnectionError = error
                case .attachmentNotFound:
                    foundMessageWithoutAttachment = true
                case .messageNotFound:
                    break
                default:
                    throw error
                }
            }
        }

        if foundMessageWithoutAttachment { throw DirectIMAPDownloadError.attachmentNotFound }
        if let lastConnectionError { throw lastConnectionError }
        if let lastAuthenticationError { throw lastAuthenticationError }
        throw DirectIMAPDownloadError.messageNotFound
    }

    func test(_ account: DirectMailAccountConfiguration) async throws -> Int {
        guard account.isUsable else { throw DirectIMAPDownloadError.noConfiguredAccount }
        let session = IMAPSession(account: account)
        return try await withTaskCancellationHandler {
            try await session.testConnection()
        } onCancel: {
            session.cancel()
        }
    }
}

struct IMAPMailbox: Equatable {
    let name: String
    let attributes: Set<String>

    var isSelectable: Bool { !attributes.contains("\\noselect") }
    var isJunkOrTrash: Bool {
        attributes.contains("\\junk") || attributes.contains("\\trash")
    }
}

private final class IMAPSession: @unchecked Sendable {
    private let account: DirectMailAccountConfiguration
    private let socket: IMAPTLSSocket
    private var nextTag = 1
    private let maximumMessageBytes = 350 * 1_024 * 1_024

    init(account: DirectMailAccountConfiguration) {
        self.account = account
        socket = IMAPTLSSocket(
            host: account.provider.IMAPServer,
            port: account.provider.defaultPort
        )
    }

    func testConnection() async throws -> Int {
        defer { socket.close() }
        try await connectAndAuthenticate()
        let mailboxes = try await listMailboxes()
        _ = try? await command("LOGOUT")
        return mailboxes.filter(\.isSelectable).count
    }

    func cancel() {
        socket.close()
    }

    func message(
        identifiedBy messageIdentifier: String,
        preferredMailbox: String
    ) async throws -> Data {
        defer { socket.close() }
        try await connectAndAuthenticate()
        let mailboxes = try await listMailboxes()
        let ordered = Self.orderedMailboxes(
            mailboxes,
            provider: account.provider,
            preferredMailbox: preferredMailbox
        )

        for mailbox in ordered {
            guard (try? await command("EXAMINE \(Self.quoted(mailbox.name))")) != nil else {
                continue
            }
            let search = try await command(
                "UID SEARCH HEADER Message-ID \(Self.quoted(messageIdentifier))"
            )
            guard let UID = IMAPProtocolParser.lastSearchUID(in: search.lines) else { continue }
            let fetch = try await command("UID FETCH \(UID) (BODY.PEEK[])")
            guard let messageData = fetch.literals.max(by: { $0.count < $1.count }) else {
                throw DirectIMAPDownloadError.invalidResponse("missing message body")
            }
            guard messageData.count <= maximumMessageBytes else {
                throw DirectIMAPDownloadError.messageTooLarge
            }
            _ = try? await command("LOGOUT")
            return messageData
        }
        throw DirectIMAPDownloadError.messageNotFound
    }

    private func connectAndAuthenticate() async throws {
        try await socket.connect()
        let greeting = try await socket.readLine()
        guard greeting.uppercased().hasPrefix("* OK") else {
            throw DirectIMAPDownloadError.invalidResponse(greeting)
        }

        var lastError: Error?
        for loginName in loginNames {
            do {
                _ = try await command(
                    "LOGIN \(Self.quoted(loginName)) \(Self.quoted(account.normalizedAppPassword))"
                )
                return
            } catch let error as DirectIMAPDownloadError {
                switch error {
                case .connectionFailed, .timedOut:
                    throw error
                default:
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }
        _ = lastError
        throw DirectIMAPDownloadError.authenticationFailed(account.emailAddress)
    }

    private var loginNames: [String] {
        var names = [account.loginName]
        let email = account.emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty, !names.contains(email) { names.append(email) }
        return names
    }

    private func listMailboxes() async throws -> [IMAPMailbox] {
        let response = try await command("LIST \"\" \"*\"")
        let parsed = response.lines.compactMap(IMAPProtocolParser.mailbox(fromListLine:))
        guard !parsed.isEmpty else {
            throw DirectIMAPDownloadError.invalidResponse("no mailboxes returned")
        }
        return parsed
    }

    private func command(_ value: String) async throws -> IMAPCommandResponse {
        let tag = String(format: "A%04d", nextTag)
        nextTag += 1
        try await socket.send("\(tag) \(value)\r\n")

        var lines: [String] = []
        var literals: [Data] = []
        while true {
            let line = try await socket.readLine()
            lines.append(line)
            if let literalByteCount = IMAPProtocolParser.trailingLiteralByteCount(in: line) {
                guard literalByteCount <= maximumMessageBytes else {
                    throw DirectIMAPDownloadError.messageTooLarge
                }
                literals.append(try await socket.readExactly(literalByteCount))
            }
            guard line.uppercased().hasPrefix(tag.uppercased() + " ") else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix(tag.uppercased() + " OK") {
                return IMAPCommandResponse(lines: lines, literals: literals)
            }
            throw DirectIMAPDownloadError.invalidResponse(Self.cleanServerError(line, tag: tag))
        }
    }

    private static func orderedMailboxes(
        _ mailboxes: [IMAPMailbox],
        provider: DirectMailProvider,
        preferredMailbox: String
    ) -> [IMAPMailbox] {
        let preferred = normalizedMailbox(preferredMailbox)
        let ordered = mailboxes
            .filter(\.isSelectable)
            .filter { !$0.isJunkOrTrash || normalizedMailbox($0.name).contains(preferred) }
            .sorted { left, right in
                mailboxScore(left, provider: provider, preferred: preferred) >
                    mailboxScore(right, provider: provider, preferred: preferred)
            }
        if provider == .gmail,
           !preferred.contains("junk"), !preferred.contains("spam"), !preferred.contains("trash"),
           let allMail = ordered.first(where: { $0.attributes.contains("\\all") }) {
            // Gmail's All Mail contains Inbox, Sent, and archived messages. A
            // single search avoids repeating the same query across every label.
            return [allMail]
        }
        return ordered
    }

    private static func mailboxScore(
        _ mailbox: IMAPMailbox,
        provider: DirectMailProvider,
        preferred: String
    ) -> Int {
        let full = normalizedMailbox(mailbox.name)
        let leaf = normalizedMailbox(mailbox.name.split(separator: "/").last.map(String.init) ?? mailbox.name)
        var score = 0
        if !preferred.isEmpty, full == preferred || leaf == preferred { score += 2_000 }
        if provider == .gmail, mailbox.attributes.contains("\\all") { score += 1_500 }
        if full == "inbox" { score += 500 }
        if mailbox.attributes.contains("\\archive") { score += 250 }
        return score
    }

    private static func normalizedMailbox(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter(\.isLetter)
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func cleanServerError(_ line: String, tag: String) -> String {
        String(line.dropFirst(min(line.count, tag.count + 1)))
    }
}

private extension DirectMailAccountConfiguration {
    var normalizedAppPassword: String {
        let trimmed = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == .gmail { return trimmed.filter { !$0.isWhitespace } }
        return trimmed
    }
}

struct IMAPCommandResponse: Equatable {
    let lines: [String]
    let literals: [Data]
}

enum IMAPProtocolParser {
    static func trailingLiteralByteCount(in line: String) -> Int? {
        guard line.hasSuffix("}"), let opening = line.lastIndex(of: "{") else { return nil }
        let value = line[line.index(after: opening)..<line.index(before: line.endIndex)]
        return Int(value)
    }

    static func lastSearchUID(in lines: [String]) -> String? {
        lines.reversed().compactMap { line -> String? in
            guard line.uppercased().hasPrefix("* SEARCH") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).dropFirst(2).last.map(String.init)
        }.first
    }

    static func mailbox(fromListLine line: String) -> IMAPMailbox? {
        guard line.uppercased().hasPrefix("* LIST "),
              let attributesStart = line.firstIndex(of: "("),
              let attributesEnd = line[attributesStart...].firstIndex(of: ")") else {
            return nil
        }
        let attributes = line[line.index(after: attributesStart)..<attributesEnd]
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        let remainder = line[line.index(after: attributesEnd)...]
            .trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }

        let name: String
        if remainder.hasSuffix("\""),
           let openingQuote = openingQuoteForLastString(in: remainder) {
            let raw = remainder[remainder.index(after: openingQuote)..<remainder.index(before: remainder.endIndex)]
            name = unescapedQuotedString(String(raw))
        } else if let last = remainder.split(whereSeparator: \.isWhitespace).last {
            name = String(last)
        } else {
            return nil
        }
        return IMAPMailbox(name: name, attributes: Set(attributes))
    }

    private static func openingQuoteForLastString(in value: String) -> String.Index? {
        guard value.count >= 2, value.last == "\"" else { return nil }
        var index = value.index(before: value.index(before: value.endIndex))
        while true {
            if value[index] == "\"" {
                var slashCount = 0
                var cursor = index
                while cursor > value.startIndex {
                    let previous = value.index(before: cursor)
                    guard value[previous] == "\\" else { break }
                    slashCount += 1
                    cursor = previous
                }
                if slashCount.isMultiple(of: 2) { return index }
            }
            guard index > value.startIndex else { return nil }
            index = value.index(before: index)
        }
    }

    private static func unescapedQuotedString(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }
}

private final class ContinuationGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    @discardableResult
    func resume(
        _ continuation: CheckedContinuation<Value, Error>,
        with result: Result<Value, Error>
    ) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}

private final class IMAPTLSSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.michelos.michelmails.imap")
    private var buffer = Data()
    private let lock = NSLock()
    private let operationTimeout: TimeInterval = 15

    init(host: String, port: UInt16) {
        let TLSOptions = NWProtocolTLS.Options()
        let parameters = NWParameters(tls: TLSOptions)
        parameters.allowLocalEndpointReuse = true
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Void>()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(continuation, with: .success(()))
                case .failed(let error), .waiting(let error):
                    gate.resume(
                        continuation,
                        with: .failure(DirectIMAPDownloadError.connectionFailed(error.localizedDescription))
                    )
                case .cancelled:
                    gate.resume(
                        continuation,
                        with: .failure(DirectIMAPDownloadError.connectionFailed("connection cancelled"))
                    )
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + operationTimeout) { [weak self] in
                if gate.resume(continuation, with: .failure(DirectIMAPDownloadError.timedOut)) {
                    self?.connection.cancel()
                }
            }
        }
    }

    func send(_ value: String) async throws {
        let data = Data(value.utf8)
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Void>()
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    gate.resume(
                        continuation,
                        with: .failure(DirectIMAPDownloadError.connectionFailed(error.localizedDescription))
                    )
                } else {
                    gate.resume(continuation, with: .success(()))
                }
            })
            queue.asyncAfter(deadline: .now() + operationTimeout) { [weak self] in
                if gate.resume(continuation, with: .failure(DirectIMAPDownloadError.timedOut)) {
                    self?.connection.cancel()
                }
            }
        }
    }

    func readLine() async throws -> String {
        while true {
            if let line = takeLineFromBuffer() {
                return String(decoding: line, as: UTF8.self)
            }
            appendToBuffer(try await receiveChunk())
        }
    }

    func readExactly(_ count: Int) async throws -> Data {
        guard count >= 0 else { throw DirectIMAPDownloadError.invalidResponse("negative literal") }
        while bufferedCount < count {
            appendToBuffer(try await receiveChunk())
        }
        return takeFromBuffer(count)
    }

    func close() {
        connection.cancel()
    }

    private var bufferedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    private func appendToBuffer(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    private func takeFromBuffer(_ count: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return result
    }

    private func takeLineFromBuffer() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let range = buffer.range(of: Data([13, 10])) else { return nil }
        let line = Data(buffer[..<range.lowerBound])
        buffer.removeSubrange(..<range.upperBound)
        return line
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate<Data>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                data, _, isComplete, error in
                if let data, !data.isEmpty {
                    gate.resume(continuation, with: .success(data))
                } else if let error {
                    gate.resume(
                        continuation,
                        with: .failure(DirectIMAPDownloadError.connectionFailed(error.localizedDescription))
                    )
                } else if isComplete {
                    gate.resume(
                        continuation,
                        with: .failure(DirectIMAPDownloadError.connectionFailed("server closed the connection"))
                    )
                }
            }
            queue.asyncAfter(deadline: .now() + operationTimeout) { [weak self] in
                if gate.resume(continuation, with: .failure(DirectIMAPDownloadError.timedOut)) {
                    self?.connection.cancel()
                }
            }
        }
    }
}
