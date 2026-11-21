import Foundation

public enum Severity: Int, Comparable, Sendable {
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
public struct LimitRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `nil` when the window isn't open, e.g. no 5-hour session is in progress.
    public var percent: Double?
    public var resetsAt: Date?
    public var severity: Severity

    public init(id: String, title: String, percent: Double?, resetsAt: Date?, severity: Severity) {
        self.id = id
        self.title = title
        self.percent = percent
        self.resetsAt = resetsAt
        self.severity = severity
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
