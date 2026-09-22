import Foundation
import SwiftUI
import UsageCore

/// What the UI knows about one provider.
struct ProviderState: Identifiable {
    let provider: Provider
    var snapshot: QuotaSnapshot?
    var error: String?
    var isLoading = false

    /// Recent 5-hour readings, oldest first. Loaded from disk, so it survives a restart.
    var history: [Double] = []

    /// Tokens used today, from the CLI session logs.
    var todayTotals: TokenTotals?
    var todayByModel: [(model: String, totals: TokenTotals)] = []
    /// Tokens per hour for the last 12 hours, oldest first.
    var hourlyTokens: [Int64] = []

    var id: String { provider.rawValue }

    var name: String {
        switch provider {
        case .anthropic: return "Claude"
        case .openai: return "Codex"
        case .githubCopilot: return "GitHub Copilot"
        }
    }

    var accent: Color {
        switch provider {
        case .anthropic: return Color(red: 0.88, green: 0.54, blue: 0.42)
        case .openai: return Color(red: 0.42, green: 0.82, blue: 0.70)
        case .githubCopilot: return Color(red: 0.55, green: 0.64, blue: 0.96)
        }
    }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var claude = ProviderState(provider: .anthropic)
    @Published private(set) var copilot = ProviderState(provider: .githubCopilot)
    @Published private(set) var codex = ProviderState(provider: .openai)
    @Published private(set) var lastUpdated: Date?

    init(settings: AppSettings, notifier: NotificationService) {
        self.settings = settings
        self.notifier = notifier
    }

    private let settings: AppSettings
    private let notifier: NotificationService
    private var timer: Task<Void, Never>?

    private let history = QuotaHistoryStore()
    /// Held so unchanged session files are not parsed again on every refresh.
    private let logCache = ClaudeCodeLogCache()

    /// Only the providers the user has switched on.
    var providers: [ProviderState] {
        [claude, copilot, codex].filter { settings.isVisible($0.provider) }
    }

    /// The window nearest its limit across every provider. Drives the menu bar title.
    var headline: QuotaWindow? {
        providers.compactMap(\.snapshot?.tightest).max { $0.usedPercent < $1.usedPercent }
    }

    /// Busiest 5-hour window across providers, for the menu bar.
    var worstFiveHour: QuotaWindow? {
        providers.compactMap(\.snapshot?.fiveHour).max { $0.usedPercent < $1.usedPercent }
    }

    /// Busiest weekly window across providers, for the menu bar.
    var worstWeekly: QuotaWindow? {
        providers.compactMap(\.snapshot?.weekly).max { $0.usedPercent < $1.usedPercent }
    }

    /// Busiest monthly window across providers, for the menu bar.
    var worstMonthly: QuotaWindow? {
        providers.compactMap(\.snapshot?.monthly).max { $0.usedPercent < $1.usedPercent }
    }

    func start() {

        let since = Date().addingTimeInterval(-24 * 3600)
        claude.history = history.primarySeries(provider: .anthropic, since: since)
        codex.history = history.primarySeries(provider: .openai, since: since)
        copilot.history = history.primarySeries(provider: .githubCopilot, since: since)
        history.trimIfNeeded()

        timer?.cancel()
        timer = Task { [weak self] in
            // Ask before the first refresh. Otherwise a crossing found on that
            // refresh is recorded as "already said" but never actually delivered.
            await self?.notifier.requestAuthorizationIfNeeded()

            while !Task.isCancelled {
                await self?.refresh()
                let seconds = self?.settings.refreshSeconds ?? 60
                try? await Task.sleep(for: .seconds(max(30, seconds)))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() async {
        let wantClaude = settings.showClaude
        let wantCopilot = settings.showCopilot
        let wantCodex = settings.showCodex

        claude.isLoading = wantClaude
        copilot.isLoading = wantCopilot
        codex.isLoading = wantCodex

        async let c: Void = wantClaude ? refreshClaude() : ()
        async let g: Void = wantCopilot ? refreshCopilot() : ()
        async let x: Void = wantCodex ? refreshCodex() : ()
        async let l: Void = wantClaude ? refreshLocalTokens() : ()
        _ = await (c, g, x, l)

        notifier.evaluate(
            snapshots: providers.compactMap(\.snapshot),
            thresholds: settings.thresholds,
            minimumLevel: settings.alertMinimumLevel
        )

        lastUpdated = Date()
    }

    private func refreshCopilot() async {
        do {
            let host = CopilotHost(rawValue: settings.copilotHost) ?? .dotCom
            let reader = CopilotCredentialsReader(host: host == .dotCom ? nil : CopilotCredentialsReader.enterpriseHost())
            let token = try reader.loadToken()
            let snap = try await CopilotClient(token: token, apiBaseURL: reader.apiBaseURL).fetchQuota()
            copilot.snapshot = snap
            history.append(snap)
            Self.record(snap, into: &copilot.history)
            copilot.error = nil
        } catch {
            copilot.error = Self.message(for: error)
        }
        copilot.isLoading = false
    }

    private func refreshClaude() async {
        do {
            let creds = try ClaudeCredentialsReader().loadValid()
            let client = ClaudeSubscriptionClient(
                accessToken: creds.accessToken,
                claudeCodeVersion: Self.claudeCodeVersion()
            )
            let snap = try await client.fetchQuota(plan: creds.subscriptionType)
            claude.snapshot = snap
            history.append(snap)
            Self.record(snap, into: &claude.history)
            claude.error = nil
        } catch {
            claude.error = Self.message(for: error)
        }
        claude.isLoading = false
    }

    private func refreshCodex() async {
        do {
            let creds = try CodexCredentialsReader().loadValid()
            let snap = try await CodexSubscriptionClient(credentials: creds).fetchQuota()
            codex.snapshot = snap
            history.append(snap)
            Self.record(snap, into: &codex.history)
            codex.error = nil
        } catch {
            codex.error = Self.message(for: error)
        }
        codex.isLoading = false
    }

    /// Reads today's tokens from the Claude Code session logs.
    /// Parsing runs off the main actor; only the result comes back.
    private func refreshLocalTokens() async {
        let cache = logCache
        let start = Calendar.current.startOfDay(for: Date())

        let result = await Task.detached(priority: .utility) { () -> (TokenTotals, [(String, TokenTotals)], [Int64]) in
            let entries = ClaudeCodeLogReader(cache: cache).entries(since: start)
            return (
                ClaudeCodeLogReader.totals(entries),
                ClaudeCodeLogReader.byModel(entries).map { ($0.model, $0.totals) },
                ClaudeCodeLogReader.hourlyTotals(entries, hours: 12)
            )
        }.value

        claude.todayTotals = result.0
        claude.todayByModel = result.1.map { (model: $0.0, totals: $0.1) }
        claude.hourlyTokens = result.2
    }

    /// Keeps about an hour of samples at the 60s poll rate.
    private static let historyLimit = 60

    private static func record(_ snap: QuotaSnapshot, into history: inout [Double]) {
        guard let pct = snap.fiveHour?.usedPercent ?? snap.monthly?.usedPercent else { return }
        history.append(pct)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The usage endpoint throttles hard unless the User-Agent names a Claude Code version.
    private static func claudeCodeVersion() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "--version"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return ClaudeSubscriptionClient.defaultClaudeCodeVersion }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: " ").first.map(String.init)
            ?? ClaudeSubscriptionClient.defaultClaudeCodeVersion
    }
}
