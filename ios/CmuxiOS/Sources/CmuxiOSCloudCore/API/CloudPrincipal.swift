import Foundation

/// Which credential a call carries. Reads and the event socket go as this
/// install; create, start, pause and delete need a signed-in person, so they
/// carry the Stack session (`CloudDO` refuses them from an install).
public enum CloudPrincipal: Hashable, Sendable {
    case install
    case session
}
