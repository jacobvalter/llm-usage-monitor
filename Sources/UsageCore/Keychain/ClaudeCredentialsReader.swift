import Foundation

/// The OAuth credential record Claude Code stores after `claude` login.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                scopes: [String] = [], subscriptionType: String? = nil, rateLimitTier: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }

    /// Parses the JSON Claude Code writes, either to the Keychain item or to
    /// `~/.claude/.credentials.json`:
    /// `{"claudeAiOauth":{"accessToken":"…","refreshToken":"…","expiresAt":1758300000000,"scopes":[…],"subscriptionType":"max"}}`
    /// `expiresAt` is Unix **milliseconds**.
    public static func parse(_ data: Data) throws -> ClaudeOAuthCredentials {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let oauth = root.claudeAiOauth, let token = oauth.accessToken, !token.isEmpty else {
            throw ClaudeSubscriptionError.noCredentials
        }
        return ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: oauth.refreshToken,
            expiresAt: oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) },
            scopes: oauth.scopes ?? [],
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    private struct Root: Decodable { let claudeAiOauth: OAuth? }
    private struct OAuth: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresAt: Double?
        let scopes: [String]?
        let subscriptionType: String?
        let rateLimitTier: String?
    }
}

/// Locates Claude Code's stored login without ever writing to it.
///
/// Lookup order:
///   1. `CLAUDE_CODE_OAUTH_TOKEN` environment variable (token only, no expiry)
///   2. macOS Keychain generic password, service "Claude Code-credentials"
///   3. `$CLAUDE_CONFIG_DIR/.credentials.json`, else `~/.claude/.credentials.json`
public struct ClaudeCredentialsReader: Sendable {
    public static let keychainService = "Claude Code-credentials"

    private let environment: [String: String]
    private let homeDirectory: URL
    private let keychainReader: @Sendable (String) -> Data?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        keychainReader: @escaping @Sendable (String) -> Data? = ClaudeCredentialsReader.readGenericPassword
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.keychainReader = keychainReader
    }

    public var credentialsFileURL: URL {
        let dir = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".claude")
        return dir.appendingPathComponent(".credentials.json")
    }

    public func load() throws -> ClaudeOAuthCredentials {
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            return ClaudeOAuthCredentials(accessToken: token)
        }
        if let data = keychainReader(Self.keychainService), let creds = try? ClaudeOAuthCredentials.parse(data) {
            return creds
        }
        if let data = try? Data(contentsOf: credentialsFileURL) {
            return try ClaudeOAuthCredentials.parse(data)
        }
        throw ClaudeSubscriptionError.noCredentials
    }

    /// Loads and validates: throws `.tokenExpired` instead of returning a dead token.
    public func loadValid(now: Date = Date()) throws -> ClaudeOAuthCredentials {
        let creds = try load()
        if creds.isExpired(at: now), let exp = creds.expiresAt {
            throw ClaudeSubscriptionError.tokenExpired(expiredAt: exp)
        }
        return creds
    }

    /// Reads a generic password via `/usr/bin/security` so the item's ACL prompt (if any)
    /// is attributed to the `security` tool the same way Claude Code's own reads are.
    /// Returns nil off-macOS or when the item does not exist.
    public static func readGenericPassword(service: String) -> Data? {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        // `security -w` appends a trailing newline.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8)
        #else
        return nil
        #endif
    }
}
