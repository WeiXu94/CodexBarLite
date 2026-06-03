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
    @ObservationIgnored private var resetTimer: Timer?
    @ObservationIgnored private var inFlight: Set<ProviderID> = []

    /// How often to poll in the background. Persisted in UserDefaults.
    static let defaultRefreshInterval: TimeInterval = 5 * 60

    /// User-configurable refresh interval (seconds). Backed by UserDefaults.
    var refreshInterval: TimeInterval = {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        return stored > 0 ? stored : 5 * 60
    }() {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: "refreshInterval")
            restartTimer()
        }
    }

    /// Predefined interval choices for the UI.
    static let refreshIntervalOptions: [(label: String, value: TimeInterval)] = [
        ("5 min", 300),
        ("10 min", 600),
        ("15 min", 900),
        ("20 min", 1200),
        ("30 min", 1800),
    ]

    var isRefreshing: Bool { !inFlight.isEmpty }

    func start() {
        notifier.requestAuthorization()
        refresh()
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(30, refreshInterval / 10)
        self.timer = timer
    }

    private func restartTimer() {
        startTimer()
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
        // Assign new dictionary to trigger @Observable mutation tracking.
        var newStates = states
        newStates[provider] = state
        states = newStates

        scheduleResetRefresh()
        
        guard case let .success(usage) = state else { return }
        for kind in WindowKind.allCases {
            notifier.process(provider: provider, kind: kind, window: usage.window(kind))
        }
    }

    /// Arm a one-shot refresh at the next window reset (+ a small buffer so the
    /// server has actually rolled over), so the ring updates the moment a limit
    /// resets instead of waiting for the next periodic poll or a popover open.
    /// Re-armed on every apply, so it always tracks the nearest upcoming reset.
    /// (A one-shot timer whose fire date passes during sleep also fires on wake.)
    private func scheduleResetRefresh() {
        resetTimer?.invalidate()
        let resets = states.values
            .compactMap(\.usage)
            .flatMap { usage in WindowKind.allCases.compactMap { usage.window($0)?.resetsAt } }
        guard let next = resets.filter({ $0 > Date() }).min() else { return }
        let interval = max(1, next.timeIntervalSinceNow + 15)
        resetTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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

}
