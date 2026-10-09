/// A tunnel stream that ended abnormally.
public enum LinkTunnelStreamError: Error, Hashable, Sendable {
    /// The Mac closed the stream with an error code (`tunnel.reset`, `auth.revoked`).
    case reset(String)
    /// The link lost bytes it could not replay.
    case lost
}
