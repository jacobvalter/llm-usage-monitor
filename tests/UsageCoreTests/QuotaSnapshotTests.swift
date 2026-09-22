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

final class LevelThresholdsTests: XCTestCase {

    func testStandardMatchesTheOldFixedScale() {
        let t = LevelThresholds.standard
        XCTAssertEqual(t.level(for: 49), .normal)
        XCTAssertEqual(t.level(for: 50), .elevated)
        XCTAssertEqual(t.level(for: 75), .high)
        XCTAssertEqual(t.level(for: 90), .critical)
    }

    func testCustomThresholdsWarnEarlier() {
        let t = LevelThresholds(elevated: 25, high: 40, critical: 60)
        XCTAssertEqual(t.level(for: 20), .normal)
        XCTAssertEqual(t.level(for: 30), .elevated)
        XCTAssertEqual(t.level(for: 45), .high)
        XCTAssertEqual(t.level(for: 61), .critical)
    }

    func testOutOfOrderValuesAreCorrected() {
        // critical below elevated would otherwise invert the scale.
        let t = LevelThresholds(elevated: 80, high: 40, critical: 10)
        XCTAssertEqual(t.elevated, 80)
        XCTAssertEqual(t.high, 80)
        XCTAssertEqual(t.critical, 80)
        XCTAssertEqual(t.level(for: 79), .normal)
        XCTAssertEqual(t.level(for: 85), .critical)
    }

    func testValuesAreClampedTo0To100() {
        let t = LevelThresholds(elevated: -10, high: 50, critical: 500)
        XCTAssertEqual(t.elevated, 0)
        XCTAssertEqual(t.critical, 100)
    }

    func testWindowAndSnapshotUseSuppliedThresholds() {
        let strict = LevelThresholds(elevated: 5, high: 10, critical: 15)
        let w = QuotaWindow(kind: .fiveHour, label: "5-hour", usedPercent: 12)
        XCTAssertEqual(w.level, .normal, "12% is normal on the standard scale")
        XCTAssertEqual(w.level(thresholds: strict), .high)

        let snap = QuotaSnapshot(provider: .anthropic, source: .claudeOAuthUsage, windows: [w])
        XCTAssertEqual(snap.level, .normal)
        XCTAssertEqual(snap.level(thresholds: strict), .high)
    }

    func testThresholdsRoundTripThroughCodable() throws {
        let t = LevelThresholds(elevated: 30, high: 60, critical: 85)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(LevelThresholds.self, from: data), t)
    }
}
