import XCTest
@testable import UsageCore

final class AnthropicAdminClientTests: XCTestCase {

    // MARK: - Usage parsing

    func testParseUsageReportFixture() throws {
        let data = try fixtureData("anthropic_usage_report")
        let fetchedAt = date("2026-09-19T12:05:00Z")
        let events = try AnthropicAdminClient.parseUsageResponse(from: data, bucketWidth: .oneMinute, fetchedAt: fetchedAt)

        // Bucket 1 has two result items, bucket 2 is empty → 2 events total.
        XCTAssertEqual(events.count, 2)

        let opus = try XCTUnwrap(events.first { $0.model == "claude-opus-4-7" })
        XCTAssertEqual(opus.provider, .anthropic)
        XCTAssertEqual(opus.source, .adminUsageAPI)
        XCTAssertEqual(opus.bucketStart, date("2026-09-19T12:00:00Z"))
        XCTAssertEqual(opus.bucketWidth, .oneMinute)
        XCTAssertEqual(opus.inputTokens, 12500)
        XCTAssertEqual(opus.outputTokens, 3200)
        XCTAssertEqual(opus.cacheReadTokens, 8000)
        XCTAssertEqual(opus.cacheCreationTokens, 1500)
        XCTAssertEqual(opus.reasoningTokens, 0)
        XCTAssertEqual(opus.requestCount, 0)
        XCTAssertNil(opus.workspaceId)
        XCTAssertNil(opus.apiKeyId)
        XCTAssertNil(opus.costUSD)
        XCTAssertEqual(opus.fetchedAt, fetchedAt)

        let sonnet = try XCTUnwrap(events.first { $0.model == "claude-sonnet-4-6" })
        XCTAssertEqual(sonnet.inputTokens, 4300)
        XCTAssertEqual(sonnet.outputTokens, 1100)
        XCTAssertEqual(sonnet.cacheReadTokens, 2000)
        XCTAssertEqual(sonnet.cacheCreationTokens, 500, "5m + 1h cache creation should be summed")
    }

    func testParseEmptyUsageReport() throws {
        let json = #"{"data": [], "has_more": false, "next_page": null}"#.data(using: .utf8)!
        XCTAssertTrue(try AnthropicAdminClient.parseUsageResponse(from: json).isEmpty)
    }

    func testParseUsageReportToleratesMissingOptionalFields() throws {
        let json = """
        {
          "data": [{
            "starting_at": "2026-09-19T12:00:00Z",
            "ending_at": "2026-09-19T12:01:00Z",
            "results": [{ "uncached_input_tokens": 100, "output_tokens": 50 }]
          }],
          "has_more": false,
          "next_page": null
        }
        """.data(using: .utf8)!
        let events = try AnthropicAdminClient.parseUsageResponse(from: json)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].inputTokens, 100)
        XCTAssertEqual(events[0].outputTokens, 50)
        XCTAssertEqual(events[0].cacheReadTokens, 0)
        XCTAssertEqual(events[0].cacheCreationTokens, 0)
        XCTAssertNil(events[0].model)
    }

    // MARK: - Cost parsing

    func testParseCostReportFixture() throws {
        let data = try fixtureData("anthropic_cost_report")
        let costs = try AnthropicAdminClient.parseCostResponse(from: data)

        XCTAssertEqual(costs.count, 3)

        let opus = try XCTUnwrap(costs.first { $0.model == "claude-opus-4-7" })
        XCTAssertEqual(opus.amountCents, Decimal(string: "123.78912"))
        XCTAssertEqual(opus.amountUSD, Decimal(string: "1.2378912"), "amount is in cents; USD must divide by 100")
        XCTAssertEqual(opus.currency, "USD")
        XCTAssertEqual(opus.costType, "tokens")
        XCTAssertEqual(opus.tokenType, "uncached_input_tokens")
        XCTAssertEqual(opus.bucketStart, date("2026-09-19T00:00:00Z"))
        XCTAssertEqual(opus.bucketEnd, date("2026-09-20T00:00:00Z"))

        let webSearch = try XCTUnwrap(costs.first { $0.costType == "web_search" })
        XCTAssertNil(webSearch.model)
        XCTAssertEqual(webSearch.amountUSD, Decimal(string: "0.04"))
    }

    // MARK: - Request construction

    func testUsageRequestHeadersAndQuery() async throws {
        let recorder = RequestRecorder()
        let client = AnthropicAdminClient(apiKey: "sk-ant-admin01-test", fetch: recorder.respond(with: [Self.emptyPage]))

        _ = try await client.fetchUsage(
            startingAt: date("2026-09-19T11:00:00Z"),
            endingAt: date("2026-09-19T12:00:00Z"),
            bucketWidth: .oneMinute
        )

        let req = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin01-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("LLMUsageMonitor/") ?? false)

        let url = try XCTUnwrap(req.url)
        XCTAssertEqual(url.path, "/v1/organizations/usage_report/messages")
        let q = queryItems(url)
        XCTAssertEqual(q["starting_at"], ["2026-09-19T11:00:00Z"])
        XCTAssertEqual(q["ending_at"], ["2026-09-19T12:00:00Z"])
        XCTAssertEqual(q["bucket_width"], ["1m"])
        XCTAssertEqual(q["limit"], ["1440"])
        XCTAssertEqual(q["group_by[]"], ["model"])
        XCTAssertNil(q["page"])
    }

    func testCostRequestUsesDailyBucketsAndDescriptionGrouping() async throws {
        let recorder = RequestRecorder()
        let client = AnthropicAdminClient(apiKey: "k", fetch: recorder.respond(with: [Self.emptyPage]))

        _ = try await client.fetchCosts(
            startingAt: date("2026-09-01T00:00:00Z"),
            endingAt: date("2026-09-20T00:00:00Z")
        )

        let url = try XCTUnwrap(recorder.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/organizations/cost_report")
        let q = queryItems(url)
        XCTAssertEqual(q["bucket_width"], ["1d"])
        XCTAssertEqual(q["limit"], ["31"])
        XCTAssertEqual(q["group_by[]"], ["description"])
    }

    // MARK: - Pagination

    func testUsageFollowsPagination() async throws {
        let page1 = """
        {
          "data": [{
            "starting_at": "2026-09-19T12:00:00Z", "ending_at": "2026-09-19T12:01:00Z",
            "results": [{ "uncached_input_tokens": 1, "output_tokens": 1, "model": "a" }]
          }],
          "has_more": true,
          "next_page": "page_two"
        }
        """
        let page2 = """
        {
          "data": [{
            "starting_at": "2026-09-19T12:01:00Z", "ending_at": "2026-09-19T12:02:00Z",
            "results": [{ "uncached_input_tokens": 2, "output_tokens": 2, "model": "b" }]
          }],
          "has_more": false,
          "next_page": null
        }
        """
        let recorder = RequestRecorder()
        let client = AnthropicAdminClient(apiKey: "k", fetch: recorder.respond(with: [page1, page2]))

        let events = try await client.fetchUsage(
            startingAt: date("2026-09-19T12:00:00Z"),
            endingAt: date("2026-09-19T12:02:00Z")
        )

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertNil(queryItems(recorder.requests[0].url!)["page"])
        XCTAssertEqual(queryItems(recorder.requests[1].url!)["page"], ["page_two"])
    }

    // MARK: - Error handling

    func testUnauthorizedThrowsHTTPError() async {
        let recorder = RequestRecorder()
        let client = AnthropicAdminClient(
            apiKey: "bad",
            fetch: recorder.respond(with: [#"{"error":{"type":"authentication_error"}}"#], status: 401)
        )
        do {
            _ = try await client.fetchUsage(startingAt: Date(), endingAt: Date())
            XCTFail("expected error")
        } catch let error as AnthropicError {
            guard case .httpError(let code, _, _) = error else { return XCTFail("wrong case \(error)") }
            XCTAssertEqual(code, 401)
            XCTAssertFalse(error.isRateLimited)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testRateLimitSurfacesRetryAfter() async {
        let recorder = RequestRecorder()
        let client = AnthropicAdminClient(
            apiKey: "k",
            fetch: recorder.respond(with: [#"{"error":{"type":"rate_limit_error"}}"#], status: 429, headers: ["retry-after": "30"])
        )
        do {
            _ = try await client.fetchUsage(startingAt: Date(), endingAt: Date())
            XCTFail("expected error")
        } catch let error as AnthropicError {
            guard case .httpError(let code, _, let retryAfter) = error else { return XCTFail("wrong case \(error)") }
            XCTAssertEqual(code, 429)
            XCTAssertEqual(retryAfter, 30)
            XCTAssertTrue(error.isRateLimited)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Dedupe keys

    func testParsedEventsHaveStableDistinctDedupeKeys() throws {
        let data = try fixtureData("anthropic_usage_report")
        let a = try AnthropicAdminClient.parseUsageResponse(from: data, fetchedAt: date("2026-09-19T12:05:00Z"))
        let b = try AnthropicAdminClient.parseUsageResponse(from: data, fetchedAt: date("2026-09-19T12:06:00Z"))
        XCTAssertEqual(a.map(\.dedupeKey), b.map(\.dedupeKey), "dedupe key must not depend on fetchedAt")
        XCTAssertEqual(Set(a.map(\.dedupeKey)).count, a.count, "each result item must have a distinct key")
    }

    // MARK: - Helpers

    static let emptyPage = #"{"data": [], "has_more": false, "next_page": null}"#

    private func date(_ s: String) -> Date { isoDate(s) }
}
