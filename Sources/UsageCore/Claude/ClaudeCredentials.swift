import Foundation

/// The subset of Claude Code's stored OAuth credentials this app needs.
public struct ClaudeCredentials: Sendable, Equatable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    /// Treats a token as expired a minute early so a request never races its expiry.
    public func isExpired(at now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }
}

/// Reads the credentials Claude Code stores after `/login`.
///
/// Strictly read-only: this app never refreshes or writes tokens, so it can't interfere with
/// Claude Code's own session. When the token expires, Claude Code refreshes it the next time it runs.
public enum ClaudeCredentialStore {
    public static let keychainService = "Claude Code-credentials"

    public static func load() throws -> ClaudeCredentials {
        if let data = readKeychain() {
            return try parse(data)
        }
        // Claude Code falls back to a plain file where no keychain is available.
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) {
            return try parse(data)
        }
        throw CredentialError.notFound
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        struct Stored: Decodable {
            struct OAuth: Decodable {
                var accessToken: String
                var expiresAt: Double?  // milliseconds since 1970
                var subscriptionType: String?
                var rateLimitTier: String?
            }
            var claudeAiOauth: OAuth?
        }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw CredentialError.malformed
        }
        guard let oauth = stored.claudeAiOauth, !oauth.accessToken.isEmpty else {
            throw CredentialError.notFound
        }
        return ClaudeCredentials(
            accessToken: oauth.accessToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    /// Reads the keychain item through `/usr/bin/security`, the tool that is already allowed to
    /// read it, rather than asking macOS to grant this app access to another app's item.
    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
