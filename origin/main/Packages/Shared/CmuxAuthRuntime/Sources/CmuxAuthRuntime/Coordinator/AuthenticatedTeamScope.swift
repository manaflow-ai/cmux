import Foundation

/// Credential-free account and team authority for cancelling scoped work.
public struct AuthenticatedTeamScope: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible {
    /// Auth session identity, including its account generation.
    public let session: AuthenticatedSessionIdentity
    /// The selected, resolved Stack team.
    public let teamID: String
    /// Advances on every account/team transition, including A to B to A.
    public let generation: UInt64

    /// Creates a captured account/team scope without copying credentials.
    public init(session: AuthenticatedSessionIdentity, teamID: String, generation: UInt64) {
        self.session = session
        self.teamID = teamID
        self.generation = generation
    }

    /// Logs contain the generation, with account and team identifiers redacted.
    public var description: String {
        "AuthenticatedTeamScope(generation: \(generation), accountID: <redacted>, teamID: <redacted>)"
    }

    public var debugDescription: String { description }
}
