import Foundation
import NetworkExtension
import WireGuardKit
import os

/// iOS owns this process. WireGuardKit encrypts the virtual interface's packets
/// directly to Cloud; neither the Mac nor the cmux app process carries them.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "com.cmux.cloud-vpn", category: "PacketTunnelProvider")
    private lazy var adapter = WireGuardAdapter(with: self) { [weak self] level, _ in
        // WireGuard diagnostics can contain endpoint/configuration values.
        if level == .error { self?.logger.error("WireGuard adapter reported a network error") }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              proto.providerConfiguration?["schemaVersion"] as? Int == 1,
              let reference = proto.passwordReference else {
            completionHandler(ProviderError.configuration)
            return
        }
        let configuration: TunnelConfiguration
        do {
            let text = try CloudVPNConfigurationKeychain.read(reference: reference)
            configuration = try TunnelConfiguration(fromWgQuickConfig: text, called: "cmux Cloud")
            guard !configuration.peers.isEmpty,
                  !configuration.interface.addresses.isEmpty,
                  configuration.interface.addresses.allSatisfy({ CloudVPNRoutePolicy.permits($0.stringRepresentation) }),
                  configuration.peers.allSatisfy({ peer in
                      peer.endpoint != nil && !peer.allowedIPs.isEmpty
                          && peer.allowedIPs.allSatisfy { CloudVPNRoutePolicy.permits($0.stringRepresentation) }
                  }) else { throw ProviderError.configuration }
            // Cloud only routes private IPs. Keep the phone's normal DNS.
            configuration.interface.dns = []
            configuration.interface.dnsSearch = []
        } catch {
            logger.error("Cloud VPN configuration is missing or invalid")
            completionHandler(ProviderError.configuration)
            return
        }
        adapter.start(tunnelConfiguration: configuration) { error in
            completionHandler(error == nil ? nil : ProviderError.start)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }

    private enum ProviderError: Error {
        case configuration
        case start
    }
}
