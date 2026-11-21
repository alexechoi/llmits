import Foundation

/// The body of `GET https://api.anthropic.com/api/oauth/usage`, the undocumented endpoint behind
/// Claude Code's `/usage` command.
///
/// Only the fields this app uses are modelled, and decoding is deliberately forgiving: unknown
/// fields are ignored and malformed entries are dropped rather than failing the whole response.
public struct UsageResponse: Sendable, Equatable {
    /// The 5-hour session window; `nil` when no session is in progress.
    public var fiveHour: Window?
    public var sevenDay: Window?
    public var sevenDayOpus: Window?
    public var sevenDaySonnet: Window?
    /// Every meter the server currently tracks. Preferred over the fields above when present.
    public var limits: [Limit]?

    public struct Window: Sendable, Equatable {
        public var utilization: Double?
        public var resetsAt: Date?
    }

    public struct Limit: Sendable, Equatable {
        /// The server's meter kind, e.g. `session`, `weekly_all` or `weekly_scoped`.
        public var kind: String
        public var group: String?
        public var percent: Double?
        /// The server's own assessment, e.g. `normal` or `critical`.
        public var severity: String?
        public var resetsAt: Date?
        /// What a scoped limit applies to, e.g. a model's display name.
        public var scopeName: String?
    }

    public static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageResponse.self, from: data)
    }
}

extension UsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fiveHour, sevenDay, sevenDayOpus, sevenDaySonnet, limits
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = container.lenient(Window.self, .fiveHour)
        sevenDay = container.lenient(Window.self, .sevenDay)
        sevenDayOpus = container.lenient(Window.self, .sevenDayOpus)
        sevenDaySonnet = container.lenient(Window.self, .sevenDaySonnet)
        limits = container.lenient([Lossy<Limit>].self, .limits)?.compactMap(\.value)
    }
}

extension UsageResponse.Window: Decodable {
    private enum CodingKeys: String, CodingKey {
        case utilization, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = container.lenient(Double.self, .utilization)
        resetsAt = container.lenient(String.self, .resetsAt).flatMap(ISODate.parse)
    }
}

extension UsageResponse.Limit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, resetsAt, scope
    }

    private enum ScopeKeys: String, CodingKey {
        case model, surface
    }

    private struct Named: Decodable {
        var displayName: String?
        var id: String?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        group = container.lenient(String.self, .group)
        percent = container.lenient(Double.self, .percent)
        severity = container.lenient(String.self, .severity)
        resetsAt = container.lenient(String.self, .resetsAt).flatMap(ISODate.parse)
        if let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope) {
            scopeName = Self.name(in: scope, .model) ?? Self.name(in: scope, .surface)
        }
    }

    /// A scope entry may be a plain string or an object carrying a `display_name`.
    private static func name(in container: KeyedDecodingContainer<ScopeKeys>, _ key: ScopeKeys) -> String? {
        if let name = container.lenient(String.self, key) {
            return name
        }
        let named = container.lenient(Named.self, key)
        return named?.displayName ?? named?.id
    }
}

extension KeyedDecodingContainer {
    /// Decodes a value if it's present and well-formed; anything else becomes `nil`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

/// Wraps an array element so that one malformed entry doesn't fail the whole array.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

enum ISODate {
    /// Parses timestamps such as `2026-11-25T05:00:00.204008+00:00`.
    static func parse(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        // ISO8601DateFormatter can reject microsecond precision, so retry without the fraction.
        formatter.formatOptions = [.withInternetDateTime]
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}
