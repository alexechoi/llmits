import Foundation

/// Claude plan limits, read with the login Claude Code keeps in the keychain.
public actor ClaudeSource: UsageSource {
    public nonisolated let service = Service.claude

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let loadCredentials: @Sendable () throws -> ClaudeCredentials
    private let get: @Sendable (URL, [String: String]) async throws -> HTTP.Reply
    /// Reading the keychain means launching `security`, which costs far more than the request,
    /// so the token stays in memory until it expires or is rejected.
    private var cached: ClaudeCredentials?

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
        if cached.map({ $0.isExpired(at: now) }) ?? true {
            cached = try? loadCredentials()
        }
        guard let credentials = cached else { return .notSignedIn }

        let plan = Format.claudePlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
        if credentials.isExpired(at: now) {
            return .tokenExpired(plan: plan)
        }

        let reply: HTTP.Reply
        do {
            reply = try await get(Self.endpoint, [
                "Authorization": "Bearer \(credentials.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
            ])
        } catch {
            return .failed(error.localizedDescription)
        }

        switch reply.status {
        case 200:
            guard let usage = try? ClaudeUsageResponse.decode(reply.data) else {
                return .failed("Unexpected response from Anthropic")
            }
            return .success(ServiceUsage(service: .claude, plan: plan, rows: usage.rows(now: now)))
        case 401:
            // Claude Code may have renewed the token since it was cached: re-read it and, if it
            // changed, try once more.
            cached = try? loadCredentials()
            if retryingRejectedToken, let fresh = cached, fresh.accessToken != credentials.accessToken {
                return await fetch(now: now, retryingRejectedToken: false)
            }
            cached = nil
            return .tokenExpired(plan: plan)
        case 403, 429:
            // Claude Code treats both as rate limiting on this endpoint.
            return .rateLimited(retryAfter: reply.retryAfter)
        case let status:
            return .failed("Anthropic returned HTTP \(status)")
        }
    }
}
