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

    /// DEBUG: `CMUX_NEXT_START_DESTINATION=<home|agents|terminals|browser|settings>`
    /// opens the shell on that destination (automated verification).
    static var initial: ShellDestination {
        #if DEBUG
        ProcessInfo.processInfo.environment["CMUX_NEXT_START_DESTINATION"].flatMap(ShellDestination.init(rawValue:)) ?? .home
        #else
        .home
        #endif
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
            // Connected: path and RTT; otherwise just the state (the error
            // detail lives in Settings > Connection).
            Text(state.isConnected ? summary.compact : summary.title)
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.cn(\.textSecondary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        // Stay clear of the leading/trailing bar buttons.
        .frame(maxWidth: 240)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection: \(summary.compact)")
        .accessibilityIdentifier("shell.connectionPill")
    }
}
#endif
