import Foundation

public struct CmuxMobileHomeSnapshot: Equatable, Sendable {
    public var auth: CmuxAuthSnapshot
    public var nodes: [CmuxHiveNode]
    public var workspaces: [CmuxMobileWorkspace]

    public init(
        auth: CmuxAuthSnapshot,
        nodes: [CmuxHiveNode],
        workspaces: [CmuxMobileWorkspace]
    ) {
        self.auth = auth
        self.nodes = nodes
        self.workspaces = workspaces
    }

    public static let fixture = CmuxMobileHomeSnapshot(
        auth: CmuxAuthSnapshot(
            state: .signedIn,
            displayName: "Lawrence",
            primaryEmail: "lawrence@example.com"
        ),
        nodes: [
            CmuxHiveNode(
                id: "node-macbook",
                name: "MacBook Pro",
                status: .online,
                route: "iroh://macbook"
            ),
            CmuxHiveNode(
                id: "node-macmini",
                name: "Mac mini",
                status: .connecting,
                route: "rivet://hive/macmini"
            ),
        ],
        workspaces: [
            CmuxMobileWorkspace(
                id: "workspace-ios-port",
                title: "iOS port",
                nodeID: "node-macbook",
                lastMessage: "cmx and iOS are sharing terminal 2",
                lastActivityLabel: "now",
                unreadCount: 2,
                spaces: [
                    CmuxMobileSpace(
                        id: "space-main",
                        title: "main",
                        panes: [
                            CmuxMobilePane(
                                id: "pane-one",
                                title: "pane 1",
                                terminals: [
                                    CmuxMobileTerminal(
                                        id: "terminal-shell",
                                        title: "shell",
                                        size: CmuxTerminalSize(cols: 66, rows: 18),
                                        rows: [
                                            "$ cargo test",
                                            "test real_cmx_tui_process_syncs_with_ios_shaped_client ... ok",
                                            "CMX_SENTINEL_TO_SIM",
                                            "SIM_SENTINEL_FROM_IOS",
                                        ]
                                    ),
                                    CmuxMobileTerminal(
                                        id: "terminal-daemon",
                                        title: "comeup daemon",
                                        size: CmuxTerminalSize(cols: 66, rows: 18),
                                        rows: [
                                            "workspace id=2 title=Sim Build",
                                            "terminal id=2 size=66x18",
                                            "latency 12ms",
                                        ]
                                    ),
                                ]
                            ),
                        ]
                    ),
                    CmuxMobileSpace(
                        id: "space-review",
                        title: "review",
                        panes: [
                            CmuxMobilePane(
                                id: "pane-review",
                                title: "pane 1",
                                terminals: [
                                    CmuxMobileTerminal(
                                        id: "terminal-pr",
                                        title: "PR checks",
                                        size: CmuxTerminalSize(cols: 80, rows: 24),
                                        rows: [
                                            "build-ghosttykit passed",
                                            "web-typecheck passed",
                                            "macOS checks pending",
                                        ]
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            ),
            CmuxMobileWorkspace(
                id: "workspace-auth",
                title: "Auth and hive",
                nodeID: "node-macmini",
                lastMessage: "Rivet discovery should attach signed-in nodes",
                lastActivityLabel: "2m",
                unreadCount: 0,
                spaces: [
                    CmuxMobileSpace(
                        id: "space-auth",
                        title: "auth",
                        panes: [
                            CmuxMobilePane(
                                id: "pane-auth",
                                title: "pane 1",
                                terminals: [
                                    CmuxMobileTerminal(
                                        id: "terminal-auth-plan",
                                        title: "Stack Auth",
                                        size: CmuxTerminalSize(cols: 80, rows: 24),
                                        rows: [
                                            "signed_in=true",
                                            "rivet_actor=hive-node-registry",
                                            "iroh_auth=required",
                                        ]
                                    ),
                                ]
                            ),
                        ]
                    ),
                ]
            ),
        ]
    )

    public func workspace(id: String?) -> CmuxMobileWorkspace? {
        if let id, let workspace = workspaces.first(where: { $0.id == id }) {
            return workspace
        }
        return workspaces.first
    }

    public func node(id: String) -> CmuxHiveNode? {
        nodes.first { $0.id == id }
    }
}

public struct CmuxAuthSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case signedOut
        case restoring
        case signedIn
    }

    public var state: State
    public var displayName: String
    public var primaryEmail: String

    public init(state: State, displayName: String, primaryEmail: String) {
        self.state = state
        self.displayName = displayName
        self.primaryEmail = primaryEmail
    }
}

public struct CmuxHiveNode: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case online
        case connecting
        case offline
    }

    public var id: String
    public var name: String
    public var status: Status
    public var route: String

    public init(id: String, name: String, status: Status, route: String) {
        self.id = id
        self.name = name
        self.status = status
        self.route = route
    }
}

public struct CmuxMobileWorkspace: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var nodeID: String
    public var lastMessage: String
    public var lastActivityLabel: String
    public var unreadCount: Int
    public var spaces: [CmuxMobileSpace]

    public init(
        id: String,
        title: String,
        nodeID: String,
        lastMessage: String,
        lastActivityLabel: String,
        unreadCount: Int,
        spaces: [CmuxMobileSpace]
    ) {
        self.id = id
        self.title = title
        self.nodeID = nodeID
        self.lastMessage = lastMessage
        self.lastActivityLabel = lastActivityLabel
        self.unreadCount = unreadCount
        self.spaces = spaces
    }

    public var terminalTree: [CmuxTerminalTreeRow] {
        spaces.flatMap { space in
            space.panes.flatMap { pane in
                pane.terminals.map { terminal in
                    CmuxTerminalTreeRow(space: space, pane: pane, terminal: terminal)
                }
            }
        }
    }

    public func terminal(id: String?) -> CmuxMobileTerminal? {
        if let id, let terminal = terminalTree.map(\.terminal).first(where: { $0.id == id }) {
            return terminal
        }
        return terminalTree.first?.terminal
    }

    public var terminalCount: Int {
        terminalTree.count
    }
}

public struct CmuxMobileSpace: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var panes: [CmuxMobilePane]

    public init(id: String, title: String, panes: [CmuxMobilePane]) {
        self.id = id
        self.title = title
        self.panes = panes
    }
}

public struct CmuxMobilePane: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var terminals: [CmuxMobileTerminal]

    public init(id: String, title: String, terminals: [CmuxMobileTerminal]) {
        self.id = id
        self.title = title
        self.terminals = terminals
    }
}

public struct CmuxMobileTerminal: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var size: CmuxTerminalSize
    public var rows: [String]

    public init(id: String, title: String, size: CmuxTerminalSize, rows: [String]) {
        self.id = id
        self.title = title
        self.size = size
        self.rows = rows
    }
}

public struct CmuxTerminalSize: Equatable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public struct CmuxTerminalTreeRow: Identifiable, Equatable, Sendable {
    public var space: CmuxMobileSpace
    public var pane: CmuxMobilePane
    public var terminal: CmuxMobileTerminal

    public var id: String {
        "\(space.id)/\(pane.id)/\(terminal.id)"
    }
}
