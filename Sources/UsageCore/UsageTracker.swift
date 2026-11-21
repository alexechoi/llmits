import Foundation

/// What the app knows about each service, and the rules for what to fetch and show, when.
///
/// A value type with the clock passed in, so its behaviour over hours of polling, failures and
/// recoveries can be tested without waiting for any of it.
public struct UsageTracker: Sendable {
    public struct State: Sendable, Equatable {
        public var signedIn = false
        public var usage: ServiceUsage?
        public var plan: String?
        public var lastUpdated: Date?
        /// Why the numbers may be out of date, if they are.
        public var problem: Problem?
        public var nextFetch = Date.distantPast
        /// Set after rate limiting; not even a manual refresh fetches before then.
        public var backoffUntil: Date?
        /// Rate limits in a row, so repeated ones back off further.
        public var rateLimitStreak = 0

        public init() {}
    }

    /// The limit the menu bar shows.
    public struct Headline: Sendable, Equatable {
        public var service: Service
        public var row: LimitRow
        /// The numbers behind it are out of date.
        public var isStale: Bool
    }

    /// How often each service is checked while all's well. Usage moves slowly, the menu
    /// refreshes whenever it opens, and Anthropic's usage endpoint rate-limits eagerly.
    public static let pollInterval: TimeInterval = 300
    /// How often an expired login or a dropped connection is checked again.
    public static let quickRetry: TimeInterval = 60
    /// How often a signed-out service is checked for a new login.
    public static let signInCheck: TimeInterval = 300
    /// Numbers only count as out of date once they're this old, so one failed check (a rate
    /// limit, a network blip, a keychain hiccup) never changes what the menu bar shows.
    public static let staleAfter: TimeInterval = 900
    /// After a rate limit with no usable Retry-After, and the most any backoff waits: the same
    /// 5 minutes and 1 hour Claude Code uses for this endpoint.
    public static let rateLimitBackoff: TimeInterval = 300
    public static let maxBackoff: TimeInterval = 3600

    public private(set) var states: [Service: State] = [:]

    public init() {}

    public func state(of service: Service) -> State? {
        states[service]
    }

    /// Services with a login, in a stable order.
    public var signedInServices: [Service] {
        Service.allCases.filter { states[$0]?.signedIn == true }
    }

    /// True until every service has been checked at least once, or has saved numbers to show.
    public var isLoading: Bool {
        Service.allCases.contains { states[$0] == nil }
    }

    /// The services worth fetching now: those that are due, or all of them when forced (a manual
    /// refresh, opening the menu, waking from sleep), except any still backing off after being
    /// rate limited.
    public func servicesToFetch(from services: [Service], force: Bool, now: Date) -> [Service] {
        services.filter { service in
            let state = states[service] ?? State()
            if let until = state.backoffUntil, until > now { return false }
            return force || state.nextFetch <= now
        }
    }

    /// When the next check is due.
    public func nextWake(after now: Date) -> Date {
        states.values.map(\.nextFetch).min() ?? now.addingTimeInterval(Self.pollInterval)
    }

    public mutating func record(_ outcome: FetchOutcome, for service: Service, at now: Date) {
        var state = states[service] ?? State()
        state.backoffUntil = nil
        if case .rateLimited = outcome {} else if case .success = outcome {
            state.rateLimitStreak = 0
        }

        switch outcome {
        case let .success(usage):
            state.signedIn = true
            state.usage = usage
            state.plan = usage.plan
            state.lastUpdated = now
            state.problem = nil
            state.nextFetch = now.addingTimeInterval(Self.pollInterval)
        case let .tokenExpired(plan):
            state.signedIn = true
            state.plan = plan ?? state.plan
            state.problem = .tokenExpired
            // Until the tool renews the token, each check only re-reads the stored login.
            state.nextFetch = now.addingTimeInterval(Self.quickRetry)
        case .notSignedIn:
            // Only a login that's genuinely gone ends up here; unreadable ones are failures.
            state = State()
            state.nextFetch = now.addingTimeInterval(Self.signInCheck)
        case let .rateLimited(retryAfter):
            // Honour the server's Retry-After (at least a minute), else wait 5 minutes; double
            // for each rate limit in a row, up to an hour.
            state.rateLimitStreak += 1
            let base = retryAfter.flatMap { $0.isFinite && $0 > 0 ? max($0, 60) : nil } ?? Self.rateLimitBackoff
            let wait = min(base * pow(2, Double(min(state.rateLimitStreak - 1, 6))), Self.maxBackoff)
            let until = now.addingTimeInterval(wait)
            state.problem = .rateLimited(until: until)
            state.backoffUntil = until
            state.nextFetch = until
        case let .failed(failure):
            state.problem = .failed(failure)
            let quick = failure == .offline || failure == .loginUnreadable
            state.nextFetch = now.addingTimeInterval(quick ? Self.quickRetry : Self.pollInterval)
        }
        states[service] = state
    }

    /// Whether a service's numbers are old enough to call out of date.
    public func isStale(_ service: Service, at now: Date) -> Bool {
        guard let state = states[service] else { return false }
        guard let updated = state.lastUpdated else { return state.problem != nil }
        // Whatever the reason (failed checks, or numbers saved before a relaunch), what matters
        // is how old they are.
        return now.timeIntervalSince(updated) > Self.staleAfter
    }

    /// The tightest limit across every signed-in service, whether or not its numbers are current.
    ///
    /// Usage within a window only ever rises until the window resets, so an old reading is a
    /// lower bound, not a guess: dropping it could only ever hide a limit that's at least that
    /// full. Windows whose reset has passed are already shown as reset.
    public func headline(at now: Date) -> Headline? {
        let usages = signedInServices.compactMap { states[$0]?.usage }
        guard let top = UsageSummary.tightest(in: usages, now: now) else { return nil }
        return Headline(service: top.service, row: top.row, isStale: isStale(top.service, at: now))
    }
}

extension UsageTracker {
    /// The last numbers for each service, kept across relaunches so a restart (or a rate limit
    /// right after one) never leaves the menu bar blank. Usage and times only; never tokens.
    public struct Snapshot: Codable, Sendable, Equatable {
        public struct Saved: Codable, Sendable, Equatable {
            public var usage: ServiceUsage
            public var lastUpdated: Date
        }

        public var services: [Service: Saved] = [:]

        public func encoded() -> Data? {
            try? JSONEncoder().encode(self)
        }

        public static func decode(_ data: Data) -> Snapshot? {
            try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    public var snapshot: Snapshot {
        var snapshot = Snapshot()
        for (service, state) in states where state.signedIn {
            if let usage = state.usage, let lastUpdated = state.lastUpdated {
                snapshot.services[service] = .init(usage: usage, lastUpdated: lastUpdated)
            }
        }
        return snapshot
    }

    /// Starts from saved numbers: shown at once (as out of date if they're old) and checked
    /// straight away. A service whose login has gone since is dropped by its first check.
    public mutating func restore(_ snapshot: Snapshot) {
        for (service, saved) in snapshot.services where states[service] == nil {
            var state = State()
            state.signedIn = true
            state.usage = saved.usage
            state.plan = saved.usage.plan
            state.lastUpdated = saved.lastUpdated
            states[service] = state
        }
    }

    /// Whether every signed-in service's numbers are recent enough not to refetch when the menu
    /// opens. Two minutes keeps well clear of Anthropic's usage endpoint's rate limit.
    public func isFresh(at now: Date) -> Bool {
        let updates = signedInServices.map { states[$0]?.lastUpdated }
        return !updates.isEmpty && updates.allSatisfy { $0.map { now.timeIntervalSince($0) < Self.freshFor } ?? false }
    }

    public static let freshFor: TimeInterval = 120
}
