import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileRPC
import CmuxV3Native
import CmuxV3Transport
import Foundation

/// Owns the v3 endpoint for one authenticated team. The endpoint and grant
/// provider are recreated on a team transition, so no transport identity or
/// cached permission crosses tenants.
public actor MobileV3RuntimeComposition {
    public struct Configuration: Sendable {
        public let controlOrigin: URL
        public let audience: String
        public let authorityKeys: [String: Data]
        public let keychainAccessGroup: String?

        public init(controlOrigin: URL, audience: String, authorityKeys: [String: Data], keychainAccessGroup: String? = nil) throws {
            guard controlOrigin.scheme?.lowercased() == "https" || controlOrigin.host == "127.0.0.1" || controlOrigin.host == "localhost" else {
                throw Error.invalidConfiguration
            }
            guard !audience.isEmpty, !authorityKeys.isEmpty, authorityKeys.count <= 32,
                  authorityKeys.values.allSatisfy({ $0.count == 32 }) else { throw Error.invalidConfiguration }
            self.controlOrigin = controlOrigin
            self.audience = audience
            self.authorityKeys = authorityKeys
            self.keychainAccessGroup = keychainAccessGroup
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidConfiguration
        case notSignedIn
        case unavailable
        case scopeChanged
    }

    public nonisolated let configuration: Configuration
    private var endpoint: NativeEndpoint?
    private var factory: CmxV3ByteTransportFactory?
    private var scope: AuthenticatedTeamScope?
    private var desiredScope: AuthenticatedTeamScope?
    private var authTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var revocationTask: Task<Void, Never>?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public func configure(auth: AuthCoordinator) async {
        authTask?.cancel()
        authTask = Task { [weak self] in
            guard let self else { return }
            for await next in await auth.authenticatedTeamScopes() {
                await self.apply(scope: next, auth: auth)
            }
        }
    }

    public func close() {
        authTask?.cancel()
        authTask = nil
        activationTask?.cancel()
        activationTask = nil
        revocationTask?.cancel()
        revocationTask = nil
        endpoint?.close()
        endpoint = nil
        factory = nil
        scope = nil
        desiredScope = nil
    }

    public func transport(for request: CmxByteTransportRequest) async throws -> any CmxByteTransport {
        guard let factory, scope != nil else { throw Error.notSignedIn }
        return try factory.makeTransport(for: request)
    }

    public func terminalLane(for request: CmxByteTransportRequest, surfaceID: String, cursor: UInt64?) async throws -> any MobileTerminalLaneConnection {
        guard let factory else { throw Error.notSignedIn }
        return MobileV3TerminalLane(
            transport: try factory.makeLaneTransport(for: request, kind: 2, resource: "terminal:\(surfaceID)", cursor: cursor),
            cursor: cursor
        )
    }

    public func terminalInputLane(for request: CmxByteTransportRequest, surfaceID: String) async throws -> any MobileTerminalLaneConnection {
        guard let factory else { throw Error.notSignedIn }
        return MobileV3TerminalLane(
            transport: try factory.makeLaneTransport(for: request, kind: 3, resource: "terminal:\(surfaceID)"),
            cursor: Optional<UInt64>.none
        )
    }

    public func artifactLane(for request: CmxByteTransportRequest, resourceID: String, offset: UInt64) async throws -> any MobileArtifactLaneConnection {
        guard let factory else { throw Error.notSignedIn }
        return MobileV3ArtifactLane(transport: try factory.makeLaneTransport(for: request, kind: 4, resource: resourceID, cursor: offset))
    }

    public func simulatorLane(for request: CmxByteTransportRequest, panelID: String) async throws -> any MobileSimulatorStreamLaneConnection {
        guard let factory else { throw Error.notSignedIn }
        return MobileV3SimulatorStreamLane(transport: try factory.makeLaneTransport(for: request, kind: 5, resource: "simulator:\(panelID)"))
    }

    private func apply(scope next: AuthenticatedTeamScope?, auth: AuthCoordinator) async {
        guard desiredScope != next else { return }
        desiredScope = next
        activationTask?.cancel()
        activationTask = nil
        revocationTask?.cancel()
        revocationTask = nil
        endpoint?.close()
        endpoint = nil
        factory = nil
        scope = nil
        guard let next else { return }
        activationTask = Task { [weak self] in
            guard let self else { return }
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    try await self.provision(next, auth: auth)
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func provision(_ next: AuthenticatedTeamScope, auth: AuthCoordinator) async throws {
        let store = MobileV3IdentityStore(
            service: "dev.cmux.transport-v3.\(configuration.audience)",
            accessGroup: configuration.keychainAccessGroup
        )
        let seed = try store.seed()
        let deviceID = try store.deviceID()
        let signingKey = try CmxV3SigningKey(rawRepresentation: seed)
        let endpoint = try await NativeEndpoint.create(
            seed: seed, team: next.teamID, authorityKeys: configuration.authorityKeys
        )
        _ = try await endpoint.listen(
            address: "/ip4/0.0.0.0/udp/0/quic-v1",
            operation: CmuxV3Native.Operation()
        )
        let advertisedAddresses = try await endpoint.addresses(operation: CmuxV3Native.Operation())
            .compactMap { address -> String? in
                guard !address.isEmpty, !address.contains("/p2p/") else { return nil }
                return "\(address)/p2p/\(endpoint.peerId())"
            }
        let provider = try CmxV3HTTPGrantProvider.Configuration(
            origin: configuration.controlOrigin,
            audience: configuration.audience,
            team: next.teamID,
            deviceID: deviceID.uuidString,
            signingKey: signingKey,
            accessToken: { try await auth.accessToken() },
            userID: {
                let snapshot = try await auth.authenticatedSessionSnapshot()
                return snapshot.accountID
            }
        )
        let grants = CmxV3HTTPGrantProvider(configuration: provider)
        try await grants.enroll(peerID: endpoint.peerId(), deviceID: deviceID, addresses: advertisedAddresses)
        guard desiredScope == next else {
            endpoint.close()
            throw Error.scopeChanged
        }
        self.endpoint = endpoint
        self.factory = CmxV3ByteTransportFactory(endpoint: endpoint, grants: grants)
        self.scope = next
        revocationTask = Task { [weak self, weak endpoint] in
            var sequence: Int64 = 0
            while !Task.isCancelled {
                do {
                    let events = try await grants.revocationEvents(afterSequence: sequence)
                    for event in events.sorted(by: { $0.sequence < $1.sequence }) {
                        guard event.sequence > sequence else { continue }
                        try await endpoint?.applyRevocationUpdate(token: event.update)
                        sequence = event.sequence
                    }
                } catch {
                    // Keep the last accepted cursor and retry. The endpoint's
                    // strict sequence check rejects gaps until the feed catches up.
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Deferred factory used by the existing RPC graph while the v3 endpoint
/// performs asynchronous Stack enrollment. It never falls back to another
/// transport kind and keeps the route request intact until activation.
public struct MobileV3DeferredTransportFactory: CmxRouteAwareByteTransportFactory {
    public let supportedKinds: [CmxAttachTransportKind] = [.v3]
    private let runtime: MobileV3RuntimeComposition

    public init(runtime: MobileV3RuntimeComposition) { self.runtime = runtime }

    public func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        try route.validate()
        return MobileV3DeferredByteTransport(runtime: runtime, route: route)
    }

    public func makeTransport(for request: CmxByteTransportRequest) throws -> any CmxByteTransport {
        try request.route.validate()
        return MobileV3DeferredByteTransport(runtime: runtime, request: request)
    }
}

private actor MobileV3DeferredByteTransport: CmxByteTransport {
    private let runtime: MobileV3RuntimeComposition
    private let request: CmxByteTransportRequest
    private var transport: (any CmxByteTransport)?
    private var closed = false

    init(runtime: MobileV3RuntimeComposition, route: CmxAttachRoute) {
        self.runtime = runtime
        request = CmxByteTransportRequest(route: route, expectedPeerDeviceID: nil, authorizationMode: .transportAdmission)
    }

    init(runtime: MobileV3RuntimeComposition, request: CmxByteTransportRequest) {
        self.runtime = runtime
        self.request = request
    }

    func connect() async throws { try await current().connect() }
    func receive() async throws -> Data? { try await current().receive() }
    func send(_ data: Data) async throws { try await current().send(data) }
    func close() async {
        closed = true
        await transport?.close()
        transport = nil
    }

    private func current() async throws -> any CmxByteTransport {
        guard !closed else { throw MobileV3RuntimeComposition.Error.notSignedIn }
        if let transport { return transport }
        let value = try await runtime.transport(for: request)
        guard !closed else {
            await value.close()
            throw MobileV3RuntimeComposition.Error.notSignedIn
        }
        transport = value
        return value
    }
}
