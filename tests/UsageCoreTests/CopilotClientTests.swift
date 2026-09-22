import XCTest
@testable import UsageCore

final class CopilotClientTests: XCTestCase {

    // MARK: - Parsing

    func testParseFixture() throws {
        let data = try fixtureData("copilot_user")
        let at = isoDate("2026-09-22T10:00:00Z")
        let snap = try CopilotClient.parseUserResponse(from: data, fetchedAt: at)

        XCTAssertEqual(snap.provider, .githubCopilot)
        XCTAssertEqual(snap.source, .copilotInternalUser)
        XCTAssertEqual(snap.plan, "individual")
        XCTAssertEqual(snap.fetchedAt, at)

        // premium_interactions has has_quota false on the free plan and is dropped.
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertTrue(snap.windows.allSatisfy { $0.kind == .monthly })
        XCTAssertFalse(snap.windows.contains { $0.label == "Premium" })

        let chat = try XCTUnwrap(snap.windows.first { $0.label == "Chat" })
        XCTAssertEqual(chat.usedPercent, 37.5, "100 - percent_remaining")
        XCTAssertEqual(chat.model, "chat")
        XCTAssertEqual(chat.resetsAt, isoDate("2026-10-01T00:00:00Z"))

        let completions = try XCTUnwrap(snap.windows.first { $0.label == "Completions" })
        XCTAssertEqual(completions.usedPercent, 0)
    }

    func testBusiestMonthlyDrivesTheBadge() throws {
        let snap = try CopilotClient.parseUserResponse(from: try fixtureData("copilot_user"))
        XCTAssertEqual(snap.monthly?.label, "Chat")
        XCTAssertEqual(snap.tightest?.label, "Chat", "monthly windows must count toward tightest")
        XCTAssertEqual(snap.level, .normal)
        XCTAssertNil(snap.fiveHour)
        XCTAssertNil(snap.weekly)
    }

    func testUnlimitedQuotaIsKeptButNotMeasured() throws {
        let json = """
        {"copilot_plan":"business","quota_snapshots":{
          "chat":{"has_quota":true,"unlimited":true,"percent_remaining":100},
          "completions":{"has_quota":true,"unlimited":false,"percent_remaining":80}}}
        """.data(using: .utf8)!
        let snap = try CopilotClient.parseUserResponse(from: json)

        // Both are kept, so the card can say "Chat - unlimited" rather than
        // silently losing it, but only the capped one gets a bar.
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.measuredWindows.map(\.label), ["Completions"])
        XCTAssertEqual(snap.measuredWindows[0].usedPercent, 20)
        XCTAssertEqual(snap.unlimitedWindows.map(\.label), ["Chat"])
        XCTAssertNil(snap.unlimitedWindows[0].resetsAt, "an unlimited quota has no reset")
    }

    func testSnapshotWithoutPercentIsSkipped() throws {
        let json = #"{"quota_snapshots":{"chat":{"has_quota":true}}}"#.data(using: .utf8)!
        XCTAssertTrue(try CopilotClient.parseUserResponse(from: json).windows.isEmpty)
    }

    func testEmptyResponseParsesToNoWindows() throws {
        let snap = try CopilotClient.parseUserResponse(from: "{}".data(using: .utf8)!)
        XCTAssertTrue(snap.windows.isEmpty)
        XCTAssertNil(snap.plan)
        XCTAssertEqual(snap.level, .normal)
    }

    func testWindowOrderIsStable() throws {
        let json = """
        {"quota_snapshots":{
          "completions":{"has_quota":true,"percent_remaining":10},
          "chat":{"has_quota":true,"percent_remaining":20},
          "premium_interactions":{"has_quota":true,"percent_remaining":30}}}
        """.data(using: .utf8)!
        let labels = try CopilotClient.parseUserResponse(from: json).windows.map(\.label)
        XCTAssertEqual(labels, ["Premium", "Chat", "Completions"])
    }

    func testUnknownQuotaIdGetsAReadableLabel() {
        XCTAssertEqual(CopilotClient.label(for: "code_review"), "Code Review")
        XCTAssertEqual(CopilotClient.label(for: "chat"), "Chat")
    }

    func testDateOnlyResetParsing() {
        XCTAssertEqual(CopilotClient.parseDateOnly("2026-10-01"), isoDate("2026-10-01T00:00:00Z"))
        XCTAssertNil(CopilotClient.parseDateOnly("nonsense"))
    }

    // MARK: - Request

    func testRequestHeaders() async throws {
        let recorder = RequestRecorder()
        let client = CopilotClient(token: "gho_test", fetch: recorder.respond(with: ["{}"]))
        _ = try await client.fetchQuota()

        let req = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(req.url, CopilotClient.userURL)
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer gho_test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Editor-Version"))
    }

    // MARK: - Errors

    func testUnauthorized() async {
        let recorder = RequestRecorder()
        let client = CopilotClient(token: "bad", fetch: recorder.respond(with: ["{}"], status: 401))
        do { _ = try await client.fetchQuota(); XCTFail("expected error") }
        catch let e as CopilotError { XCTAssertEqual(e, .unauthorized) }
        catch { XCTFail("unexpected \(error)") }
    }

    func testNoCopilotAccess() async {
        let recorder = RequestRecorder()
        let client = CopilotClient(token: "t", fetch: recorder.respond(with: ["{}"], status: 404))
        do { _ = try await client.fetchQuota(); XCTFail("expected error") }
        catch let e as CopilotError { XCTAssertEqual(e, .noCopilotAccess) }
        catch { XCTFail("unexpected \(error)") }
    }

    func testRateLimited() async {
        let recorder = RequestRecorder()
        let client = CopilotClient(token: "t", fetch: recorder.respond(with: ["{}"], status: 429,
                                                                       headers: ["retry-after": "60"]))
        do { _ = try await client.fetchQuota(); XCTFail("expected error") }
        catch let e as CopilotError { XCTAssertEqual(e, .rateLimited(retryAfterSeconds: 60)) }
        catch { XCTFail("unexpected \(error)") }
    }

    // MARK: - Credentials

    func testEnvironmentTokenWins() throws {
        let reader = CopilotCredentialsReader(
            environment: ["GH_TOKEN": "from-env"],
            ghTokenProvider: { _ in XCTFail("gh must not be called"); return nil }
        )
        XCTAssertEqual(try reader.loadToken(), "from-env")
    }

    func testGithubTokenFallback() throws {
        let reader = CopilotCredentialsReader(environment: ["GITHUB_TOKEN": "gh-env"], ghTokenProvider: { _ in nil })
        XCTAssertEqual(try reader.loadToken(), "gh-env")
    }

    func testFallsBackToGHCLI() throws {
        let reader = CopilotCredentialsReader(environment: [:], ghTokenProvider: { _ in "from-cli" })
        XCTAssertEqual(try reader.loadToken(), "from-cli")
    }

    func testEmptyValuesAreIgnored() throws {
        let reader = CopilotCredentialsReader(environment: ["GH_TOKEN": ""], ghTokenProvider: { _ in "from-cli" })
        XCTAssertEqual(try reader.loadToken(), "from-cli")
    }

    func testThrowsWhenNothingAvailable() {
        let reader = CopilotCredentialsReader(environment: [:], ghTokenProvider: { _ in nil })
        XCTAssertThrowsError(try reader.loadToken()) { error in
            XCTAssertEqual(error as? CopilotError, .noCredentials)
        }
    }
}

final class CopilotHostTests: XCTestCase {

    func testAPIBaseForDotCom() {
        XCTAssertEqual(CopilotCredentialsReader.apiBaseURL(for: nil).absoluteString, "https://api.github.com")
        XCTAssertEqual(CopilotCredentialsReader.apiBaseURL(for: "github.com").absoluteString, "https://api.github.com")
        XCTAssertEqual(CopilotCredentialsReader.apiBaseURL(for: "").absoluteString, "https://api.github.com")
    }

    func testAPIBaseForEnterpriseCloudWithDataResidency() {
        // acme.ghe.com puts the API on api.acme.ghe.com, not /api/v3.
        XCTAssertEqual(CopilotCredentialsReader.apiBaseURL(for: "continental.ghe.com").absoluteString,
                       "https://api.continental.ghe.com")
    }

    func testAPIBaseForEnterpriseServer() {
        XCTAssertEqual(CopilotCredentialsReader.apiBaseURL(for: "git.example.com").absoluteString,
                       "https://git.example.com/api/v3")
    }

    func testQuotaURLFollowsTheBase() {
        let client = CopilotClient(token: "t",
                                   apiBaseURL: URL(string: "https://api.continental.ghe.com")!,
                                   fetch: { _ in throw CopilotError.invalidResponse })
        XCTAssertEqual(client.quotaURL.absoluteString,
                       "https://api.continental.ghe.com/copilot_internal/user")
    }

    func testRequestGoesToTheEnterpriseHost() async throws {
        let recorder = RequestRecorder()
        let client = CopilotClient(token: "ghe_token",
                                   apiBaseURL: URL(string: "https://api.continental.ghe.com")!,
                                   fetch: recorder.respond(with: ["{}"]))
        _ = try await client.fetchQuota()
        XCTAssertEqual(recorder.requests.first?.url?.host, "api.continental.ghe.com")
    }

    func testEnvironmentTokenIsIgnoredForEnterprise() throws {
        // GH_TOKEN is a github.com token; it must not be sent to an enterprise host.
        let reader = CopilotCredentialsReader(
            host: "continental.ghe.com",
            environment: ["GH_TOKEN": "dotcom-token"],
            ghTokenProvider: { host in
                XCTAssertEqual(host, "continental.ghe.com")
                return "enterprise-token"
            }
        )
        XCTAssertEqual(try reader.loadToken(), "enterprise-token")
    }

    func testHostsYamlParsing() {
        let yaml = """
        github.com:
            git_protocol: https
            users:
                someone:
            user: someone
        continental.ghe.com:
            git_protocol: https
            user: uia00000
        """
        XCTAssertEqual(CopilotCredentialsReader.parseHosts(yaml), ["github.com", "continental.ghe.com"])
    }

    func testEnterpriseHostDiscovery() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "github.com:\n    user: a\nacme.ghe.com:\n    user: b\n"
            .write(to: dir.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)

        XCTAssertEqual(CopilotCredentialsReader.enterpriseHost(configDirectory: dir), "acme.ghe.com")
    }

    func testEnterpriseHostDiscoveryReturnsNilWhenOnlyDotCom() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "github.com:\n    user: a\n"
            .write(to: dir.appendingPathComponent("hosts.yml"), atomically: true, encoding: .utf8)

        XCTAssertNil(CopilotCredentialsReader.enterpriseHost(configDirectory: dir))
    }

    func testMissingHostsFileIsHandled() {
        XCTAssertNil(CopilotCredentialsReader.enterpriseHost(
            configDirectory: URL(fileURLWithPath: "/nonexistent/gh")))
    }
}

final class CopilotBusinessPlanTests: XCTestCase {

    /// Shape taken from a real Copilot Business seat: chat and completions are
    /// unlimited, and premium_interactions is the only capped quota.
    private let businessJSON = """
    {"copilot_plan":"business","access_type_sku":"copilot_for_business_seat_quota",
     "quota_reset_date":"2026-10-01",
     "quota_snapshots":{
       "chat":{"has_quota":true,"unlimited":true,"entitlement":0,"percent_remaining":100.0},
       "completions":{"has_quota":true,"unlimited":true,"entitlement":0,"percent_remaining":100.0},
       "premium_interactions":{"has_quota":true,"unlimited":false,"entitlement":3000,
                               "percent_remaining":82.0,"overage_permitted":true}}}
    """.data(using: .utf8)!

    func testOnlyTheCappedQuotaGetsABar() throws {
        let snap = try CopilotClient.parseUserResponse(from: businessJSON)
        XCTAssertEqual(snap.plan, "business")

        XCTAssertEqual(snap.measuredWindows.count, 1)
        XCTAssertEqual(snap.measuredWindows[0].label, "Premium")
        XCTAssertEqual(snap.measuredWindows[0].usedPercent, 18)
        XCTAssertEqual(snap.measuredWindows[0].resetsAt, isoDate("2026-10-01T00:00:00Z"))
    }

    func testUnlimitedQuotasAreKeptAsNotes() throws {
        let snap = try CopilotClient.parseUserResponse(from: businessJSON)
        let labels = snap.unlimitedWindows.map(\.label)
        XCTAssertEqual(Set(labels), ["Chat", "Completions"])
        XCTAssertTrue(snap.unlimitedWindows.allSatisfy { $0.isUnlimited })
    }

    func testUnlimitedNeverDrivesTheBadge() throws {
        let snap = try CopilotClient.parseUserResponse(from: businessJSON)
        XCTAssertEqual(snap.tightest?.label, "Premium")
        XCTAssertEqual(snap.monthly?.label, "Premium")
        XCTAssertEqual(snap.level, .normal)
    }

    func testFreePlanStillSkipsQuotaLessPremium() throws {
        // has_quota false must stay excluded from both lists.
        let snap = try CopilotClient.parseUserResponse(from: try fixtureData("copilot_user"))
        XCTAssertFalse(snap.windows.contains { $0.label == "Premium" })
        XCTAssertTrue(snap.unlimitedWindows.isEmpty)
        XCTAssertEqual(snap.measuredWindows.count, 2)
    }
}

final class CopilotCountsTests: XCTestCase {

    func testBusinessSeatCarriesExactCounts() throws {
        let json = """
        {"copilot_plan":"business","quota_reset_date":"2026-10-01",
         "quota_snapshots":{"premium_interactions":{
            "has_quota":true,"unlimited":false,"entitlement":3000,
            "remaining":2817,"percent_remaining":93.9,
            "overage_count":0,"overage_permitted":true}}}
        """.data(using: .utf8)!
        let w = try XCTUnwrap(CopilotClient.parseUserResponse(from: json).measuredWindows.first)

        XCTAssertEqual(w.limit, 3000)
        XCTAssertEqual(w.used, 183, "entitlement minus remaining")
        XCTAssertEqual(w.countsText(locale: Locale(identifier: "en_US")), "183 of 3,000 used")
    }

    func testOverageIsAppendedOnlyWhenSpent() throws {
        func window(overage: Double) -> QuotaWindow {
            QuotaWindow(kind: .monthly, label: "Premium", usedPercent: 100,
                        used: 3000, limit: 3000, overage: overage)
        }
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(window(overage: 0).countsText(locale: us), "3,000 of 3,000 used")
        XCTAssertEqual(window(overage: 42).countsText(locale: us), "3,000 of 3,000 used · 42 over")
    }

    func testFreePlanQuotasCarryCountsToo() throws {
        let snap = try CopilotClient.parseUserResponse(from: try fixtureData("copilot_user"))
        let chat = try XCTUnwrap(snap.measuredWindows.first { $0.label == "Chat" })
        XCTAssertEqual(chat.limit, 200)
        XCTAssertEqual(chat.used, 75, "200 entitlement minus 125 remaining")
        XCTAssertEqual(chat.countsText(locale: Locale(identifier: "en_US")), "75 of 200 used")
    }

    func testGroupingFollowsTheReaderLocale() {
        let w = QuotaWindow(kind: .monthly, label: "Premium", usedPercent: 0,
                            used: 183, limit: 3000)

        // Built from each locale's own separator: Czech uses a non-breaking
        // space, which is invisible in a source literal and easy to get wrong.
        for id in ["cs_CZ", "de_DE", "en_US"] {
            let locale = Locale(identifier: id)
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = locale
            let grouped = f.string(from: 3000)!
            XCTAssertEqual(w.countsText(locale: locale), "183 of \(grouped) used", "locale \(id)")
        }

        // The separators really do differ, so this is a meaningful check.
        XCTAssertNotEqual(w.countsText(locale: Locale(identifier: "cs_CZ")),
                          w.countsText(locale: Locale(identifier: "en_US")))
    }

    func testUnlimitedQuotaHasNoCounts() throws {
        let json = """
        {"quota_snapshots":{"chat":{"has_quota":true,"unlimited":true,
          "entitlement":0,"remaining":0,"percent_remaining":100}}}
        """.data(using: .utf8)!
        let w = try XCTUnwrap(CopilotClient.parseUserResponse(from: json).unlimitedWindows.first)
        XCTAssertNil(w.limit)
        XCTAssertNil(w.countsText, "an uncapped quota has nothing to count against")
    }

    func testClaudeWindowsHaveNoCounts() throws {
        let json = #"{"five_hour":{"utilization":30}}"#.data(using: .utf8)!
        let snap = try ClaudeSubscriptionClient.parseUsageResponse(from: json)
        XCTAssertNil(snap.fiveHour?.countsText, "Claude reports a percentage only")
    }
}
