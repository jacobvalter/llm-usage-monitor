import Foundation
import ServiceManagement

/// "Start at login", backed by SMAppService.
/// Only works from a signed .app bundle, so it is hidden when run via `swift run`.
@MainActor
enum LoginItem {
    /// False when running as a bare executable, where registration cannot work.
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually reached, so the UI never shows a toggle that did not take.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard isSupported else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem: could not \(enabled ? "register" : "unregister"): \(error)")
        }
        return isEnabled
    }
}
