#if os(iOS)
import CNAuthUI
import CNBackend
import CNCore
import CNMockHost
import CNSettingsUI
import CNTransport
import CNTransportWebRTC
import Foundation
import Observation
import Synchronization

/// Root app state: which shell to show, the backend session, the paired Macs,
/// and the connection to the selected one.
@MainActor
@Observable
public final class AppModel {
    public enum Shell: String, Sendable { case drawer, tabs }

    /// What the root shows.
    public enum Phase: Equatable, Sendable {
        case restoring
        case signedOut
        /// Signed in, waiting for the host list.
        case loadingHosts
        /// Signed in with no paired Mac.
        case onboarding
        case ready
    }

    public let shell: Shell
    public let devScreen: DevScreen?
    public let isMock: Bool
    public let auth: AuthSession
    public let hosts: HostsStore
    public let preferences: AppPreferences
    public let connection: HostConnection
    public let signIn: SignInController
    public let shellData: ShellDataModel

    @ObservationIgnored let mockHost: MockHost?
    @ObservationIgnored private let signaling: SignalingClient?
    @ObservationIgnored private let relaySwitch: RelaySwitch?
    @ObservationIgnored private var started = false

    init(shell: Shell, devScreen: DevScreen?, backend: BackendClient, preferences: AppPreferences,
         connector: any Connector, clientInfo: ClientInfo, mockHost: MockHost?,
         signaling: SignalingClient?, relaySwitch: RelaySwitch?) {
        self.shell = shell
        self.devScreen = devScreen
        self.isMock = mockHost != nil
        self.auth = AuthSession(backend: backend)
        self.hosts = HostsStore(backend: backend)
        self.preferences = preferences
        self.connection = HostConnection(connector: connector, clientInfo: clientInfo)
        self.signIn = SignInController(auth: auth)
        self.shellData = ShellDataModel(connection: connection)
        self.mockHost = mockHost
        self.signaling = signaling
        self.relaySwitch = relaySwitch
    }

    public var phase: Phase {
        switch auth.state {
        case .restoring: return .restoring
        case .signedOut: return .signedOut
        case .signedIn:
            if hosts.hasLoaded && hosts.hosts.isEmpty { return .onboarding }
            if !hosts.hasLoaded && preferences.selectedHostId == nil { return .loadingHosts }
            return .ready
        }
    }

    public var selectedHost: HostRecord? { preferences.selectedHostId.flatMap(hosts.host(id:)) }

    // MARK: Factories

    static func clientInfo(bundle: Bundle) -> ClientInfo {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return ClientInfo(name: "cmux-next-ios", version: version, platform: "ios")
    }

    /// The app's model. DEBUG `CMUX_NEXT_MOCK=1` or `CMUX_NEXT_DEV_SCREEN`
    /// runs on the in-process mock host and backend instead.
    public static func live(bundle: Bundle, environment: [String: String] = ProcessInfo.processInfo.environment) -> AppModel {
        let raw = bundle.object(forInfoDictionaryKey: "CmuxNextShell") as? String
        var shell = Shell(rawValue: raw ?? "") ?? .tabs
        let devScreen = DevScreen.current(environment)
        if devScreen == .drawer { shell = .drawer }
        if devScreen == .tabs { shell = .tabs }
        let info = clientInfo(bundle: bundle)

        let model = make(shell: shell, devScreen: devScreen, bundle: bundle, environment: environment, clientInfo: info)
        #if DEBUG
        // Captures: `CMUX_NEXT_APPEARANCE=light|dark|system` sets Settings > Appearance.
        if let raw = environment["CMUX_NEXT_APPEARANCE"], let appearance = AppPreferences.Appearance(rawValue: raw) {
            model.preferences.appearance = appearance
        }
        // `CMUX_NEXT_FORCE_RELAY=1|0` sets Settings > Force relay (TURN).
        if let raw = environment["CMUX_NEXT_FORCE_RELAY"] {
            model.preferences.forceRelay = raw == "1"
            model.relaySwitch?.set(raw == "1")
        }
        #endif
        return model
    }

    private static func make(shell: Shell, devScreen: DevScreen?, bundle: Bundle, environment: [String: String],
                             clientInfo info: ClientInfo) -> AppModel {
        if DevScreen.mockEnabled(environment) {
            return mock(shell: shell, devScreen: devScreen, clientInfo: info)
        }

        let configuration = BackendConfiguration(bundle: bundle, environment: environment)
            ?? BackendConfiguration(baseURL: URL(string: "https://cmux-next-mobile.debussy.workers.dev")!)
        let backend = BackendClient(configuration: configuration, tokenStore: SessionTokenStore())
        let preferences = AppPreferences()
        let signaling = SignalingClient(urlProvider: { try await backend.signalingURL() })
        let relaySwitch = RelaySwitch(preferences.forceRelay)
        let connector = SwitchingWebRTCConnector(signaling: signaling, relay: relaySwitch) {
            try await backend.iceConfiguration()
        }
        return AppModel(shell: shell, devScreen: devScreen, backend: backend, preferences: preferences,
                        connector: connector, clientInfo: info, mockHost: nil, signaling: signaling, relaySwitch: relaySwitch)
    }

    static func mock(shell: Shell, devScreen: DevScreen?, clientInfo: ClientInfo) -> AppModel {
        let host = MockHost()
        let signedIn = devScreen != .signin
        MockBackendState.shared.configure(
            hosts: devScreen == .onboarding ? [] : [host.hostRecord],
            pairable: host.hostRecord
        )
        let backend = BackendClient(
            configuration: BackendConfiguration(baseURL: MockBackendState.baseURL),
            tokenStore: InMemoryTokenStore(signedIn ? MockBackendState.storedSession() : nil),
            urlSession: MockBackendURLProtocol.makeSession()
        )
        let defaults = UserDefaults(suiteName: "cmux-next-mock") ?? .standard
        defaults.removePersistentDomain(forName: "cmux-next-mock")
        let preferences = AppPreferences(defaults: defaults)
        if devScreen != .onboarding { preferences.selectedHostId = host.options.hostId }
        return AppModel(shell: shell, devScreen: devScreen, backend: backend, preferences: preferences,
                        connector: host.makeConnector(), clientInfo: clientInfo, mockHost: host, signaling: nil, relaySwitch: nil)
    }

    // MARK: Lifecycle

    /// Restores the session once; the root calls it from `.task`.
    func start() async {
        guard !started else { return }
        started = true
        await auth.restore()
    }

    /// Reacts to sign-in / sign-out.
    func authStateChanged() async {
        switch auth.state {
        case .signedIn:
            if let signaling {
                await signaling.start()
                hosts.observePresence(signaling.presence())
            }
            ensureConnected()
            await hosts.refresh()
            reconcileSelection()
        case .signedOut:
            connection.disconnect()
            await signaling?.stop()
            hosts.clear()
            if !isMock { preferences.selectedHostId = nil }
        case .restoring:
            break
        }
    }

    /// Keeps the selection valid after the host list changes.
    func reconcileSelection() {
        guard hosts.hasLoaded, !hosts.hosts.isEmpty else { return }
        if let id = preferences.selectedHostId, hosts.host(id: id) != nil { return }
        selectHost((hosts.onlineHosts.first ?? hosts.hosts.first)?.id)
    }

    func selectHost(_ id: String?) {
        guard preferences.selectedHostId != id else { ensureConnected(); return }
        preferences.selectedHostId = id
        ensureConnected(force: true)
    }

    /// Connects to the selected host unless already on it.
    func ensureConnected(force: Bool = false) {
        guard auth.state.user != nil, let id = preferences.selectedHostId else { return }
        if !force, connection.hostId == id, connection.state != .idle {
            if case .failed = connection.state { connection.retry() }
            return
        }
        connection.connect(hostId: id)
    }

    /// Applies the Settings "Force relay (TURN)" toggle and reconnects.
    func forceRelayChanged() {
        relaySwitch?.set(preferences.forceRelay)
        if connection.hostId != nil { connection.retry() }
    }

    /// The app came back to the foreground.
    func becameActive() {
        switch connection.state {
        case .failed, .reconnecting: connection.retry()
        default: break
        }
        Task { await hosts.refresh(); reconcileSelection() }
    }

    func handleOpenURL(_ url: URL) {
        // OAuth callbacks (`<bundle id>://oauth/callback`, Stack's
        // `stack-auth-mobile-oauth-url://`) are delivered to the
        // ASWebAuthenticationSession that started them; nothing else routes
        // through the scheme yet.
    }
}

/// Thread-safe relay-only flag read at every connect.
final class RelaySwitch: Sendable {
    private let value: Mutex<Bool>
    init(_ initial: Bool) { value = Mutex(initial) }
    func set(_ on: Bool) { value.withLock { $0 = on } }
    var isOn: Bool { value.withLock { $0 } }
}

/// A `WebRTCConnector` whose relay-only option follows Settings at each connect.
final class SwitchingWebRTCConnector: Connector {
    let signaling: SignalingClient
    let relay: RelaySwitch
    let fetchICE: @Sendable () async throws -> ICEConfiguration

    init(signaling: SignalingClient, relay: RelaySwitch, fetchICE: @escaping @Sendable () async throws -> ICEConfiguration) {
        self.signaling = signaling
        self.relay = relay
        self.fetchICE = fetchICE
    }

    func connect(hostId: String) async throws -> any LinkTransport {
        let connector = WebRTCConnector(signaling: signaling, options: .init(relayOnly: relay.isOn), fetchICE: fetchICE)
        return try await connector.connect(hostId: hostId)
    }
}
#endif
