import Foundation

/// ChatGPT plan limits, read with the ChatGPT login the Codex CLI keeps in `~/.codex/auth.json`.
/// The limits are plan-wide; the Codex login is simply how the app can see them.
public actor ChatGPTSource: UsageSource {
    public nonisolated let service = Service.chatGPT

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let loadCredentials: @Sendable () throws -> ChatGPTCredentials
    private let get: @Sendable (URL, [String: String]) async throws -> HTTP.Reply

    public init() {
        self.init(loadCredentials: ChatGPTCredentialStore.load, get: HTTP.get)
    }

    init(
        loadCredentials: @escaping @Sendable () throws -> ChatGPTCredentials,
        get: @escaping @Sendable (URL, [String: String]) async throws -> HTTP.Reply
    ) {
        self.loadCredentials = loadCredentials
        self.get = get
    }

    public func fetch(now: Date) async -> FetchOutcome {
        // A small file read, so it's re-read on every poll and always matches what Codex last wrote.
        guard let credentials = try? loadCredentials() else { return .notSignedIn }
        if credentials.isExpired(at: now) {
            return .tokenExpired(plan: nil)
        }

        var headers = ["Authorization": "Bearer \(credentials.accessToken)"]
        if let account = credentials.accountID {
            headers["ChatGPT-Account-Id"] = account
        }

        let reply: HTTP.Reply
        do {
            reply = try await get(Self.endpoint, headers)
        } catch {
            return .failed(error.localizedDescription)
        }

        switch reply.status {
        case 200:
            guard let usage = try? ChatGPTUsageResponse.decode(reply.data) else {
                return .failed("Unexpected response from OpenAI")
            }
            return .success(ServiceUsage(
                service: .chatGPT,
                plan: Format.chatGPTPlan(usage.planType),
                rows: usage.rows(now: now)
            ))
        case 401:
            return .tokenExpired(plan: nil)
        case 429:
            return .rateLimited(retryAfter: reply.retryAfter)
        case let status:
            return .failed("OpenAI returned HTTP \(status)")
        }
    }
}
