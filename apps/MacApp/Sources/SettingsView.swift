import AppKit
import SwiftUI
import UsageCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    /// Read once: gh's host list does not change while the window is open.
    private let discoveredEnterpriseHost = CopilotCredentialsReader.enterpriseHost()

    private var enterpriseLabel: String {
        discoveredEnterpriseHost ?? "Enterprise (not signed in)"
    }

    private var enterpriseHint: String {
        if let host = discoveredEnterpriseHost {
            return "Uses the token the gh CLI already holds. Enterprise host: \(host)."
        }
        return "No enterprise host found. Run: gh auth login --hostname <your-host>"
    }

    private static let intervals: [(label: String, seconds: Double)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300),
    ]

    var body: some View {
        Form {
            Section("Refresh") {
                Picker("Check every", selection: $settings.refreshSeconds) {
                    ForEach(Self.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                Text("Claude and GitHub update their own numbers about once a minute, so shorter is rarely better.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Show") {
                Toggle("Claude", isOn: $settings.showClaude)
                Toggle("GitHub Copilot", isOn: $settings.showCopilot)
                Toggle("Codex", isOn: $settings.showCodex)
            }

            Section("GitHub Copilot") {
                Picker("Account", selection: $settings.copilotHost) {
                    Text(CopilotHost.dotCom.label).tag(CopilotHost.dotCom.rawValue)
                    Text(enterpriseLabel).tag(CopilotHost.enterprise.rawValue)
                        .disabled(discoveredEnterpriseHost == nil)
                }
                Text(enterpriseHint)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Picker("Warn me", selection: $settings.alertPreference) {
                    ForEach(AlertPreference.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Sent once each time a limit gets worse, not on every check. "
                     + "A window that resets can warn again.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("This build is signed locally, so alerts are shown through "
                     + "macOS scripting and are credited to Script Editor. "
                     + "A Developer ID signature would make them come from this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Warning colours") {
                ThresholdRow(title: "Yellow above", value: $settings.elevatedAt, level: .elevated)
                ThresholdRow(title: "Orange above", value: $settings.highAt, level: .high)
                ThresholdRow(title: "Red above", value: $settings.criticalAt, level: .critical)

                HStack {
                    ThresholdPreview(thresholds: settings.thresholds)
                    Spacer()
                    Button("Reset") { settings.resetThresholds() }
                        .controlSize(.small)
                }
            }

            if LoginItem.isSupported {
                Section("Startup") {
                    Toggle("Start at login", isOn: Binding(
                        get: { LoginItem.isEnabled },
                        set: { _ = LoginItem.setEnabled($0) }
                    ))
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 560)
    }
}

private struct ThresholdRow: View {
    let title: String
    @Binding var value: Double
    let level: UsageLevel

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(level.color).frame(width: 9, height: 9)
            Text(title)
            Spacer()
            Slider(value: $value, in: 0...100, step: 5).frame(width: 160)
            Text("\(Int(value))%")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
    }
}

/// Shows the scale as it will actually look, including any correction
/// the model makes to out-of-order values.
private struct ThresholdPreview: View {
    let thresholds: LevelThresholds

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(stride(from: 0, to: 100, by: 2)), id: \.self) { pct in
                Rectangle()
                    .fill(thresholds.level(for: Double(pct)).color)
                    .frame(width: 5, height: 10)
            }
        }
        .clipShape(Capsule())
    }
}

/// Owns the settings window. A menu bar app has no windows by default, so one
/// is made on demand and the app is brought forward to show it.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: AppSettings) {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            w.title = "LLM Usage Monitor Settings"
            w.contentViewController = NSHostingController(rootView: SettingsView(settings: settings))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
