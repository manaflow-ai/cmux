import Foundation

/// The non-secret peer description returned by `cloud.machine.connect_info`.
///
/// A connect-info value is a point-in-time description. It does not contain a
/// dial credential; the credential used in the VM hello is minted separately
/// and must never be cached with this value.
public struct CloudConnectInfo: Hashable, Sendable {
    public struct Peer: Hashable, Sendable {
        public var wireGuardPublicKey: String
        public var overlayAddress: String
        public var vpcEndpoint: String?
        public var publicIPv6: String?

        public init(
            wireGuardPublicKey: String,
            overlayAddress: String,
            vpcEndpoint: String? = nil,
            publicIPv6: String? = nil
        ) {
            self.wireGuardPublicKey = wireGuardPublicKey
            self.overlayAddress = overlayAddress
            self.vpcEndpoint = vpcEndpoint
            self.publicIPv6 = publicIPv6
        }
    }

    public struct Gateway: Hashable, Sendable {
        public var tunnelID: String
        public var endpoint: String
        public var serverPublicKey: String
        public var clientAddress: String
        public var allowedIPs: [String]

        public init(
            tunnelID: String,
            endpoint: String,
            serverPublicKey: String,
            clientAddress: String,
            allowedIPs: [String]
        ) {
            self.tunnelID = tunnelID
            self.endpoint = endpoint
            self.serverPublicKey = serverPublicKey
            self.clientAddress = clientAddress
            self.allowedIPs = allowedIPs
        }
    }

    public enum Service: String, CaseIterable, Hashable, Sendable {
        case daemon
        case ssh
    }

    public var machineID: String
    public var hostID: HostID
    public var epoch: Int
    public var state: CloudMachineStatus
    public var peer: Peer
    public var gateway: Gateway?
    public var services: [Service]
    public var daemonVersion: String?
    public var daemonCapabilities: [String]
    public var revision: UInt64

    public init(
        machineID: String,
        hostID: HostID,
        epoch: Int,
        state: CloudMachineStatus,
        peer: Peer,
        gateway: Gateway? = nil,
        services: [Service],
        daemonVersion: String? = nil,
        daemonCapabilities: [String] = [],
        revision: UInt64 = 0
    ) {
        self.machineID = machineID
        self.hostID = hostID
        self.epoch = epoch
        self.state = state
        self.peer = peer
        self.gateway = gateway
        self.services = services
        self.daemonVersion = daemonVersion
        self.daemonCapabilities = daemonCapabilities
        self.revision = revision
    }
}
