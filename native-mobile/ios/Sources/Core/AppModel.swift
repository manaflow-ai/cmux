import CmuxNativeLink
import Foundation
import Observation
import os

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

    private let tokenStore = SessionTokenStore()
    private var token: String? { tokenStore.value }

    var api: APIClient { APIClient(base: APIClient.configuredBase, token: token) }

    var selectedHostID: String? {
        get { UserDefaults.standard.string(forKey: "selectedHost") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedHost") }
    }

    func launch() async {
        Logger(subsystem: "dev.cmux.next.native", category: "auth").info("launch dev=\(ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_EMAIL"] ?? "none", privacy: .public) token=\(self.token != nil, privacy: .public)")
        if let devEmail = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_EMAIL"],
           let devSecret = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_SECRET"], token == nil {
            do { try await signInDev(email: devEmail, secret: devSecret) } catch { Logger(subsystem: "dev.cmux.next.native", category: "auth").error("dev sign-in failed: \(String(describing: error), privacy: .public)") }
        }
        guard token != nil else { phase = .signedOut; return }
        // Signed in before: show the app at once (like Claude/ChatGPT) and
        // confirm the session in the background.
        phase = .ready
        // Connect to the last Mac right away from the cached list.
        if hosts.isEmpty, let data = UserDefaults.standard.data(forKey: "cachedHosts"),
           let cached = try? JSONDecoder().decode([APIClient.Host].self, from: data) {
            hosts = cached
            if let host = cached.first(where: { $0.id == selectedHostID }) ?? cached.first { connect(host) }
        }
        async let hosts: Void = reloadHosts()
        do {
            user = try await api.me()
            await hosts
        } catch let error as APIClient.APIError where error.status == 401 {
            await hosts
            signOut()
        } catch {
            // Offline or a transient failure: keep the session and keep
            // trying to load the Macs.
            Self.log.error("launch me() failed: \(String(describing: error), privacy: .public)")
            await hosts
        }
    }

    static let log = Logger(subsystem: "dev.cmux.next.native", category: "app")

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
        tokenStore.value = response.sessionToken
        user = response.user
        phase = .ready
    }

    func signOut() {
        connection?.stop()
        connection = nil
        tokenStore.value = nil
        user = nil
        hosts = []
        selectedHostID = nil
        UserDefaults.standard.removeObject(forKey: "cachedHosts")
        phase = .signedOut
    }

    func reloadHosts() async {
        do {
            hosts = try await api.hosts()
            hostsLoaded = true
            UserDefaults.standard.set(try? JSONEncoder().encode(hosts), forKey: "cachedHosts")
            if connection == nil, let host = hosts.first(where: { $0.id == selectedHostID }) ?? hosts.first {
                connect(host)
            }
        } catch {
            Self.log.error("hosts failed: \(String(describing: error), privacy: .public)")
            hostsLoaded = true
            // Retry while nothing is connected (lifecycle: the next foreground
            // or pull-to-refresh also retries).
            if connection == nil {
                try? await Task.sleep(for: .seconds(3))
                if connection == nil, phase == .ready { await reloadHosts() }
            }
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
            configuration: .init(apiBase: APIClient.configuredBase, hostID: host.id, token: { [tokenStore] in tokenStore.value ?? "" })
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
