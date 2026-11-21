import Foundation

/// The body of `GET https://api.anthropic.com/api/oauth/usage`, the undocumented endpoint behind
/// Claude Code's `/usage` command.
///
/// Only the fields this app uses are modelled, and decoding is deliberately forgiving: unknown
/// fields are ignored and malformed entries are dropped rather than failing the whole response.
public struct ClaudeUsageResponse: Sendable, Equatable {
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

    public static func decode(_ data: Data) throws -> ClaudeUsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ClaudeUsageResponse.self, from: data)
    }

    /// One row per limit, with the session first and always present.
    public func rows(now: Date = .now) -> [LimitRow] {
        let limits = limits ?? []
        var rows: [LimitRow] = []

        if let session = limits.first(where: { $0.kind == "session" }) {
            rows.append(Self.row(for: session, id: "session"))
        } else {
            rows.append(Self.row(id: "session", title: "Session (5h)", window: fiveHour))
        }

        if limits.isEmpty {
            // Older response shape, without `limits`.
            let legacy: [(id: String, title: String, window: Window?)] = [
                ("seven_day", "Weekly · all models", sevenDay),
                ("seven_day_opus", "Weekly · Opus", sevenDayOpus),
                ("seven_day_sonnet", "Weekly · Sonnet", sevenDaySonnet),
            ]
            for entry in legacy where entry.window != nil {
                rows.append(Self.row(id: entry.id, title: entry.title, window: entry.window))
            }
        } else {
            for (index, limit) in limits.enumerated() where limit.kind != "session" {
                rows.append(Self.row(for: limit, id: "\(limit.kind)-\(index)"))
            }
        }

        return rows.map { $0.rolledOver(at: now) }
    }

    static func title(for limit: Limit) -> String {
        switch limit.kind {
        case "session":
            return "Session (5h)"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            return "Weekly · \(limit.scopeName ?? "scoped")"
        default:
            let name = Format.limitName(limit.group ?? (limit.kind.isEmpty ? "limit" : limit.kind))
            return limit.scopeName.map { "\(name) · \($0)" } ?? name
        }
    }

    private static func row(for limit: Limit, id: String) -> LimitRow {
        LimitRow(
            id: id,
            title: title(for: limit),
            percent: limit.percent,
            resetsAt: limit.resetsAt,
            severity: Severity(serverValue: limit.severity, percent: limit.percent),
            windowLength: windowLength(kind: limit.kind, group: limit.group)
        )
    }

    private static func row(id: String, title: String, window: Window?) -> LimitRow {
        LimitRow(
            id: id,
            title: title,
            percent: window?.utilization,
            resetsAt: window?.resetsAt,
            severity: Severity(percent: window?.utilization),
            windowLength: id == "session" ? 5 * 3600 : 7 * 86_400
        )
    }

    /// The server doesn't say how long each window is, but its kinds and groups do.
    static func windowLength(kind: String, group: String?) -> TimeInterval? {
        let name = "\(kind) \(group ?? "")"
        if name.contains("session") { return 5 * 3600 }
        if name.contains("daily") { return 86_400 }
        if name.contains("weekly") { return 7 * 86_400 }
        return nil
    }
}

extension ClaudeUsageResponse: Decodable {
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

extension ClaudeUsageResponse.Window: Decodable {
    private enum CodingKeys: String, CodingKey {
        case utilization, resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = Sanitise.percent(container.number(.utilization))
        resetsAt = container.lenient(String.self, .resetsAt).flatMap(ISODate.parse) ?? Sanitise.epoch(container.number(.resetsAt))
    }
}

extension ClaudeUsageResponse.Limit: Decodable {
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
        group = container.text(.group)
        percent = Sanitise.percent(container.number(.percent))
        severity = container.text(.severity)
        resetsAt = container.lenient(String.self, .resetsAt).flatMap(ISODate.parse) ?? Sanitise.epoch(container.number(.resetsAt))
        if let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope) {
            scopeName = Self.name(in: scope, .model) ?? Self.name(in: scope, .surface)
        }
    }

    /// A scope entry may be a plain string or an object carrying a `display_name`.
    private static func name(in container: KeyedDecodingContainer<ScopeKeys>, _ key: ScopeKeys) -> String? {
        if let name = container.text(key) {
            return name
        }
        let named = container.lenient(Named.self, key)
        return [named?.displayName, named?.id].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
