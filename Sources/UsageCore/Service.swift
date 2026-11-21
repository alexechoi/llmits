import Foundation

/// A service whose plan limits the app can show.
public enum Service: String, CaseIterable, Sendable, Identifiable {
    case claude
    case chatGPT

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    /// The command-line tool whose login the app reads.
    public var loginTool: String {
        switch self {
        case .claude: "Claude Code"
        case .chatGPT: "Codex"
        }
    }
}

/// One service's limits as they were when fetched.
public struct ServiceUsage: Sendable, Equatable {
    public var service: Service
    /// The plan's display name, e.g. "Max 20x" or "Pro Lite".
    public var plan: String?
    public var rows: [LimitRow]

    public init(service: Service, plan: String?, rows: [LimitRow]) {
        self.service = service
        self.plan = plan
        self.rows = rows
    }

    /// The rows as they stand at `now`, with any window whose reset has passed shown as reset.
    public func rows(at now: Date) -> [LimitRow] {
        rows.map { $0.rolledOver(at: now) }
    }
}

public enum FetchOutcome: Sendable, Equatable {
    case success(ServiceUsage)
    /// No login for this service was found on this Mac.
    case notSignedIn
    /// The stored token has expired or was rejected; its tool renews it the next time it runs.
    case tokenExpired(plan: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case failed(String)
}

/// Fetches one service's usage. Implementations only ever read the stored login.
public protocol UsageSource: Sendable {
    var service: Service { get }
    func fetch(now: Date) async -> FetchOutcome
}

public enum CredentialError: Error, Equatable {
    case notFound
    case malformed
}
