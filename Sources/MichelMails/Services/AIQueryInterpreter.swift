import Foundation

actor AIQueryInterpreter {
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let localInterpreter = LocalQueryInterpreter()

    func interpret(_ prompt: String, APIKey: String?, model: String) async throws -> MailQuery {
        guard let APIKey, !APIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return localInterpreter.interpret(prompt)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(APIKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(prompt: prompt, model: model))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let HTTPResponse = response as? HTTPURLResponse else {
            throw MichelMailsError.invalidAPIResponse
        }

        guard (200..<300).contains(HTTPResponse.statusCode) else {
            let message = Self.errorMessage(from: data) ?? "HTTP \(HTTPResponse.statusCode)"
            throw MichelMailsError.openAI(message)
        }

        guard let text = Self.outputText(from: data),
              let JSONData = text.data(using: .utf8) else {
            throw MichelMailsError.invalidAPIResponse
        }

        let payload = try JSONDecoder().decode(AIMailQuery.self, from: JSONData)
        return payload.mailQuery
    }

    private func requestBody(prompt: String, model: String) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let currentDate = formatter.string(from: Date())

        let instructions = """
        You translate a person's natural-language request about their Apple Mail messages into a structured query. The user may write French, English, mix both languages, make spelling mistakes, omit accents, use nicknames, or use relative dates. Preserve the sender text exactly as understood; another local component resolves it against real correspondents. Never invent message data. Use copy_images only when the user explicitly asks to copy, save, or export images. Use search for all other requests. Set has_image for photos, screenshots, scans, pictures, or image files. Dates must be ISO 8601 or empty. Today is \(currentDate). Keep only meaningful content terms in keywords. If no count is given, use 25. Set all_results only when the person explicitly says all, tous, toutes, every, or equivalent. destination_folder is a requested folder name or path, otherwise empty.
        """

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "action": ["type": "string", "enum": ["search", "copy_images"]],
                "sender": ["type": "string"],
                "keywords": ["type": "array", "items": ["type": "string"], "maxItems": 8],
                "start_date": ["type": "string"],
                "end_date": ["type": "string"],
                "has_image": ["type": "boolean"],
                "has_attachment": ["type": "boolean"],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                "all_results": ["type": "boolean"],
                "destination_folder": ["type": "string"],
                "language": ["type": "string", "enum": ["fr", "en", "mixed"]],
                "confidence": ["type": "number", "minimum": 0, "maximum": 1]
            ],
            "required": [
                "action", "sender", "keywords", "start_date", "end_date", "has_image",
                "has_attachment", "limit", "all_results", "destination_folder", "language", "confidence"
            ]
        ]

        return [
            "model": model,
            "store": false,
            "instructions": instructions,
            "input": prompt,
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "michel_mails_query",
                    "strict": true,
                    "schema": schema
                ]
            ]
        ]
    }

    private static func outputText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let text = root["output_text"] as? String, !text.isEmpty {
            return text
        }

        guard let output = root["output"] as? [[String: Any]] else { return nil }
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else { continue }
            for part in content where part["type"] as? String == "output_text" {
                if let text = part["text"] as? String { return text }
            }
        }
        return nil
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        return error["message"] as? String
    }
}

private struct AIMailQuery: Decodable {
    let action: MailAction
    let sender: String
    let keywords: [String]
    let startDate: String
    let endDate: String
    let hasImage: Bool
    let hasAttachment: Bool
    let limit: Int
    let allResults: Bool
    let destinationFolder: String
    let language: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case action, sender, keywords, limit, language, confidence
        case startDate = "start_date"
        case endDate = "end_date"
        case hasImage = "has_image"
        case hasAttachment = "has_attachment"
        case allResults = "all_results"
        case destinationFolder = "destination_folder"
    }

    var mailQuery: MailQuery {
        MailQuery(
            action: action,
            sender: sender.nilIfBlank,
            keywords: keywords,
            startDate: Self.date(from: startDate),
            endDate: Self.date(from: endDate),
            hasImage: hasImage,
            hasAttachment: hasAttachment,
            limit: min(max(limit, 1), 100),
            allResults: allResults,
            destinationFolder: destinationFolder.nilIfBlank,
            language: language,
            confidence: confidence
        )
    }

    private static func date(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
