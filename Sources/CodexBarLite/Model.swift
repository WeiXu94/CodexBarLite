import Foundation

/// The two subscriptions this app tracks. Nothing else.
enum ProviderID: String, CaseIterable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        }
    }
}

/// Which limit window a value belongs to.
enum WindowKind: String, Sendable, CaseIterable {
    case fiveHour
    case weekly

    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "Weekly"
        }
    }
}

/// A single rate-limit window (the 5h session limit or the weekly limit).
struct UsageWindow: Equatable, Sendable {
    /// 0...100, percent of the window already consumed.
    let usedPercent: Double
    /// When this window rolls over and the limit resets.
    let resetsAt: Date?

    /// 0...100, percent still available.
    var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }
}

/// A successful read of one provider's limits.
struct ProviderUsage: Equatable, Sendable {
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
    /// Plan name when the API exposes it (e.g. "Pro", "Max"). Purely cosmetic.
    let planName: String?

    func window(_ kind: WindowKind) -> UsageWindow? {
        switch kind {
        case .fiveHour: fiveHour
        case .weekly: weekly
        }
    }
}

/// The state of a single provider, as shown in the menu.
enum ProviderState: Sendable {
    case loading
    case success(ProviderUsage)
    case failure(String)

    var usage: ProviderUsage? {
        if case let .success(usage) = self { return usage }
        return nil
    }
}
