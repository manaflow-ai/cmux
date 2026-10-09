import Foundation

/// Where a moved workspace is filed: its current group, no group, or the
/// group with this id on the same host.
public enum WorkspaceGroupPlacement: Hashable, Sendable {
    case keep
    case ungrouped
    case group(String)
}
