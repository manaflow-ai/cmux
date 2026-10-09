/// The localized reasons an SSH host shows offline in the list; the
/// composition root hands them to the SSH workspaces channel.
public struct SSHWorkspaceReasonTexts: Sendable {
    public var untrustedKey: String
    public var needsLogin: String
    public var unreachable: String
    public var refused: String
}
