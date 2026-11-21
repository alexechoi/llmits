import Foundation

public enum Format {
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    /// "resets in 42m", "resets in 3h 5m", or "resets Wed 05:00" once it's more than a day away.
    public static func reset(
        _ date: Date?,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date, date > now else { return nil }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 {
            return "resets in \(minutes)m"
        }
        if minutes < 24 * 60 {
            return "resets in \(minutes / 60)h \(minutes % 60)m"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEjjmm")
        return "resets \(formatter.string(from: roundedToMinute(date)))"
    }

    /// Rounds rather than truncates, so a reset at 04:59:59.9 reads as 05:00.
    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    /// A row's title for VoiceOver, e.g. "Weekly, Fable" rather than reading out the "·".
    public static func spokenTitle(_ row: LimitRow) -> String {
        row.title.replacingOccurrences(of: " · ", with: ", ")
    }

    /// A row's value for VoiceOver, e.g. "94 percent used, resets in 3 hours, 5 minutes".
    public static func spokenValue(
        _ row: LimitRow,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let percent = row.percent else { return "No active session" }
        var parts = ["\(Int(percent.rounded())) percent used"]
        if let resetsAt = row.resetsAt, resetsAt > now {
            let seconds = resetsAt.timeIntervalSince(now)
            if seconds < 24 * 3600 {
                let formatter = DateComponentsFormatter()
                formatter.unitsStyle = .full
                formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
                var calendar = Calendar.current
                calendar.locale = locale
                formatter.calendar = calendar
                let rounded = (seconds / 60).rounded(.up) * 60
                if let interval = formatter.string(from: rounded) {
                    parts.append("resets in \(interval)")
                }
            } else {
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.timeZone = timeZone
                formatter.setLocalizedDateFormatFromTemplate("EEEEjjmm")
                parts.append("resets \(formatter.string(from: roundedToMinute(resetsAt)))")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// A clock time such as "20:15", in the user's preferred hour cycle.
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jjmm")
        return formatter.string(from: date)
    }

    /// "Max 20x" from `max` plus `default_claude_max_20x`; "Pro" from `pro`.
    public static func plan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        let name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier = rateLimitTier, let match = tier.firstMatch(of: /_(\d+x)$/) {
            return "\(name) \(match.1)"
        }
        return name
    }
}
