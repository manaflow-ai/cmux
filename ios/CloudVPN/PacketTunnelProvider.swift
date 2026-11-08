import Foundation
import NetworkExtension
import CmuxCloudTunnelCore
import os

private let logger = Logger(subsystem: "dev.cmux.ios.cloud-vpn", category: "PacketTunnelProvider")

/// Runs the optional cmux Cloud system VPN on iOS.
///
/// The same ordered lifecycle and WireGuard adapter as the macOS system
/// extension (`TunnelExtension/`); only the configuration source differs. On
/// iOS the key-bearing wg-quick text lives in the Keychain group this
/// extension shares with the app, and the saved preferences hold only its
/// persistent reference. Every route and address is checked against the
/// private-range policy again here, so an edited preference cannot turn the
/// VPN into a full tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var lifecycle: CloudTunnelProviderStartGate?
    private var lifecycleTask: Task<Void, Never>?
    private let routePolicy = CloudVPNRoutePolicy()

    override init() {
        super.init()
        let lifecycle = CloudTunnelProviderStartGate(
            adapter: CloudTunnelWireGuardAdapter(provider: self),
            diagnostic: { message in logger.info("\(message, privacy: .public)") }
        )
        self.lifecycle = lifecycle
        lifecycleTask = Task { await lifecycle.run() }
    }

    deinit {
        lifecycle?.stop {}
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let lifecycle else { completionHandler(CloudTunnelProviderError.invalidState); return }
        let completion = CloudTunnelProviderCompletion(completionHandler)
        lifecycle.start(configuration: savedConfiguration()) { error in completion.call(error) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        guard let lifecycle else { completionHandler(); return }
        logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        let completion = CloudTunnelProviderCompletion { _ in completionHandler() }
        lifecycle.stop { completion.call(nil) }
    }

    private func savedConfiguration() -> Result<String, CloudTunnelProviderError> {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let reference = proto.passwordReference else { return .failure(.missingConfiguration) }
        guard proto.providerConfiguration?[CloudTunnelProviderConfigurationKeys.schemaVersion] as? Int
                == CloudTunnelProviderConfigurationKeys.currentSchemaVersion else {
            return .failure(.unsupportedSchema)
        }
        let text: String
        do {
            text = try CloudVPNConfigurationKeychain.read(reference: reference)
        } catch {
            return .failure(.missingConfiguration)
        }
        guard routesArePrivate(in: text) else {
            logger.error("refusing a Cloud VPN configuration that routes public addresses")
            return .failure(.invalidConfiguration)
        }
        return .success(text)
    }

    /// Every `Address` and `AllowedIPs` entry must be private, and there must
    /// be at least one route. Kept as a local copy of
    /// `CloudVPNRoutePolicy.permitsOnlyPrivateRoutes(inQuickConfig:)` because
    /// this extension does not link CmuxMobileCloud; the two must change
    /// together.
    private func routesArePrivate(in configuration: String) -> Bool {
        var cidrs: [String] = []
        var routeCount = 0
        for line in configuration.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let values = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            switch parts[0].lowercased() {
            case "allowedips":
                routeCount += values.count
                cidrs += values
            case "address":
                cidrs += values
            case "dns":
                return false
            default:
                continue
            }
        }
        return routeCount > 0 && cidrs.allSatisfy(routePolicy.permits)
    }
}
