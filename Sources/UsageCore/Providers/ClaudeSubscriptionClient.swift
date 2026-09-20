import Foundation

/// Reads the rolling limits of a Claude Pro/Max subscription — the same numbers
/// Claude Code shows in `/usage`.
///
/// Endpoint: GET https://api.anthropic.com/api/oauth/usage
/// This endpoint is **undocumented**; it is what Claude Code itself calls. It needs the
/// OAuth access token Claude Code stores locally (see `ClaudeCredentialsReader`) and a
/// `User-Agent: claude-code/<version>` header — without that header the request lands
/// in a heavily rate-limited bucket and returns persistent 429s.
///
/// v0.1 policy: we never refresh tokens ourselves. Refreshing would rotate the refresh
/// token out from under the CLI and log the user out. If the token is expired we report
/// `.tokenExpired` and the UI asks the user to run `claude` once.
public struct ClaudeSubscriptionClient: Sendable {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let betaHeader = "oauth-2025-04-20"
    /// Fallback when the installed Claude Code version cannot be detected.
    public static let defaultClaudeCodeVersion = "2.1.0"

    private let accessToken: String
    private let claudeCodeVersion: String
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        accessToken: String,
        claudeCodeVersion: String = ClaudeSubscriptionClient.defaultClaudeCodeVersion,
        session: URLSession = .shared
    ) {
        self.accessToken = accessToken
        self.claudeCodeVersion = claudeCodeVersion
        self.fetch = { request in try await session.data(for: request) }
    }

    /// Test seam.
    init(
        accessToken: String,
        claudeCodeVersion: String = ClaudeSubscriptionClient.defaultClaudeCodeVersion,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.accessToken = accessToken
        self.claudeCodeVersion = claudeCodeVersion
        self.fetch = fetch
    }

    // MARK: - Public API

    public func fetchQuota(plan: String? = nil) async throws -> QuotaSnapshot {
        let data = try await get(Self.usageURL)
        return try Self.parseUsageResponse(from: data, plan: plan, fetchedAt: Date())
    }

    public func fetchProfile() async throws -> ClaudeProfile {
        let data = try await get(Self.profileURL)
        return try JSONDecoder().decode(ClaudeProfile.self, from: data)
    }

    // MARK: - Parsing (pure, exposed for tests)

    public static func parseUsageResponse(from data: Data, plan: String? = nil, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let wire = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        var windows: [QuotaWindow] = []

        if let w = wire.fiveHour, let pct = w.utilization {
            windows.append(QuotaWindow(kind: .fiveHour, label: "5‑hour", usedPercent: pct,
                                       resetsAt: w.resetsAt.flatMap(DateParsing.date), windowSeconds: 5 * 3600))
        }
        if let w = wire.sevenDay, let pct = w.utilization {
            windows.append(QuotaWindow(kind: .weekly, label: "Weekly", usedPercent: pct,
                                       resetsAt: w.resetsAt.flatMap(DateParsing.date), windowSeconds: 7 * 86400))
        }
        if let w = wire.sevenDayOpus, let pct = w.utilization {
            windows.append(QuotaWindow(kind: .weeklyModel, label: "Weekly · Opus", usedPercent: pct,
                                       resetsAt: w.resetsAt.flatMap(DateParsing.date), windowSeconds: 7 * 86400, model: "opus"))
        }
        if let w = wire.sevenDaySonnet, let pct = w.utilization {
            windows.append(QuotaWindow(kind: .weeklyModel, label: "Weekly · Sonnet", usedPercent: pct,
                                       resetsAt: w.resetsAt.flatMap(DateParsing.date), windowSeconds: 7 * 86400, model: "sonnet"))
        }
        if let w = wire.sevenDayOAuthApps, let pct = w.utilization {
            windows.append(QuotaWindow(kind: .other, label: "Weekly · OAuth apps", usedPercent: pct,
                                       resetsAt: w.resetsAt.flatMap(DateParsing.date), windowSeconds: 7 * 86400))
        }
        // `limits[]` repeats the fixed windows above as kind "session" / "weekly_all",
        // and adds model-scoped ones as "weekly_scoped". Keep only the scoped entries.
        for entry in wire.limits ?? [] {
            guard let pct = entry.percent else { continue }
            if entry.kind == "session" || entry.kind == "weekly_all" { continue }
            // A scoped limit names its model in display_name; `id` is often null.
            let model = entry.scope?.model
            let display = model?.displayName ?? model?.id
            guard let display else { continue }
            windows.append(QuotaWindow(kind: .weeklyModel, label: "Weekly · \(display)", usedPercent: pct,
                                       resetsAt: entry.resetsAt.flatMap(DateParsing.date),
                                       windowSeconds: 7 * 86400, model: model?.id ?? display))
        }
        if let extra = wire.extraUsage, extra.isEnabled == true, let pct = extra.utilization {
            windows.append(QuotaWindow(kind: .monthlyExtra, label: "Extra usage", usedPercent: pct))
        }

        let breakdown = (wire.sevenDayBreakdown?.rows ?? []).compactMap { row -> QuotaBreakdownRow? in
            guard let name = row.displayName, let pct = row.percent else { return nil }
            return QuotaBreakdownRow(key: row.key ?? name, label: name, percent: pct)
        }

        return QuotaSnapshot(provider: .anthropic, source: .claudeOAuthUsage, plan: plan,
                             windows: windows, breakdown: breakdown, fetchedAt: fetchedAt)
    }

    // MARK: - Networking

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw ClaudeSubscriptionError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw ClaudeSubscriptionError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ClaudeSubscriptionError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw ClaudeSubscriptionError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }
}

// MARK: - Wire types

struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let sevenDayOAuthApps: OAuthUsageWindow?
    let extraUsage: OAuthExtraUsage?
    let sevenDayBreakdown: OAuthBreakdown?
    let limits: [OAuthLimitEntry]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayOAuthApps = "seven_day_oauth_apps"
        case extraUsage = "extra_usage"
        case sevenDayBreakdown = "seven_day_breakdown"
        case limits
    }
}

struct OAuthBreakdown: Decodable {
    let rows: [OAuthBreakdownRow]?
}

struct OAuthBreakdownRow: Decodable {
    let key: String?
    let displayName: String?
    let percent: Double?

    enum CodingKeys: String, CodingKey {
        case key, percent
        case displayName = "display_name"
    }
}

struct OAuthUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct OAuthExtraUsage: Decodable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization, currency
    }
}

struct OAuthLimitEntry: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: OAuthLimitScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

struct OAuthLimitScope: Decodable {
    let model: OAuthLimitScopeModel?
}

struct OAuthLimitScopeModel: Decodable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public struct ClaudeProfile: Decodable, Sendable, Equatable {
    public let accountUuid: String?
    public let emailAddress: String?
    public let organizationUuid: String?

    enum CodingKeys: String, CodingKey {
        case accountUuid = "account_uuid"
        case emailAddress = "email_address"
        case organizationUuid = "organization_uuid"
    }
}

// MARK: - Errors

public enum ClaudeSubscriptionError: Error, Equatable, LocalizedError {
    case noCredentials
    case tokenExpired(expiredAt: Date)
    case unauthorized
    case rateLimited(retryAfterSeconds: Double?)
    case httpError(statusCode: Int, body: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Claude Code login found. Run `claude` once to sign in."
        case .tokenExpired: return "Claude Code login has expired. Run `claude` once to refresh it."
        case .unauthorized: return "Claude rejected the stored login token."
        case .rateLimited(let s): return "Claude usage endpoint rate-limited" + (s.map { " (retry in \(Int($0))s)" } ?? "")
        case .httpError(let code, let body): return "Claude usage endpoint returned HTTP \(code): \(body ?? "no body")"
        case .invalidResponse: return "Invalid response from Claude usage endpoint"
        }
    }
}
