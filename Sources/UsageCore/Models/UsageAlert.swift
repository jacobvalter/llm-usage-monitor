import Foundation

extension UsageLevel: Comparable {
    /// Severity order, so "has it got worse?" is a plain comparison.
    public var rank: Int {
        switch self {
        case .normal: return 0
        case .elevated: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (a: UsageLevel, b: UsageLevel) -> Bool { a.rank < b.rank }
}

/// Something worth telling the user about.
public struct UsageAlert: Equatable, Sendable {
    public let key: String
    public let provider: Provider
    public let windowLabel: String
    public let level: UsageLevel
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(
        key: String, provider: Provider, windowLabel: String,
        level: UsageLevel, usedPercent: Double, resetsAt: Date?
    ) {
        self.key = key
        self.provider = provider
        self.windowLabel = windowLabel
        self.level = level
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var title: String {
        let name: String
        switch provider {
        case .anthropic: name = "Claude"
        case .openai: name = "Codex"
        case .githubCopilot: name = "GitHub Copilot"
        }
        return level == .critical ? "\(name) almost used up" : "\(name) usage is high"
    }

    public var body: String {
        var text = "\(windowLabel) is at \(Int(usedPercent))%."
        if let resetsAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            text += " Resets \(f.localizedString(for: resetsAt, relativeTo: Date()))."
        }
        return text
    }
}

/// What was last said about one window, so the same thing is not said twice.
public struct AlertState: Codable, Equatable, Sendable {
    public var level: UsageLevel
    /// When this window resets. A different value means a fresh window.
    public var windowResetsAt: Date?

    public init(level: UsageLevel, windowResetsAt: Date?) {
        self.level = level
        self.windowResetsAt = windowResetsAt
    }
}

/// Decides when a window deserves a notification.
///
/// Fires only when the level gets *worse* than last time, so a window sitting at
/// 80% does not notify on every poll. When a window resets, its memory is cleared,
/// so the next climb notifies again.
public struct UsageAlertEvaluator: Sendable {
    /// Quietest level worth interrupting for.
    public let minimumLevel: UsageLevel

    public init(minimumLevel: UsageLevel = .high) {
        self.minimumLevel = minimumLevel
    }

    public static func key(provider: Provider, window: QuotaWindow) -> String {
        "\(provider.rawValue)|\(window.kind.rawValue)|\(window.label)"
    }

    /// Returns what to notify about, and updates `state` in place.
    public func alerts(
        for snapshots: [QuotaSnapshot],
        thresholds: LevelThresholds = .standard,
        state: inout [String: AlertState]
    ) -> [UsageAlert] {
        var out: [UsageAlert] = []

        for snapshot in snapshots {
            for window in snapshot.measuredWindows {
                guard window.kind == .fiveHour || window.kind == .weekly || window.kind == .monthly else { continue }

                let key = Self.key(provider: snapshot.provider, window: window)
                let level = thresholds.level(for: window.usedPercent)

                // A new window starts with a clean slate.
                let previous = state[key]
                let sameWindow = previous?.windowResetsAt == window.resetsAt
                let previousLevel = sameWindow ? (previous?.level ?? .normal) : .normal

                if level >= minimumLevel, level > previousLevel {
                    out.append(UsageAlert(
                        key: key,
                        provider: snapshot.provider,
                        windowLabel: window.label,
                        level: level,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    ))
                }

                state[key] = AlertState(level: level, windowResetsAt: window.resetsAt)
            }
        }

        return out
    }
}
