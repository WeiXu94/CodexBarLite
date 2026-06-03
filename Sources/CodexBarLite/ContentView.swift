import SwiftUI

/// The single menu page: one card per sub, each showing the 5h and weekly
/// limits with how much is left and when they reset.
///
/// Reports its natural content height via `onHeightChange`; the AppDelegate
/// clamps that to the screen and sets the popover size, so the popover sizes to
/// content but never grows past the screen (it scrolls instead).
struct ContentView: View {
    @Bindable var monitor: UsageMonitor
    let onHeightChange: (CGFloat) -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                ForEach(ProviderID.allCases, id: \.self) { provider in
                    ProviderCard(provider: provider, state: monitor.states[provider] ?? .loading)
                }

                Divider()
                footer
            }
            .padding(14)
            .background(GeometryReader { geo in
                Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                    onHeightChange(height)
                }
            })
        }
    }

    private var header: some View {
        HStack {
            Text("CodexBar Lite").font(.headline)
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(monitor.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .disabled(monitor.isRefreshing)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.callout)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.set(newValue)
                    launchAtLogin = LaunchAtLogin.isEnabled
                }

            Picker("Refresh every", selection: Binding(
                get: { monitor.refreshInterval },
                set: { monitor.refreshInterval = $0 }
            )) {
                ForEach(UsageMonitor.refreshIntervalOptions, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)

            HStack {
                if let updated = monitor.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
    }
}

private struct ProviderCard: View {
    let provider: ProviderID
    let state: ProviderState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(provider.displayName).font(.subheadline.weight(.semibold))
                if case let .success(usage) = state, let plan = usage.planName {
                    Text(plan)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }

            switch state {
            case .loading:
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            case let .failure(message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case let .success(usage):
                WindowRow(kind: .fiveHour, window: usage.fiveHour)
                WindowRow(kind: .weekly, window: usage.weekly)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WindowRow: View {
    let kind: WindowKind
    let window: UsageWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kind.shortLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let window {
                    Text("\(Int(window.remainingPercent.rounded()))% left")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                } else {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: (window?.remainingPercent ?? 0) / 100)
                .progressViewStyle(.linear)
                .tint(color)
            if let reset = window?.resetsAt {
                Text("resets \(Self.resetText(reset))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        guard let remaining = window?.remainingPercent else { return .secondary }
        switch remaining {
        case ..<10: return .red
        case ..<25: return .orange
        default: return .green
        }
    }

    private static func resetText(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "now" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "in \(days)d \(hours % 24)h"
        }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        return "in \(minutes)m"
    }
}
