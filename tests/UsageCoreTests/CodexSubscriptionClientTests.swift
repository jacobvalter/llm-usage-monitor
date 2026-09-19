import XCTest
@testable import UsageCore

final class CodexSubscriptionClientTests: XCTestCase {

    // MARK: - Parsing

    func testParseFixtureClassifiesWindowsByDuration() throws {
        let data = try fixtureData("codex_wham_usage")
        let fetchedAt = isoDate("2026-09-19T14:32:00Z")
        let snap = try CodexSubscriptionClient.parseUsageResponse(from: data, fetchedAt: fetchedAt)

        XCTAssertEqual(snap.provider, .openai)
        XCTAssertEqual(snap.source, .codexWhamUsage)
        XCTAssertEqual(snap.plan, "pro")

        let five = try XCTUnwrap(snap.fiveHour)
        XCTAssertEqual(five.usedPercent, 12)
        XCTAssertEqual(five.windowSeconds, 18000)
        XCTAssertEqual(five.resetsAt, Date(timeIntervalSince1970: 1_758_300_000), "reset_at is unix seconds")

        let weekly = try XCTUnwrap(snap.weekly)
        XCTAssertEqual(weekly.usedPercent, 27)
        XCTAssertEqual(weekly.windowSeconds, 604800)

        // The code-review limit comes through as an `.other` window, not as a second weekly.
        let extras = snap.windows.filter { $0.kind == .other }
        XCTAssertEqual(extras.count, 1)
        XCTAssertEqual(extras[0].label, "code_review · Weekly")
        XCTAssertEqual(extras[0].usedPercent, 5)

        XCTAssertEqual(snap.tightest?.kind, .weekly)
    }

    func testSingleWeeklyWindowPlanHasNoFiveHour() throws {
        // Some plans return only a weekly window in primary_window with secondary null.
        let json = """
        {"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_at":1758637200},"secondary_window":null}}
        """.data(using: .utf8)!
        let snap = try CodexSubscriptionClient.parseUsageResponse(from: json)
        XCTAssertNil(snap.fiveHour)
        XCTAssertEqual(snap.weekly?.usedPercent, 64)
    }

    func testResetAfterSecondsIsUsedWhenResetAtMissing() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":18000,"reset_after_seconds":600}}}"#.data(using: .utf8)!
        let fetchedAt = isoDate("2026-09-19T14:00:00Z")
        let snap = try CodexSubscriptionClient.parseUsageResponse(from: json, fetchedAt: fetchedAt)
        XCTAssertEqual(snap.fiveHour?.resetsAt, fetchedAt.addingTimeInterval(600))
    }

    func testEmptyRateLimitYieldsNoWindows() throws {
        let snap = try CodexSubscriptionClient.parseUsageResponse(from: #"{"plan_type":"free"}"#.data(using: .utf8)!)
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertEqual(snap.plan, "free")
    }

    // MARK: - Request

    func testRequestHeaders() async throws {
        let recorder = RequestRecorder()
        let client = CodexSubscriptionClient(accessToken: "eyJ.access", accountId: "acct_42", fetch: recorder.respond(with: ["{}"]))
        _ = try await client.fetchQuota()

        let req = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(req.url, CodexSubscriptionClient.usageURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer eyJ.access")
        XCTAssertEqual(req.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_42")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "originator"), "codex_cli_rs")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("LLMUsageMonitor/") ?? false)
    }

    func testRequestOmitsAccountHeaderWhenUnknown() async throws {
        let recorder = RequestRecorder()
        let client = CodexSubscriptionClient(accessToken: "t", accountId: nil, fetch: recorder.respond(with: ["{}"]))
        _ = try await client.fetchQuota()
        XCTAssertNil(recorder.requests.first?.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    // MARK: - Errors

    func testUnauthorized() async {
        let recorder = RequestRecorder()
        let client = CodexSubscriptionClient(accessToken: "t", accountId: nil, fetch: recorder.respond(with: ["{}"], status: 401))
        do { _ = try await client.fetchQuota(); XCTFail("expected error") }
        catch let e as CodexSubscriptionError { XCTAssertEqual(e, .unauthorized) }
        catch { XCTFail("unexpected \(error)") }
    }

    func testRateLimited() async {
        let recorder = RequestRecorder()
        let client = CodexSubscriptionClient(accessToken: "t", accountId: nil,
                                             fetch: recorder.respond(with: ["{}"], status: 429, headers: ["retry-after": "45"]))
        do { _ = try await client.fetchQuota(); XCTFail("expected error") }
        catch let e as CodexSubscriptionError { XCTAssertEqual(e, .rateLimited(retryAfterSeconds: 45)) }
        catch { XCTFail("unexpected \(error)") }
    }

    // MARK: - Credentials

    func testParseAuthJSONWithExplicitAccountId() throws {
        let access = Self.jwt(["exp": 1_758_400_000, "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]])
        let json = """
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
         "tokens":{"id_token":"\(Self.jwt(["email":"me@example.com"]))","access_token":"\(access)","refresh_token":"rt_1","account_id":"acct_explicit"},
         "last_refresh":"2026-09-19T10:00:00.000Z"}
        """.data(using: .utf8)!
        let creds = try CodexOAuthCredentials.parse(json)
        XCTAssertEqual(creds.accessToken, access)
        XCTAssertEqual(creds.refreshToken, "rt_1")
        XCTAssertEqual(creds.accountId, "acct_explicit")
        XCTAssertEqual(creds.planType, "pro")
        XCTAssertEqual(creds.email, "me@example.com")
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_758_400_000))
        XCTAssertEqual(creds.lastRefresh, isoDate("2026-09-19T10:00:00Z"))
        XCTAssertFalse(creds.isExpired(at: Date(timeIntervalSince1970: 1_758_000_000)))
        XCTAssertTrue(creds.isExpired(at: Date(timeIntervalSince1970: 1_758_500_000)))
    }

    func testAccountIdFallsBackToJWTAuthClaim() throws {
        let idToken = Self.jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct_from_jwt", "chatgpt_plan_type": "plus"]])
        let json = #"{"tokens":{"id_token":"\#(idToken)","access_token":"a.b.c"}}"#.data(using: .utf8)!
        let creds = try CodexOAuthCredentials.parse(json)
        XCTAssertEqual(creds.accountId, "acct_from_jwt")
        XCTAssertEqual(creds.planType, "plus")
    }

    func testAccountIdFallsBackToOrganizations() throws {
        let idToken = Self.jwt(["https://api.openai.com/auth": ["organizations": [["id": "org_1"], ["id": "org_2"]]]])
        let json = #"{"tokens":{"id_token":"\#(idToken)","access_token":"a.b.c"}}"#.data(using: .utf8)!
        XCTAssertEqual(try CodexOAuthCredentials.parse(json).accountId, "org_1")
    }

    func testApiKeyOnlyAuthIsReported() {
        let json = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-proj-x","tokens":null}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexOAuthCredentials.parse(json)) { error in
            XCTAssertEqual(error as? CodexSubscriptionError, .apiKeyOnly)
        }
    }

    func testReaderCandidatePathsHonourCodexHome() {
        let reader = CodexCredentialsReader(environment: ["CODEX_HOME": "/custom/codex"], homeDirectory: URL(fileURLWithPath: "/home/x"))
        XCTAssertEqual(reader.candidateFileURLs.map(\.path),
                       ["/custom/codex/auth.json", "/home/x/.codex/auth.json", "/home/x/.config/codex/auth.json"])
    }

    func testReaderLoadsFromHomeDotCodex() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usagecore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"tokens":{"access_token":"a.b.c","account_id":"acct"}}"#.data(using: .utf8)!
            .write(to: tmp.appendingPathComponent(".codex/auth.json"))

        let creds = try CodexCredentialsReader(environment: [:], homeDirectory: tmp).load()
        XCTAssertEqual(creds.accessToken, "a.b.c")
        XCTAssertEqual(creds.accountId, "acct")
    }

    func testReaderThrowsWhenNothingExists() {
        let reader = CodexCredentialsReader(environment: [:], homeDirectory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(error as? CodexSubscriptionError, .noCredentials)
        }
    }

    // MARK: - Helpers

    /// Builds an unsigned JWT with the given payload (header.payload.sig, base64url, no padding).
    static func jwt(_ payload: [String: Any]) -> String {
        func b64url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return "\(b64url(header)).\(b64url(body)).sig"
    }
}
