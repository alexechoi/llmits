import Foundation

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
    // Formatters are costly to create and safe to share for parsing, so make each one once.
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    /// Parses timestamps such as `2026-11-25T05:00:00.204008+00:00`.
    static func parse(_ string: String) -> Date? {
        if let date = withFraction.date(from: string) ?? plain.date(from: string) {
            return date
        }
        // ISO8601DateFormatter can reject some fractional precisions, so retry without the fraction.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: trimmed)
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
              let exp = object["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}
