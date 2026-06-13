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
        statusItem.button?.image = MenuBarIcon.image(states: monitor.states)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        popover.behavior = .transient
        let content = ContentView(monitor: monitor) { [weak self] height in
            self?.resizePopover(toContentHeight: height)
        }
        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: popoverWidth, height: 200)

        observeIcon()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
        monitor.start()
    }

    /// The menu-bar thickness can change when displays change (e.g. moving to a
    /// notched built-in screen). Rebuild the icon so it re-reads the new thickness.
    @objc private func screenParametersChanged() {
        statusItem.button?.image = MenuBarIcon.image(states: monitor.states)
    }

    /// Timers are suspended during sleep, so after waking the data is likely
    /// stale (a limit may have reset while asleep). Re-fetch so the ring catches
    /// up immediately rather than at the next periodic poll.
    @objc private func systemDidWake() {
        monitor.refresh()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            monitor.refresh(interactive: true)
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

    /// Keep the menu-bar glyph in sync with provider states.
    private func observeIcon() {
        withObservationTracking {
            statusItem.button?.image = MenuBarIcon.image(states: monitor.states)
        } onChange: {
            Task { @MainActor [weak self] in self?.observeIcon() }
        }
    }
}
