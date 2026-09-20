import XCTest
@testable import UsageCore

final class UsageEventTests: XCTestCase {
    func testDedupeKeyIsStable() {
        let date = ISO8601DateFormatter().date(from: "2025-04-16T12:00:00Z")!
        let event = UsageEvent(
            provider: .anthropic,
            source: .adminUsageAPI,
            bucketStart: date,
            bucketWidth: .oneMinute,
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            outputTokens: 500,
            requestCount: 3
        )
        let key1 = event.dedupeKey
        let key2 = event.dedupeKey
        XCTAssertEqual(key1, key2, "Dedupe key must be deterministic")
    }

    func testDifferentBucketsProduceDifferentKeys() {
        let date1 = ISO8601DateFormatter().date(from: "2025-04-16T12:00:00Z")!
        let date2 = ISO8601DateFormatter().date(from: "2025-04-16T12:01:00Z")!

        let event1 = UsageEvent(
            provider: .anthropic,
            source: .adminUsageAPI,
            bucketStart: date1,
            bucketWidth: .oneMinute,
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            outputTokens: 500,
            requestCount: 3
        )
        let event2 = UsageEvent(
            provider: .anthropic,
            source: .adminUsageAPI,
            bucketStart: date2,
            bucketWidth: .oneMinute,
            model: "claude-sonnet-4-6",
            inputTokens: 800,
            outputTokens: 400,
            requestCount: 2
        )
        XCTAssertNotEqual(event1.dedupeKey, event2.dedupeKey)
    }

    func testCodableRoundTrip() throws {
        let date = ISO8601DateFormatter().date(from: "2025-04-16T12:00:00Z")!
        let event = UsageEvent(
            provider: .openai,
            source: .adminUsageAPI,
            bucketStart: date,
            bucketWidth: .oneHour,
            model: "gpt-4o",
            inputTokens: 5000,
            outputTokens: 2000,
            reasoningTokens: 300,
            requestCount: 10,
            costUSD: 0.045,
            fetchedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageEvent.self, from: data)

        XCTAssertEqual(event, decoded)
    }

    /// ISO-8601 encoding keeps whole seconds only, so a round trip drops any
    /// fraction of a second. Harmless here: buckets are minutes or days.
    func testCodableRoundTripDropsSubSecondPrecision() throws {
        let precise = Date(timeIntervalSince1970: 1_758_300_000.75)
        let event = UsageEvent(
            provider: .anthropic,
            source: .claudeOAuthUsage,
            bucketStart: precise,
            bucketWidth: .oneMinute,
            inputTokens: 1,
            outputTokens: 1,
            requestCount: 1,
            fetchedAt: precise
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageEvent.self, from: try encoder.encode(event))

        XCTAssertNotEqual(event, decoded)
        XCTAssertEqual(decoded.bucketStart, Date(timeIntervalSince1970: 1_758_300_000))
    }
}
