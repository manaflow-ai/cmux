import CmuxNativeLink
import Foundation
import Observation

/// App state: who is signed in, which Macs are paired, and the live
/// connection to the selected Mac.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var user: APIClient.User?
    private(set) var hosts: [APIClient.Host] = []
    private(set) var hostsLoaded = false
    private(set) var connection: HostConnection?
    let feed = FeedStore()

    private let keychain = Keychain(service: "dev.cmux.next.native")
    private var token: String? { keychain.read("session") }

    var api: APIClient { APIClient(base: APIClient.configuredBase, token: token) }

    var selectedHostID: String? {
        get { UserDefaults.standard.string(forKey: "selectedHost") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedHost") }
    }

    func launch() async {
        if let devEmail = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_EMAIL"],
           let devSecret = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_SECRET"], token == nil {
            try? await signInDev(email: devEmail, secret: devSecret)
        }
        guard token != nil else { phase = .signedOut; return }
        do {
            user = try await api.me()
            phase = .ready
            await reloadHosts()
        } catch let error as APIClient.APIError where error.status == 401 {
            keychain.write("session", nil)
            phase = .signedOut
        } catch {
            // Offline at launch: keep the session, show cached state.
            phase = .ready
        }
    }

    func signInWithApple(identityToken: String, name: String?) async throws {
        let response = try await api.signInWithApple(identityToken: identityToken, name: name)
        complete(response)
        await reloadHosts()
    }

    func signInDev(email: String, secret: String) async throws {
        let response = try await api.signInDev(email: email, secret: secret)
        complete(response)
        await reloadHosts()
    }

    private func complete(_ response: APIClient.AuthResponse) {
        keychain.write("session", response.sessionToken)
        user = response.user
        phase = .ready
    }

    func signOut() {
        connection?.stop()
        connection = nil
        keychain.write("session", nil)
        user = nil
        hosts = []
        selectedHostID = nil
        phase = .signedOut
    }

    func reloadHosts() async {
        do {
            hosts = try await api.hosts()
            hostsLoaded = true
            if connection == nil, let host = hosts.first(where: { $0.id == selectedHostID }) ?? hosts.first {
                connect(host)
            }
        } catch {
            hostsLoaded = true
        }
    }

    func pair(code: String) async throws {
        let host = try await api.pair(code: code)
        await reloadHosts()
        if let paired = hosts.first(where: { $0.id == host.id }) { connect(paired) }
    }

    func unpair(_ host: APIClient.Host) async {
        if connection?.host.id == host.id {
            connection?.stop()
            connection = nil
        }
        try? await api.unpair(hostID: host.id)
        await reloadHosts()
    }

    func reconnect() {
        guard let host = connection?.host else { return }
        connection?.stop()
        connection = nil
        connect(host)
    }

    func connect(_ host: APIClient.Host) {
        if connection?.host.id == host.id { return }
        connection?.stop()
        selectedHostID = host.id
        let link = WebRTCHostLink(
            configuration: .init(apiBase: APIClient.configuredBase, hostID: host.id, token: { [keychain] in keychain.read("session") ?? "" })
        )
        let connection = HostConnection(host: host, link: link)
        connection.onNotification = { [weak self] notification in self?.feed.ingest(notification, from: connection) }
        connection.onAgentChange = { [weak self] agent, previous in self?.feed.ingest(agent, previous: previous, from: connection) }
        connection.onConnected = { [weak self] in Task { await self?.feed.backfill() } }
        self.connection = connection
        feed.attach(connection)
        connection.start()
    }
}
