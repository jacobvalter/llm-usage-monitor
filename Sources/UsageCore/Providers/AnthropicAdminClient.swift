import Foundation

/// Client for the Anthropic Admin Usage & Cost API.
///
/// Endpoints:
///   GET /v1/organizations/usage_report/messages
///   GET /v1/organizations/cost_report
///
/// Requires an Admin API key (`sk-ant-admin01-...`). Workspace-scoped keys do not work,
/// and the Admin API is not available for individual (non-organization) accounts.
/// Data is typically ~5 minutes behind real time; polling once per minute is supported.
public struct AnthropicAdminClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    static let apiVersion = "2023-06-01"
    static let userAgent = "LLMUsageMonitor/\(UsageCore.version) (https://github.com/jacobvalter/llm-usage-monitor)"

    private let apiKey: String
    private let baseURL: URL
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        apiKey: String,
        baseURL: URL = AnthropicAdminClient.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetch = { request in try await session.data(for: request) }
    }

    /// Test seam: inject the transport.
    init(
        apiKey: String,
        baseURL: URL = AnthropicAdminClient.defaultBaseURL,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetch = fetch
    }

    // MARK: - Public API

    /// Fetches token usage between `startingAt` (inclusive) and `endingAt` (exclusive),
    /// following pagination until every bucket is retrieved. One `UsageEvent` is emitted
    /// per (bucket × result item).
    public func fetchUsage(
        startingAt: Date,
        endingAt: Date,
        bucketWidth: BucketWidth = .oneMinute,
        groupBy: [String] = ["model"]
    ) async throws -> [UsageEvent] {
        var events: [UsageEvent] = []
        var page: String? = nil
        let fetchedAt = Date()

        repeat {
            var items = [
                URLQueryItem(name: "starting_at", value: Self.rfc3339(startingAt)),
                URLQueryItem(name: "ending_at", value: Self.rfc3339(endingAt)),
                URLQueryItem(name: "bucket_width", value: bucketWidth.rawValue),
                URLQueryItem(name: "limit", value: String(Self.maxBuckets(for: bucketWidth))),
            ]
            items += groupBy.map { URLQueryItem(name: "group_by[]", value: $0) }
            if let page { items.append(URLQueryItem(name: "page", value: page)) }

            let data = try await request(path: "/v1/organizations/usage_report/messages", queryItems: items)
            let report = try Self.decoder.decode(UsageReportPage.self, from: data)
            events += Self.usageEvents(from: report, bucketWidth: bucketWidth, fetchedAt: fetchedAt)
            page = report.hasMore ? report.nextPage : nil
        } while page != nil

        return events
    }

    /// Fetches daily cost buckets between `startingAt` and `endingAt`, following pagination.
    /// The cost endpoint only supports `1d` buckets.
    public func fetchCosts(
        startingAt: Date,
        endingAt: Date,
        groupBy: [String] = ["description"]
    ) async throws -> [CostItem] {
        var costs: [CostItem] = []
        var page: String? = nil

        repeat {
            var items = [
                URLQueryItem(name: "starting_at", value: Self.rfc3339(startingAt)),
                URLQueryItem(name: "ending_at", value: Self.rfc3339(endingAt)),
                URLQueryItem(name: "bucket_width", value: BucketWidth.oneDay.rawValue),
                URLQueryItem(name: "limit", value: "31"),
            ]
            items += groupBy.map { URLQueryItem(name: "group_by[]", value: $0) }
            if let page { items.append(URLQueryItem(name: "page", value: page)) }

            let data = try await request(path: "/v1/organizations/cost_report", queryItems: items)
            let report = try Self.decoder.decode(CostReportPage.self, from: data)
            costs += Self.costItems(from: report)
            page = report.hasMore ? report.nextPage : nil
        } while page != nil

        return costs
    }

    // MARK: - Parsing (pure, exposed for tests)

    public static func parseUsageResponse(
        from data: Data,
        bucketWidth: BucketWidth = .oneMinute,
        fetchedAt: Date = Date()
    ) throws -> [UsageEvent] {
        let report = try decoder.decode(UsageReportPage.self, from: data)
        return usageEvents(from: report, bucketWidth: bucketWidth, fetchedAt: fetchedAt)
    }

    public static func parseCostResponse(from data: Data) throws -> [CostItem] {
        let report = try decoder.decode(CostReportPage.self, from: data)
        return costItems(from: report)
    }

    static func usageEvents(from report: UsageReportPage, bucketWidth: BucketWidth, fetchedAt: Date) -> [UsageEvent] {
        report.data.flatMap { bucket in
            bucket.results.map { item in
                UsageEvent(
                    provider: .anthropic,
                    source: .adminUsageAPI,
                    bucketStart: bucket.startingAt,
                    bucketWidth: bucketWidth,
                    model: item.model,
                    workspaceId: item.workspaceId,
                    apiKeyId: item.apiKeyId,
                    inputTokens: item.uncachedInputTokens,
                    outputTokens: item.outputTokens,
                    cacheReadTokens: item.cacheReadInputTokens,
                    cacheCreationTokens: item.cacheCreation.total,
                    reasoningTokens: 0,
                    requestCount: 0, // not reported by the Anthropic usage endpoint
                    costUSD: nil,
                    fetchedAt: fetchedAt
                )
            }
        }
    }

    static func costItems(from report: CostReportPage) -> [CostItem] {
        report.data.flatMap { bucket in
            bucket.results.map { item in
                CostItem(
                    bucketStart: bucket.startingAt,
                    bucketEnd: bucket.endingAt,
                    amountCents: Decimal(string: item.amount) ?? 0,
                    currency: item.currency,
                    description: item.description,
                    costType: item.costType,
                    model: item.model,
                    tokenType: item.tokenType,
                    workspaceId: item.workspaceId
                )
            }
        }
    }

    // MARK: - Networking

    private func request(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AnthropicError.invalidURL
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw AnthropicError.invalidURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await fetch(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw AnthropicError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8),
                retryAfterSeconds: retryAfter
            )
        }
        return data
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = rfc3339Formatter.date(from: string) ?? rfc3339FractionalFormatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid RFC 3339 date: \(string)")
        }
        return d
    }

    private static var rfc3339Formatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    private static var rfc3339FractionalFormatter: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    static func rfc3339(_ date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }

    static func maxBuckets(for width: BucketWidth) -> Int {
        switch width {
        case .oneMinute: return 1440
        case .oneHour: return 168
        case .oneDay: return 31
        }
    }
}

// MARK: - Wire types (match the API JSON exactly)

struct UsageReportPage: Decodable {
    let data: [UsageBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct UsageBucket: Decodable {
    let startingAt: Date
    let endingAt: Date
    let results: [UsageResultItem]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct UsageResultItem: Decodable {
    let uncachedInputTokens: Int64
    let cacheReadInputTokens: Int64
    let cacheCreation: CacheCreation
    let outputTokens: Int64
    let serverToolUse: ServerToolUse?
    let model: String?
    let workspaceId: String?
    let apiKeyId: String?
    let accountId: String?
    let serviceAccountId: String?
    let serviceTier: String?
    let contextWindow: String?
    let inferenceGeo: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreation = "cache_creation"
        case outputTokens = "output_tokens"
        case serverToolUse = "server_tool_use"
        case model
        case workspaceId = "workspace_id"
        case apiKeyId = "api_key_id"
        case accountId = "account_id"
        case serviceAccountId = "service_account_id"
        case serviceTier = "service_tier"
        case contextWindow = "context_window"
        case inferenceGeo = "inference_geo"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uncachedInputTokens = try c.decodeIfPresent(Int64.self, forKey: .uncachedInputTokens) ?? 0
        cacheReadInputTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheReadInputTokens) ?? 0
        cacheCreation = try c.decodeIfPresent(CacheCreation.self, forKey: .cacheCreation) ?? CacheCreation(ephemeral5mInputTokens: 0, ephemeral1hInputTokens: 0)
        outputTokens = try c.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        serverToolUse = try c.decodeIfPresent(ServerToolUse.self, forKey: .serverToolUse)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId)
        apiKeyId = try c.decodeIfPresent(String.self, forKey: .apiKeyId)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        serviceAccountId = try c.decodeIfPresent(String.self, forKey: .serviceAccountId)
        serviceTier = try c.decodeIfPresent(String.self, forKey: .serviceTier)
        contextWindow = try c.decodeIfPresent(String.self, forKey: .contextWindow)
        inferenceGeo = try c.decodeIfPresent(String.self, forKey: .inferenceGeo)
    }
}

struct CacheCreation: Decodable {
    let ephemeral5mInputTokens: Int64
    let ephemeral1hInputTokens: Int64

    var total: Int64 { ephemeral5mInputTokens + ephemeral1hInputTokens }

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }

    init(ephemeral5mInputTokens: Int64, ephemeral1hInputTokens: Int64) {
        self.ephemeral5mInputTokens = ephemeral5mInputTokens
        self.ephemeral1hInputTokens = ephemeral1hInputTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ephemeral5mInputTokens = try c.decodeIfPresent(Int64.self, forKey: .ephemeral5mInputTokens) ?? 0
        ephemeral1hInputTokens = try c.decodeIfPresent(Int64.self, forKey: .ephemeral1hInputTokens) ?? 0
    }
}

struct ServerToolUse: Decodable {
    let webSearchRequests: Int64

    enum CodingKeys: String, CodingKey {
        case webSearchRequests = "web_search_requests"
    }
}

struct CostReportPage: Decodable {
    let data: [CostBucket]
    let hasMore: Bool
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

struct CostBucket: Decodable {
    let startingAt: Date
    let endingAt: Date
    let results: [CostResultItem]

    enum CodingKeys: String, CodingKey {
        case startingAt = "starting_at"
        case endingAt = "ending_at"
        case results
    }
}

struct CostResultItem: Decodable {
    let amount: String
    let currency: String
    let description: String?
    let costType: String?
    let model: String?
    let tokenType: String?
    let workspaceId: String?

    enum CodingKeys: String, CodingKey {
        case amount, currency, description, model
        case costType = "cost_type"
        case tokenType = "token_type"
        case workspaceId = "workspace_id"
    }
}

// MARK: - Public cost model

/// One cost line from the Anthropic cost report. `amountCents` is the raw value the API
/// returns (lowest currency unit, decimal string); use `amountUSD` for display.
public struct CostItem: Sendable, Equatable {
    public let bucketStart: Date
    public let bucketEnd: Date
    public let amountCents: Decimal
    public let currency: String
    public let description: String?
    public let costType: String?
    public let model: String?
    public let tokenType: String?
    public let workspaceId: String?

    public var amountUSD: Decimal { amountCents / 100 }
}

// MARK: - Errors

public enum AnthropicError: Error, Equatable, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, body: String?, retryAfterSeconds: Double?)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Could not build Anthropic API URL"
        case .invalidResponse:
            return "Invalid response from Anthropic API"
        case .httpError(let code, let body, _):
            return "Anthropic API returned HTTP \(code): \(body ?? "no body")"
        }
    }

    public var isRateLimited: Bool {
        if case .httpError(let code, _, _) = self { return code == 429 }
        return false
    }
}
