import Foundation
import SwiftUI
import UsageCore

/// What the UI knows about one provider.
struct ProviderState: Identifiable {
    let provider: Provider
    var snapshot: QuotaSnapshot?
    var error: String?
    var isLoading = false

    /// Recent 5-hour readings, oldest first. Feeds the sparkline. Memory only.
    var history: [Double] = []

    var id: String { provider.rawValue }

    var name: String { provider == .anthropic ? "Claude" : "Codex" }

    var accent: Color { provider == .anthropic ? Color(red: 0.88, green: 0.54, blue: 0.42)
                                               : Color(red: 0.42, green: 0.82, blue: 0.70) }
}

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var claude = ProviderState(provider: .anthropic)
    @Published private(set) var codex = ProviderState(provider: .openai)
    @Published private(set) var lastUpdated: Date?

    /// Poll interval. The providers refresh their own numbers about once a minute.
    private let interval: TimeInterval = 60
    private var timer: Task<Void, Never>?

    var providers: [ProviderState] { [claude, codex] }

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

    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.interval ?? 60))
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func refresh() async {
        claude.isLoading = true
        codex.isLoading = true
        async let c: Void = refreshClaude()
        async let x: Void = refreshCodex()
        _ = await (c, x)
        lastUpdated = Date()
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
            Self.record(snap, into: &codex.history)
            codex.error = nil
        } catch {
            codex.error = Self.message(for: error)
        }
        codex.isLoading = false
    }

    /// Keeps about an hour of samples at the 60s poll rate.
    private static let historyLimit = 60

    private static func record(_ snap: QuotaSnapshot, into history: inout [Double]) {
        guard let pct = snap.fiveHour?.usedPercent else { return }
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
