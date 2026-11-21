import Foundation

/// Claude plan limits, read with the login Claude Code keeps in the keychain.
public actor ClaudeSource: UsageSource {
    public nonisolated let service = Service.claude

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// How long a token read from the keychain is trusted before re-reading it, so an account
    /// switch or sign-out in Claude Code shows up within minutes rather than at token expiry.
    static let cacheLifetime: TimeInterval = 15 * 60

    private let loadCredentials: @Sendable () throws -> ClaudeCredentials
    private let get: @Sendable (URL, [String: String]) async throws -> HTTP.Reply
    /// Reading the keychain means launching `security`, which costs more than the request, so
    /// the token stays in memory for a while rather than being read on every check.
    private var cached: ClaudeCredentials?
    private var cachedAt: Date?
    /// A token the server has turned down. It's never sent again; until Claude Code stores a
    /// new one, checks only re-read the keychain.
    private var rejectedToken: String?

    public init() {
        self.init(loadCredentials: ClaudeCredentialStore.load, get: HTTP.get)
    }

    init(
        loadCredentials: @escaping @Sendable () throws -> ClaudeCredentials,
        get: @escaping @Sendable (URL, [String: String]) async throws -> HTTP.Reply
    ) {
        self.loadCredentials = loadCredentials
        self.get = get
    }

    public func fetch(now: Date) async -> FetchOutcome {
        await fetch(now: now, retryingRejectedToken: true)
    }

    private func fetch(now: Date, retryingRejectedToken: Bool) async -> FetchOutcome {
        let cacheIsOld = cachedAt.map { now.timeIntervalSince($0) > Self.cacheLifetime || now < $0 } ?? true
        if cached == nil || cached?.isExpired(at: now) == true || cacheIsOld || rejectedToken != nil {
            if let outcome = reloadCredentials(at: now) {
                return outcome
            }
        }
        guard let credentials = cached else { return .notSignedIn }

        let plan = Format.claudePlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
        if credentials.isExpired(at: now) || credentials.accessToken == rejectedToken {
            return .tokenExpired(plan: plan)
        }

        let reply: HTTP.Reply
        do {
            reply = try await get(Self.endpoint, [
                "Authorization": "Bearer \(credentials.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        } catch {
            return .failed(Failure(error))
        }

        switch reply.status {
        case 200:
            rejectedToken = nil
            guard let usage = try? ClaudeUsageResponse.decode(reply.data) else {
                return .failed(.unreadable)
            }
            return .success(ServiceUsage(service: .claude, plan: plan, rows: usage.rows(now: now)))
        case 401:
            rejectedToken = credentials.accessToken
            // Claude Code may have renewed the token since it was cached: re-read it and, if it
            // changed, try once more.
            if let outcome = reloadCredentials(at: now) {
                return outcome
            }
            if retryingRejectedToken, let fresh = cached, fresh.accessToken != rejectedToken {
                return await fetch(now: now, retryingRejectedToken: false)
            }
            return .tokenExpired(plan: plan)
        case 403, 429:
            // Claude Code treats both as rate limiting on this endpoint.
            return .rateLimited(retryAfter: reply.retryAfter)
        case let status:
            return .failed(.server(status: status))
        }
    }

    /// Re-reads the stored login into `cached`, returning an outcome to report instead of
    /// fetching if there is one. Only a login that's genuinely missing means signed out.
    private func reloadCredentials(at now: Date) -> FetchOutcome? {
        do {
            cached = try loadCredentials()
            cachedAt = now
            if cached?.accessToken != rejectedToken {
                rejectedToken = nil
            }
            return nil
        } catch CredentialError.notFound {
            cached = nil
            cachedAt = nil
            rejectedToken = nil
            return .notSignedIn
        } catch {
            // Keep any token in hand: it may still work once the login can be read again.
            return .failed(.loginUnreadable)
        }
    }
}
