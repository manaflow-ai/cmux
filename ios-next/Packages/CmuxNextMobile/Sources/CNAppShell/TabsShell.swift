#if os(iOS)
import CNDesign
import CNSettingsUI
import CNTransport
import SwiftUI

/// Native tab bar shell: Home, Agents, Terminals, Browser, Settings, with the
/// iOS 26 minimize-on-scroll tab bar and a bottom accessory for status.
struct TabsShell: View {
    let model: AppModel
    @State private var selection: ShellDestination = .initial

    var body: some View {
        let roots = ModuleRoots(model: model)
        TabView(selection: $selection) {
            Tab(ShellDestination.home.title, systemImage: ShellDestination.home.symbol, value: .home) {
                roots.conversations().cnStatusBarStyleSuppressed(selection != .home)
            }
            Tab(ShellDestination.agents.title, systemImage: ShellDestination.agents.symbol, value: .agents) {
                roots.agents().cnStatusBarStyleSuppressed(selection != .agents)
            }
            .badge(model.shellData.attentionCount)
            Tab(ShellDestination.terminals.title, systemImage: ShellDestination.terminals.symbol, value: .terminals) {
                roots.terminals().cnStatusBarStyleSuppressed(selection != .terminals)
            }
            Tab(ShellDestination.browser.title, systemImage: ShellDestination.browser.symbol, value: .browser) {
                roots.browser().cnStatusBarStyleSuppressed(selection != .browser)
            }
            Tab(ShellDestination.settings.title, systemImage: ShellDestination.settings.symbol, value: .settings) {
                roots.settings().cnStatusBarStyleSuppressed(selection != .settings)
            }
        }
        .environment(\.cnHostedInTabBar, true)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            StatusAccessory(model: model) { selection = .agents }
        }
        .modifier(ShellEnvironment(model: model))
        .task { await model.shellData.run() }
        .task(id: ShellDataKey(generation: model.connection.generation, connected: model.connection.state.isConnected)) {
            await model.shellData.reloadIfNeeded()
        }
    }
}

/// Bottom accessory: running agents plus the connection path.
struct StatusAccessory: View {
    let model: AppModel
    let openAgents: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let summary = ConnectionSummary(model.connection.state)
        let running = model.shellData.runningSessions.count
        let waiting = model.shellData.waitingSessions.count
        let unread = model.shellData.unreadSessions.count
        Button(action: openAgents) {
            HStack(spacing: 8) {
                Circle().fill(summary.tone.color).frame(width: 7, height: 7)
                if placement == .inline {
                    Text(running > 0 ? "\(running) running" : summary.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                } else {
                    // Hierarchical styles follow the glass's own light/dark
                    // adaptation over the page behind it; the app's palette
                    // tokens follow the app scheme and went white-on-light.
                    Text(agentText(running: running, waiting: waiting, unread: unread))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(summary.compact)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("shell.connectionPill")
    }

    private func agentText(running: Int, waiting: Int, unread: Int) -> String {
        switch (running, waiting) {
        case (0, 0) where unread > 0: unread == 1 ? "1 unread agent" : "\(unread) unread agents"
        case (0, 0): model.connection.hostInfo?.hostName ?? model.selectedHost?.name ?? "No agents running"
        case (_, 0): running == 1 ? "1 agent running" : "\(running) agents running"
        case (0, _): waiting == 1 ? "1 agent needs you" : "\(waiting) agents need you"
        default: "\(running) running · \(waiting) need you"
        }
    }
}
#endif
