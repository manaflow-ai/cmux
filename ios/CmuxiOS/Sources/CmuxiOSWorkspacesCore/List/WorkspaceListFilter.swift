import Foundation

/// Which workspaces the list shows.
public enum WorkspaceListFilter: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case unread
    case needsInput
    case running
}
