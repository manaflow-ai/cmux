import Foundation

/// How rows are sectioned.
public enum WorkspaceListGrouping: String, CaseIterable, Codable, Hashable, Sendable {
    /// One block per machine, split into Pinned, its groups, and the rest.
    case byMachine
    /// One list across machines.
    case flat
}
