import Foundation

public struct AnthropicAdminClient: Sendable {
    private let apiKey: String
    private let baseURL: URL
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetch = { request in try await session.data(for: request) }
    }

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.fetch = fetch
    }

    // MARK: - Public API

    public func fetchUsage(
        startTime: Date,
        endTime: Date,
        bucketWidth: BucketWidth = .oneMinute
    ) async throws -> [UsageEvent] {
        let data = try await request(
            path: "/v1/organizations/usage",
            queryItems: [
                URLQueryItem(name: "start_time", value: Self.unixString(startTime)),
                URLQueryItem(name: "end_time", value: Self.unixString(endTime)),
                URLQueryItem(name: "bucket_width", value: bucketWidth.rawValue),
            ]
        )
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let now = Date()
        return response.data.map { bucket in
            bucket.toUsageEvent(bucketWidth: bucketWidth, fetchedAt: now)
        }
    }

    public func fetchCosts(
        startTime: Date,
        endTime: Date,
        bucketWidth: BucketWidth = .oneDay
    ) async throws -> [CostRecord] {
        let data = try await request(
            path: "/v1/organizations/costs",
            queryItems: [
                URLQueryItem(name: "start_time", value: Self.unixString(startTime)),
                URLQueryItem(name: "end_time", value: Self.unixString(endTime)),
                URLQueryItem(name: "bucket_width", value: bucketWidth.rawValue),
            ]
        )
        let response = try JSONDecoder().decode(CostResponse.self, from: data)
        return response.data
    }

    // MARK: - Parsing (exposed for testing)

    public static func parseUsageResponse(from data: Data, fetchedAt: Date = Date()) throws -> [UsageEvent] {
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        return response.data.map { $0.toUsageEvent(bucketWidth: .oneMinute, fetchedAt: fetchedAt) }
    }

    public static func parseCostResponse(from data: Data) throws -> [CostRecord] {
        let response = try JSONDecoder().decode(CostResponse.self, from: data)
        return response.data
    }

    // MARK: - Networking

    private func request(path: String, queryItems: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems

        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")

        let (data, response) = try await fetch(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw AnthropicError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        return data
    }

    private static func unixString(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}

// MARK: - Response types

public struct UsageResponse: Codable, Sendable {
    public let data: [UsageBucket]
}

public struct UsageBucket: Codable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadInputTokens: Int64?
    public let cacheCreationInputTokens: Int64?
    public let model: String?
    public let workspaceId: String?
    public let apiKeyId: String?
    public let snapshotTime: String
    public let requestCount: Int64

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case model
        case workspaceId = "workspace_id"
        case apiKeyId = "api_key_id"
        case snapshotTime = "snapshot_time"
        case requestCount = "request_count"
    }

    func toUsageEvent(bucketWidth: BucketWidth, fetchedAt: Date) -> UsageEvent {
        let formatter = ISO8601DateFormatter()
        let bucketStart = formatter.date(from: snapshotTime) ?? Date.distantPast
        return UsageEvent(
            provider: .anthropic,
            source: .adminUsageAPI,
            bucketStart: bucketStart,
            bucketWidth: bucketWidth,
            model: model,
            workspaceId: workspaceId,
            apiKeyId: apiKeyId,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadInputTokens ?? 0,
            cacheCreationTokens: cacheCreationInputTokens ?? 0,
            reasoningTokens: 0,
            requestCount: requestCount,
            fetchedAt: fetchedAt
        )
    }
}

public struct CostResponse: Codable, Sendable {
    public let data: [CostRecord]
}

public struct CostRecord: Codable, Sendable, Equatable {
    public let costUsd: String
    public let model: String?
    public let workspaceId: String?
    public let snapshotTime: String

    enum CodingKeys: String, CodingKey {
        case costUsd = "cost_usd"
        case model
        case workspaceId = "workspace_id"
        case snapshotTime = "snapshot_time"
    }

    public var costDecimal: Decimal? {
        Decimal(string: costUsd)
    }
}

// MARK: - Errors

public enum AnthropicError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Anthropic API"
        case .httpError(let code, let body):
            return "Anthropic API returned HTTP \(code): \(body ?? "no body")"
        }
    }
}
