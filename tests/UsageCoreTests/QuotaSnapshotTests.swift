import XCTest
@testable import UsageCore

final class UsageLevelTests: XCTestCase {

    func testThresholds() {
        XCTAssertEqual(UsageLevel(usedPercent: 0), .normal)
        XCTAssertEqual(UsageLevel(usedPercent: 49.9), .normal)
        XCTAssertEqual(UsageLevel(usedPercent: 50), .elevated)
        XCTAssertEqual(UsageLevel(usedPercent: 74.9), .elevated)
        XCTAssertEqual(UsageLevel(usedPercent: 75), .high)
        XCTAssertEqual(UsageLevel(usedPercent: 89.9), .high)
        XCTAssertEqual(UsageLevel(usedPercent: 90), .critical)
        XCTAssertEqual(UsageLevel(usedPercent: 100), .critical)
    }

    func testWindowLevel() {
        let w = QuotaWindow(kind: .fiveHour, label: "5-hour", usedPercent: 82)
        XCTAssertEqual(w.level, .high)
    }

    func testSnapshotLevelUsesTightestWindow() {
        let snap = QuotaSnapshot(
            provider: .anthropic,
            source: .claudeOAuthUsage,
            windows: [
                QuotaWindow(kind: .fiveHour, label: "5-hour", usedPercent: 12),
                QuotaWindow(kind: .weekly, label: "Weekly", usedPercent: 93),
                // A model window must not drive the badge.
                QuotaWindow(kind: .weeklyModel, label: "Weekly · X", usedPercent: 99, model: "x"),
            ]
        )
        XCTAssertEqual(snap.tightest?.usedPercent, 93)
        XCTAssertEqual(snap.level, .critical)
    }

    func testEmptySnapshotIsNormal() {
        let snap = QuotaSnapshot(provider: .openai, source: .codexWhamUsage, windows: [])
        XCTAssertEqual(snap.level, .normal)
    }
}
