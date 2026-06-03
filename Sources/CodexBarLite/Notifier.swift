import Foundation
import UserNotifications

/// Local notifications for limit events:
///  - when a window hits its limit ("limit reached")
///  - a punctual reminder scheduled for the moment the window resets
///
/// The reset reminder is scheduled with the system, so it fires at the reset
/// time even if the app isn't actively polling (or is relaunched) at that moment.
@MainActor
final class Notifier {
    /// A window with <= this percent remaining counts as "at the limit".
    private static let depletedThreshold = 0.5

    /// nil when running unbundled (e.g. `swift run`) — UNUserNotificationCenter
    /// requires a real .app bundle, so notifications are simply disabled then.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    private var authorized = false

    /// Remembers whether each window was depleted on the previous poll, so we
    /// only notify on the transition into the depleted state.
    private var depleted: [String: Bool] = [:]

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Call on every refresh with the latest window value (or nil if unavailable).
    func process(provider: ProviderID, kind: WindowKind, window: UsageWindow?) {
        guard let window else { return }
        let key = "\(provider.rawValue).\(kind.rawValue)"
        let isDepleted = window.remainingPercent <= Self.depletedThreshold
        let wasDepleted = depleted[key] ?? false
        depleted[key] = isDepleted

        guard isDepleted != wasDepleted else { return }

        if isDepleted {
            postReached(provider: provider, kind: kind)
            scheduleReset(provider: provider, kind: kind, at: window.resetsAt, key: key)
        } else {
            // Limit reset (early or natural): the scheduled reminder is no
            // longer valid because the limit is already reset. Cancel it and
            // post the "limit reset" notification immediately so the user
            // is alerted now, not at the stale scheduled time.
            center?.removePendingNotificationRequests(withIdentifiers: [key])
            postReset(provider: provider, kind: kind)
        }
    }

    // MARK: - Posting

    private func postReached(provider: ProviderID, kind: WindowKind) {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) \(kind.shortLabel) limit reached"
        content.body = "You've hit your \(kind.label) limit. You'll be reminded when it resets."
        content.sound = .default
        deliver(content, identifier: "\(provider.rawValue).\(kind.rawValue).reached")
    }

    private func postReset(provider: ProviderID, kind: WindowKind) {
        let prefix = "\(provider.rawValue).\(kind.rawValue)"
        let identifier = "\(prefix).reset"
        // Within this window we treat any reset banner (scheduled or
        // immediate) as the same event — covers the natural-reset race where
        // the scheduled notification fires moments before the poll that would
        // also post an immediate. Anything older belongs to a previous cycle
        // and is a different event.
        let dedupWindow: TimeInterval = 5 * 60
        center?.getDeliveredNotifications { [weak self] delivered in
            Task { @MainActor in
                guard let self else { return }
                let recentlyDelivered = delivered.contains { notification in
                    let id = notification.request.identifier
                    guard id == prefix || id == identifier else { return false }
                    return notification.date.timeIntervalSinceNow > -dedupWindow
                }
                guard !recentlyDelivered else { return }

                let content = UNMutableNotificationContent()
                content.title = "\(provider.displayName) \(kind.shortLabel) limit reset"
                content.body = "Your \(kind.label) limit just reset — you're good to go."
                content.sound = .default
                self.deliver(content, identifier: identifier)
            }
        }
    }

    private func scheduleReset(provider: ProviderID, kind: WindowKind, at date: Date?, key: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [key])
        guard let date, date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(provider.displayName) \(kind.shortLabel) limit reset"
        content.body = "Your \(kind.label) limit just reset — you're good to go."
        content.sound = .default

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: key, content: content, trigger: trigger)
        center?.add(request)
    }

    private func deliver(_ content: UNMutableNotificationContent, identifier: String) {
        guard authorized else { return }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center?.add(request)
    }
}

private extension WindowKind {
    var label: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "weekly"
        }
    }
}
