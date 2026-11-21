import Foundation

public enum Severity: Int, Codable, Comparable, Sendable {
    case normal, warning, critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Prefers the server's own label, falling back to thresholds when it's missing or unfamiliar.
    init(serverValue: String?, percent: Double?) {
        switch serverValue?.lowercased() {
        case "critical": self = .critical
        case "warning", "high", "elevated": self = .warning
        case "normal", "low", "ok": self = .normal
        default: self.init(percent: percent)
        }
    }

    init(percent: Double?) {
        switch percent ?? 0 {
        case 90.0...: self = .critical
        case 75.0...: self = .warning
        default: self = .normal
        }
    }
}

/// One limit in the dropdown.
public struct LimitRow: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `nil` when the window isn't open, e.g. no 5-hour session is in progress.
    public var percent: Double?
    public var resetsAt: Date?
    public var severity: Severity
    /// How long the window lasts, when known: 5 hours for a session, 7 days for a week.
    public var windowLength: TimeInterval?

    public init(
        id: String,
        title: String,
        percent: Double?,
        resetsAt: Date?,
        severity: Severity,
        windowLength: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
        self.windowLength = windowLength
    }

    /// How much of the current window has passed, from 0 to 1. Compared with the share used,
    /// it shows whether usage is running ahead of the window.
    public func elapsedFraction(at now: Date) -> Double? {
        guard percent != nil, let resetsAt, let windowLength, windowLength > 0, resetsAt > now else { return nil }
        return min(max(1 - resetsAt.timeIntervalSince(now) / windowLength, 0), 1)
    }

    public enum Pace: Sendable, Equatable {
        /// Usage is at or behind an even pace through the window.
        case onTrack
        /// Usage is running more than a few points ahead of an even pace.
        case ahead
    }

    /// Whether usage is keeping up with the window. `nil` early in a window, when any use at all
    /// would look "ahead", and once the limit is used up, when pace no longer matters.
    public func pace(at now: Date) -> Pace? {
        guard let percent, percent < 100, let elapsed = elapsedFraction(at: now), elapsed >= 0.1 else { return nil }
        return percent - elapsed * 100 > 5 ? .ahead : .onTrack
    }

    /// Shows a window whose reset time has passed as reset, so stale data never keeps reporting
    /// a limit that has since rolled over.
    public func rolledOver(at now: Date) -> LimitRow {
        guard let resetsAt, resetsAt <= now else { return self }
        var row = self
        // A new weekly window starts straight away; a new session only starts on next use.
        row.percent = id == "session" ? nil : 0
        row.resetsAt = nil
        row.severity = .normal
        return row
    }
}

public enum UsageSummary {
    /// The limit closest to being hit: the highest percentage, with ties broken by severity.
    public static func tightest(_ rows: [LimitRow]) -> LimitRow? {
        rows.filter { $0.percent != nil }
            .max { ($0.percent ?? 0, $0.severity) < ($1.percent ?? 0, $1.severity) }
    }

    /// The tightest limit across several services, and which service it belongs to.
    public static func tightest(in usages: [ServiceUsage], now: Date = .now) -> (service: Service, row: LimitRow)? {
        var best: (service: Service, row: LimitRow)?
        for usage in usages {
            guard let row = tightest(usage.rows(at: now)) else { continue }
            if let current = best,
               (row.percent ?? 0, row.severity) <= (current.row.percent ?? 0, current.row.severity) {
                continue
            }
            best = (usage.service, row)
        }
        return best
    }
}
