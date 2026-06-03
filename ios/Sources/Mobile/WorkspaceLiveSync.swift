import Combine
import Foundation

@MainActor
protocol WorkspaceLiveSyncing: AnyObject {
    func publisher(teamID: String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never>
}

struct WorkspaceLiveSyncSnapshot: Equatable, Sendable {
    let rows: [MobileInboxWorkspaceRow]
    let isAuthoritative: Bool

    static func authoritative(_ rows: [MobileInboxWorkspaceRow]) -> WorkspaceLiveSyncSnapshot {
        WorkspaceLiveSyncSnapshot(rows: rows, isAuthoritative: true)
    }

    static func placeholder(_ rows: [MobileInboxWorkspaceRow] = []) -> WorkspaceLiveSyncSnapshot {
        WorkspaceLiveSyncSnapshot(rows: rows, isAuthoritative: false)
    }
}

@MainActor
final class NoOpWorkspaceLiveSync: WorkspaceLiveSyncing {
    func publisher(teamID: String) -> AnyPublisher<WorkspaceLiveSyncSnapshot, Never> {
        Just(.authoritative([])).eraseToAnyPublisher()
    }
}
