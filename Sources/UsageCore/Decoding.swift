import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value if it's present and well-formed; anything else becomes `nil`.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    /// A number sent either as a number or as a numeric string.
    func number(_ key: Key) -> Double? {
        if let value = lenient(Double.self, key) {
            return value
        }
        return lenient(String.self, key).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// A string that's present and not empty.
    func text(_ key: Key) -> String? {
        lenient(String.self, key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

/// Keeps whatever the servers send within bounds the app can safely show and count with:
/// one absurd value must never crash it or push a date into another millennium.
enum Sanitise {
    /// A percentage: finite and between 0 and 1000.
    static func percent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1000)
    }

    /// A length of time in seconds: finite, not negative, at most 400 days.
    static func seconds(_ value: Double?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 400 * 86_400)
    }

    /// A Unix timestamp in seconds, or in milliseconds, between the years 2000 and 2200.
    static func epoch(_ value: Double?) -> Date? {
        guard var value, value.isFinite else { return nil }
        if value > 100_000_000_000 {
            value /= 1000  // milliseconds
        }
        return date(Date(timeIntervalSince1970: value))
    }

    /// A date between the years 2000 and 2200; anything else is treated as unknown.
    static func date(_ date: Date?) -> Date? {
        guard let date, (946_684_800 ... 7_258_118_400).contains(date.timeIntervalSince1970) else { return nil }
        return date
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
    // Formatters are costly to create and safe to share for parsing, so make each one once.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Parses timestamps such as `2026-11-25T05:00:00.204008+00:00`, and the other forms RFC 3339
    /// allows (a space or lowercase `t` between date and time, lowercase `z`). A timestamp with
    /// no offset at all is taken as UTC.
    static func parse(_ string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespaces)
        if text.count > 10 {
            let separator = text.index(text.startIndex, offsetBy: 10)
            if text[separator] == " " || text[separator] == "t" {
                text.replaceSubrange(separator ... separator, with: "T")
            }
        }
        if text.hasSuffix("z") {
            text = String(text.dropLast()) + "Z"
        }
        if text.contains("T"), text.range(of: #"(Z|[+-]\d{2}:?\d{2})$"#, options: .regularExpression) == nil {
            text += "Z"
        }
        if let date = withFraction.date(from: text) ?? plain.date(from: text) {
            return Sanitise.date(date)
        }
        // ISO8601DateFormatter can reject some fractional precisions, so retry without the fraction.
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return Sanitise.date(plain.date(from: trimmed))
    }
}

enum JWT {
    /// The `exp` claim of a JSON Web Token. Only reads it; the signature isn't checked because
    /// the token is only ever sent back to the service that issued it.
    static func expiry(of token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (object["exp"] as? NSNumber)?.doubleValue ?? (object["exp"] as? String).flatMap(Double.init)
        else { return nil }
        return Sanitise.epoch(exp)
    }
}
