import AppKit
import Combine
import SwiftUI
import UsageCore

/// Menu bar shell. AppKit owns the status item; the popover content is SwiftUI.
/// Built as a plain executable, so there is no Info.plist and no app bundle yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = UsageViewModel()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(model: model) { NSApp.terminate(nil) }
        )

        // Keep the menu bar title in step with the numbers.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.updateTitle() }
            }
            .store(in: &cancellables)

        updateTitle()
        model.start()
    }

    /// Menu bar shows both windows: a dot for the worst level, then "5h n%  7d n%".
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let five = model.worstFiveHour
        let weekly = model.worstWeekly

        button.image = Self.badge(for: model.headline?.level)

        guard five != nil || weekly != nil else {
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "LLM Usage — no data yet"
            return
        }

        let title = NSMutableAttributedString()
        if let five { title.append(Self.segment(label: "5h", window: five, leadingSpace: true)) }
        if let weekly { title.append(Self.segment(label: "7d", window: weekly, leadingSpace: five != nil)) }
        button.attributedTitle = title

        button.toolTip = [five.map { "5-hour: \(Int($0.usedPercent))%" },
                          weekly.map { "Weekly: \(Int($0.usedPercent))%" }]
            .compactMap { $0 }
            .joined(separator: "   ")
    }

    /// One "5h 12%" run: dim label, percent in the level colour.
    private static func segment(label: String, window: QuotaWindow, leadingSpace: Bool) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "\(leadingSpace ? "  " : " ")\(label) ",
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        ))
        out.append(NSAttributedString(
            string: "\(Int(window.usedPercent))%",
            attributes: [.font: font, .foregroundColor: Self.nsColor(for: window.level)]
        ))
        return out
    }

    private static func nsColor(for level: UsageLevel) -> NSColor {
        switch level {
        case .normal:   return NSColor(red: 0.30, green: 0.78, blue: 0.47, alpha: 1)
        case .elevated: return NSColor(red: 0.95, green: 0.80, blue: 0.25, alpha: 1)
        case .high:     return NSColor(red: 0.96, green: 0.58, blue: 0.20, alpha: 1)
        case .critical: return NSColor(red: 0.93, green: 0.33, blue: 0.31, alpha: 1)
        }
    }

    /// Filled dot in the level colour. Not a template image, so the colour survives.
    private static func badge(for level: UsageLevel?) -> NSImage {
        let color = level.map(Self.nsColor(for:)) ?? NSColor.tertiaryLabelColor
        let size = NSSize(width: 9, height: 9)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await model.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

@main
enum LLMUsageMonitorApp {
    /// Held strongly: NSApplication does not retain its delegate.
    @MainActor static let delegate = AppDelegate()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Menu bar only: no Dock icon, no main window.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
