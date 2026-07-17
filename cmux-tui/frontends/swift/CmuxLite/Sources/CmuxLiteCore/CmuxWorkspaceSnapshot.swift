import Foundation

/// An immutable workspace row and its ordered screens.
public struct CmuxWorkspaceSnapshot: Sendable, Equatable {
    /// The server-owned workspace identifier.
    public let id: UInt64

    /// The workspace display name.
    public let name: String

    /// The selected or active surface title shown below the workspace name.
    public let subtitle: String?

    /// Screens in server order.
    public let screens: [CmuxScreenSnapshot]

    /// Creates a workspace snapshot.
    /// - Parameters:
    ///   - id: The server-owned workspace identifier.
    ///   - name: The workspace display name.
    ///   - subtitle: The selected or active surface title, when available.
    ///   - screens: Screens in server order.
    public init(id: UInt64, name: String, subtitle: String?, screens: [CmuxScreenSnapshot]) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.screens = screens
    }
}
