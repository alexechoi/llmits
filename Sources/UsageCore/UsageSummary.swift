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

/// One line of the dropdown.
public struct LimitRow: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// `nil` when the window isn't open, e.g. no 5-hour session is in progress.
    public var percent: Double?
    public var resetsAt: Date?
    public var severity: Severity
}

public enum UsageSummary {
    /// One row per limit, with the session first and always present.
    ///
    /// A window whose reset time has passed is shown as reset, so stale data never keeps reporting
    /// a limit that has since rolled over.
    public static func rows(from usage: UsageResponse, now: Date = .now) -> [LimitRow] {
        let limits = usage.limits ?? []
        var rows: [LimitRow] = []

        if let session = limits.first(where: { $0.kind == "session" }) {
            rows.append(row(for: session, id: "session"))
        } else {
            rows.append(row(id: "session", title: "Session (5h)", window: usage.fiveHour))
        }

        if limits.isEmpty {
            // Older response shape, without `limits`.
            rows += [
                usage.sevenDay.map { row(id: "seven_day", title: "Weekly · all models", window: $0) },
                usage.sevenDayOpus.map { row(id: "seven_day_opus", title: "Weekly · Opus", window: $0) },
                usage.sevenDaySonnet.map { row(id: "seven_day_sonnet", title: "Weekly · Sonnet", window: $0) },
            ].compactMap { $0 }
        } else {
            for (index, limit) in limits.enumerated() where limit.kind != "session" {
                rows.append(row(for: limit, id: "\(limit.kind)-\(index)"))
            }
        }

        return rows.map { $0.rolledOver(at: now) }
    }

    /// The limit closest to being hit: the highest percentage, with ties broken by severity.
    public static func tightest(_ rows: [LimitRow]) -> LimitRow? {
        rows.filter { $0.percent != nil }
            .max { ($0.percent ?? 0, $0.severity) < ($1.percent ?? 0, $1.severity) }
    }

    static func title(for limit: UsageResponse.Limit) -> String {
        switch limit.kind {
        case "session":
            return "Session (5h)"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            return "Weekly · \(limit.scopeName ?? "scoped")"
        default:
            let base = (limit.group ?? limit.kind).replacingOccurrences(of: "_", with: " ")
            let name = base.prefix(1).uppercased() + base.dropFirst()
            return limit.scopeName.map { "\(name) · \($0)" } ?? name
        }
    }

    private static func row(for limit: UsageResponse.Limit, id: String) -> LimitRow {
        LimitRow(
            id: id,
            title: title(for: limit),
            percent: limit.percent,
            resetsAt: limit.resetsAt,
            severity: Severity(serverValue: limit.severity, percent: limit.percent)
        )
    }

    private static func row(id: String, title: String, window: UsageResponse.Window?) -> LimitRow {
        LimitRow(
            id: id,
            title: title,
            percent: window?.utilization,
            resetsAt: window?.resetsAt,
            severity: Severity(percent: window?.utilization)
        )
    }
}

extension LimitRow {
    func rolledOver(at now: Date) -> LimitRow {
        guard let resetsAt, resetsAt <= now else { return self }
        var row = self
        // A new weekly window starts straight away; a new session only starts on next use.
        row.percent = id == "session" ? nil : 0
        row.resetsAt = nil
        row.severity = .normal
        return row
    }
}
