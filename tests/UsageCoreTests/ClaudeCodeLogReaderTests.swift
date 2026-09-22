import XCTest
@testable import UsageCore

final class ClaudeCodeLogReaderTests: XCTestCase {

    private func fixtureEntries() throws -> [ClaudeCodeEntry] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "claude_code_session", withExtension: "jsonl", subdirectory: "Fixtures"))
        return ClaudeCodeLogReader.parse(try Data(contentsOf: url))
    }

    // MARK: - Parsing

    func testParsePicksOnlyBillableAssistantMessages() throws {
        let entries = try fixtureEntries()
        // 3 records for msg_A, 1 for msg_B, 1 for msg_D. The user, system
        // and <synthetic> lines are skipped.
        XCTAssertEqual(entries.count, 5)
        XCTAssertFalse(entries.contains { $0.model == ClaudeCodeLogReader.syntheticModel })
        XCTAssertFalse(entries.contains { $0.model.isEmpty })
    }

    func testFieldsAreReadCorrectly() throws {
        let e = try XCTUnwrap(fixtureEntries().first)
        XCTAssertEqual(e.model, "claude-opus-4-7")
        XCTAssertEqual(e.sessionId, "sess_1")
        XCTAssertEqual(e.inputTokens, 6)
        XCTAssertEqual(e.outputTokens, 217)
        XCTAssertEqual(e.cacheReadTokens, 0)
        XCTAssertEqual(e.cacheCreationTokens, 21764)
        XCTAssertEqual(e.totalTokens, 6 + 217 + 0 + 21764)
        XCTAssertEqual(e.timestamp, isoDate("2026-09-20T10:00:05Z"))
    }

    func testNestedCacheCreationIsSummedWhenFlatFieldIsAbsent() throws {
        let d = try XCTUnwrap(fixtureEntries().first { $0.model == "claude-fable-5-1" && $0.inputTokens == 100 })
        XCTAssertEqual(d.cacheCreationTokens, 45, "40 (5m) + 5 (1h)")
    }

    func testNonAssistantLinesAreIgnored() {
        XCTAssertNil(ClaudeCodeLogReader.parseLine(#"{"type":"user","message":{"role":"user"}}"#.data(using: .utf8)!))
        XCTAssertNil(ClaudeCodeLogReader.parseLine(#"{"type":"system"}"#.data(using: .utf8)!))
        XCTAssertNil(ClaudeCodeLogReader.parseLine("not json".data(using: .utf8)!))
        XCTAssertNil(ClaudeCodeLogReader.parseLine(Data()))
    }

    func testMessageWithoutUsageIsIgnored() {
        let line = #"{"type":"assistant","timestamp":"2026-09-20T10:00:00Z","message":{"id":"m","model":"x"}}"#
        XCTAssertNil(ClaudeCodeLogReader.parseLine(line.data(using: .utf8)!))
    }

    // MARK: - Deduplication (the 3x over-count guard)

    func testDedupeKeyIsSharedByRepeatsOfTheSameMessage() throws {
        let entries = try fixtureEntries()
        let msgA = entries.filter { $0.dedupeKey.hasPrefix("msg_A") }
        XCTAssertEqual(msgA.count, 3, "the fixture repeats msg_A three times")
        XCTAssertEqual(Set(msgA.map(\.dedupeKey)).count, 1, "repeats must share one key")
    }

    func testTotalsAfterDedupeAreNotInflated() throws {
        let entries = try fixtureEntries()

        // What a naive sum of every record would produce.
        let naive = ClaudeCodeLogReader.totals(entries)
        XCTAssertEqual(naive.outputTokens, 217 * 3 + 2660 + 50)

        // What we actually report: one row per message id.
        var seen = Set<String>()
        let deduped = entries.filter { seen.insert($0.dedupeKey).inserted }
        let real = ClaudeCodeLogReader.totals(deduped)

        XCTAssertEqual(deduped.count, 3)
        XCTAssertEqual(real.outputTokens, 217 + 2660 + 50)
        XCTAssertEqual(real.inputTokens, 6 + 1 + 100)
        XCTAssertEqual(real.cacheReadTokens, 0 + 22124 + 10)
        XCTAssertEqual(real.cacheCreationTokens, 21764 + 0 + 45)
        XCTAssertEqual(real.messageCount, 3)
        XCTAssertLessThan(real.outputTokens, naive.outputTokens)
    }

    // MARK: - Aggregation

    func testByModelIsSortedBusiestFirst() throws {
        var seen = Set<String>()
        let deduped = try fixtureEntries().filter { seen.insert($0.dedupeKey).inserted }
        let rows = ClaudeCodeLogReader.byModel(deduped)

        XCTAssertEqual(rows.count, 2)
        // fable: msg_B 24785 + msg_D 205 = 24990. opus: msg_A 21987.
        XCTAssertEqual(rows[0].model, "claude-fable-5-1")
        XCTAssertEqual(rows[0].totals.totalTokens, 24990)
        XCTAssertEqual(rows[0].totals.messageCount, 2)
        XCTAssertEqual(rows[1].model, "claude-opus-4-7")
        XCTAssertEqual(rows[1].totals.totalTokens, 21987)
        XCTAssertEqual(rows.map(\.totals.messageCount).reduce(0, +), 3)
    }

    func testHourlyTotalsBucketsByHour() throws {
        var seen = Set<String>()
        let deduped = try fixtureEntries().filter { seen.insert($0.dedupeKey).inserted }
        // Fixture spans 10:00 and 11:30/11:33 UTC.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let buckets = ClaudeCodeLogReader.hourlyTotals(
            deduped, hours: 3, now: isoDate("2026-09-20T12:10:00Z"), calendar: utc
        )
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets[0], 6 + 217 + 21764, "10:00 bucket")
        XCTAssertGreaterThan(buckets[1], 0, "11:00 bucket holds msg_B and msg_D")
        XCTAssertEqual(buckets[2], 0, "12:00 bucket is empty")
    }

    func testHourlyTotalsWithNoEntries() {
        XCTAssertEqual(ClaudeCodeLogReader.hourlyTotals([], hours: 4), [0, 0, 0, 0])
        XCTAssertEqual(ClaudeCodeLogReader.hourlyTotals([], hours: 0), [])
    }

    func testTotalsOfNothingIsZero() {
        let t = ClaudeCodeLogReader.totals([])
        XCTAssertEqual(t.totalTokens, 0)
        XCTAssertEqual(t.messageCount, 0)
    }

    // MARK: - File discovery

    func testMissingDirectoryYieldsNoEntries() {
        let reader = ClaudeCodeLogReader(projectsDirectory: URL(fileURLWithPath: "/nonexistent/projects"))
        XCTAssertTrue(reader.entries(since: .distantPast).isEmpty)
    }

    func testEntriesReadsFilesAndDedupesAcrossThem() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        let project = tmp.appendingPathComponent("proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "claude_code_session", withExtension: "jsonl", subdirectory: "Fixtures"))
        let body = try Data(contentsOf: url)
        // Same content in two files: the dedupe must still collapse it.
        try body.write(to: project.appendingPathComponent("a.jsonl"))
        try body.write(to: project.appendingPathComponent("b.jsonl"))

        let entries = ClaudeCodeLogReader(projectsDirectory: tmp).entries(since: .distantPast)
        XCTAssertEqual(entries.count, 3, "3 unique messages across both copies")
        XCTAssertEqual(entries.map(\.timestamp), entries.map(\.timestamp).sorted(), "oldest first")
    }

    func testSinceFiltersOldEntries() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "claude_code_session", withExtension: "jsonl", subdirectory: "Fixtures"))
        try Data(contentsOf: url).write(to: tmp.appendingPathComponent("a.jsonl"))

        let entries = ClaudeCodeLogReader(projectsDirectory: tmp)
            .entries(since: isoDate("2026-09-20T11:00:00Z"))
        XCTAssertEqual(entries.count, 2, "the 10:00 message is excluded")
    }
}

final class ClaudeCodeLogCacheTests: XCTestCase {

    private func makeLogDir() throws -> (dir: URL, file: URL) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "claude_code_session", withExtension: "jsonl", subdirectory: "Fixtures"))
        let file = tmp.appendingPathComponent("a.jsonl")
        try Data(contentsOf: url).write(to: file)
        return (tmp, file)
    }

    func testSecondReadIsServedFromCache() throws {
        let (dir, file) = try makeLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = ClaudeCodeLogCache()
        let reader = ClaudeCodeLogReader(projectsDirectory: dir, cache: cache)

        let first = reader.entries(since: .distantPast)
        // Deleting the file must not change the answer if the cache is doing its job.
        try FileManager.default.removeItem(at: file)
        // The file is gone, so discovery finds nothing; re-create it to keep discovery working.
        let src = try XCTUnwrap(Bundle.module.url(
            forResource: "claude_code_session", withExtension: "jsonl", subdirectory: "Fixtures"))
        try Data(contentsOf: src).write(to: file)

        let second = reader.entries(since: .distantPast)
        XCTAssertEqual(first.count, second.count)
        XCTAssertEqual(first.map(\.dedupeKey), second.map(\.dedupeKey))
    }

    func testChangedFileIsParsedAgain() throws {
        let (dir, file) = try makeLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = ClaudeCodeLogCache()
        let reader = ClaudeCodeLogReader(projectsDirectory: dir, cache: cache)
        let before = reader.entries(since: .distantPast)

        // Append one more message; size changes, so the cache entry must be replaced.
        let extra = #"{"type":"assistant","timestamp":"2026-09-20T12:00:00.000Z","requestId":"req_E","sessionId":"s","message":{"id":"msg_E","model":"claude-opus-5","usage":{"input_tokens":5,"output_tokens":7}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.data(using: .utf8)!)
        try handle.close()

        let after = reader.entries(since: .distantPast)
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertTrue(after.contains { $0.model == "claude-opus-5" })
    }

    func testClearForcesReparse() throws {
        let (dir, _) = try makeLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cache = ClaudeCodeLogCache()
        let reader = ClaudeCodeLogReader(projectsDirectory: dir, cache: cache)
        let a = reader.entries(since: .distantPast)
        cache.clear()
        let b = reader.entries(since: .distantPast)
        XCTAssertEqual(a.map(\.dedupeKey), b.map(\.dedupeKey))
    }

    func testReaderWithoutCacheStillWorks() throws {
        let (dir, _) = try makeLogDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = ClaudeCodeLogReader(projectsDirectory: dir, cache: nil).entries(since: .distantPast)
        XCTAssertEqual(entries.count, 3)
    }
}
