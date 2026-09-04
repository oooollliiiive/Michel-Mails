import Foundation

struct LocalQueryInterpreter {
    private let calendar = Calendar.current

    func interpret(_ prompt: String, now: Date = Date()) -> MailQuery {
        let normalized = prompt
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        var query = MailQuery()
        query.language = detectLanguage(normalized)
        query.action = containsAny(normalized, ["copie", "copier", "enregistre", "sauvegarde", "copy", "save", "export"])
            ? .copyImages
            : .search
        query.hasImage = containsAny(normalized, ["photo", "photos", "image", "images", "picture", "pictures", "jpg", "jpeg", "png", "heic"])
        query.hasAttachment = query.hasImage || containsAny(normalized, ["piece jointe", "pieces jointes", "attachment", "attachments", "pdf"])
        query.sender = extractSender(from: prompt)
        query.destinationFolder = extractDestination(from: prompt)
        query.limit = extractLimit(from: normalized) ?? 25
        query.allResults = containsAny(normalized, ["tous", "toutes", "all ", "every "])
        query.confidence = 0.55

        if containsAny(normalized, ["aujourd'hui", "aujourdhui", "today"]) {
            query.startDate = calendar.startOfDay(for: now)
        } else if containsAny(normalized, ["hier", "yesterday"]) {
            let today = calendar.startOfDay(for: now)
            query.startDate = calendar.date(byAdding: .day, value: -1, to: today)
            query.endDate = today
        } else if containsAny(normalized, ["semaine derniere", "last week"]) {
            let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            query.startDate = startOfWeek.flatMap { calendar.date(byAdding: .weekOfYear, value: -1, to: $0) }
            query.endDate = startOfWeek
        } else if containsAny(normalized, ["ce mois", "this month"]) {
            query.startDate = calendar.dateInterval(of: .month, for: now)?.start
        } else if containsAny(normalized, ["mois dernier", "last month"]) {
            let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start
            query.startDate = startOfMonth.flatMap { calendar.date(byAdding: .month, value: -1, to: $0) }
            query.endDate = startOfMonth
        }

        query.keywords = extractKeywords(from: normalized, sender: query.sender)
        return query
    }

    private func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0) }
    }

    private func detectLanguage(_ text: String) -> String {
        let french = ["trouve", "mail", "courriel", "de", "avec", "dernier", "copie", "dossier"]
        let english = ["find", "email", "from", "with", "last", "copy", "folder"]
        let frenchScore = french.filter(text.contains).count
        let englishScore = english.filter(text.contains).count
        if frenchScore > 0 && englishScore > 0 { return "mixed" }
        return englishScore > frenchScore ? "en" : "fr"
    }

    private func extractSender(from prompt: String) -> String? {
        let patterns = [
            #"(?i)(?:emails?|mails?|courriels?)\s+(?:envoy[ée]s?\s+)?(?:de|from|par|by)\s+([^,.;]+?)(?=\s+(?:qui|avec|ayant|contenant|dans|du|de la|depuis|entre|that|who|with|containing|into|sent|last|from)\b|[,.;]|$)"#,
            #"(?i)(?:de|from|par|by)\s+([\p{L}\p{N}'’._+-]+(?:\s+[\p{L}\p{N}'’._+-]+)?)(?=\s+(?:qui|avec|ayant|contenant|dans|du|depuis|that|who|with|containing|into|sent)\b|[,.;]|$)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
                  let range = Range(match.range(at: 1), in: prompt) else { continue }
            let value = String(prompt[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func extractDestination(from prompt: String) -> String? {
        let pattern = #"(?i)(?:dossier|folder)\s+[\"“”']?([^\"“”',.;]+?)[\"“”']?(?:\s*$|[,.;])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
              let range = Range(match.range(at: 1), in: prompt) else { return nil }
        return String(prompt[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractLimit(from text: String) -> Int? {
        let pattern = #"\b([1-9][0-9]?)\s+(?:derniers?|dernieres?|latest|last|emails?|mails?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func extractKeywords(from text: String, sender: String?) -> [String] {
        let stopWords = Set([
            "trouve", "retrouve", "cherche", "find", "show", "me", "moi", "les", "des", "un", "une",
            "emails", "email", "mails", "mail", "courriels", "courriel", "de", "du", "from", "par", "by",
            "dernier", "derniers", "derniere", "dernieres", "latest", "last", "avec", "with", "qui", "ont",
            "une", "photo", "photos", "image", "images", "picture", "pictures", "piece", "jointe", "attachment",
            "copie", "copier", "copy", "dans", "dossier", "folder", "aujourd", "hui", "hier", "semaine", "mois"
        ])
        let senderWords = Set((sender ?? "").lowercased().split(separator: " ").map(String.init))
        return text
            .replacingOccurrences(of: "[^a-z0-9à-ÿ]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) && !senderWords.contains($0) && Int($0) == nil }
            .prefix(6)
            .map { $0 }
    }
}
