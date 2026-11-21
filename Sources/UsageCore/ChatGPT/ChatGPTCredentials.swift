import Foundation

/// The subset of the Codex CLI's ChatGPT login this app needs.
public struct ChatGPTCredentials: Sendable, Equatable {
    public var accessToken: String
    public var accountID: String?
    public var expiresAt: Date?

    /// Treats a token as expired a minute early so a request never races its expiry.
    public func isExpired(at now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

/// Reads the ChatGPT login the Codex CLI stores in `~/.codex/auth.json` (or `$CODEX_HOME`).
///
/// Strictly read-only, like the Claude side: Codex renews its own tokens.
public enum ChatGPTCredentialStore {
    public static func load() throws -> ChatGPTCredentials {
        guard let data = try? Data(contentsOf: authFile()) else {
            throw CredentialError.notFound
        }
        return try parse(data)
    }

    static func authFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(filePath: home).appending(path: "auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    static func parse(_ data: Data) throws -> ChatGPTCredentials {
        struct Stored: Decodable {
            struct Tokens: Decodable {
                var accessToken: String?
                var accountId: String?
            }
            var tokens: Tokens?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            throw CredentialError.malformed
        }
        // An API-key login has no ChatGPT tokens, and no ChatGPT plan limits to show.
        guard let token = stored.tokens?.accessToken, !token.isEmpty else {
            throw CredentialError.notFound
        }
        return ChatGPTCredentials(
            accessToken: token,
            accountID: stored.tokens?.accountId,
            expiresAt: JWT.expiry(of: token)
        )
    }
}
