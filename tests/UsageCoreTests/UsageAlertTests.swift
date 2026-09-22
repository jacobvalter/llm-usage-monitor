import XCTest
@testable import UsageCore

final class UsageAlertEvaluatorTests: XCTestCase {

    private let reset = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ percent: Double, resetsAt: Date? = nil,
                          provider: Provider = .anthropic,
                          kind: QuotaWindowKind = .fiveHour,
                          label: String = "5-hour") -> QuotaSnapshot {
        QuotaSnapshot(
            provider: provider,
            source: .claudeOAuthUsage,
            windows: [QuotaWindow(kind: kind, label: label, usedPercent: percent, resetsAt: resetsAt)]
        )
    }

    // MARK: - Level ordering

    func testLevelsCompareBySeverity() {
        XCTAssertLessThan(UsageLevel.normal, .elevated)
        XCTAssertLessThan(UsageLevel.elevated, .high)
        XCTAssertLessThan(UsageLevel.high, .critical)
        XCTAssertEqual([UsageLevel.critical, .normal, .high].max(), .critical)
    }

    // MARK: - Firing

    func testFiresWhenCrossingIntoHigh() {
        var state: [String: AlertState] = [:]
        let alerts = UsageAlertEvaluator().alerts(for: [snapshot(80, resetsAt: reset)], state: &state)

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].level, .high)
        XCTAssertEqual(alerts[0].usedPercent, 80)
        XCTAssertEqual(alerts[0].provider, .anthropic)
        XCTAssertEqual(alerts[0].windowLabel, "5-hour")
    }

    func testDoesNotFireBelowTheMinimumLevel() {
        var state: [String: AlertState] = [:]
        XCTAssertTrue(UsageAlertEvaluator().alerts(for: [snapshot(60, resetsAt: reset)], state: &state).isEmpty,
                      "60% is elevated, below the default minimum of high")
        XCTAssertEqual(state.values.first?.level, .elevated, "state is still recorded")
    }

    func testDoesNotRepeatAtTheSameLevel() {
        var state: [String: AlertState] = [:]
        let e = UsageAlertEvaluator()
        XCTAssertEqual(e.alerts(for: [snapshot(80, resetsAt: reset)], state: &state).count, 1)
        XCTAssertTrue(e.alerts(for: [snapshot(82, resetsAt: reset)], state: &state).isEmpty)
        XCTAssertTrue(e.alerts(for: [snapshot(89, resetsAt: reset)], state: &state).isEmpty)
    }

    func testFiresAgainWhenEscalating() {
        var state: [String: AlertState] = [:]
        let e = UsageAlertEvaluator()
        XCTAssertEqual(e.alerts(for: [snapshot(80, resetsAt: reset)], state: &state).count, 1)
        let escalated = e.alerts(for: [snapshot(95, resetsAt: reset)], state: &state)
        XCTAssertEqual(escalated.count, 1)
        XCTAssertEqual(escalated[0].level, .critical)
    }

    func testDoesNotFireWhenUsageFalls() {
        var state: [String: AlertState] = [:]
        let e = UsageAlertEvaluator()
        _ = e.alerts(for: [snapshot(95, resetsAt: reset)], state: &state)
        XCTAssertTrue(e.alerts(for: [snapshot(80, resetsAt: reset)], state: &state).isEmpty)
        XCTAssertEqual(state.values.first?.level, .high, "the drop is remembered")
    }

    func testFiresAgainAfterTheWindowResets() {
        var state: [String: AlertState] = [:]
        let e = UsageAlertEvaluator()
        XCTAssertEqual(e.alerts(for: [snapshot(95, resetsAt: reset)], state: &state).count, 1)

        // A new reset date means a fresh window, even at the same percentage.
        let next = reset.addingTimeInterval(5 * 3600)
        let alerts = e.alerts(for: [snapshot(95, resetsAt: next)], state: &state)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].level, .critical)
    }

    // MARK: - Scope

    func testUnlimitedWindowsNeverAlert() {
        var state: [String: AlertState] = [:]
        let snap = QuotaSnapshot(
            provider: .githubCopilot, source: .copilotInternalUser,
            windows: [QuotaWindow(kind: .monthly, label: "Chat", usedPercent: 99, isUnlimited: true)]
        )
        XCTAssertTrue(UsageAlertEvaluator().alerts(for: [snap], state: &state).isEmpty)
        XCTAssertTrue(state.isEmpty)
    }

    func testModelScopedWindowsDoNotAlert() {
        var state: [String: AlertState] = [:]
        let snap = snapshot(99, resetsAt: reset, kind: .weeklyModel, label: "Weekly · Opus")
        XCTAssertTrue(UsageAlertEvaluator().alerts(for: [snap], state: &state).isEmpty)
    }

    func testProvidersAndWindowsAreTrackedSeparately() {
        var state: [String: AlertState] = [:]
        let claude = snapshot(95, resetsAt: reset, provider: .anthropic)
        let copilot = snapshot(95, resetsAt: reset, provider: .githubCopilot,
                               kind: .monthly, label: "Premium")
        let alerts = UsageAlertEvaluator().alerts(for: [claude, copilot], state: &state)
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.provider)), [.anthropic, .githubCopilot])
        XCTAssertEqual(state.count, 2)
    }

    func testCustomThresholdsChangeWhenItFires() {
        var state: [String: AlertState] = [:]
        let strict = LevelThresholds(elevated: 10, high: 20, critical: 30)
        let alerts = UsageAlertEvaluator().alerts(for: [snapshot(25, resetsAt: reset)],
                                                  thresholds: strict, state: &state)
        XCTAssertEqual(alerts.count, 1, "25% is high on a strict scale")
    }

    func testCriticalOnlyMode() {
        var state: [String: AlertState] = [:]
        let e = UsageAlertEvaluator(minimumLevel: .critical)
        XCTAssertTrue(e.alerts(for: [snapshot(80, resetsAt: reset)], state: &state).isEmpty)
        XCTAssertEqual(e.alerts(for: [snapshot(95, resetsAt: reset)], state: &state).count, 1)
    }

    // MARK: - Wording

    func testAlertTextReadsWell() {
        let alert = UsageAlert(key: "k", provider: .githubCopilot, windowLabel: "Premium",
                               level: .critical, usedPercent: 96, resetsAt: nil)
        XCTAssertEqual(alert.title, "GitHub Copilot almost used up")
        XCTAssertEqual(alert.body, "Premium is at 96%.")

        let high = UsageAlert(key: "k", provider: .anthropic, windowLabel: "5-hour",
                              level: .high, usedPercent: 78, resetsAt: nil)
        XCTAssertEqual(high.title, "Claude usage is high")
        XCTAssertTrue(high.body.hasPrefix("5-hour is at 78%."))
    }

    func testAlertStateRoundTripsThroughCodable() throws {
        let state = ["a": AlertState(level: .high, windowResetsAt: reset)]
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode([String: AlertState].self, from: data), state)
    }
}
