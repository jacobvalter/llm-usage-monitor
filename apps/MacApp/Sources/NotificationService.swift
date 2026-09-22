import AppKit
import Foundation
import UsageCore
import UserNotifications

/// Sends the macOS notifications and remembers what has already been said.
///
/// Only works from a signed .app bundle. Run as a bare executable, the
/// notification centre has no bundle to attribute alerts to, so this stays off.
@MainActor
final class NotificationService {
    private let defaults: UserDefaults
    private let stateKey = "alertState"
    private var state: [String: AlertState]
    private var authorized = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode([String: AlertState].self, from: data) {
            state = decoded
        } else {
            state = [:]
        }
    }

    /// False when running outside an .app, where UNUserNotificationCenter would trap.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// How alerts are actually getting out.
    enum Delivery {
        case notificationCenter   // properly signed: alerts come from this app
        case appleScript          // ad-hoc signed: alerts come via osascript
        case none
    }

    private(set) var delivery: Delivery = .none

    /// Never blocks for long. The system does not always answer this for an
    /// ad-hoc signed app, and polling must not wait on it.
    func requestAuthorizationIfNeeded() async {
        guard Self.isSupported else {
            delivery = .none
            return
        }

        let settled = await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        if let settled {
            authorized = settled
            delivery = settled ? .notificationCenter : .appleScript
        } else {
            NSLog("NotificationService: authorization did not answer; using AppleScript fallback")
            authorized = false
            delivery = .appleScript
        }
    }

    /// Works out what is newly worth saying, then says it.
    func evaluate(snapshots: [QuotaSnapshot], thresholds: LevelThresholds, minimumLevel: UsageLevel?) {
        guard let minimumLevel else {
            // Notifications are off, but keep tracking so turning them back on
            // does not fire a burst about windows that were already high.
            _ = UsageAlertEvaluator(minimumLevel: .critical)
                .alerts(for: snapshots, thresholds: thresholds, state: &state)
            persist()
            return
        }

        let alerts = UsageAlertEvaluator(minimumLevel: minimumLevel)
            .alerts(for: snapshots, thresholds: thresholds, state: &state)
        persist()

        for alert in alerts { deliver(alert) }
    }

    private func deliver(_ alert: UsageAlert) {
        switch delivery {
        case .notificationCenter:
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.level == .critical ? .default : nil
            // One pending notification per window; a newer one replaces the old.
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
            ) { error in
                if let error { NSLog("NotificationService: deliver failed: \(error)") }
            }
        case .appleScript:
            Self.deliverViaAppleScript(alert)
        case .none:
            break
        }
    }

    /// Works without a Developer ID signature. The alert is attributed to the
    /// script runner rather than to this app, which is the cost of the fallback.
    private static func deliverViaAppleScript(_ alert: UsageAlert) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                     .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(alert.body)) "
            + "with title \(quoted(alert.title))"
            + (alert.level == .critical ? " sound name \"Submarine\"" : "")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            NSLog("NotificationService: osascript failed: \(error)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }
}

/// What the user picked in Settings.
enum AlertPreference: String, CaseIterable, Identifiable {
    case off
    case high
    case critical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Never"
        case .high: return "At orange"
        case .critical: return "At red only"
        }
    }

    var minimumLevel: UsageLevel? {
        switch self {
        case .off: return nil
        case .high: return .high
        case .critical: return .critical
        }
    }
}
