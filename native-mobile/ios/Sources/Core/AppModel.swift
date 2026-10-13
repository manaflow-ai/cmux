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
    /// The last Mac list load failed (offline, server error). With no cached
    /// list the UI shows a load error with Retry, never "Connect your Mac".
    private(set) var hostsError: String?
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
            if let host = cached.launchHost(selectedID: selectedHostID) { connect(host, remember: false) }
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
        // Stop alerts with terminal text reaching a signed-out phone: revoke
        // the session and the push registration before forgetting the token.
        let api = PushAPI(token: token)
        let device = PushManager.shared.deviceToken
        Task { try? await api.logout(deviceToken: device) }
        connection?.stop()
        connection = nil
        tokenStore.value = nil
        user = nil
        hosts = []
        selectedHostID = nil
        UserDefaults.standard.removeObject(forKey: "cachedHosts")
        phase = .signedOut
    }

    /// What the Mac list shows: loading, a load failure, no Mac yet, or Macs.
    var macList: MacListState {
        MacListState(loaded: hostsLoaded, hostCount: hosts.count, error: hostsError)
    }

    /// Loads the Macs. A failure retries a few times on its own (backing
    /// off); after that Retry, pull-to-refresh or the next foreground does.
    func reloadHosts() async {
        for attempt in 0..<3 {
            do {
                let loaded = try await api.hosts()
                hosts = loaded
                hostsLoaded = true
                hostsError = nil
                UserDefaults.standard.set(try? JSONEncoder().encode(loaded), forKey: "cachedHosts")
                // The cached list's online flags can be stale: an automatic
                // pick that isn't connected moves to a Mac that is online now.
                if let host = loaded.autoSwitch(selectedID: selectedHostID, currentID: connection?.host.id,
                                                currentConnected: connection?.phase == .connected) {
                    connect(host, remember: false)
                }
                return
            } catch let error as APIClient.APIError where error.status == 401 {
                hostsError = error.localizedDescription
                return
            } catch {
                Self.log.error("hosts failed: \(String(describing: error), privacy: .public)")
                hostsError = error.localizedDescription
                guard attempt < 2, phase == .ready, connection == nil else { return }
                try? await Task.sleep(for: .seconds(2 << attempt))
            }
        }
    }

    /// The app came back to the foreground: a link that went quiet in the
    /// background is replaced right away instead of waiting for ICE restart
    /// timers, and the tree, agents and feed catch up on what happened.
    func becameActive() async {
        guard phase == .ready else { return }
        if hostsError != nil || !hostsLoaded { Task { await reloadHosts() } }
        guard let connection else { return }
        let healthy = connection.phase == .connected ? await connection.probe(timeout: .seconds(2)) : false
        switch ForegroundRecovery.action(phase: connection.phase, probeSucceeded: healthy) {
        case .refresh:
            await connection.refresh()
            await feed.backfill()
        case .reconnect:
            Self.log.info("foreground: reconnecting (phase \(String(describing: connection.phase), privacy: .public))")
            reconnect()
        case .wait:
            break
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
        // Recovery is not a choice: keep whatever the user picked (or didn't).
        connect(host, remember: false)
    }

    /// `remember: false` for automatic picks, so only a Mac the user chose
    /// sticks across launches.
    func connect(_ host: APIClient.Host, remember: Bool = true) {
        if connection?.host.id == host.id { return }
        connection?.stop()
        if remember { selectedHostID = host.id }
        var configuration = WebRTCHostLink.Configuration(apiBase: APIClient.configuredBase, hostID: host.id, token: { [tokenStore] in tokenStore.value ?? "" })
        // QA: `-relayOnly YES` forces the TURN relay path (no direct candidates).
        configuration.relayOnly = UserDefaults.standard.bool(forKey: "relayOnly")
        let link = WebRTCHostLink(configuration: configuration)
        let connection = HostConnection(host: host, link: link)
        // Weak: the connection owns these closures; a strong capture kept every
        // replaced connection (and its terminal surfaces) alive.
        connection.onNotification = { [weak self, weak connection] notification in
            guard let connection else { return }
            self?.feed.ingest(notification, from: connection)
        }
        connection.onAgentChange = { [weak self, weak connection] agent, previous in
            guard let connection else { return }
            self?.feed.ingest(agent, previous: previous, from: connection)
        }
        connection.onConnected = { [weak self] in Task { await self?.feed.backfill() } }
        self.connection = connection
        feed.attach(connection)
        connection.start()
    }
}

/// What the Mac list (Home, sidebar) shows.
enum MacListState: Equatable {
    case loading
    case failed(String)
    case noMac
    case macs

    init(loaded: Bool, hostCount: Int, error: String?) {
        if hostCount > 0 { self = .macs }
        else if let error { self = .failed(error) }
        else if loaded { self = .noMac }
        else { self = .loading }
    }
}

/// What to do with the link when the app returns to the foreground.
enum ForegroundRecovery: Equatable {
    /// The link answered: refresh tree, agents and feed.
    case refresh
    /// The link is down or silent: replace it now.
    case reconnect
    /// The first connect is still underway.
    case wait

    static func action(phase: HostConnection.Phase, probeSucceeded: Bool) -> ForegroundRecovery {
        switch phase {
        case .connected: probeSucceeded ? .refresh : .reconnect
        case .connecting: .wait
        case .reconnecting, .offline: .reconnect
        }
    }
}

extension [APIClient.Host] {
    /// The Mac to open at launch: the one the user picked, else one that is
    /// online now, else the first. A fresh install with an old, offline Mac
    /// listed first would otherwise sit on "Reconnecting…".
    func launchHost(selectedID: String?) -> APIClient.Host? {
        first { $0.id == selectedID } ?? first { $0.online == true } ?? first
    }

    /// After a fresh list: the Mac to switch to, or nil to stay. A Mac the
    /// user picked, or one that is connected, stays.
    func autoSwitch(selectedID: String?, currentID: String?, currentConnected: Bool) -> APIClient.Host? {
        guard let currentID else { return launchHost(selectedID: selectedID) }
        if currentConnected || contains(where: { $0.id == selectedID }) { return nil }
        guard let best = launchHost(selectedID: nil), best.id != currentID else { return nil }
        return best
    }
}
