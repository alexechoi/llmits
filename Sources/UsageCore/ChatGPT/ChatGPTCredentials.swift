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
        try load(from: authFile())
    }

    static func load(from file: URL) throws -> ChatGPTCredentials {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CredentialError.notFound
        }
        guard let data = try? Data(contentsOf: file) else {
            throw CredentialError.unreadable
        }
        do {
            return try parse(data)
        } catch CredentialError.malformed {
            // Most likely caught mid-write while Codex renews its token; try again shortly.
            throw CredentialError.unreadable
        }
    }

    static func authFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return URL(filePath: home).appending(path: "auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    }

    static func parse(_ data: Data) throws -> ChatGPTCredentials {
        // Read loosely: only the access token is essential.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.malformed
        }
        let tokens = root["tokens"] as? [String: Any]
        // An API-key login has no ChatGPT tokens, and no ChatGPT plan limits to show.
        guard let token = tokens?["access_token"] as? String, !token.isEmpty else {
            throw CredentialError.notFound
        }
        let account = tokens?["account_id"]
        return ChatGPTCredentials(
            accessToken: token,
            accountID: (account as? String) ?? (account as? NSNumber)?.stringValue,
            expiresAt: JWT.expiry(of: token)
        )
    }
}
