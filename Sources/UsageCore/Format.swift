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
        // Round rather than truncate, so a reset at 04:59:59.9 reads as 05:00.
        let rounded = Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        return "resets \(formatter.string(from: rounded))"
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
