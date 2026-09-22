import Foundation

/// Reads GitHub Copilot monthly quotas.
///
/// Endpoint: GET https://api.github.com/copilot_internal/user
/// Undocumented, but it is what the editor extensions call to draw their quota UI.
/// A normal GitHub OAuth token works; see `CopilotCredentialsReader`.
///
/// Quotas are monthly and reset on `quota_reset_date`. Snapshots with
/// `has_quota: false` (premium requests on the free plan) or `unlimited: true`
/// carry no usable number and are skipped.
public struct CopilotClient: Sendable {
    public static let dotComAPI = URL(string: "https://api.github.com")!
    /// Kept for callers that only ever talk to github.com.
    public static let userURL = dotComAPI.appendingPathComponent("copilot_internal/user")
    static let editorVersion = "vscode/1.100.0"
    static let userAgent = "GitHubCopilotChat/0.26.7"

    private let token: String
    private let apiBaseURL: URL
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public var quotaURL: URL { apiBaseURL.appendingPathComponent("copilot_internal/user") }

    public init(token: String, apiBaseURL: URL = CopilotClient.dotComAPI, session: URLSession = .shared) {
        self.token = token
        self.apiBaseURL = apiBaseURL
        self.fetch = { request in try await session.data(for: request) }
    }

    /// Test seam.
    init(
        token: String,
        apiBaseURL: URL = CopilotClient.dotComAPI,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.token = token
        self.apiBaseURL = apiBaseURL
        self.fetch = fetch
    }

    // MARK: - Public API

    public func fetchQuota() async throws -> QuotaSnapshot {
        var request = URLRequest(url: quotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse else { throw CopilotError.invalidResponse }
        switch http.statusCode {
        case 200...299:
            return try Self.parseUserResponse(from: data, fetchedAt: Date())
        case 401, 403:
            throw CopilotError.unauthorized
        case 404:
            throw CopilotError.noCopilotAccess
        case 429:
            throw CopilotError.rateLimited(
                retryAfterSeconds: http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init))
        default:
            throw CopilotError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Parsing (pure, exposed for tests)

    public static func parseUserResponse(from data: Data, fetchedAt: Date = Date()) throws -> QuotaSnapshot {
        let wire = try JSONDecoder().decode(CopilotUserResponse.self, from: data)
        let resetsAt = wire.quotaResetDateUTC.flatMap(DateParsing.date)
            ?? wire.quotaResetDate.flatMap(Self.parseDateOnly)

        // Stable order so the panel does not reshuffle between refreshes.
        let order = ["premium_interactions", "chat", "completions"]
        let windows = (wire.quotaSnapshots ?? [:])
            .sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? order.count
                let ib = order.firstIndex(of: b.key) ?? order.count
                return ia == ib ? a.key < b.key : ia < ib
            }
            .compactMap { key, snap -> QuotaWindow? in
                guard snap.hasQuota == true else { return nil }
                let unlimited = snap.unlimited == true
                // An unlimited quota has no meaningful percentage; it is kept only as a note.
                guard let remaining = snap.percentRemaining else { return nil }
                return QuotaWindow(
                    kind: .monthly,
                    label: Self.label(for: key),
                    usedPercent: unlimited ? 0 : 100 - remaining,
                    resetsAt: unlimited ? nil : resetsAt,
                    model: key,
                    isUnlimited: unlimited
                )
            }

        return QuotaSnapshot(
            provider: .githubCopilot,
            source: .copilotInternalUser,
            plan: wire.copilotPlan ?? wire.accessTypeSKU,
            windows: windows,
            fetchedAt: fetchedAt
        )
    }

    static func label(for quotaId: String) -> String {
        switch quotaId {
        case "premium_interactions": return "Premium"
        case "chat": return "Chat"
        case "completions": return "Completions"
        default:
            return quotaId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "2026-10-01" — the date-only sibling of quota_reset_date_utc.
    static func parseDateOnly(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}

// MARK: - Wire types

struct CopilotUserResponse: Decodable {
    let copilotPlan: String?
    let accessTypeSKU: String?
    let quotaResetDate: String?
    let quotaResetDateUTC: String?
    let quotaSnapshots: [String: CopilotQuotaSnapshot]?

    enum CodingKeys: String, CodingKey {
        case copilotPlan = "copilot_plan"
        case accessTypeSKU = "access_type_sku"
        case quotaResetDate = "quota_reset_date"
        case quotaResetDateUTC = "quota_reset_date_utc"
        case quotaSnapshots = "quota_snapshots"
    }
}

struct CopilotQuotaSnapshot: Decodable {
    let entitlement: Double?
    let remaining: Double?
    let percentRemaining: Double?
    let unlimited: Bool?
    let hasQuota: Bool?
    let overageCount: Double?
    let overagePermitted: Bool?

    enum CodingKeys: String, CodingKey {
        case entitlement, remaining, unlimited
        case percentRemaining = "percent_remaining"
        case hasQuota = "has_quota"
        case overageCount = "overage_count"
        case overagePermitted = "overage_permitted"
    }
}

// MARK: - Errors

public enum CopilotError: Error, Equatable, LocalizedError {
    case noCredentials
    case unauthorized
    case noCopilotAccess
    case rateLimited(retryAfterSeconds: Double?)
    case httpError(statusCode: Int, body: String?)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .noCredentials: return "No GitHub login found. Run `gh auth login` once."
        case .unauthorized: return "GitHub rejected the stored token."
        case .noCopilotAccess: return "This GitHub account has no Copilot access."
        case .rateLimited(let s): return "GitHub rate-limited us" + (s.map { " (retry in \(Int($0))s)" } ?? "")
        case .httpError(let code, let body): return "GitHub returned HTTP \(code): \(body ?? "no body")"
        case .invalidResponse: return "Invalid response from GitHub."
        }
    }
}
