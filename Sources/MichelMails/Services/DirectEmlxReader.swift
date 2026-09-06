import Foundation

struct DirectEmlxAttachment: Equatable, Sendable {
    let identifier: String
    let name: String
    let MIMEType: String
    let sizeBytes: Int64
}

struct DirectEmlxMessage: Equatable, Sendable {
    let body: String
    let attachments: [DirectEmlxAttachment]
}

enum DirectEmlxError: LocalizedError {
    case unreadable
    case malformed
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The local email file could not be read."
        case .malformed: return "The local email file is malformed."
        case .tooLarge: return "The local email file is too large to scan safely."
        }
    }
}

enum DirectEmlxReader {
    private static let maximumMessageBytes = 300 * 1_024 * 1_024

    static func read(at URL: URL) throws -> DirectEmlxMessage {
        let data = try messageData(at: URL)
        let root = parsePart(data, identifier: "1")
        let plain = firstText(in: root, MIMEPrefix: "text/plain")
        let HTML = plain == nil ? firstText(in: root, MIMEPrefix: "text/html") : nil
        let body = (plain ?? HTML.map(stripHTML) ?? "")
            .replacingOccurrences(of: "\u{0000}", with: "")
        return DirectEmlxMessage(
            body: body,
            attachments: attachmentParts(in: root).map { part in
                DirectEmlxAttachment(
                    identifier: part.identifier,
                    name: attachmentName(for: part),
                    MIMEType: part.MIMEType,
                    sizeBytes: Int64(decodedData(for: part).count)
                )
            }
        )
    }

    static func extractAttachment(
        identifier: String,
        preferredName: String? = nil,
        from URL: URL
    ) throws -> Data? {
        let root = parsePart(try messageData(at: URL), identifier: "1")
        let attachments = attachmentParts(in: root)
        let indexedPosition = identifier.hasPrefix("index-")
            ? Int(identifier.dropFirst("index-".count)).map { $0 - 1 }
            : nil
        let part = findPart(identifier: identifier, in: root)
            ?? indexedPosition.flatMap { attachments.indices.contains($0) ? attachments[$0] : nil }
            ?? preferredName.flatMap { name in
                attachments.first { attachmentName(for: $0).caseInsensitiveCompare(name) == .orderedSame }
            }
        guard let part, part.isAttachment else {
            return nil
        }
        return decodedData(for: part)
    }

    private struct Part {
        let identifier: String
        let headers: [String: String]
        let body: Data
        let children: [Part]

        var MIMEType: String {
            (headers["content-type"] ?? "text/plain")
                .components(separatedBy: ";")[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        var isAttachment: Bool {
            let disposition = headers["content-disposition"]?.lowercased() ?? ""
            if disposition.contains("attachment") { return true }
            if headerParameter("filename", in: headers["content-disposition"]) != nil { return true }
            if headerParameter("filename*", in: headers["content-disposition"]) != nil { return true }
            if headerParameter("name", in: headers["content-type"]) != nil { return true }
            if MIMEType.hasPrefix("image/") || MIMEType.hasPrefix("audio/") || MIMEType.hasPrefix("video/") {
                return true
            }
            return MIMEType == "application/pdf" || MIMEType.hasPrefix("application/")
        }
    }

    private static func messageData(at URL: URL) throws -> Data {
        guard let values = try? URL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= maximumMessageBytes else {
            throw DirectEmlxError.tooLarge
        }
        guard let data = try? Data(contentsOf: URL, options: [.mappedIfSafe]) else {
            throw DirectEmlxError.unreadable
        }
        guard let newline = data.firstIndex(of: 0x0A),
              let countText = String(data: data[..<newline], encoding: .utf8),
              let byteCount = Int(countText.trimmingCharacters(in: .whitespacesAndNewlines)),
              byteCount >= 0 else {
            throw DirectEmlxError.malformed
        }
        let start = data.index(after: newline)
        guard let end = data.index(start, offsetBy: byteCount, limitedBy: data.endIndex) else {
            throw DirectEmlxError.malformed
        }
        return Data(data[start..<end])
    }

    private static func parsePart(_ data: Data, identifier: String) -> Part {
        let split = splitHeadersAndBody(data)
        let headers = parseHeaders(split.headers)
        let contentType = headers["content-type"] ?? "text/plain"
        var children: [Part] = []
        if contentType.lowercased().hasPrefix("multipart/"),
           let boundary = headerParameter("boundary", in: contentType) {
            children = splitMultipart(split.body, boundary: boundary).enumerated().map { index, data in
                parsePart(data, identifier: "\(identifier).\(index + 1)")
            }
        }
        return Part(identifier: identifier, headers: headers, body: split.body, children: children)
    }

    private static func splitHeadersAndBody(_ data: Data) -> (headers: Data, body: Data) {
        for marker in [Data([13, 10, 13, 10]), Data([10, 10])] {
            if let range = data.range(of: marker) {
                return (
                    Data(data[data.startIndex..<range.lowerBound]),
                    Data(data[range.upperBound..<data.endIndex])
                )
            }
        }
        return (data, Data())
    }

    private static func parseHeaders(_ data: Data) -> [String: String] {
        let raw = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in raw.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                unfolded.append(line)
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        return headers
    }

    private static func splitMultipart(_ data: Data, boundary: String) -> [Data] {
        guard let marker = "--\(boundary)".data(using: .utf8) else { return [] }
        var ranges: [Range<Data.Index>] = []
        var cursor = data.startIndex
        while let range = data.range(of: marker, in: cursor..<data.endIndex) {
            let isLineStart = range.lowerBound == data.startIndex ||
                data[data.index(before: range.lowerBound)] == 0x0A
            if isLineStart { ranges.append(range) }
            cursor = range.upperBound
        }
        guard ranges.count >= 2 else { return [] }
        var parts: [Data] = []
        for index in 0..<(ranges.count - 1) {
            var start = ranges[index].upperBound
            if start < data.endIndex, data[start] == 0x2D { continue }
            while start < data.endIndex, data[start] == 0x0D || data[start] == 0x0A {
                start = data.index(after: start)
            }
            var end = ranges[index + 1].lowerBound
            while end > start {
                let previous = data.index(before: end)
                if data[previous] == 0x0D || data[previous] == 0x0A {
                    end = previous
                } else {
                    break
                }
            }
            if start < end { parts.append(Data(data[start..<end])) }
        }
        return parts
    }

    private static func headerParameter(_ name: String, in rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        for component in headerComponents(rawValue).dropFirst() {
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            var value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if name.hasSuffix("*"), let apostrophe = value.range(of: "''") {
                value = String(value[apostrophe.upperBound...])
            }
            return value.removingPercentEncoding ?? value
        }
        return nil
    }

    /// MIME parameters are separated by semicolons, except when the semicolon
    /// belongs to a quoted filename. A plain String.split creates phantom
    /// attachments such as `"5193ae` for `filename="5193ae;rest.png"`.
    private static func headerComponents(_ value: String) -> [Substring] {
        var components: [Substring] = []
        var start = value.startIndex
        var index = value.startIndex
        var isQuoted = false
        var isEscaped = false

        while index < value.endIndex {
            let character = value[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\", isQuoted {
                isEscaped = true
            } else if character == "\"" {
                isQuoted.toggle()
            } else if character == ";", !isQuoted {
                components.append(value[start..<index])
                start = value.index(after: index)
            }
            index = value.index(after: index)
        }
        components.append(value[start..<value.endIndex])
        return components
    }

    private static func attachmentParts(in part: Part) -> [Part] {
        var result = part.isAttachment ? [part] : []
        for child in part.children { result.append(contentsOf: attachmentParts(in: child)) }
        return result
    }

    private static func findPart(identifier: String, in part: Part) -> Part? {
        if part.identifier == identifier { return part }
        for child in part.children {
            if let match = findPart(identifier: identifier, in: child) { return match }
        }
        return nil
    }

    private static func attachmentName(for part: Part) -> String {
        if let name = headerParameter("filename*", in: part.headers["content-disposition"]) ??
            headerParameter("filename", in: part.headers["content-disposition"]) ??
            headerParameter("name", in: part.headers["content-type"]), !name.isEmpty {
            return decodeHeader(name)
        }
        let contentID = part.headers["content-id"]?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        let stem = contentID?.isEmpty == false ? contentID! : "Attachment-\(part.identifier)"
        return stem + extensionForMIMEType(part.MIMEType)
    }

    private static func extensionForMIMEType(_ MIMEType: String) -> String {
        switch MIMEType {
        case "image/jpeg": return ".jpg"
        case "image/png": return ".png"
        case "image/gif": return ".gif"
        case "image/heic", "image/heif": return ".heic"
        case "image/webp": return ".webp"
        case "application/pdf": return ".pdf"
        default: return ""
        }
    }

    private static func firstText(in part: Part, MIMEPrefix: String) -> String? {
        if !part.isAttachment && part.MIMEType.hasPrefix(MIMEPrefix) {
            let charset = headerParameter("charset", in: part.headers["content-type"]) ?? "utf-8"
            return decodeText(decodedData(for: part), charset: charset)
        }
        for child in part.children {
            if let text = firstText(in: child, MIMEPrefix: MIMEPrefix) { return text }
        }
        return nil
    }

    private static func decodedData(for part: Part) -> Data {
        let encoding = part.headers["content-transfer-encoding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch encoding {
        case "base64":
            let text = String(decoding: part.body, as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            return Data(base64Encoded: text) ?? part.body
        case "quoted-printable":
            return decodeQuotedPrintable(part.body)
        default:
            return part.body
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        func hexadecimal(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 65 + 10
            case 97...102: return byte - 97 + 10
            default: return nil
            }
        }
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 61 {
                let first = data.index(after: index)
                if first < data.endIndex, data[first] == 10 {
                    index = data.index(after: first)
                    continue
                }
                if first < data.endIndex, data[first] == 13 {
                    var next = data.index(after: first)
                    if next < data.endIndex, data[next] == 10 { next = data.index(after: next) }
                    index = next
                    continue
                }
                let second = first < data.endIndex ? data.index(after: first) : data.endIndex
                if second < data.endIndex,
                   let high = hexadecimal(data[first]),
                   let low = hexadecimal(data[second]) {
                    output.append((high << 4) | low)
                    index = data.index(after: second)
                    continue
                }
            }
            output.append(data[index])
            index = data.index(after: index)
        }
        return output
    }

    private static func decodeText(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private static func decodeHeader(_ value: String) -> String {
        guard value.hasPrefix("=?"), value.hasSuffix("?=") else { return value }
        let pieces = value.dropFirst(2).dropLast(2).split(separator: "?", maxSplits: 2)
        guard pieces.count == 3 else { return value }
        let charset = String(pieces[0])
        let mode = pieces[1].lowercased()
        let payload = String(pieces[2])
        let data: Data?
        if mode == "b" {
            data = Data(base64Encoded: payload)
        } else if mode == "q" {
            data = decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
        } else {
            data = nil
        }
        return data.map { decodeText($0, charset: charset) } ?? value
    }

    private static func stripHTML(_ HTML: String) -> String {
        var text = HTML
        for tag in ["style", "script", "head"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'"
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
