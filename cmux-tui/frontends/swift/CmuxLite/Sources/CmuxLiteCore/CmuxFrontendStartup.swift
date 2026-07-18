import Foundation

/// Summarizes cmux-lite's local navigation and visible byte attachments.
public struct CmuxFrontendStartup: Sendable, Equatable {
    /// Workspaces and screens in server order.
    public let workspaces: [CmuxWorkspaceSnapshot]

    /// The workspace selected by this client without changing server selection.
    public let selectedWorkspace: UInt64

    /// The screen selected by this client without changing server selection.
    public let selectedScreen: UInt64

    /// The locally active or first attached PTY surface identifier.
    public let surface: UInt64

    /// Every PTY surface attached for the selected visible screen.
    public let surfaces: [UInt64]

    /// The negotiated server protocol version.
    public let protocolVersion: UInt32

    /// The server session name rendered in the status badge.
    public let sessionName: String

    /// Creates a frontend snapshot.
    /// - Parameters:
    ///   - workspaces: Workspaces and screens in server order.
    ///   - selectedWorkspace: The locally selected workspace identifier.
    ///   - selectedScreen: The locally selected screen identifier.
    ///   - surface: The active or first selected PTY surface.
    ///   - surfaces: Every attached visible PTY surface.
    ///   - protocolVersion: The identified server protocol.
    ///   - sessionName: The identified server session name.
    public init(
        workspaces: [CmuxWorkspaceSnapshot],
        selectedWorkspace: UInt64,
        selectedScreen: UInt64,
        surface: UInt64,
        surfaces: [UInt64]? = nil,
        protocolVersion: UInt32,
        sessionName: String
    ) {
        self.workspaces = workspaces
        self.selectedWorkspace = selectedWorkspace
        self.selectedScreen = selectedScreen
        self.surface = surface
        self.surfaces = surfaces ?? [surface]
        self.protocolVersion = protocolVersion
        self.sessionName = sessionName
    }
}
