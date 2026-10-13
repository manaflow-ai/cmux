import CmuxWireGuard
import CmuxWireGuardPairing
import Foundation
import Observation
import UIKit
import os

/// App state: the phone's identity, its paired Macs and the pairing flow.
@MainActor @Observable
final class AppModel {
    enum Pairing: Equatable {
        case idle
        case pairing(hostName: String)
        case paired(hostName: String)
        case failed(String)
    }

    private(set) var connections: [HostConnection] = []
    var selectedHostID: String?
    private(set) var pairing: Pairing = .idle
    private(set) var startupError: String?

    @ObservationIgnored private let vault = PhoneVault()
    @ObservationIgnored private let logger = Logger(subsystem: "dev.cmux.ios.wg", category: "pairing")
    @ObservationIgnored private var identity: WireGuardKey?

    init() {
        do {
            let key = try vault.identityKey()
            identity = key
            connections = vault.pairedHosts().map { makeConnection($0, key: key) }
            selectedHostID = connections.first?.id
        } catch {
            startupError = HostConnection.describe(error)
            logger.error("identity key unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// DEBUG simulator checks: `simctl launch <udid> dev.cmux.ios.wg -pairLink <link>`
    /// pairs without the URL-open confirmation. Called once the first view is up.
    func consumeLaunchPairLink() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard pairing == .idle else { return }
        if let index = arguments.firstIndex(of: "-pairCode"), index + 1 < arguments.count,
           let code = PairingCode(arguments[index + 1]) {
            return pair(code: code)
        }
        guard let index = arguments.firstIndex(of: "-pairLink"), index + 1 < arguments.count else { return }
        pair(link: arguments[index + 1])
        #endif
    }

    var selected: HostConnection? {
        connections.first { $0.id == selectedHostID } ?? connections.first
    }

    var identityFingerprint: String { identity?.publicKey.fingerprint ?? "—" }

    private func makeConnection(_ host: PairedHost, key: WireGuardKey) -> HostConnection {
        let connection = HostConnection(host: host, privateKey: key)
        connection.onEndpointLearned = { [weak self] host in self?.persist(host) }
        return connection
    }

    // MARK: Pairing

    /// A scanned QR code, a pasted link, or a `cmux-next://pair` URL.
    func pair(link: String) {
        do {
            let invitation = try PairingInvitation(link: link)
            Task { await pair(invitation) }
        } catch {
            logger.error("pairing link rejected: \(String(describing: error), privacy: .public)")
            pairing = .failed(HostConnection.describe(error))
        }
    }

    /// A code typed from the Mac's pairing window (same network only).
    func pair(code: PairingCode) {
        Task {
            await pair(hostName: String(localized: "your Mac")) { client, key, name, model in
                try await client.pair(code: code, permanentKey: key, deviceName: name, deviceModel: model)
            }
        }
    }

    private func pair(_ invitation: PairingInvitation) async {
        await pair(hostName: invitation.hostName) { client, key, name, model in
            try await client.pair(invitation: invitation, permanentKey: key, deviceName: name, deviceModel: model)
        }
    }

    private func pair(hostName: String,
                      _ run: (WireGuardPairingClient, WireGuardKey, String, String) async throws -> PairedHost) async {
        guard let identity else {
            pairing = .failed(startupError ?? String(localized: "This iPhone's key is unavailable."))
            return
        }
        pairing = .pairing(hostName: hostName)
        do {
            let host = try await run(WireGuardPairingClient(), identity, UIDevice.current.name, UIDevice.current.model)
            connections.first { $0.id == host.hostID }?.disconnect()
            connections.removeAll { $0.id == host.hostID }
            let connection = makeConnection(host, key: identity)
            connections.append(connection)
            selectedHostID = host.hostID
            persistAll()
            pairing = .paired(hostName: host.hostName)
            logger.info("paired with \(host.hostName, privacy: .public) via \(host.lastGoodEndpoint ?? "?", privacy: .public)")
            connection.connect()
        } catch {
            logger.error("pairing failed: \(String(describing: error), privacy: .public)")
            pairing = .failed(HostConnection.describe(error))
        }
    }

    func dismissPairingResult() {
        pairing = .idle
    }

    func unpair(_ connection: HostConnection) {
        connection.disconnect()
        connections.removeAll { $0.id == connection.id }
        if selectedHostID == connection.id { selectedHostID = connections.first?.id }
        persistAll()
    }

    // MARK: Lifecycle

    func becameActive() {
        selected?.connect()
    }

    func enteredBackground() {
        for connection in connections { connection.disconnect() }
    }

    func networkChanged() {
        selected?.networkChanged()
    }

    private func persist(_ host: PairedHost) {
        var hosts = vault.pairedHosts()
        if let index = hosts.firstIndex(where: { $0.hostID == host.hostID }) { hosts[index] = host } else { hosts.append(host) }
        try? vault.savePairedHosts(hosts)
    }

    private func persistAll() {
        try? vault.savePairedHosts(connections.map(\.host))
    }
}
