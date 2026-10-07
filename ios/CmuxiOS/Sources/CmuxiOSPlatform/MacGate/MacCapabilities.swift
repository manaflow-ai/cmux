public import CmuxiOSFeatureKit

/// What one Mac's cmux announces in capability negotiation (A0; B5 serves it).
public struct MacCapabilities: Hashable, Sendable {
    public let host: HostID
    public let name: String
    /// The Mac app's marketing version, for the update hint.
    public let appVersion: String
    /// The `cmux.mobile` protocol version it speaks.
    public let protocolVersion: Int
    public let capabilities: Set<String>

    public init(host: HostID, name: String, appVersion: String, protocolVersion: Int, capabilities: Set<String>) {
        self.host = host
        self.name = name
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}
