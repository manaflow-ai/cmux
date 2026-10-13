#if os(iOS)
import CnxModel
import SwiftUI

/// Owns one `AgentChatStore` per agent tab so the chat, Home and Feed share
/// session state (answering in the Feed updates the open chat). Sources are
/// mocks until the acpmux link lands; swap `makeSource` then.
@MainActor
@Observable
public final class AgentSessionDirectory {
    public static let shared = AgentSessionDirectory()
    private var stores: [String: AgentChatStore] = [:]
    public var makeSource: (AgentSessionSummary) -> any AgentSessionSource = { summary in
        MockAgentSession(summary: summary, richFirstTurn: summary.harness == "claude")
    }

    public init() {}

    public func store(for summary: AgentSessionSummary) -> AgentChatStore {
        if let store = stores[summary.id] { return store }
        let store = AgentChatStore(source: makeSource(summary))
        stores[summary.id] = store
        return store
    }

    public func existingStore(id: String) -> AgentChatStore? { stores[id] }

    /// Forgets the tab's store; the next `store(for:)` builds one from
    /// `makeSource` again (the tab's session changed on the Mac).
    public func invalidate(id: String) { stores[id] = nil }

    public func store(workspace: Workspace, tab: WorkspaceTab, macName: String) -> AgentChatStore {
        store(for: AgentSessionSummary(
            id: tab.id, name: tab.subtitle ?? tab.title, harness: tab.harness ?? "claude", agentName: tab.title,
            cwd: workspace.directory, workspaceTitle: workspace.title, macName: macName, branch: workspace.branch
        ))
    }
}

/// A navigation value that opens an agent tab's chat.
public struct AgentChatDestination: Hashable, Sendable {
    public var workspaceID: String
    public var tabID: String

    public init(workspaceID: String, tabID: String) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

/// Resolves a destination against the app store and shows the chat.
public struct AgentChatDestinationView: View {
    let destination: AgentChatDestination
    @Environment(AppStore.self) private var appStore

    public init(destination: AgentChatDestination) {
        self.destination = destination
    }

    public var body: some View {
        if let workspace = appStore.workspaces.first(where: { $0.id == destination.workspaceID }),
           let tab = workspace.tabs.first(where: { $0.id == destination.tabID }) {
            let mac = appStore.teams.flatMap(\.macs).first { $0.id == workspace.macID }?.name ?? "Mac"
            AgentChatScreen(store: AgentSessionDirectory.shared.store(workspace: workspace, tab: tab, macName: mac))
                .onAppear { appStore.noteOpened(tabID: tab.id, in: workspace.id) }
        } else {
            ContentUnavailableView("Tab closed", systemImage: "sparkle", description: Text("This agent tab is no longer open."))
        }
    }
}

extension View {
    /// Registers `AgentChatDestination` on the enclosing NavigationStack.
    public func agentChatDestinations() -> some View {
        navigationDestination(for: AgentChatDestination.self) { AgentChatDestinationView(destination: $0) }
    }
}
#endif
