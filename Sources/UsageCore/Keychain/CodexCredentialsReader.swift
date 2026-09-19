import Foundation

/// The ChatGPT OAuth record Codex CLI stores in `~/.codex/auth.json` after `codex login`.
public struct CodexOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountId: String?
    /// From the access token's `exp` claim.
    public let expiresAt: Date?
    /// From the `https://api.openai.com/auth` claim (`chatgpt_plan_type`), e.g. "plus", "pro".
    public let planType: String?
    public let email: String?
    public let lastRefresh: Date?

    public init(accessToken: String, refreshToken: String? = nil, idToken: String? = nil, accountId: String? = nil,
                expiresAt: Date? = nil, planType: String? = nil, email: String? = nil, lastRefresh: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.expiresAt = expiresAt
        self.planType = planType
        self.email = email
        self.lastRefresh = lastRefresh
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }

    /// Parses Codex CLI's `auth.json`:
    /// ```
    /// {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
    ///  "tokens":{"id_token":"…","access_token":"…","refresh_token":"…","account_id":"…"},
    ///  "last_refresh":"2026-09-19T10:00:00.000Z"}
    /// ```
    /// When `tokens.account_id` is missing, the account id is taken from the JWT claims
    /// (`chatgpt_account_id`, then `https://api.openai.com/auth`.`chatgpt_account_id`,
    /// then `organizations[0].id`), the same way Codex CLI does.
    public static func parse(_ data: Data) throws -> CodexOAuthCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexSubscriptionError.invalidCredentialsFile
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            if let key = root["OPENAI_API_KEY"] as? String, !key.isEmpty {
                throw CodexSubscriptionError.apiKeyOnly
            }
            throw CodexSubscriptionError.noCredentials
        }

        let idToken = tokens["id_token"] as? String
        let accessClaims = JWT.claims(of: access) ?? [:]
        let idClaims = idToken.flatMap(JWT.claims(of:)) ?? [:]
        let authClaims = (idClaims["https://api.openai.com/auth"] as? [String: Any])
            ?? (accessClaims["https://api.openai.com/auth"] as? [String: Any]) ?? [:]

        let accountId = (tokens["account_id"] as? String)
            ?? (idClaims["chatgpt_account_id"] as? String)
            ?? (accessClaims["chatgpt_account_id"] as? String)
            ?? (authClaims["chatgpt_account_id"] as? String)
            ?? ((authClaims["organizations"] as? [[String: Any]])?.first?["id"] as? String)

        let exp = (accessClaims["exp"] as? Double) ?? (accessClaims["exp"] as? Int).map(Double.init)
        let lastRefresh = (root["last_refresh"] as? String).flatMap(DateParsing.date)

        return CodexOAuthCredentials(
            accessToken: access,
            refreshToken: tokens["refresh_token"] as? String,
            idToken: idToken,
            accountId: accountId,
            expiresAt: exp.map { Date(timeIntervalSince1970: $0) },
            planType: authClaims["chatgpt_plan_type"] as? String,
            email: (idClaims["email"] as? String) ?? (accessClaims["email"] as? String),
            lastRefresh: lastRefresh
        )
    }
}

/// Locates Codex CLI's stored login without writing to it.
///
/// Lookup order: `$CODEX_HOME/auth.json`, `~/.codex/auth.json`, `~/.config/codex/auth.json`.
public struct CodexCredentialsReader: Sendable {
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public var candidateFileURLs: [URL] {
        var urls: [URL] = []
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            urls.append(URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
        }
        urls.append(homeDirectory.appendingPathComponent(".codex/auth.json"))
        urls.append(homeDirectory.appendingPathComponent(".config/codex/auth.json"))
        return urls
    }

    public func load() throws -> CodexOAuthCredentials {
        for url in candidateFileURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            return try CodexOAuthCredentials.parse(data)
        }
        throw CodexSubscriptionError.noCredentials
    }

    public func loadValid(now: Date = Date()) throws -> CodexOAuthCredentials {
        let creds = try load()
        if creds.isExpired(at: now), let exp = creds.expiresAt {
            throw CodexSubscriptionError.tokenExpired(expiredAt: exp)
        }
        return creds
    }
}

/// Minimal JWT payload decoding (no signature verification — we only read our own token's claims).
enum JWT {
    static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
