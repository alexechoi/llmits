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
        switch readKeychain() {
        case let .found(data):
            return try parse(data)
        case .unreadable:
            // The item may well exist (a locked keychain, a timeout): not the same as signed out.
            throw CredentialError.unreadable
        case .missing:
            break
        }
        // Claude Code falls back to a plain file where no keychain is available.
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CredentialError.notFound
        }
        guard let data = try? Data(contentsOf: file) else {
            throw CredentialError.unreadable
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> ClaudeCredentials {
        // Read loosely, like the usage responses: only the token itself is essential.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.malformed
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            throw CredentialError.notFound
        }
        return ClaudeCredentials(
            accessToken: token,
            // Milliseconds since 1970 today; seconds are accepted too.
            expiresAt: Sanitise.epoch(number(oauth["expiresAt"])),
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Reads the keychain item through `/usr/bin/security`, the tool that is already allowed to
    /// read it, rather than asking macOS to grant this app access to another app's item.
    private static func readKeychain() -> KeychainRead {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .unreadable
        }
        // A keychain prompt would block `security` indefinitely, and every check with it.
        if finished.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return .unreadable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return keychainRead(status: process.terminationStatus, output: data)
    }

    enum KeychainRead: Equatable {
        case found(Data)
        /// `security` reported that the item doesn't exist.
        case missing
        case unreadable
    }

    static func keychainRead(status: Int32, output: Data) -> KeychainRead {
        switch status {
        case 0 where !output.isEmpty: .found(plainText(fromSecurityOutput: output))
        case 44: .missing  // errSecItemNotFound, the only status that means "no login"
        default: .unreadable
        }
    }

    /// `security -w` prints the item as text, or as hex if it holds any non-printable bytes.
    static func plainText(fromSecurityOutput output: Data) -> Data {
        guard let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.hasPrefix("{"), text.count.isMultiple(of: 2),
              text.allSatisfy(\.isHexDigit)
        else { return output }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index ..< next], radix: 16) else { return output }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
