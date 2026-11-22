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
        /// The last check found no login. Tools briefly remove a login while replacing it, so a
        /// service only counts as signed out once it's missing twice in a row.
        public var loginMissing = false

        public init() {}
    }

    /// A limit the menu bar shows.
    public struct Headline: Sendable, Equatable {
        public var service: Service
        public var row: LimitRow
        /// The numbers behind it are out of date.
        public var isStale: Bool
    }

    /// How often each service is checked while all's well. Usage moves slowly, the menu
    /// refreshes whenever it opens, and Anthropic's usage endpoint rate-limits eagerly.
    public static let pollInterval: TimeInterval = 300
    /// How often an expired login, a dropped connection or a missing login is checked again.
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
    /// Numbers this recent aren't fetched again, even for Refresh or opening the menu: Anthropic's
    /// usage endpoint rate-limits a second request that soon, and usage won't have moved.
    public static let freshFor: TimeInterval = 120
    /// The longest wait the tracker sets between checks, other than a rate limit's backoff.
    static let longestWait = max(pollInterval, signInCheck, quickRetry, freshFor)
    /// How far the clock may step back (as time syncing can nudge it) before a time recorded
    /// earlier counts as being in the future.
    static let clockSlack: TimeInterval = 60

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

    /// The services worth fetching now: those whose check is due and, when forced (Refresh,
    /// opening the menu, waking from sleep), any without numbers from the last two minutes.
    /// Never one still backing off after being rate limited.
    public func servicesToFetch(from services: [Service], force: Bool, now: Date) -> [Service] {
        services.filter { service in
            let state = states[service] ?? State()
            guard !Self.isBackingOff(state, at: now) else { return false }
            return Self.isDue(state, at: now) || (force && !Self.isFresh(state, at: now))
        }
    }

    /// When something next changes: a check comes due, a service's numbers go out of date, or a
    /// window resets. The app wakes then, to fetch or just to redraw.
    public func nextWake(after now: Date) -> Date {
        var times: [Date] = []
        for state in states.values {
            if Self.isBackingOff(state, at: now), let until = state.backoffUntil {
                times.append(until)
            } else if Self.isDue(state, at: now) {
                return now
            } else {
                times.append(state.nextFetch)
            }
            guard state.signedIn else { continue }
            if let updated = state.lastUpdated {
                times.append(updated.addingTimeInterval(Self.staleAfter))
            }
            times += (state.usage?.rows ?? []).compactMap(\.resetsAt)
        }
        // Moments already here or gone have been drawn.
        return times.filter { $0 > now }.min() ?? now.addingTimeInterval(Self.pollInterval)
    }

    public mutating func record(_ outcome: FetchOutcome, for service: Service, at now: Date) {
        var state = states[service] ?? State()
        if outcome == .notSignedIn, state.signedIn, !state.loginMissing {
            // Missing once: keep everything as it was and look again shortly.
            state.loginMissing = true
            state.nextFetch = now.addingTimeInterval(Self.quickRetry)
            states[service] = state
            return
        }
        state.loginMissing = false
        state.backoffUntil = nil
        if case .success = outcome {
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
            // The request carried a login, so the service is signed in whatever came back.
            state.signedIn = true
            // Honour the server's Retry-After (at least a minute), else wait 5 minutes; double
            // for each rate limit in a row, up to an hour.
            state.rateLimitStreak = min(state.rateLimitStreak + 1, 8)
            let base = retryAfter.flatMap { $0.isFinite && $0 > 0 ? max($0, 60) : nil } ?? Self.rateLimitBackoff
            let wait = min(base * pow(2, Double(min(state.rateLimitStreak - 1, 6))), Self.maxBackoff)
            let until = now.addingTimeInterval(wait)
            state.problem = .rateLimited(until: until)
            state.backoffUntil = until
            state.nextFetch = until
        case let .failed(failure):
            // Every other failure comes after a login was found and used. An unreadable one may
            // not exist at all, so it doesn't sign a service in by itself.
            if failure != .loginUnreadable {
                state.signedIn = true
            }
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
        // is how old they are. Numbers from the future mean the clock was set back, and there's
        // no telling how old those are.
        let age = now.timeIntervalSince(updated)
        return age > Self.staleAfter || age < -Self.clockSlack
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

    /// Whether a check has come. One due further ahead than any wait the tracker sets means the
    /// clock was set back, so it's due now rather than once the clock catches up.
    static func isDue(_ state: State, at now: Date) -> Bool {
        guard !isBackingOff(state, at: now) else { return false }
        let wait = state.nextFetch.timeIntervalSince(now)
        return wait <= 0 || wait > longestWait
    }

    /// Whether a rate limit's wait is still running. One longer than any backoff the tracker sets
    /// means the clock was set back, so it's over.
    static func isBackingOff(_ state: State, at now: Date) -> Bool {
        guard let until = state.backoffUntil else { return false }
        let wait = until.timeIntervalSince(now)
        return wait > 0 && wait <= maxBackoff
    }

    /// Whether a service's numbers are from the last two minutes. Numbers from the future aren't.
    static func isFresh(_ state: State, at now: Date) -> Bool {
        guard let updated = state.lastUpdated else { return false }
        let age = now.timeIntervalSince(updated)
        return age > -clockSlack && age < freshFor
    }
}

extension UsageTracker {
    /// What's kept across relaunches, so a restart never leaves the menu bar blank or asks a
    /// server again too soon: each service's last numbers, and any rate limit's wait. Never tokens.
    public struct Snapshot: Codable, Sendable, Equatable {
        public struct Saved: Codable, Sendable, Equatable {
            public var usage: ServiceUsage?
            public var lastUpdated: Date?
            public var backoffUntil: Date?
            public var rateLimitStreak: Int?

            public init(usage: ServiceUsage? = nil, lastUpdated: Date? = nil, backoffUntil: Date? = nil, rateLimitStreak: Int? = nil) {
                self.usage = usage
                self.lastUpdated = lastUpdated
                self.backoffUntil = backoffUntil
                self.rateLimitStreak = rateLimitStreak
            }
        }

        public var services: [Service: Saved] = [:]

        public init() {}

        private enum CodingKeys: String, CodingKey {
            case services
        }

        /// Keyed by service name, and lenient: an entry this build can't read (one saved by a
        /// newer version, say) drops only itself.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            for (name, entry) in container.lenient([String: Lossy<Saved>].self, .services) ?? [:] {
                if let service = Service(rawValue: name), let saved = entry.value {
                    services[service] = saved
                }
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let named = Dictionary(uniqueKeysWithValues: services.map { ($0.key.rawValue, $0.value) })
            try container.encode(named, forKey: .services)
        }

        public func encoded() -> Data? {
            try? JSONEncoder().encode(self)
        }

        public static func decode(_ data: Data) -> Snapshot? {
            try? JSONDecoder().decode(Snapshot.self, from: data)
        }
    }

    public var snapshot: Snapshot {
        var snapshot = Snapshot()
        for (service, state) in states where state.signedIn && (state.usage != nil || state.backoffUntil != nil) {
            snapshot.services[service] = .init(
                usage: state.usage,
                lastUpdated: state.lastUpdated,
                backoffUntil: state.backoffUntil,
                rateLimitStreak: state.backoffUntil == nil ? nil : state.rateLimitStreak
            )
        }
        return snapshot
    }

    /// Starts from what was saved. The numbers show at once (as out of date, if they're old), and
    /// each service is checked once its numbers are two minutes old and any rate limit's wait is
    /// over. A service whose login has gone since drops out when its checks find no login.
    public mutating func restore(_ snapshot: Snapshot, at now: Date) {
        for (service, saved) in snapshot.services where states[service] == nil {
            var state = State()
            state.signedIn = true
            if let usage = saved.usage, let updated = saved.lastUpdated {
                state.usage = usage
                state.plan = usage.plan
                state.lastUpdated = updated
                state.nextFetch = updated.addingTimeInterval(Self.freshFor)
            }
            if let until = saved.backoffUntil {
                state.backoffUntil = until
                if Self.isBackingOff(state, at: now) {
                    state.nextFetch = max(state.nextFetch, until)
                    state.problem = .rateLimited(until: until)
                    state.rateLimitStreak = min(max(saved.rateLimitStreak ?? 1, 1), 8)
                } else {
                    state.backoffUntil = nil
                }
            }
            guard state.usage != nil || state.backoffUntil != nil else { continue }
            states[service] = state
        }
    }
}
