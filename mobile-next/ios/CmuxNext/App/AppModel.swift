import CNMBackend
import CNMProtocol
import CNMTransport
import CNMWebRTC
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, signedIn }

    var phase: Phase = .launching
    var user: BackendUser?
    var hosts: [HostConnection] = []
    var hostsLoaded = false
    /// The first presence snapshot arrived; until then a Mac is "connecting",
    /// never "offline".
    var presenceKnown = false
    var lastError: String?

    let backend: BackendClient
    @ObservationIgnored private let store = AuthStore()
    @ObservationIgnored private var session: BackendSession?
    @ObservationIgnored private var refreshTask: Task<BackendSession?, Never>?
    @ObservationIgnored private var hub: SignalHub?
    @ObservationIgnored private var dialer: WebRTCDialer?
    @ObservationIgnored private var presenceTask: Task<Void, Never>?
    @ObservationIgnored let peerID = "phone-" + UUID().uuidString.lowercased().prefix(12)

    init() {
        let configured = (Bundle.main.object(forInfoDictionaryKey: "CNMBackendURL") as? String).flatMap(URL.init(string:))
        backend = BackendClient(baseURL: configured ?? BackendClient.productionURL)
    }

    var isNewUser = false

    func launch() async {
        if ProcessInfo.processInfo.arguments.contains("-cnm-reset") { store.clear() }
        guard let saved = store.load() else {
            phase = .signedOut
            return
        }
        session = saved
        user = saved.user
        phase = .signedIn
        await startServices()
    }

    // MARK: Auth

    func startEmail(_ email: String) async throws {
        try await backend.startEmail(email)
    }

    func verifyEmail(_ email: String, code: String) async throws {
        let session = try await backend.verifyEmail(email, code: code)
        await signedIn(session)
    }

    func signInWithApple(identityToken: String, rawNonce: String, givenName: String?, familyName: String?) async throws {
        let session = try await backend.signInWithApple(
            identityToken: identityToken, rawNonce: rawNonce, givenName: givenName, familyName: familyName
        )
        await signedIn(session)
    }

    private func signedIn(_ session: BackendSession) async {
        store.save(session)
        self.session = session
        user = session.user
        isNewUser = session.isNewUser ?? false
        phase = .signedIn
        await startServices()
    }

    func signOut() async {
        if let refresh = session?.refreshToken { try? await backend.logout(refresh) }
        tearDown()
    }

    func deleteAccount() async throws {
        let token = try await accessToken()
        try await backend.deleteAccount(token: token)
        tearDown()
    }

    func updateName(_ name: String) async {
        guard let token = try? await accessToken(), let user = try? await backend.updateMe(token: token, displayName: name) else { return }
        self.user = user
        if var session { session.user = user; store.save(session); self.session = session }
    }

    private func tearDown() {
        presenceTask?.cancel()
        hub?.channel.close()
        hub = nil
        dialer = nil
        for host in hosts { host.disconnect() }
        hosts = []
        hostsLoaded = false
        presenceKnown = false
        store.clear()
        session = nil
        user = nil
        phase = .signedOut
    }

    /// A valid access token, refreshed when it is within a minute of expiry.
    func accessToken() async throws -> String {
        guard let session else { throw BackendError(status: 401, code: "signed_out", message: "Signed out") }
        if session.accessExpiry.timeIntervalSinceNow > 60 { return session.accessToken }
        if let refreshTask, let refreshed = await refreshTask.value { return refreshed.accessToken }
        let task = Task<BackendSession?, Never> { [backend, weak self] in
            do {
                return try await backend.refresh(session.refreshToken)
            } catch let error as BackendError where error.status == 401 {
                // The refresh token was revoked or already rotated: sign out.
                await MainActor.run { self?.tearDown() }
                return nil
            } catch {
                return nil
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        guard let refreshed = await task.value else {
            throw BackendError(status: 401, code: "refresh_failed", message: "Please sign in again")
        }
        self.session = refreshed
        store.save(refreshed)
        return refreshed.accessToken
    }

    // MARK: Macs

    private func startServices() async {
        guard hub == nil else { return }
        let signaling = WebSocketSignaling(baseURL: backend.baseURL, peerID: String(peerID)) { [weak self] in
            try? await self?.accessToken()
        }
        let hub = SignalHub(channel: signaling)
        let backend = backend
        let relayOnly = ProcessInfo.processInfo.arguments.contains("-cnm-relay-only")
        let dialer = WebRTCDialer(hub: hub, options: WebRTCOptions(
            iceServers: { [weak self] in
                guard let token = try? await self?.accessToken(),
                      let servers = try? await backend.iceServers(token: token), !servers.isEmpty
                else { return [.cloudflareSTUN] }
                return servers.map { ICEServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
            },
            relayOnly: relayOnly
        ))
        self.hub = hub
        self.dialer = dialer
        await reloadHosts()
        presenceTask = Task { [weak self] in
            for await event in hub.subscribe() {
                guard let self else { return }
                switch event {
                case .welcome(_, let peers), .presence(let peers):
                    await self.applyPresence(peers)
                    self.presenceKnown = true
                case .closed:
                    for host in self.hosts { host.signalingLost() }
                default:
                    break
                }
            }
        }
    }

    private func applyPresence(_ peers: [SignalPeer]) async {
        let online = Set(peers.compactMap { $0.kind == .host ? $0.hostID : nil })
        if online.contains(where: { id in !hosts.contains { $0.id == id } }) { await reloadHosts() }
        for host in hosts { host.setOnline(online.contains(host.id)) }
    }

    func reloadHosts() async {
        guard let dialer, let token = try? await accessToken() else { return }
        do {
            let list = try await backend.hosts(token: token)
            var next: [HostConnection] = []
            for item in list {
                if let existing = hosts.first(where: { $0.id == item.id }) {
                    existing.name = item.name
                    next.append(existing)
                } else {
                    let connection = HostConnection(host: item, dialer: dialer)
                    next.append(connection)
                }
            }
            for removed in hosts where !next.contains(where: { $0.id == removed.id }) { removed.disconnect() }
            hosts = next
            hostsLoaded = true
            let online = Set((hub?.peers ?? []).compactMap { $0.kind == .host ? $0.hostID : nil })
            for host in hosts { host.setOnline(online.contains(host.id)) }
        } catch {
            lastError = error.localizedDescription
            hostsLoaded = true
        }
    }

    func pair(code: String) async throws -> BackendHost {
        let token = try await accessToken()
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        let host = try await backend.claimPairing(token: token, code: normalized)
        await reloadHosts()
        return host
    }

    func removeHost(_ host: HostConnection) async {
        guard let token = try? await accessToken() else { return }
        try? await backend.removeHost(token: token, id: host.id)
        host.disconnect()
        hosts.removeAll { $0.id == host.id }
    }

    func host(_ id: String) -> HostConnection? { hosts.first { $0.id == id } }

    var connectedHosts: [HostConnection] { hosts.filter { $0.status.isConnected } }
}
