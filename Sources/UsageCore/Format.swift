import Foundation

public enum Format {
    /// Rounds down, so 99.6% reads as 99% and "100%" only ever means used up.
    public static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded(.down)))%"
    }

    /// "Resets in 42m", "Resets in 3h 5m", "Resets tomorrow 05:00" or "Resets Wed 05:00".
    public static func reset(
        _ date: Date?,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        guard let date, date > now else { return nil }
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 {
            return "Resets in \(minutes)m"
        }
        if minutes < 24 * 60 {
            return "Resets in \(minutes / 60)h \(minutes % 60)m"
        }
        let rounded = roundedToMinute(date)
        if isTomorrow(rounded, now: now, timeZone: timeZone) {
            return "Resets tomorrow \(time(rounded, locale: locale, timeZone: timeZone))"
        }
        return "Resets \(Formatters.date("EEEjjmm", locale: locale, timeZone: timeZone).string(from: rounded))"
    }

    /// The line under a row's bar: when it resets and whether usage is keeping pace, e.g.
    /// "Resets Wed 05:00 · ahead of pace", or why there's nothing to show.
    public static func caption(
        _ row: LimitRow,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        if let reset = reset(row.resetsAt, now: now, locale: locale, timeZone: timeZone) {
            return [reset, pace(row.pace(at: now))].compactMap { $0 }.joined(separator: " · ")
        }
        guard row.percent == nil else { return nil }
        return row.id == "session" ? "Starts with your next message" : "No usage yet"
    }

    /// A row's title for VoiceOver, e.g. "Weekly, Fable" rather than reading out the "·".
    public static func spokenTitle(_ row: LimitRow) -> String {
        row.title
            .replacingOccurrences(of: "Session (5h)", with: "5-hour session")
            .replacingOccurrences(of: " · ", with: ", ")
    }

    /// A row's value for VoiceOver, e.g. "Nearly used up, 94 percent used, 60 percent of the
    /// week gone, resets in 3 hours, 5 minutes". Says so when the numbers are out of date.
    public static func spokenValue(
        _ row: LimitRow,
        stale: Bool = false,
        now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard let percent = row.percent else {
            return caption(row, now: now, locale: locale, timeZone: timeZone) ?? "No usage yet"
        }
        var parts: [String] = []
        switch row.severity {
        case .critical: parts.append(percent >= 100 ? "Limit reached" : "Nearly used up")
        case .warning: parts.append("Getting high")
        case .normal: break
        }
        parts.append("\(Int(percent.rounded(.down))) percent used")
        if let elapsed = row.elapsedFraction(at: now) {
            parts.append("\(Int((elapsed * 100).rounded())) percent of the \(spokenWindow(row.windowLength)) gone")
        }
        if let pace = pace(row.pace(at: now)) {
            parts.append(pace)
        }
        if let resetsAt = row.resetsAt, resetsAt > now {
            parts.append(spokenReset(resetsAt, now: now, locale: locale, timeZone: timeZone))
        }
        if stale {
            parts.append("out of date")
        }
        return parts.joined(separator: ", ")
    }

    /// What to tell people when a service's numbers may be out of date, and what happens next.
    public static func problem(_ problem: Problem, service: Service, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch problem {
        case .tokenExpired:
            return "Login expired. Run \(service.loginTool) to renew it."
        case let .rateLimited(until):
            return "Too many requests. Retrying at \(time(until, locale: locale, timeZone: timeZone))."
        case .failed(.offline):
            return "You're offline. Retrying automatically."
        case .failed(.unreadable):
            return "Couldn't read \(service.name) usage. Try updating this app."
        case .failed(.server), .failed(.other):
            return "Couldn't load \(service.name) usage. Retrying automatically."
        }
    }

    /// Technical detail for a problem, if any, e.g. "HTTP 503".
    public static func problemDetail(_ problem: Problem) -> String? {
        switch problem {
        case let .failed(.server(status)): "HTTP \(status)"
        case let .failed(.other(message)): message
        default: nil
        }
    }

    /// "on track" or "ahead of pace": how usage compares with an even pace through the window,
    /// which the mark on each bar shows.
    public static func pace(_ pace: LimitRow.Pace?) -> String? {
        switch pace {
        case .onTrack: "on track"
        case .ahead: "ahead of pace"
        case nil: nil
        }
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

    /// Forgets cached formatters, e.g. after the person changes their region or clock settings.
    public static func clearCaches() {
        Formatters.clear()
    }

    // MARK: - Helpers

    /// Rounds rather than truncates, so a reset at 04:59:59.9 reads as 05:00.
    private static func roundedToMinute(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded() * 60)
    }

    private static func isTomorrow(_ date: Date, now: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return false }
        return calendar.isDate(date, inSameDayAs: tomorrow)
    }

    private static func spokenWindow(_ length: TimeInterval?) -> String {
        switch length {
        case 5 * 3600: "session"
        case 86_400: "day"
        case 604_800: "week"
        default: "window"
        }
    }

    private static func spokenReset(_ date: Date, now: Date, locale: Locale, timeZone: TimeZone) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds < 24 * 3600 {
            let formatter = Formatters.duration(hours: seconds >= 3600, locale: locale)
            if let interval = formatter.string(from: (seconds / 60).rounded(.up) * 60) {
                return "resets in \(interval)"
            }
        }
        let rounded = roundedToMinute(date)
        if isTomorrow(rounded, now: now, timeZone: timeZone) {
            return "resets tomorrow at \(time(rounded, locale: locale, timeZone: timeZone))"
        }
        return "resets \(Formatters.date("EEEEjjmm", locale: locale, timeZone: timeZone).string(from: rounded))"
    }
}

/// Formatters are expensive to create and the menu re-renders often, so each distinct
/// template, locale and time zone gets one formatter, reused from then on.
private enum Formatters {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var formatters: [String: DateFormatter] = [:]
        var durations: [String: DateComponentsFormatter] = [:]
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

    static func duration(hours: Bool, locale: Locale) -> DateComponentsFormatter {
        let key = "\(hours)|\(locale.identifier)"
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.durations[key] {
            return formatter
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = hours ? [.hour, .minute] : [.minute]
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        cache.durations[key] = formatter
        return formatter
    }

    static func clear() {
        cache.lock.lock()
        cache.formatters.removeAll()
        cache.durations.removeAll()
        cache.lock.unlock()
    }
}
