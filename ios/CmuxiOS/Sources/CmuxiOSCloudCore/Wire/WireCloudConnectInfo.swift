import Foundation

/// The snake-case wire representation of `cloud.machine.connect_info`.
struct WireCloudConnectInfo: Decodable {
    struct Peer: Decodable {
        var wg_public_key: String
        var overlay_address: String
        var vpc_endpoint: String?
        var public_ipv6: String?
    }

    struct Gateway: Decodable {
        var tunnel_id: String
        var endpoint: String
        var server_public_key: String
        var client_address: String
        var allowed_ips: [String]
    }

    struct Daemon: Decodable {
        var version: String?
        var capabilities: [String]
    }

    var machine: String
    var host: String
    var epoch: Int
    var state: String
    var peer: Peer
    var gateway: Gateway?
    var services: [String]
    var daemon: Daemon
    var revision: String?
}
