import Foundation

enum HTTP {
    struct Reply: Sendable {
        var status: Int
        var data: Data
        var retryAfter: TimeInterval?
    }

    /// One shared session with no cache, cookies or credential storage: each poll is a single
    /// small GET, so there's nothing worth keeping in memory or on disk between them.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    static func get(_ url: URL, headers: [String: String]) async throws -> Reply {
        var request = URLRequest(url: url)
        request.setValue("claude-usage-bar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Reply(
            status: http?.statusCode ?? 0,
            data: data,
            retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        )
    }
}
