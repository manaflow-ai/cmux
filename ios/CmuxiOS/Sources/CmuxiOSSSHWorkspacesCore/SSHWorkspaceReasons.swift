public import CmuxiOSSSHCore

/// Localized offline reasons for an SSH host in the Workspaces list,
/// supplied by the UI layer.
public struct SSHWorkspaceReasons: Sendable {
    public var untrustedKey: String
    public var needsLogin: String
    public var unreachable: String
    public var refused: String

    public init(untrustedKey: String, needsLogin: String, unreachable: String, refused: String) {
        self.untrustedKey = untrustedKey
        self.needsLogin = needsLogin
        self.unreachable = unreachable
        self.refused = refused
    }

    public func text(for failure: SSHSessionFailure) -> String {
        switch failure {
        case .hostKeyRejected: untrustedKey
        case .missingCredentials, .missingUser, .authenticationFailed: needsLogin
        case .network: unreachable
        case .invalidChain, .shellRejected, .sessionGone: refused
        }
    }
}
