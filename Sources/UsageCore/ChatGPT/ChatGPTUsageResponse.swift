import Foundation

/// The body of `GET https://chatgpt.com/backend-api/wham/usage`, the endpoint the Codex CLI
/// uses for your ChatGPT plan's usage limits. Undocumented; decoded as forgivingly as Claude's.
public struct ChatGPTUsageResponse: Sendable, Equatable {
    public var planType: String?
    public var rateLimit: RateLimit?
    public var codeReviewRateLimit: RateLimit?
    public var additionalRateLimits: [NamedLimit]?

    public struct RateLimit: Sendable, Equatable {
        public var allowed: Bool?
        public var limitReached: Bool?
        public var primaryWindow: Window?
        public var secondaryWindow: Window?
    }

    public struct Window: Sendable, Equatable {
        public var usedPercent: Double?
        public var limitWindowSeconds: Int?
        public var resetAfterSeconds: Int?
        public var resetAt: Date?
    }

    public struct NamedLimit: Sendable, Equatable {
        public var limitName: String?
        public var meteredFeature: String?
        public var rateLimit: RateLimit?
    }

    public static func decode(_ data: Data) throws -> ChatGPTUsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ChatGPTUsageResponse.self, from: data)
    }

    /// One row per usage window: the plan's own windows first, then code review and any others.
    public func rows(now: Date = .now) -> [LimitRow] {
        var rows: [LimitRow] = []
        Self.append(rateLimit, label: nil, id: "chatgpt", now: now, to: &rows)
        Self.append(codeReviewRateLimit, label: "Code review", id: "chatgpt-code-review", now: now, to: &rows)
        for (index, extra) in (additionalRateLimits ?? []).enumerated() {
            let label = Format.limitName(extra.limitName ?? extra.meteredFeature ?? "Other")
            Self.append(extra.rateLimit, label: label, id: "chatgpt-extra-\(index)", now: now, to: &rows)
        }
        return rows.map { $0.rolledOver(at: now) }
    }

    private static func append(_ limit: RateLimit?, label: String?, id: String, now: Date, to rows: inout [LimitRow]) {
        guard let limit else { return }
        let windows = [limit.primaryWindow, limit.secondaryWindow].compactMap { $0 }
        let highest = windows.compactMap(\.usedPercent).max()
        let blocked = limit.limitReached == true || limit.allowed == false

        for (index, window) in windows.enumerated() {
            let span = Format.windowName(seconds: window.limitWindowSeconds)
            var severity = Severity(percent: window.usedPercent)
            // When the server says the limit is hit, the fullest window is the one that hit it.
            if blocked, window.usedPercent == highest {
                severity = .critical
            }
            rows.append(LimitRow(
                id: "\(id)-\(index)",
                title: label.map { "\(span) · \($0)" } ?? span,
                percent: window.usedPercent,
                resetsAt: window.resetAt ?? window.resetAfterSeconds.map { now.addingTimeInterval(TimeInterval($0)) },
                severity: severity
            ))
        }
    }
}

extension ChatGPTUsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case planType, rateLimit, codeReviewRateLimit, additionalRateLimits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = container.lenient(String.self, .planType)
        rateLimit = container.lenient(RateLimit.self, .rateLimit)
        codeReviewRateLimit = container.lenient(RateLimit.self, .codeReviewRateLimit)
        additionalRateLimits = container.lenient([Lossy<NamedLimit>].self, .additionalRateLimits)?.compactMap(\.value)
    }
}

extension ChatGPTUsageResponse.RateLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case allowed, limitReached, primaryWindow, secondaryWindow
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowed = container.lenient(Bool.self, .allowed)
        limitReached = container.lenient(Bool.self, .limitReached)
        primaryWindow = container.lenient(ChatGPTUsageResponse.Window.self, .primaryWindow)
        secondaryWindow = container.lenient(ChatGPTUsageResponse.Window.self, .secondaryWindow)
    }
}

extension ChatGPTUsageResponse.Window: Decodable {
    private enum CodingKeys: String, CodingKey {
        case usedPercent, limitWindowSeconds, resetAfterSeconds, resetAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = container.lenient(Double.self, .usedPercent)
        limitWindowSeconds = container.lenient(Int.self, .limitWindowSeconds)
        resetAfterSeconds = container.lenient(Int.self, .resetAfterSeconds)
        resetAt = container.lenient(Double.self, .resetAt).map { Date(timeIntervalSince1970: $0) }
    }
}

extension ChatGPTUsageResponse.NamedLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case limitName, meteredFeature, rateLimit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitName = container.lenient(String.self, .limitName)
        meteredFeature = container.lenient(String.self, .meteredFeature)
        rateLimit = container.lenient(ChatGPTUsageResponse.RateLimit.self, .rateLimit)
    }
}
