import Foundation

/// The protocol version this client speaks (PROTOCOL §4 `host.hello`).
public let cmuxNextProtocolVersion = 1

public struct ClientInfo: Codable, Sendable, Hashable {
    public var name: String
    public var version: String
    public var platform: String

    public init(name: String, version: String, platform: String) {
        self.name = name; self.version = version; self.platform = platform
    }
}

public struct HelloParams: Codable, Sendable, Hashable {
    public var client: ClientInfo
    public var `protocol`: Int

    public init(client: ClientInfo, protocol: Int = cmuxNextProtocolVersion) {
        self.client = client; self.protocol = `protocol`
    }
}

/// `host.hello` result.
public struct HostInfo: Codable, Sendable, Hashable {
    public var hostId: String
    public var hostName: String
    public var os: String
    public var version: String
    public var `protocol`: Int
    public var capabilities: [String]

    public init(hostId: String, hostName: String, os: String, version: String, protocol: Int = cmuxNextProtocolVersion, capabilities: [String]) {
        self.hostId = hostId; self.hostName = hostName; self.os = os; self.version = version
        self.protocol = `protocol`; self.capabilities = capabilities
    }

    public func supports(_ capability: HostCapability) -> Bool { capabilities.contains(capability.rawValue) }
}

public enum HostCapability: String, Sendable, CaseIterable {
    case terminal = "term.v1"
    case agent = "agent.v1"
    case browser = "browser.v1"
    case conversations = "conv.v1"
    case files = "fs.v1"
}

public struct PingResult: Codable, Sendable, Hashable {
    public var at: EpochMillis
    public init(at: EpochMillis) { self.at = at }
}
