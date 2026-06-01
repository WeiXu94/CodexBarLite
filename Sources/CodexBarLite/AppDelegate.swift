import AppKit
import Observation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = UsageMonitor()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let popoverWidth: CGFloat = 290

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = MenuBarIcon.image(remaining: nil)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        let content = ContentView(monitor: monitor) { [weak self] height in
            self?.resizePopover(toContentHeight: height)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: popoverWidth, height: 200)

        observeIcon()
        monitor.start()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Size the popover to its content, but never taller than the screen below the
    /// menu bar (otherwise it clips behind it) — the content scrolls when clamped.
    private func resizePopover(toContentHeight height: CGFloat) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let maxHeight = (screen?.visibleFrame.height ?? 800) - 12
        let target = max(1, min(height, maxHeight))
        if abs(popover.contentSize.height - target) > 0.5 {
            popover.contentSize = NSSize(width: popoverWidth, height: target)
        }
    }

    /// Keep the menu-bar glyph in sync with the most-constrained window.
    private func observeIcon() {
        withObservationTracking {
            statusItem.button?.image = MenuBarIcon.image(remaining: monitor.worstRemainingFraction)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeIcon() }
        }
    }
}
