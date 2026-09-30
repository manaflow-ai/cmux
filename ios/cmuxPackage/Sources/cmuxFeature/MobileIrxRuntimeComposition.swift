public import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxIrxTransport
public import CmuxMobileShellModel
public import CmuxMobileTransport
public import Foundation

/// Owns one v2 control service and endpoint per authenticated team/build identity.
public actor MobileIrxRuntimeComposition {
    public enum CompositionError: Error, Sendable {
        case notSignedIn, unsupportedRoute, peerNotDiscovered, directDialUnavailable, scopeChanged
    }
    enum DialIntent: Equatable, Sendable {
        case automatic
        case direct([CmxIrohDirectDialCandidate])
    }

    public nonisolated let macListAuthState: MobileMacListAuthState
    public nonisolated let configuration: MobileIrohV2Configuration
    public nonisolated var tag: String { configuration.buildTag }
    public nonisolated var forceRelayOnly: Bool { configuration.forceRelayOnly }
    public nonisolated var transportFactory: CmxConnectivityDeferredTransportFactory {
        CmxConnectivityDeferredTransportFactory(provider: self)
    }
    let journal: IrxJournal
    let diagnosticLog: DiagnosticLog?
    let installation: MobileIrohV2InstallationStore
    let localPaths: MobileIrohV2LocalPathStore
    let urlSession: URLSession
    weak var auth: AuthCoordinator?
    var activeScope: AuthenticatedTeamScope?
    var epoch: UInt64 = 0
    var authTask: Task<Void, Never>?
    var provisionTask: Task<Void, Never>?
    var controlTask: Task<Void, Never>?
    var foregroundTask: Task<Void, Never>?
    var endpointWarmupTask: Task<Void, Never>?
    var control: V2ControlService?
    var endpointSupervisor: IrxEndpointSupervisor?
    var directEndpointSupervisor: IrxEndpointSupervisor?
    var identity: IrxIdentity?
    var cache: V2CachedState?
    var lastFailure: String?
    var lastLoggedControlState: String?
    var enginesByPeer: [String: IrxPeerEngine] = [:]
    var dialIntentByPeer: [String: DialIntent] = [:]
    var activeDialIntentByPeer: [String: DialIntent] = [:]
    var expectedDeviceIDByPeer: [String: String] = [:]
    var controlLaneClaims = MobileIrxControlLaneClaims()
    var claimedEventSessions: [String: String] = [:]
    /// One server-event lane acceptor per admitted session, keyed by peer.
    var eventLaneHubs: [String: (sessionID: String, hub: IrxServerEventLaneHub)] = [:]
    var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var launchTime = Date()
    var backgroundTime: Date?
    var applicationActive = true
    var activityGeneration: UInt64 = 0
    var admittedSessionCount = 0

    /// Dependencies are owned here; authentication is supplied later without copying its persistence.
    public init(configuration: MobileIrohV2Configuration, macListAuthState: MobileMacListAuthState, keychainAccessGroup: String? = nil,
                session: URLSession = .shared, diagnosticLog: DiagnosticLog? = nil) {
        self.macListAuthState = macListAuthState
        self.configuration = configuration
        self.urlSession = session
        self.diagnosticLog = diagnosticLog
        localPaths = MobileIrohV2LocalPathStore(root: configuration.stateDirectory)
        installation = MobileIrohV2InstallationStore(configuration: configuration, accessGroup: keychainAccessGroup)
        journal = IrxJournal(subsystem: "dev.cmux.ios", category: "iroh-v2",
            journalFileURL: configuration.stateDirectory.appendingPathComponent("iroh-v2-journal.jsonl"))
    }

    func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changeObservers[id] = continuation
        continuation.yield(())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeChangeObserver(id) } }
        return stream
    }
    func removeChangeObserver(_ id: UUID) { changeObservers[id] = nil }
    func publish() {
        for observer in changeObservers.values { observer.yield(()) }
    }
    func assertScope(_ captured: AuthenticatedTeamScope, epoch capturedEpoch: UInt64) async throws {
        guard epoch == capturedEpoch, activeScope == captured, let auth,
              await auth.isAuthenticatedTeamScopeCurrent(captured) else { throw CompositionError.scopeChanged }
        guard epoch == capturedEpoch, activeScope == captured else { throw CompositionError.scopeChanged }
    }
}

extension MobileIrxRuntimeComposition: CmxIrohDeferredTransportProviding {}
