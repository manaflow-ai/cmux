import Foundation

/// The aggregate agent state of a workspace.
public enum WorkspaceStatus: String, Hashable, Sendable, CaseIterable {
    case idle
    case running
    case waitingForInput
    case failed
}
