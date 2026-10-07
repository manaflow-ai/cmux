import Foundation

/// A network address with optional port and user.
public struct HostEndpoint: Hashable, Sendable {
    public var address: String
    public var port: UInt16?
    public var user: String?

    public init(address: String, port: UInt16? = nil, user: String? = nil) {
        self.address = address
        self.port = port
        self.user = user
    }
}
