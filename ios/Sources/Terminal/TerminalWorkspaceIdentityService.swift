import Foundation

enum TerminalWorkspaceIdentityError: Error, Sendable {
    case missingTeamID
}

@MainActor
protocol TerminalWorkspaceIdentityReserving {
    func reserveWorkspace(for host: TerminalHost) async throws -> TerminalWorkspaceBackendIdentity
}
