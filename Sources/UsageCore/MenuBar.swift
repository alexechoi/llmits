import Foundation

/// A limit someone has chosen to show in the menu bar, identified by its service and title.
/// Titles, unlike row IDs, don't shift when a service starts listing a new limit before it, so a
/// saved choice never lands on a different limit.
public struct LimitChoice: Hashable, Sendable {
    public var service: Service
    public var title: String

    public init(service: Service, title: String) {
        self.service = service
        self.title = title
    }

    /// How it's saved, e.g. "claude/Weekly · all models".
    public var stored: String {
        "\(service.rawValue)/\(title)"
    }

    public init?(stored: String) {
        guard let slash = stored.firstIndex(of: "/"),
              let service = Service(rawValue: String(stored[..<slash])) else { return nil }
        let title = String(stored[stored.index(after: slash)...])
        guard !title.isEmpty else { return nil }
        self.init(service: service, title: title)
    }
}

extension UsageTracker {
    /// The most limits the menu bar shows at once: three rows of dots fit its height.
    public static let menuBarLimit = 3

    /// Every limit that could be shown in the menu bar, in the menu's order.
    public func choices(at now: Date) -> [LimitChoice] {
        signedInServices.flatMap { service in
            (states[service]?.usage?.rows(at: now) ?? []).map { LimitChoice(service: service, title: $0.title) }
        }
    }

    /// What the menu bar shows: the chosen limits that exist now, in the menu's order and at most
    /// three, or the tightest limit when nothing is chosen or none of the chosen exist (say, after
    /// signing out of a service).
    public func menuBarLimits(chosen: Set<LimitChoice>, at now: Date) -> [Headline] {
        if !chosen.isEmpty {
            var shown: [Headline] = []
            // Each choice shows once, as in the submenu, even if two limits share a title.
            var seen = Set<LimitChoice>()
            for service in signedInServices {
                guard let usage = states[service]?.usage else { continue }
                let stale = isStale(service, at: now)
                for row in usage.rows(at: now) {
                    let choice = LimitChoice(service: service, title: row.title)
                    guard chosen.contains(choice), seen.insert(choice).inserted else { continue }
                    shown.append(Headline(service: service, row: row, isStale: stale))
                    if shown.count == Self.menuBarLimit {
                        return shown
                    }
                }
            }
            if !shown.isEmpty {
                return shown
            }
        }
        return headline(at: now).map { [$0] } ?? []
    }

    /// The choices after ticking or unticking one. Choices for limits that aren't there now (a
    /// service signed out, say) are kept for when they're back, but give way to a new pick, so no
    /// more than three are ever saved and every ticked limit that's there is in the menu bar.
    public func toggling(_ choice: LimitChoice, in chosen: Set<LimitChoice>, at now: Date) -> Set<LimitChoice> {
        var chosen = chosen
        if chosen.remove(choice) != nil {
            return chosen
        }
        if chosen.count >= Self.menuBarLimit {
            chosen.formIntersection(choices(at: now))
        }
        if chosen.count < Self.menuBarLimit {
            chosen.insert(choice)
        }
        return chosen
    }

    /// The one whose number the menu bar shows: the most severe, then the fullest, ties going to
    /// the first. Limits with no number yet (a session not started) only count if nothing else has one.
    public static func tightest(of shown: [Headline]) -> Headline? {
        shown.filter { $0.row.percent != nil }
            .max { ($0.row.severity, $0.row.percent ?? 0) < ($1.row.severity, $1.row.percent ?? 0) }
            ?? shown.first
    }
}
