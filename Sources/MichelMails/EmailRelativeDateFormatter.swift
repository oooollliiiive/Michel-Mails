import Foundation

enum EmailRelativeDateFormatter {
    static func string(
        for date: Date?,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let date else { return "Unknown date" }
        if calendar.isDate(date, inSameDayAs: now) {
            let time = date.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened)
                    .locale(Locale(identifier: "en_US"))
            )
            return "Today at \(time)"
        }

        let components = calendar.dateComponents(
            [.year, .day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        )
        let years = components.year ?? 0
        let days = components.day ?? 0
        if years > 0 {
            let yearLabel = years == 1 ? "1 year" : "\(years) years"
            guard days > 0 else { return "\(yearLabel) ago" }
            let dayLabel = days == 1 ? "1 day" : "\(days) days"
            return "\(yearLabel) \(dayLabel) ago"
        }
        if days == 1 { return "1 day ago" }
        if days > 1 { return "\(days) days ago" }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(Locale(identifier: "en_US"))
        )
    }
}
