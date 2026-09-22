import Foundation
import SwiftUI
import UsageCore

/// User settings, stored in UserDefaults.
/// Every property writes through on change, so there is no Save button.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.refreshSeconds = defaults.value(forKey: Key.refreshSeconds) as? Double ?? 60
        self.showClaude = defaults.value(forKey: Key.showClaude) as? Bool ?? true
        self.showCopilot = defaults.value(forKey: Key.showCopilot) as? Bool ?? true
        self.showCodex = defaults.value(forKey: Key.showCodex) as? Bool ?? false
        self.elevatedAt = defaults.value(forKey: Key.elevatedAt) as? Double ?? LevelThresholds.standard.elevated
        self.highAt = defaults.value(forKey: Key.highAt) as? Double ?? LevelThresholds.standard.high
        self.criticalAt = defaults.value(forKey: Key.criticalAt) as? Double ?? LevelThresholds.standard.critical
        self.copilotHost = defaults.string(forKey: Key.copilotHost) ?? CopilotHost.dotCom.rawValue
        self.alertPreference = defaults.string(forKey: Key.alertPreference) ?? AlertPreference.high.rawValue
        self.tokenRange = defaults.string(forKey: Key.tokenRange) ?? TokenRange.today.rawValue
    }

    private enum Key {
        static let refreshSeconds = "refreshSeconds"
        static let showClaude = "showClaude"
        static let showCopilot = "showCopilot"
        static let showCodex = "showCodex"
        static let elevatedAt = "elevatedAt"
        static let highAt = "highAt"
        static let criticalAt = "criticalAt"
        static let copilotHost = "copilotHost"
        static let alertPreference = "alertPreference"
        static let tokenRange = "tokenRange"
    }

    /// How often to poll. 30s is the floor; the providers only move about once a minute.
    @Published var refreshSeconds: Double { didSet { defaults.set(refreshSeconds, forKey: Key.refreshSeconds) } }

    @Published var showClaude: Bool { didSet { defaults.set(showClaude, forKey: Key.showClaude) } }
    @Published var showCopilot: Bool { didSet { defaults.set(showCopilot, forKey: Key.showCopilot) } }
    @Published var showCodex: Bool { didSet { defaults.set(showCodex, forKey: Key.showCodex) } }

    @Published var elevatedAt: Double { didSet { defaults.set(elevatedAt, forKey: Key.elevatedAt) } }
    @Published var highAt: Double { didSet { defaults.set(highAt, forKey: Key.highAt) } }
    @Published var criticalAt: Double { didSet { defaults.set(criticalAt, forKey: Key.criticalAt) } }

    /// Which GitHub to ask for Copilot quota.
    @Published var copilotHost: String { didSet { defaults.set(copilotHost, forKey: Key.copilotHost) } }

    /// Which period the token counts cover.
    @Published var tokenRange: String { didSet { defaults.set(tokenRange, forKey: Key.tokenRange) } }

    var selectedTokenRange: TokenRange { TokenRange(rawValue: tokenRange) ?? .today }

    /// When to send a notification.
    @Published var alertPreference: String { didSet { defaults.set(alertPreference, forKey: Key.alertPreference) } }

    var alertMinimumLevel: UsageLevel? {
        (AlertPreference(rawValue: alertPreference) ?? .high).minimumLevel
    }

    var thresholds: LevelThresholds {
        LevelThresholds(elevated: elevatedAt, high: highAt, critical: criticalAt)
    }

    func resetThresholds() {
        let s = LevelThresholds.standard
        elevatedAt = s.elevated
        highAt = s.high
        criticalAt = s.critical
    }

    func isVisible(_ provider: Provider) -> Bool {
        switch provider {
        case .anthropic: return showClaude
        case .githubCopilot: return showCopilot
        case .openai: return showCodex
        }
    }
}

/// The period the local token counts cover.
enum TokenRange: String, CaseIterable, Identifiable {
    case today
    case week

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: return "Today"
        case .week: return "7 days"
        }
    }

    /// Wording for the headline, e.g. "tokens today".
    var caption: String {
        switch self {
        case .today: return "tokens today"
        case .week: return "tokens this week"
        }
    }

    func start(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today) ?? today
        }
    }

    /// How many hourly buckets the small chart should show.
    var chartHours: Int {
        switch self {
        case .today: return 12
        case .week: return 7 * 24
        }
    }
}

/// The GitHub a Copilot seat lives on.
enum CopilotHost: String, CaseIterable, Identifiable {
    case dotCom = "github.com"
    case enterprise = "enterprise"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dotCom: return "github.com"
        case .enterprise: return "Enterprise"
        }
    }
}
