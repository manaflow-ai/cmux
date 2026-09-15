public import CMUXMobileCore
import CmuxAuthRuntime
public import CmuxIrohTransport
import CmuxIrxTransport
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

    public nonisolated let configuration: MobileIrohV2Configuration
    public nonisolated var tag: String { configuration.buildTag }
    public nonisolated var forceRelayOnly: Bool { configuration.forceRelayOnly }
    public nonisolated var transportFactory: CmxConnectivityDeferredTransportFactory {
        CmxConnectivityDeferredTransportFactory(provider: self)
    }
    let journal: IrxJournal
    let installation: MobileIrohV2InstallationStore
    let localPaths: MobileIrohV2LocalPathStore
    let stateStore: V2FileStateStore
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
    var enginesByPeer: [String: IrxPeerEngine] = [:]
    var dialIntentByPeer: [String: DialIntent] = [:]
    var activeDialIntentByPeer: [String: DialIntent] = [:]
    var expectedDeviceIDByPeer: [String: String] = [:]
    var controlLaneClaims = MobileIrxControlLaneClaims()
    var claimedEventSessions: [String: String] = [:]
    var changeObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    var launchTime = Date()
    var backgroundTime: Date?
    var applicationActive = true
    var activityGeneration: UInt64 = 0
    var admittedSessionCount = 0

    /// Dependencies are owned here; authentication is supplied later without copying its persistence.
    public init(configuration: MobileIrohV2Configuration, keychainAccessGroup: String? = nil,
                session: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = session
        localPaths = MobileIrohV2LocalPathStore(root: configuration.stateDirectory)
        installation = MobileIrohV2InstallationStore(configuration: configuration, accessGroup: keychainAccessGroup)
        stateStore = V2FileStateStore(rootDirectory: configuration.stateDirectory, fileManager: FileManager())
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
