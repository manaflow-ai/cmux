import CmuxWireGuard
import CmuxWireGuardPairing
import Foundation
import Observation
import UIKit

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
    @ObservationIgnored private var identity: WireGuardKey?

    init() {
        do {
            let key = try vault.identityKey()
            identity = key
            connections = vault.pairedHosts().map { makeConnection($0, key: key) }
            selectedHostID = connections.first?.id
        } catch {
            startupError = HostConnection.describe(error)
        }
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
            pairing = .failed(HostConnection.describe(error))
        }
    }

    private func pair(_ invitation: PairingInvitation) async {
        guard let identity else { return }
        pairing = .pairing(hostName: invitation.hostName)
        do {
            let host = try await WireGuardPairingClient().pair(
                invitation: invitation, permanentKey: identity,
                deviceName: UIDevice.current.name, deviceModel: UIDevice.current.model)
            connections.first { $0.id == host.hostID }?.disconnect()
            connections.removeAll { $0.id == host.hostID }
            let connection = makeConnection(host, key: identity)
            connections.append(connection)
            selectedHostID = host.hostID
            persistAll()
            pairing = .paired(hostName: host.hostName)
            connection.connect()
        } catch {
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
