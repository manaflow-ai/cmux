import Foundation

/// Row order within a section.
public enum WorkspaceListSort: String, CaseIterable, Codable, Hashable, Sendable {
    /// The Mac's own order (its sidebar).
    case ownerOrder
    case recentActivity
    case name
}
