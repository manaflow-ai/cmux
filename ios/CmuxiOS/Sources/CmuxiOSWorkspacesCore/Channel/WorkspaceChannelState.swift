import Foundation

/// The host socket as the workspace list sees it.
public enum WorkspaceChannelState: Hashable, Sendable {
    case connecting
    /// Connected and negotiated: `path` is the carrier badge, `caps` the
    /// `hello.ok` capability intersection.
    case live(path: String?, caps: Set<String>)
    case offline(reason: String?)
}
