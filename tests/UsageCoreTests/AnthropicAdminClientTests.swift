import XCTest
@testable import UsageCore

final class AnthropicAdminClientTests: XCTestCase {

    // MARK: - Usage parsing

    func testParseUsageReport() throws {
        let data = try fixtureData("anthropic_usage_report")
        let fixedDate = ISO8601DateFormatter().date(from: "2025-04-16T13:00:00Z")!
        let events = try AnthropicAdminClient.parseUsageResponse(from: data, fetchedAt: fixedDate)

        XCTAssertEqual(events.count, 2)

        let first = events[0]
        XCTAssertEqual(first.provider, .anthropic)
        XCTAssertEqual(first.source, .adminUsageAPI)
        XCTAssertEqual(first.model, "claude-sonnet-4-6")
        XCTAssertEqual(first.workspaceId, "wrkspc_01abc")
        XCTAssertEqual(first.apiKeyId, "sk-ant-api03-abc")
        XCTAssertEqual(first.inputTokens, 12500)
        XCTAssertEqual(first.outputTokens, 3200)
        XCTAssertEqual(first.cacheReadTokens, 8000)
        XCTAssertEqual(first.cacheCreationTokens, 1500)
        XCTAssertEqual(first.reasoningTokens, 0)
        XCTAssertEqual(first.requestCount, 15)
        XCTAssertEqual(first.bucketWidth, .oneMinute)
        XCTAssertEqual(first.fetchedAt, fixedDate)
        XCTAssertNil(first.costUSD)

        let expectedDate = ISO8601DateFormatter().date(from: "2025-04-16T12:00:00Z")!
        XCTAssertEqual(first.bucketStart, expectedDate)

        let second = events[1]
        XCTAssertEqual(second.model, "claude-haiku-4-5-20251001")
        XCTAssertEqual(second.inputTokens, 4300)
        XCTAssertEqual(second.outputTokens, 1100)
        XCTAssertEqual(second.cacheReadTokens, 2000)
        XCTAssertEqual(second.cacheCreationTokens, 500)
        XCTAssertEqual(second.requestCount, 8)
    }

    func testParseEmptyUsageReport() throws {
        let json = #"{"data": []}"#.data(using: .utf8)!
        let events = try AnthropicAdminClient.parseUsageResponse(from: json)
        XCTAssertTrue(events.isEmpty)
    }

    func testParseUsageReportMissingOptionalCacheFields() throws {
        let json = """
        {
          "data": [{
            "input_tokens": 100,
            "output_tokens": 50,
            "model": "claude-sonnet-4-6",
            "snapshot_time": "2025-04-16T12:00:00Z",
            "request_count": 1
          }]
        }
        """.data(using: .utf8)!
        let events = try AnthropicAdminClient.parseUsageResponse(from: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].cacheReadTokens, 0)
        XCTAssertEqual(events[0].cacheCreationTokens, 0)
        XCTAssertNil(events[0].workspaceId)
        XCTAssertNil(events[0].apiKeyId)
    }

    // MARK: - Cost parsing

    func testParseCostReport() throws {
        let data = try fixtureData("anthropic_cost_report")
        let costs = try AnthropicAdminClient.parseCostResponse(from: data)

        XCTAssertEqual(costs.count, 2)

        XCTAssertEqual(costs[0].costUsd, "0.01875")
        XCTAssertEqual(costs[0].model, "claude-sonnet-4-6")
        XCTAssertEqual(costs[0].costDecimal, Decimal(string: "0.01875"))

        XCTAssertEqual(costs[1].costUsd, "0.00322")
        XCTAssertEqual(costs[1].model, "claude-haiku-4-5-20251001")
    }

    // MARK: - Request construction

    func testRequestIncludesCorrectHeaders() async throws {
        var capturedRequest: URLRequest?

        let client = AnthropicAdminClient(
            apiKey: "sk-ant-admin-test-key",
            baseURL: URL(string: "https://api.anthropic.com")!,
            fetch: { request in
                capturedRequest = request
                let json = #"{"data": []}"#.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (json, response)
            }
        )

        _ = try await client.fetchUsage(
            startTime: Date(timeIntervalSince1970: 1744804800),
            endTime: Date(timeIntervalSince1970: 1744808400)
        )

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin-test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "accept"), "application/json")
        XCTAssertEqual(req.httpMethod, "GET")

        let urlString = req.url!.absoluteString
        XCTAssertTrue(urlString.contains("start_time=1744804800"))
        XCTAssertTrue(urlString.contains("end_time=1744808400"))
        XCTAssertTrue(urlString.contains("bucket_width=1m"))
    }

    func testRequestUsesCorrectPaths() async throws {
        var capturedURLs: [String] = []

        let client = AnthropicAdminClient(
            apiKey: "sk-ant-admin-test",
            fetch: { request in
                capturedURLs.append(request.url!.path)
                let json = #"{"data": []}"#.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (json, response)
            }
        )

        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 3600)

        _ = try await client.fetchUsage(startTime: start, endTime: end)
        _ = try await client.fetchCosts(startTime: start, endTime: end)

        XCTAssertEqual(capturedURLs.count, 2)
        XCTAssertTrue(capturedURLs[0].hasSuffix("/v1/organizations/usage"))
        XCTAssertTrue(capturedURLs[1].hasSuffix("/v1/organizations/costs"))
    }

    // MARK: - Error handling

    func testHTTPErrorThrows() async {
        let client = AnthropicAdminClient(
            apiKey: "bad-key",
            fetch: { request in
                let body = #"{"error": "unauthorized"}"#.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
                )!
                return (body, response)
            }
        )

        do {
            _ = try await client.fetchUsage(
                startTime: Date(),
                endTime: Date()
            )
            XCTFail("Expected AnthropicError.httpError")
        } catch let error as AnthropicError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 401)
            } else {
                XCTFail("Wrong error case: \(error)")
            }
        }
    }

    func testRateLimitErrorThrows429() async {
        let client = AnthropicAdminClient(
            apiKey: "key",
            fetch: { request in
                let body = #"{"error": "rate_limit_exceeded"}"#.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil
                )!
                return (body, response)
            }
        )

        do {
            _ = try await client.fetchUsage(startTime: Date(), endTime: Date())
            XCTFail("Expected error")
        } catch let error as AnthropicError {
            if case .httpError(let code, _) = error {
                XCTAssertEqual(code, 429)
            } else {
                XCTFail("Wrong error case")
            }
        }
    }

    // MARK: - Dedupe key consistency

    func testParsedEventsHaveStableDedupeKeys() throws {
        let data = try fixtureData("anthropic_usage_report")
        let fixedDate = ISO8601DateFormatter().date(from: "2025-04-16T13:00:00Z")!
        let events1 = try AnthropicAdminClient.parseUsageResponse(from: data, fetchedAt: fixedDate)
        let events2 = try AnthropicAdminClient.parseUsageResponse(from: data, fetchedAt: fixedDate)

        XCTAssertEqual(events1[0].dedupeKey, events2[0].dedupeKey)
        XCTAssertEqual(events1[1].dedupeKey, events2[1].dedupeKey)
        XCTAssertNotEqual(events1[0].dedupeKey, events1[1].dedupeKey)
    }

    // MARK: - Helpers

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }
}
