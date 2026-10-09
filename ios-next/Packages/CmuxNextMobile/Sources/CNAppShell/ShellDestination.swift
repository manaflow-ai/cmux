#if os(iOS)
import CNDesign
import CNSettingsUI
import CNTransport
import SwiftUI

/// The top-level destinations both shells offer.
enum ShellDestination: String, CaseIterable, Hashable, Sendable {
    case home, agents, terminals, browser, settings

    var title: String {
        switch self {
        case .home: "Home"
        case .agents: "Agents"
        case .terminals: "Terminals"
        case .browser: "Browser"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "bubble.left.and.bubble.right"
        case .agents: "sparkles"
        case .terminals: "apple.terminal"
        case .browser: "safari"
        case .settings: "gearshape"
        }
    }
}

/// Connection status capsule: a dot plus `Direct · 12 ms`.
struct ConnectionPill: View {
    let state: HostConnectionState

    var body: some View {
        let summary = ConnectionSummary(state)
        HStack(spacing: 6) {
            Circle().fill(summary.tone.color).frame(width: 7, height: 7)
            Text(summary.compact)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.cn(\.textSecondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(summary.compact)")
        .accessibilityIdentifier("shell.connectionPill")
    }
}
#endif
