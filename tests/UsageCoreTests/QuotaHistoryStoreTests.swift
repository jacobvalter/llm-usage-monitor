import XCTest
@testable import UsageCore

final class QuotaHistoryStoreTests: XCTestCase {

    private var dir: URL!
    private var store: QuotaHistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = QuotaHistoryStore(fileURL: dir.appendingPathComponent("quota-history.jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snapshot(_ five: Double?, _ weekly: Double?, at: Date, provider: Provider = .anthropic) -> QuotaSnapshot {
        var windows: [QuotaWindow] = []
        if let five { windows.append(QuotaWindow(kind: .fiveHour, label: "5-hour", usedPercent: five)) }
        if let weekly { windows.append(QuotaWindow(kind: .weekly, label: "Weekly", usedPercent: weekly)) }
        return QuotaSnapshot(provider: provider, source: .claudeOAuthUsage, windows: windows, fetchedAt: at)
    }

    func testEmptyStoreReadsAsEmpty() {
        XCTAssertTrue(store.points().isEmpty)
        XCTAssertTrue(store.fiveHourSeries(provider: .anthropic).isEmpty)
    }

    func testAppendAndReadBack() {
        let t = isoDate("2026-09-20T10:00:00Z")
        store.append(snapshot(34, 7, at: t))
        let points = store.points()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points[0].provider, .anthropic)
        XCTAssertEqual(points[0].fiveHourPercent, 34)
        XCTAssertEqual(points[0].weeklyPercent, 7)
        XCTAssertEqual(points[0].at, t)
    }

    func testHistorySurvivesANewStoreInstance() {
        let t = isoDate("2026-09-20T10:00:00Z")
        store.append(snapshot(10, 5, at: t))
        store.append(snapshot(20, 6, at: t.addingTimeInterval(60)))

        // A fresh instance is what a relaunch looks like.
        let reopened = QuotaHistoryStore(fileURL: URL(fileURLWithPath: store.path))
        XCTAssertEqual(reopened.fiveHourSeries(provider: .anthropic), [10, 20])
    }

    func testSnapshotWithNoWindowsIsNotStored() {
        store.append(QuotaSnapshot(provider: .openai, source: .codexWhamUsage, windows: []))
        XCTAssertTrue(store.points().isEmpty)
    }

    func testFilterByProviderAndDate() {
        let t = isoDate("2026-09-20T10:00:00Z")
        store.append(snapshot(10, 1, at: t, provider: .anthropic))
        store.append(snapshot(20, 2, at: t.addingTimeInterval(60), provider: .openai))
        store.append(snapshot(30, 3, at: t.addingTimeInterval(120), provider: .anthropic))

        XCTAssertEqual(store.points(provider: .anthropic).count, 2)
        XCTAssertEqual(store.points(provider: .openai).count, 1)
        XCTAssertEqual(store.points(since: t.addingTimeInterval(60)).count, 2)
        XCTAssertEqual(store.fiveHourSeries(provider: .anthropic), [10, 30])
    }

    func testCorruptLinesAreSkipped() throws {
        let t = isoDate("2026-09-20T10:00:00Z")
        store.append(snapshot(10, 1, at: t))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: store.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n{\"broken\":true}\n".utf8))
        try handle.close()
        store.append(snapshot(20, 2, at: t.addingTimeInterval(60)))

        XCTAssertEqual(store.fiveHourSeries(provider: .anthropic), [10, 20])
    }

    func testTrimKeepsNewestPoints() {
        let small = QuotaHistoryStore(fileURL: dir.appendingPathComponent("small.jsonl"), maxPoints: 5)
        let t = isoDate("2026-09-20T10:00:00Z")
        for i in 0..<12 {
            small.append(snapshot(Double(i), nil, at: t.addingTimeInterval(Double(i) * 60)))
        }
        XCTAssertEqual(small.points().count, 12)
        small.trimIfNeeded()
        XCTAssertEqual(small.fiveHourSeries(provider: .anthropic), [7, 8, 9, 10, 11])
    }

    func testTrimIsANoOpBelowTheLimit() {
        let t = isoDate("2026-09-20T10:00:00Z")
        store.append(snapshot(1, 1, at: t))
        store.trimIfNeeded()
        XCTAssertEqual(store.points().count, 1)
    }
}

extension QuotaHistoryStoreTests {

    func testMonthlyOnlySnapshotIsStored() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-m-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaHistoryStore(fileURL: dir.appendingPathComponent("h.jsonl"))

        // Copilot reports only monthly windows; it must still be recorded.
        let snap = QuotaSnapshot(
            provider: .githubCopilot,
            source: .copilotInternalUser,
            plan: "individual",
            windows: [
                QuotaWindow(kind: .monthly, label: "Chat", usedPercent: 37.5, model: "chat"),
                QuotaWindow(kind: .monthly, label: "Completions", usedPercent: 0, model: "completions"),
            ],
            fetchedAt: isoDate("2026-09-22T10:00:00Z")
        )
        store.append(snap)

        let points = store.points(provider: .githubCopilot)
        XCTAssertEqual(points.count, 1)
        XCTAssertNil(points[0].fiveHourPercent)
        XCTAssertEqual(points[0].monthlyPercent, 37.5, "the busiest monthly window is stored")
        XCTAssertEqual(store.monthlySeries(provider: .githubCopilot), [37.5])
        XCTAssertEqual(store.primarySeries(provider: .githubCopilot), [37.5])
    }

    func testPrimarySeriesPrefersFiveHour() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-p-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaHistoryStore(fileURL: dir.appendingPathComponent("h.jsonl"))

        store.append(QuotaHistoryPoint(at: isoDate("2026-09-22T10:00:00Z"), provider: .anthropic,
                                       fiveHourPercent: 12, weeklyPercent: 5, monthlyPercent: 99))
        XCTAssertEqual(store.primarySeries(provider: .anthropic), [12])
    }

    func testPointWithNoValuesIsRejected() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hist-n-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = QuotaHistoryStore(fileURL: dir.appendingPathComponent("h.jsonl"))

        store.append(QuotaSnapshot(provider: .githubCopilot, source: .copilotInternalUser, windows: []))
        XCTAssertTrue(store.points().isEmpty)
    }
}
