import Foundation
import CMUXMobileSyncCore
import Observation

public struct MobileWorkspacePreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var terminals: [MobileTerminalPreview]

    public init(id: ID, name: String, terminals: [MobileTerminalPreview]) {
        self.id = id
        self.name = name
        self.terminals = terminals
    }
}

public struct MobileTerminalPreview: Identifiable, Equatable, Sendable {
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    public var id: ID
    public var name: String
    public var snapshot: MobileTerminalGhosttySnapshot

    public init(id: ID, name: String, snapshot: MobileTerminalGhosttySnapshot) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
    }

    public init(id: ID, name: String, lines: [String]) {
        self.id = id
        self.name = name
        self.snapshot = PreviewMobileHost.snapshot(
            terminalID: id.rawValue,
            lines: lines
        )
    }

    public var lines: [String] {
        snapshot.renderedVisibleLines
    }
}

public enum MobileConnectionState: Equatable, Sendable {
    case disconnected
    case connected
}

public enum MobileShellPhase: Equatable, Sendable {
    case signIn
    case pairing
    case workspaces
}

@MainActor
@Observable
public final class CMUXMobileShellStore {
    public private(set) var isSignedIn: Bool
    public private(set) var connectionState: MobileConnectionState
    public private(set) var connectedHostName: String
    public var pairingCode: String
    public var workspaces: [MobileWorkspacePreview]
    public var selectedWorkspaceID: MobileWorkspacePreview.ID? {
        didSet {
            syncSelectedTerminalForWorkspace()
        }
    }
    public var selectedTerminalID: MobileTerminalPreview.ID?

    public var phase: MobileShellPhase {
        if !isSignedIn {
            return .signIn
        }
        if connectionState != .connected {
            return .pairing
        }
        return .workspaces
    }

    public var selectedWorkspace: MobileWorkspacePreview? {
        guard let selectedWorkspaceID else {
            return workspaces.first
        }
        return workspaces.first { $0.id == selectedWorkspaceID } ?? workspaces.first
    }

    public init(
        isSignedIn: Bool = false,
        connectionState: MobileConnectionState = .disconnected,
        connectedHostName: String = "",
        pairingCode: String = "",
        workspaces: [MobileWorkspacePreview] = []
    ) {
        self.isSignedIn = isSignedIn
        self.connectionState = connectionState
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.workspaces = workspaces
        self.selectedWorkspaceID = workspaces.first?.id
        self.selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public static func preview() -> CMUXMobileShellStore {
        CMUXMobileShellStore(workspaces: PreviewMobileHost.workspaces)
    }

    public func signIn() {
        isSignedIn = true
    }

    public func signOut() {
        isSignedIn = false
        connectionState = .disconnected
        connectedHostName = ""
        pairingCode = ""
        workspaces = PreviewMobileHost.workspaces
        selectedWorkspaceID = workspaces.first?.id
        selectedTerminalID = workspaces.first?.terminals.first?.id
    }

    public func connectPreviewHost() {
        guard !pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        connectedHostName = PreviewMobileHost.hostName
        connectionState = .connected
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }

    public func createWorkspace() {
        let nextIndex = workspaces.count + 1
        let workspace = MobileWorkspacePreview(
            id: .init(rawValue: "workspace-\(nextIndex)"),
            name: L10n.workspaceName(index: nextIndex),
            terminals: [
                MobileTerminalPreview(
                    id: .init(rawValue: "workspace-\(nextIndex)-terminal-1"),
                    name: L10n.terminalName(index: 1),
                    lines: [
                        "$ cmux mobile preview",
                        "workspace: Workspace \(nextIndex)",
                        "terminal: Terminal 1",
                    ]
                ),
            ]
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        selectedTerminalID = workspace.terminals.first?.id
    }

    public func createTerminal() {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspace?.id }) else {
            return
        }
        let terminalIndex = workspaces[workspaceIndex].terminals.count + 1
        let terminal = MobileTerminalPreview(
            id: .init(rawValue: "\(workspaces[workspaceIndex].id.rawValue)-terminal-\(terminalIndex)"),
            name: L10n.terminalName(index: terminalIndex),
            lines: [
                "$ cmux mobile preview",
                "workspace: \(workspaces[workspaceIndex].name)",
                "terminal: Terminal \(terminalIndex)",
            ]
        )
        workspaces[workspaceIndex].terminals.append(terminal)
        selectedTerminalID = terminal.id
    }

    public func selectTerminal(_ id: MobileTerminalPreview.ID?) {
        selectedTerminalID = id
    }

    private func syncSelectedTerminalForWorkspace() {
        guard let selectedWorkspace else {
            selectedTerminalID = nil
            return
        }
        if let selectedTerminalID,
           selectedWorkspace.terminals.contains(where: { $0.id == selectedTerminalID }) {
            return
        }
        selectedTerminalID = selectedWorkspace.terminals.first?.id
    }
}

enum PreviewMobileHost {
    static let hostName = "cmux-macbook"

    static let workspaces: [MobileWorkspacePreview] = [
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [
                MobileTerminalPreview(
                    id: "terminal-build",
                    name: "Build",
                    lines: [
                        "$ cmux ios status",
                        "Mobile Sync: enabled",
                        "Listener: stopped",
                        "Tailscale: available",
                    ]
                ),
                MobileTerminalPreview(
                    id: "terminal-agent",
                    name: "Agent",
                    lines: [
                        "$ git status --short",
                        "## feat-ios-minimal-shell",
                        "$ swift test",
                        "Test Suite passed",
                    ]
                ),
                MobileTerminalPreview(
                    id: "terminal-tui",
                    name: "TUI",
                    snapshot: snapshot(
                        terminalID: "terminal-tui",
                        lines: [
                            "LAZYGIT",
                            "files branches log",
                            "main feat-ios clean",
                            "q quit",
                        ],
                        activeScreen: .alternate,
                        modes: MobileTerminalGhosttyModes(
                            bracketedPaste: true,
                            applicationCursorKeys: true,
                            applicationKeypad: true,
                            mouseTracking: true,
                            cursorVisible: false
                        ),
                        streamOffset: 128
                    )
                ),
            ]
        ),
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: [
                MobileTerminalPreview(
                    id: "terminal-notes",
                    name: "Notes",
                    lines: [
                        "$ rg \"Tailscale\" docs",
                        "docs/mobile-sync.md:Pairing uses Tailscale only.",
                    ]
                ),
            ]
        ),
    ]

    static func snapshot(
        terminalID: String,
        lines: [String],
        scrollbackLines: [String] = [],
        activeScreen: MobileTerminalGhosttyScreen = .primary,
        modes: MobileTerminalGhosttyModes = MobileTerminalGhosttyModes(),
        streamOffset: UInt64 = 0
    ) -> MobileTerminalGhosttySnapshot {
        do {
            return try MobileTerminalGhosttySnapshot.fixture(
                terminalID: terminalID,
                columns: 48,
                rows: 6,
                scrollbackLines: scrollbackLines,
                visibleLines: lines,
                activeScreen: activeScreen,
                modes: modes,
                streamOffset: streamOffset
            )
        } catch {
            preconditionFailure("Invalid mobile terminal preview snapshot: \(error)")
        }
    }
}
