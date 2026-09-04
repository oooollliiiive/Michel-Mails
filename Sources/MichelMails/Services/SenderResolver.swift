import Foundation

struct SenderResolver {
    func resolve(_ requested: String, among senders: [String]) -> String {
        let needle = normalizedName(requested)
        guard !needle.isEmpty else { return requested }

        let ranked = senders
            .map { sender in
                (sender: sender, score: similarity(needle, normalizedName(sender)))
            }
            .filter { $0.score >= 0.58 }
            .sorted {
                if $0.score == $1.score { return $0.sender.count < $1.sender.count }
                return $0.score > $1.score
            }

        return ranked.first?.sender ?? requested
    }

    func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        let rhsTokens = rhs.split(separator: " ").map(String.init)
        let candidates = [rhs] + rhsTokens
        return candidates.map { candidate in
            if candidate.hasPrefix(lhs) || lhs.hasPrefix(candidate) {
                let lengthRatio = Double(min(candidate.count, lhs.count)) / Double(max(candidate.count, lhs.count))
                return 0.84 + (0.16 * lengthRatio)
            }
            let distance = levenshtein(lhs, candidate)
            return 1 - (Double(distance) / Double(max(lhs.count, candidate.count)))
        }.max() ?? 0
    }

    private func normalizedName(_ value: String) -> String {
        let displayName = value.components(separatedBy: "<").first ?? value
        return displayName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func levenshtein(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[right.count]
    }
}
