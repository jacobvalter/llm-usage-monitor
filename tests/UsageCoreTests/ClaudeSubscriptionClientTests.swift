import XCTest
@testable import UsageCore

final class ClaudeSubscriptionClientTests: XCTestCase {

    // MARK: - Parsing

    func testParseFixtureProducesWindows() throws {
        let data = try fixtureData("claude_oauth_usage")
        let fetchedAt = isoDate("2026-09-19T14:32:00Z")
        let snap = try ClaudeSubscriptionClient.parseUsageResponse(from: data, plan: "max", fetchedAt: fetchedAt)

        XCTAssertEqual(snap.provider, .anthropic)
        XCTAssertEqual(snap.source, .claudeOAuthUsage)
        XCTAssertEqual(snap.plan, "max")
        XCTAssertEqual(snap.fetchedAt, fetchedAt)

        let five = try XCTUnwrap(snap.fiveHour)
        XCTAssertEqual(five.usedPercent, 33)
        XCTAssertEqual(five.windowSeconds, 5 * 3600)
        XCTAssertEqual(five.resetsAt, isoDate("2026-09-19T17:00:00Z").addingTimeInterval(0.528), accuracy: 0.001)

        let weekly = try XCTUnwrap(snap.weekly)
        XCTAssertEqual(weekly.usedPercent, 13)
        XCTAssertNotNil(weekly.resetsAt)

        // seven_day_opus is null → no Opus window; Sonnet is present; limits[] adds Fable.
        let models = snap.modelWindows
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.first { $0.model == "sonnet" }?.usedPercent, 1)
        let fable = try XCTUnwrap(models.first { $0.model == "claude-fable-5-1" })
        XCTAssertEqual(fable.usedPercent, 42)
        XCTAssertEqual(fable.label, "Weekly · Fable")

        // extra_usage disabled → not surfaced.
        XCTAssertFalse(snap.windows.contains { $0.kind == .monthlyExtra })

        // Tightest of 5h/weekly is the 5h at 33%.
        XCTAssertEqual(snap.tightest?.kind, .fiveHour)
    }

    func testParseMinimalResponse() throws {
        let json = #"{"five_hour":{"utilization":80.5,"resets_at":"2026-09-19T17:00:00Z"}}"#.data(using: .utf8)!
        let snap = try ClaudeSubscriptionClient.parseUsageResponse(from: json)
        XCTAssertEqual(snap.windows.count, 1)
        XCTAssertEqual(snap.fiveHour?.usedPercent, 80.5)
        XCTAssertNil(snap.weekly)
    }

    func testUtilizationIsClampedTo0To100() throws {
        let json = #"{"five_hour":{"utilization":140.0},"seven_day":{"utilization":-3.0}}"#.data(using: .utf8)!
        let snap = try ClaudeSubscriptionClient.parseUsageResponse(from: json)
        XCTAssertEqual(snap.fiveHour?.usedPercent, 100)
        XCTAssertEqual(snap.weekly?.usedPercent, 0)
    }

    // MARK: - Request

    func testRequestHeaders() async throws {
        let recorder = RequestRecorder()
        let client = ClaudeSubscriptionClient(
            accessToken: "sk-ant-oat01-test",
            claudeCodeVersion: "2.3.4",
            fetch: recorder.respond(with: [#"{"five_hour":{"utilization":1}}"#])
        )
        _ = try await client.fetchQuota()

        let req = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(req.url, ClaudeSubscriptionClient.usageURL)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-ant-oat01-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "claude-code/2.3.4")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: - Errors

    func testUnauthorized() async {
        let recorder = RequestRecorder()
        let client = ClaudeSubscriptionClient(accessToken: "dead", fetch: recorder.respond(with: ["{}"], status: 401))
        do {
            _ = try await client.fetchQuota()
            XCTFail("expected error")
        } catch let error as ClaudeSubscriptionError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRateLimitedCarriesRetryAfter() async {
        let recorder = RequestRecorder()
        let client = ClaudeSubscriptionClient(
            accessToken: "t",
            fetch: recorder.respond(with: ["{}"], status: 429, headers: ["retry-after": "120"])
        )
        do {
            _ = try await client.fetchQuota()
            XCTFail("expected error")
        } catch let error as ClaudeSubscriptionError {
            XCTAssertEqual(error, .rateLimited(retryAfterSeconds: 120))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Credentials

    func testCredentialsParseFromClaudeCodeJSON() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def",
         "expiresAt":1758300000000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}
        """.data(using: .utf8)!
        let creds = try ClaudeOAuthCredentials.parse(json)
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(creds.refreshToken, "sk-ant-ort01-def")
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_758_300_000), "expiresAt is milliseconds")
        XCTAssertEqual(creds.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(creds.subscriptionType, "max")
        XCTAssertFalse(creds.isExpired(at: Date(timeIntervalSince1970: 1_758_000_000)))
        XCTAssertTrue(creds.isExpired(at: Date(timeIntervalSince1970: 1_758_400_000)))
    }

    func testCredentialsParseRejectsMissingToken() {
        let json = #"{"claudeAiOauth":{"refreshToken":"x"}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeOAuthCredentials.parse(json)) { error in
            XCTAssertEqual(error as? ClaudeSubscriptionError, .noCredentials)
        }
    }

    func testReaderPrefersEnvironmentToken() throws {
        let reader = ClaudeCredentialsReader(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "env-token"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent"),
            keychainReader: { _ in nil }
        )
        XCTAssertEqual(try reader.load().accessToken, "env-token")
    }

    func testReaderFallsBackToKeychainThenFile() throws {
        let keychainJSON = #"{"claudeAiOauth":{"accessToken":"from-keychain","expiresAt":9999999999000}}"#.data(using: .utf8)
        let reader = ClaudeCredentialsReader(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/nonexistent"),
            keychainReader: { service in
                XCTAssertEqual(service, "Claude Code-credentials")
                return keychainJSON
            }
        )
        XCTAssertEqual(try reader.load().accessToken, "from-keychain")

        // File fallback
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("usagecore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try #"{"claudeAiOauth":{"accessToken":"from-file"}}"#.data(using: .utf8)!
            .write(to: tmp.appendingPathComponent(".claude/.credentials.json"))
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileReader = ClaudeCredentialsReader(environment: [:], homeDirectory: tmp, keychainReader: { _ in nil })
        XCTAssertEqual(try fileReader.load().accessToken, "from-file")
        XCTAssertEqual(fileReader.credentialsFileURL.path, tmp.appendingPathComponent(".claude/.credentials.json").path)
    }

    func testReaderHonoursClaudeConfigDir() {
        let reader = ClaudeCredentialsReader(
            environment: ["CLAUDE_CONFIG_DIR": "/custom/claude"],
            homeDirectory: URL(fileURLWithPath: "/home/x"),
            keychainReader: { _ in nil }
        )
        XCTAssertEqual(reader.credentialsFileURL.path, "/custom/claude/.credentials.json")
    }

    func testLoadValidThrowsOnExpiredToken() {
        let json = #"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000000000000}}"#.data(using: .utf8)
        let reader = ClaudeCredentialsReader(environment: [:], homeDirectory: URL(fileURLWithPath: "/nonexistent"),
                                             keychainReader: { _ in json })
        XCTAssertThrowsError(try reader.loadValid(now: Date(timeIntervalSince1970: 2_000_000_000))) { error in
            guard case .tokenExpired = error as? ClaudeSubscriptionError else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: - Date parsing

    func testDateParsingHandlesMicrosecondsAndOffsets() {
        XCTAssertNotNil(DateParsing.date(from: "2026-04-11T07:00:00.528743+00:00"))
        XCTAssertNotNil(DateParsing.date(from: "2026-04-11T07:00:00.528Z"))
        XCTAssertNotNil(DateParsing.date(from: "2026-04-11T07:00:00Z"))
        XCTAssertNil(DateParsing.date(from: "not a date"))
        XCTAssertEqual(DateParsing.date(from: "2026-04-11T07:00:00.528743+00:00"),
                       isoDate("2026-04-11T07:00:00Z").addingTimeInterval(0.528), accuracy: 0.001)
    }
}

private func XCTAssertEqual(_ a: Date?, _ b: Date, accuracy: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("date was nil", file: file, line: line) }
    XCTAssertEqual(a.timeIntervalSince1970, b.timeIntervalSince1970, accuracy: accuracy, file: file, line: line)
}
