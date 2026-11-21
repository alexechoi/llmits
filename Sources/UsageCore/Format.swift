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
        let formatter = Formatters.date("EEEjjmm", locale: locale, timeZone: timeZone)
        return "resets \(formatter.string(from: roundedToMinute(date)))"
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
                if let interval = formatter.string(from: (seconds / 60).rounded(.up) * 60) {
                    parts.append("resets in \(interval)")
                }
            } else {
                let formatter = Formatters.date("EEEEjjmm", locale: locale, timeZone: timeZone)
                parts.append("resets \(formatter.string(from: roundedToMinute(resetsAt)))")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// A clock time such as "20:15", in the user's preferred hour cycle.
    public static func time(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        Formatters.date("jjmm", locale: locale, timeZone: timeZone).string(from: date)
    }

    /// "Max 20x" from `max` plus `default_claude_max_20x`; "Pro" from `pro`.
    public static func claudePlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType, !type.isEmpty else { return nil }
        let name = type.prefix(1).uppercased() + type.dropFirst()
        if let tier = rateLimitTier, let match = tier.firstMatch(of: /_(\d+x)$/) {
            return "\(name) \(match.1)"
        }
        return name
    }

    /// A ChatGPT plan's display name: "Pro Lite" from `prolite`, "Plus" from `plus`.
    public static func chatGPTPlan(_ planType: String?) -> String? {
        guard let raw = planType?.lowercased(), !raw.isEmpty else { return nil }
        let known = [
            "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite", "promax": "Pro Max",
            "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu", "education": "Edu",
            "k12": "K-12", "free_workspace": "Free Workspace", "guest": "Guest",
        ]
        if let name = known[raw] { return name }
        if raw.hasPrefix("ent") { return "Enterprise" }
        if raw.contains("business") { return "Business" }
        return limitName(raw).split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// "Session (5h)", "Daily", "Weekly" or "Monthly" for a usage window's length.
    public static func windowName(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "Usage" }
        switch seconds {
        case 5 * 3600: return "Session (5h)"
        case 86_400: return "Daily"
        case 604_800: return "Weekly"
        case 28 * 86_400 ... 31 * 86_400: return "Monthly"
        case ..<3600: return "\(Int((Double(seconds) / 60).rounded()))-minute"
        case ..<86_400: return "\(Int((Double(seconds) / 3600).rounded()))-hour"
        default: return "\(Int((Double(seconds) / 86_400).rounded()))-day"
        }
    }

    /// A readable name for a server identifier: "Code review" from `code_review`.
    public static func limitName(_ identifier: String) -> String {
        let words = identifier.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Rounds rather than truncates, so a reset at 04:59:59.9 reads as 05:00.
    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }
}

/// Date formatters are expensive to create and the menu re-renders often, so each distinct
/// template, locale and time zone gets one formatter, reused from then on.
private enum Formatters {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var formatters: [String: DateFormatter] = [:]
    }

    private static let cache = Cache()

    static func date(_ template: String, locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let key = "\(template)|\(locale.identifier)|\(timeZone.identifier)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.formatters[key] {
            return formatter
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        cache.formatters[key] = formatter
        return formatter
    }
}
