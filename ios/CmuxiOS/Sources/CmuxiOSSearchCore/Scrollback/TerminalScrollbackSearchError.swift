/// Why a scrollback search could not run.
public enum TerminalScrollbackSearchError: Error, Hashable, Sendable {
    /// The Mac does not serve paged history (`terminal.history` answered
    /// `proto.unsupported`).
    case unsupported
    case offline
}
