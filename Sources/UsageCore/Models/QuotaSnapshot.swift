import Foundation

/// The kind of rolling limit a subscription window represents.
public enum QuotaWindowKind: String, Codable, Sendable, CaseIterable {
    /// Rolling 5-hour session window (Claude Max/Pro, ChatGPT Plus/Pro).
    case fiveHour = "5h"
    /// Rolling ~weekly window across all models.
    case weekly = "7d"
    /// Weekly window scoped to a single model family (e.g. Claude Opus).
    case weeklyModel = "7d_model"
    /// Monthly allowance that resets on a billing date (GitHub Copilot).
    case monthly = "1mo"
    /// Monthly pay-as-you-go "extra usage" credit pool.
    case monthlyExtra = "monthly_extra"
    /// Provider-specific window we recognise but do not classify.
    case other
}

/// One rolling usage window of a subscription plan.
public struct QuotaWindow: Codable, Sendable, Equatable {
    public let kind: QuotaWindowKind
    /// Short human label, e.g. "5‑hour", "Weekly", "Weekly · Opus".
    public let label: String
    /// 0…100. Clamped on construction.
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Length of the window in seconds when the provider reports it.
    public let windowSeconds: Int?
    /// Model id when the window is model-scoped.
    public let model: String?
    /// The plan grants this without a cap, so the percentage carries no meaning.
    public let isUnlimited: Bool

    public init(
        kind: QuotaWindowKind,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowSeconds: Int? = nil,
        model: String? = nil,
        isUnlimited: Bool = false
    ) {
        self.kind = kind
        self.label = label
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowSeconds = windowSeconds
        self.model = model
        self.isUnlimited = isUnlimited
    }

    public var remainingPercent: Double { 100 - usedPercent }

    public var level: UsageLevel { UsageLevel(usedPercent: usedPercent) }

    public func level(thresholds: LevelThresholds) -> UsageLevel {
        thresholds.level(for: usedPercent)
    }

    /// Seconds until reset, or nil when unknown or already past.
    public func secondsUntilReset(from now: Date = Date()) -> TimeInterval? {
        guard let resetsAt else { return nil }
        let delta = resetsAt.timeIntervalSince(now)
        return delta > 0 ? delta : nil
    }
}

/// How close a window is to its limit. One scale, used by every surface.
public enum UsageLevel: String, Codable, Sendable, CaseIterable {
    case normal    // green
    case elevated  // yellow
    case high      // orange
    case critical  // red

    public init(usedPercent: Double, thresholds: LevelThresholds = .standard) {
        self = thresholds.level(for: usedPercent)
    }
}

/// Where the colour changes. Adjustable, because how early a warning is useful
/// depends on the plan and the person.
public struct LevelThresholds: Codable, Sendable, Equatable {
    public var elevated: Double
    public var high: Double
    public var critical: Double

    public static let standard = LevelThresholds(elevated: 50, high: 75, critical: 90)

    /// Values are clamped to 0...100 and forced into ascending order, so a
    /// bad combination from settings can never invert the scale.
    public init(elevated: Double, high: Double, critical: Double) {
        let e = min(max(elevated, 0), 100)
        let h = min(max(high, 0), 100)
        let c = min(max(critical, 0), 100)
        self.elevated = e
        self.high = max(e, h)
        self.critical = max(max(e, h), c)
    }

    public func level(for usedPercent: Double) -> UsageLevel {
        switch usedPercent {
        case ..<elevated: return .normal
        case ..<high: return .elevated
        case ..<critical: return .high
        default: return .critical
        }
    }
}

/// One slice of where a weekly window was spent, e.g. "Claude Code 96%".
public struct QuotaBreakdownRow: Codable, Sendable, Equatable {
    public let key: String
    public let label: String
    public let percent: Double

    public init(key: String, label: String, percent: Double) {
        self.key = key
        self.label = label
        self.percent = percent
    }
}

/// A point-in-time reading of a provider's subscription limits.
/// This is what drives the 5‑hour / weekly bars in the UI.
public struct QuotaSnapshot: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let provider: Provider
    public let source: UsageSource
    /// Plan name as reported by the provider (e.g. "max", "pro", "plus"), if known.
    public let plan: String?
    public let windows: [QuotaWindow]
    /// Where the weekly window went, when the provider reports it.
    public let breakdown: [QuotaBreakdownRow]
    public let fetchedAt: Date

    public init(
        id: UUID = UUID(),
        provider: Provider,
        source: UsageSource,
        plan: String? = nil,
        windows: [QuotaWindow],
        breakdown: [QuotaBreakdownRow] = [],
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.source = source
        self.plan = plan
        self.windows = windows
        self.breakdown = breakdown
        self.fetchedAt = fetchedAt
    }

    public var fiveHour: QuotaWindow? { windows.first { $0.kind == .fiveHour } }
    public var weekly: QuotaWindow? { windows.first { $0.kind == .weekly } }
    public var monthlyWindows: [QuotaWindow] { windows.filter { $0.kind == .monthly && !$0.isUnlimited } }

    /// Capped windows only: what the bars and the badge should use.
    public var measuredWindows: [QuotaWindow] { windows.filter { !$0.isUnlimited } }

    /// Windows the plan grants without a cap, shown as a note rather than a bar.
    public var unlimitedWindows: [QuotaWindow] { windows.filter(\.isUnlimited) }
    public var modelWindows: [QuotaWindow] { windows.filter { $0.kind == .weeklyModel } }

    /// Busiest monthly window, for providers billed per month.
    public var monthly: QuotaWindow? { monthlyWindows.max { $0.usedPercent < $1.usedPercent } }

    /// Worst level across the windows that matter. Drives the menu bar badge.
    public var level: UsageLevel { tightest.map(\.level) ?? .normal }

    public func level(thresholds: LevelThresholds) -> UsageLevel {
        tightest.map { $0.level(thresholds: thresholds) } ?? .normal
    }

    /// The window closest to its limit — what a single status-bar ring should show.
    /// Model-scoped and extra-credit windows are excluded; they are not the main limit.
    public var tightest: QuotaWindow? {
        windows
            .filter { !$0.isUnlimited }
            .filter { $0.kind == .fiveHour || $0.kind == .weekly || $0.kind == .monthly }
            .max { $0.usedPercent < $1.usedPercent }
    }
}
