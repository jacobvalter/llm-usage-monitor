import Foundation

/// Reads the rolling limits of a ChatGPT Plus/Pro subscription as used by Codex CLI —
/// the numbers Codex shows in `/status`.
///
/// Endpoint: GET https://chatgpt.com/backend-api/wham/usage
/// **Undocumented**; it is what Codex CLI polls every 60 s. Needs the ChatGPT OAuth access
/// token and account id from `~/.codex/auth.json` (see `CodexCredentialsReader`).
///
/// Windows are classified by duration, not position: a window of ≤ 6 h is the 5‑hour
/// session window, anything longer is weekly. Some plans return only a single weekly
/// window as `primary_window` with `secondary_window` null.
///
/// v0.1 policy: no token refresh (see `ClaudeSubscriptionClient`).
public struct CodexSubscriptionClient: Sendable {
    public static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let userAgent = "LLMUsageMonitor/\(UsageCore.version)"
    static let sessionWindowMaxSeconds = 6 * 3600

    private let accessToken: String
    private let accountId: String?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(accessToken: String, accountId: String?, session: URLSession = .shared) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.fetch = { request in try await session.data(for: request) }
    }

    /// Test seam.
    init(accessToken: String, accountId: String?, fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.accessToken = accessToken
        self.accountId = accountId
        self.fetch = fetch
    }

    public init(credentials: CodexOAuthCredentials, session: URLSession = .shared) {
        self.init(accessToken: credentials.accessToken, accountId: credentials.accountId, session: session)
    }

    // MARK: - Public API

    public func fetchQuota() async throws -> QuotaSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw CodexSubscriptionError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            return try Self.parseUsageResponse(from: data, fetchedAt: Date())
        case 401, 403:
            throw CodexSubscriptionError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw CodexSubscriptionError.rateLimited(retryAfterSeconds: retryAfter)
        default:
            throw CodexSubscriptionError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Parsing (pure, exposed for tests)

    public static func parseUsageResponse(from data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let wire = try JSONDecoder().decode(WhamUsageResponse.self, from: data)
        var windows: [QuotaWindow] = []

        for w in [wire.rateLimit?.primaryWindow, wire.rateLimit?.secondaryWindow].compactMap({ $0 }) {
            windows.append(window(from: w, fetchedAt: fetchedAt, model: nil))
        }
        for extra in wire.additionalRateLimits ?? [] {
            for w in [extra.rateLimit?.primaryWindow, extra.rateLimit?.secondaryWindow].compactMap({ $0 }) {
                var win = window(from: w, fetchedAt: fetchedAt, model: extra.limitName ?? extra.meteredFeature)
                let name = extra.limitName ?? extra.meteredFeature ?? "Extra"
                win = QuotaWindow(kind: .other, label: "\(name) · \(win.label)", usedPercent: win.usedPercent,
                                  resetsAt: win.resetsAt, windowSeconds: win.windowSeconds, model: win.model)
                windows.append(win)
            }
        }

        return QuotaSnapshot(provider: .openai, source: .codexWhamUsage, plan: wire.planType, windows: windows, fetchedAt: fetchedAt)
    }

    private static func window(from w: WhamWindow, fetchedAt: Date, model: String?) -> QuotaWindow {
        let seconds = w.limitWindowSeconds
        let kind: QuotaWindowKind
        let label: String
        switch seconds {
        case .some(let s) where s <= sessionWindowMaxSeconds:
            kind = .fiveHour; label = "5‑hour"
        case .some:
            kind = .weekly; label = "Weekly"
        case .none:
            kind = .other; label = "Limit"
        }
        let resetsAt: Date? = w.resetAt.map { Date(timeIntervalSince1970: $0) }
            ?? w.resetAfterSeconds.map { fetchedAt.addingTimeInterval($0) }
        return QuotaWindow(kind: kind, label: label, usedPercent: w.usedPercent ?? 0,
                           resetsAt: resetsAt, windowSeconds: seconds, model: model)
    }
}

// MARK: - Wire types

struct WhamUsageResponse: Decodable {
    let accountId: String?
    let email: String?
    let planType: String?
    let rateLimit: WhamRateLimit?
    let additionalRateLimits: [WhamAdditionalRateLimit]?
    let rateLimitReachedType: String?

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case email
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case rateLimitReachedType = "rate_limit_reached_type"
    }
}

struct WhamRateLimit: Decodable {
    let primaryWindow: WhamWindow?
    let secondaryWindow: WhamWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

struct WhamWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAfterSeconds: Double?
    /// Unix seconds.
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }
}

struct WhamAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: WhamRateLimit?

    enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

// MARK: - Errors

public enum CodexSubscriptionError: Error, Equatable, LocalizedError {
    case noCredentials
    case apiKeyOnly
    case invalidCredentialsFile
    case tokenExpired(expiredAt: Date)
    case unauthorized
    case rateLimited(retryAfterSeconds: Double?)
    case httpError(statusCode: Int, body: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "No Codex CLI login found. Run `codex login` once."
        case .apiKeyOnly: return "Codex CLI is using an API key, not a ChatGPT login; subscription limits are unavailable."
        case .invalidCredentialsFile: return "Could not read ~/.codex/auth.json."
        case .tokenExpired: return "Codex CLI login has expired. Run `codex` once to refresh it."
        case .unauthorized: return "ChatGPT rejected the stored login token."
        case .rateLimited(let s): return "ChatGPT usage endpoint rate-limited" + (s.map { " (retry in \(Int($0))s)" } ?? "")
        case .httpError(let code, let body): return "ChatGPT usage endpoint returned HTTP \(code): \(body ?? "no body")"
        case .invalidResponse: return "Invalid response from ChatGPT usage endpoint"
        }
    }
}
