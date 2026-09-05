import Foundation

struct LocalQueryInterpreter {
    private let calendar = Calendar.current

    func interpret(_ prompt: String, now: Date = Date()) -> MailQuery {
        let normalized = prompt
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        var query = MailQuery()
        query.language = detectLanguage(normalized)
        query.hasImage = containsAny(normalized, ["photo", "photos", "image", "images", "picture", "pictures", "jpg", "jpeg", "png", "heic"])
        query.attachmentKinds = attachmentKinds(in: normalized)
        query.hasAttachment = query.hasImage || !query.attachmentKinds.isEmpty || containsAny(normalized, ["piece jointe", "pieces jointes", "attachment", "attachments", "fichier", "fichiers", "file", "files"])
        if containsAny(normalized, ["copie", "copier", "enregistre", "sauvegarde", "copy", "save", "export"]) {
            query.action = .copyImages
        } else if requestsImageGallery(normalized) {
            query.action = .showImages
        } else if requestsFileGallery(normalized) {
            query.action = .showFiles
        } else {
            query.action = .search
        }
        if containsAny(normalized, ["recu", "recue", "recus", "recues", "received", "incoming"]) {
            query.direction = .received
        } else if containsAny(normalized, ["que j ai envoye", "que jai envoye", "i sent", "mes emails envoyes"]) {
            query.direction = .sent
        }
        query.sender = extractSender(from: prompt)
        query.destinationFolder = extractDestination(from: prompt)
        query.limit = extractLimit(from: normalized) ?? 25
        query.allResults = containsAny(normalized, ["tous", "toutes", "all ", "every "])
        if normalized.range(of: #"\b(?:plus\s+vieux|plus\s+vieilles?|anciens?|anciennes?|oldest|earliest|least\s+recent)\b"#, options: .regularExpression) != nil {
            query.sortOrder = .oldestFirst
        }
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

    private func requestsImageGallery(_ text: String) -> Bool {
        guard containsAny(text, ["montre", "affiche", "voir", "show", "display"]),
              let imageRange = text.range(of: #"\b(?:images?|photos?|pictures?)\b"#, options: .regularExpression) else {
            return false
        }

        guard let emailRange = text.range(
            of: #"\b(?:emails?|mails?|courriels?)\b"#,
            options: .regularExpression
        ) else {
            return true
        }
        return imageRange.lowerBound < emailRange.lowerBound
    }

    private func requestsFileGallery(_ text: String) -> Bool {
        containsAny(text, ["montre", "affiche", "voir", "show", "display", "browse", "liste", "list"]) &&
            containsAny(text, [
                "piece jointe", "pieces jointes", "attachment", "attachments", "fichier", "fichiers",
                "file", "files", "pdf", "document", "documents", "spreadsheet", "presentation", "archive",
                "video", "videos", "movie", "movies", "film", "films"
            ])
    }

    private func attachmentKinds(in text: String) -> [MailAttachmentKind] {
        var kinds: [MailAttachmentKind] = []
        if containsAny(text, ["photo", "photos", "image", "images", "picture", "pictures", "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "raw"]) { kinds.append(.image) }
        if containsAny(text, ["pdf"]) { kinds.append(.pdf) }
        if containsAny(text, ["document", "documents", "docx", "word", "texte", "text file"]) { kinds.append(.document) }
        if containsAny(text, ["spreadsheet", "tableur", "excel", "xlsx", "numbers", "csv"]) { kinds.append(.spreadsheet) }
        if containsAny(text, ["presentation", "powerpoint", "pptx", "keynote", "slides"]) { kinds.append(.presentation) }
        if containsAny(text, ["archive", "archives", "zip", "rar"]) { kinds.append(.archive) }
        if containsAny(text, ["audio", "mp3", "wav", "music", "musique"]) { kinds.append(.audio) }
        if containsAny(text, ["video", "videos", "movie", "film", "mp4", "mov"]) { kinds.append(.video) }
        return kinds
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
            let normalizedValue = value
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            let genericValues = Set(["email", "emails", "mail", "mails", "courriel", "courriels"])
            if !value.isEmpty && !genericValues.contains(normalizedValue) { return value }
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
        let pattern = #"\b([1-9][0-9]?)\s+(?:(?:plus\s+)?(?:vieux|vieilles?|anciens?|anciennes?|oldest|earliest)\s+)?(?:derniers?|dernieres?|latest|last|emails?|mails?|fichiers?|files?|photos?|images?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private func extractKeywords(from text: String, sender: String?) -> [String] {
        let stopWords = Set([
            "trouve", "retrouve", "cherche", "find", "show", "me", "moi", "les", "des", "un", "une",
            "montre", "montrer", "affiche", "afficher", "display", "voir",
            "emails", "email", "mails", "mail", "courriels", "courriel", "de", "du", "from", "par", "by",
            "dernier", "derniers", "derniere", "dernieres", "latest", "last", "avec", "with", "qui", "ont",
            "une", "photo", "photos", "image", "images", "picture", "pictures", "piece", "jointe", "attachment",
            "copie", "copier", "copy", "dans", "dossier", "folder", "aujourd", "hui", "hier", "semaine", "mois",
            "recu", "recue", "recus", "recues", "received", "incoming", "plus", "vieux", "vieille", "vieilles",
            "ancien", "anciens", "ancienne", "anciennes", "oldest", "earliest", "recent", "pdf", "fichier", "fichiers",
            "file", "files", "document", "documents"
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
