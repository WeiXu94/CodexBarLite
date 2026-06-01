import Foundation
import Observation

/// Owns the live state for both providers, refreshes them on a timer, and feeds
/// limit transitions to the notifier. Observed by the SwiftUI menu.
///
/// Each provider refreshes independently, so a slow or blocked provider (e.g. a
/// pending Claude Keychain prompt) never holds up the other one.
@MainActor
@Observable
final class UsageMonitor {
    /// Current state per provider (loading / success / failure).
    private(set) var states: [ProviderID: ProviderState] = [
        .codex: .loading,
        .claude: .loading,
    ]
    /// Last time any refresh completed.
    private(set) var lastUpdated: Date?

    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight: Set<ProviderID> = []

    /// How often to poll in the background.
    static let refreshInterval: TimeInterval = 5 * 60

    var isRefreshing: Bool { !inFlight.isEmpty }

    func start() {
        notifier.requestAuthorization()
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        self.timer = timer
    }

    func refresh() {
        for provider in ProviderID.allCases {
            refresh(provider)
        }
    }

    private func refresh(_ provider: ProviderID) {
        guard !inFlight.contains(provider) else { return }
        inFlight.insert(provider)
        Task { [weak self] in
            let state = await Self.load { try await Self.fetch(provider) }
            guard let self else { return }
            self.apply(provider: provider, state: state)
            self.inFlight.remove(provider)
            self.lastUpdated = Date()
        }
    }

    private func apply(provider: ProviderID, state: ProviderState) {
        states[provider] = state
        guard case let .success(usage) = state else { return }
        for kind in WindowKind.allCases {
            notifier.process(provider: provider, kind: kind, window: usage.window(kind))
        }
    }

    private static func fetch(_ provider: ProviderID) async throws -> ProviderUsage {
        switch provider {
        case .codex: try await CodexClient.fetch()
        case .claude: try await ClaudeClient.fetch()
        }
    }

    private static func load(_ fetch: () async throws -> ProviderUsage) async -> ProviderState {
        do {
            return .success(try await fetch())
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Worst (lowest) remaining fraction across all four windows, 0...1, for the
    /// menu-bar icon. `nil` when nothing has loaded yet.
    var worstRemainingFraction: Double? {
        let remainings = states.values
            .compactMap(\.usage)
            .flatMap { [$0.fiveHour, $0.weekly] }
            .compactMap { $0?.remainingPercent }
        guard let min = remainings.min() else { return nil }
        return min / 100.0
    }
}
