import Foundation

/// The workspace changes a host's owner accepts, from capability
/// negotiation. Screens offer only these.
public struct WorkspaceCapabilities: OptionSet, Hashable, Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let create = WorkspaceCapabilities(rawValue: 1 << 0)
    public static let rename = WorkspaceCapabilities(rawValue: 1 << 1)
    public static let close = WorkspaceCapabilities(rawValue: 1 << 2)
    public static let markRead = WorkspaceCapabilities(rawValue: 1 << 3)
    /// The host sends preview lines.
    public static let preview = WorkspaceCapabilities(rawValue: 1 << 4)
    /// Drag reorder and Move to Group.
    public static let move = WorkspaceCapabilities(rawValue: 1 << 5)
    public static let renameGroup = WorkspaceCapabilities(rawValue: 1 << 6)
    /// Color and icon.
    public static let customize = WorkspaceCapabilities(rawValue: 1 << 7)

    public static let all: WorkspaceCapabilities = [.create, .rename, .close, .markRead, .preview, .move, .renameGroup, .customize]
}
