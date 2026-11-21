import Foundation

public enum FetchOutcome: Sendable {
    case success(UsageResponse, plan: String?)
    /// No Claude Code login was found on this Mac.
    case notSignedIn
    /// The stored access token has expired or was rejected. Claude Code refreshes it the next time it runs.
    case tokenExpired(plan: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Reads the current credentials and fetches usage. Never modifies the stored credentials.
    public func fetch(now: Date = .now) async -> FetchOutcome {
        let credentials: Credentials
        do {
            credentials = try CredentialStore.load()
        } catch {
            return .notSignedIn
        }
        let plan = Format.plan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier)
        if credentials.isExpired(at: now) {
            return .tokenExpired(plan: plan)
        }

        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-usage-bar", forHTTPHeaderField: "User-Agent")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            return .failed(error.localizedDescription)
        }
        let (data, response) = result
        let http = response as? HTTPURLResponse

        switch http?.statusCode ?? 0 {
        case 200:
            guard let usage = try? UsageResponse.decode(data) else {
                return .failed("Unexpected response from Anthropic")
            }
            return .success(usage, plan: plan)
        case 401:
            return .tokenExpired(plan: plan)
        case 403, 429:
            // Claude Code treats both as rate limiting on this endpoint.
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case let status:
            return .failed("HTTP \(status) from Anthropic")
        }
    }
}
