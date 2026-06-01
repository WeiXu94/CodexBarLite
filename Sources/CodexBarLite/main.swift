import AppKit

// Startup runs on the main thread; adopt main-actor isolation for the AppKit setup.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run() // Blocks for the app's lifetime, keeping `delegate` alive.
}
