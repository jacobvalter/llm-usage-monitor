import Foundation

public enum Provider: String, Codable, Sendable {
    case anthropic
    case openai
}

public enum UsageSource: String, Codable, Sendable {
    /// Org-level Admin Usage/Cost APIs (API-key billing). Optional provider.
    case adminUsageAPI = "admin_usage_api"
    /// Claude Pro/Max rolling limits via api.anthropic.com/api/oauth/usage.
    case claudeOAuthUsage = "claude_oauth_usage"
    /// ChatGPT Plus/Pro rolling limits via chatgpt.com/backend-api/wham/usage.
    case codexWhamUsage = "codex_wham_usage"
    /// Per-turn token counts parsed from ~/.claude/projects/**/*.jsonl.
    case claudeCodeJSONL = "claude_code_jsonl"
    /// Per-turn token counts parsed from ~/.codex/sessions/**/*.jsonl.
    case codexJSONL = "codex_jsonl"
    /// Claude Code OpenTelemetry export.
    case otel
}

public enum BucketWidth: String, Codable, Sendable {
    case oneMinute = "1m"
    case oneHour = "1h"
    case oneDay = "1d"
}

public struct UsageEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let provider: Provider
    public let source: UsageSource
    public let bucketStart: Date
    public let bucketWidth: BucketWidth
    public let model: String?
    public let workspaceId: String?
    public let apiKeyId: String?
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheCreationTokens: Int64
    public let reasoningTokens: Int64
    public let requestCount: Int64
    public let costUSD: Decimal?
    public let fetchedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        source: UsageSource,
        bucketStart: Date,
        bucketWidth: BucketWidth,
        model: String? = nil,
        workspaceId: String? = nil,
        apiKeyId: String? = nil,
        inputTokens: Int64,
        outputTokens: Int64,
        cacheReadTokens: Int64 = 0,
        cacheCreationTokens: Int64 = 0,
        reasoningTokens: Int64 = 0,
        requestCount: Int64,
        costUSD: Decimal? = nil,
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.bucketStart = bucketStart
        self.bucketWidth = bucketWidth
        self.model = model
        self.workspaceId = workspaceId
        self.apiKeyId = apiKeyId
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.reasoningTokens = reasoningTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.fetchedAt = fetchedAt
    }

    /// Natural dedupe key: same provider + source + bucket + model + workspace + apiKey → same event.
    public var dedupeKey: String {
        [
            provider.rawValue,
            source.rawValue,
            ISO8601DateFormatter().string(from: bucketStart),
            bucketWidth.rawValue,
            model ?? "",
            workspaceId ?? "",
            apiKeyId ?? "",
        ].joined(separator: "|")
    }
}
