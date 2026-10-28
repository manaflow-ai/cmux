import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxMobileTransport
import CmuxMobileRPC
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The two halves of the bearer-token rule for device links. Route selection:
/// the token leaves this Mac over a Tailscale peer address only with the
/// pairing store's device-bound grant for that exact peer (or over DEBUG
/// loopback), in the host's priority order, and undialable kinds are skipped,
/// never downgraded. Host identity: the Mac that answers must prove it is the
/// device and app instance the row named before anything is subscribed.
@Suite("Devices: route selection and host identity")
struct DeviceRouteSelectorTests {
    private let studio = SurfaceDeviceInstanceID(deviceID: "22222222-2222-2222-2222-222222222222", tag: "default")

    private func route(
        _ id: String,
        kind: CmxAttachTransportKind,
        host: String,
        port: Int = 51000,
        priority: Int
    ) throws -> CmxAttachRoute {
        try CmxAttachRoute(id: id, kind: kind, endpoint: .hostPort(host: host, port: port), priority: priority)
    }

    /// The grant the pairing store would hold for `route` on `deviceID`.
    private func grant(for route: CmxAttachRoute, deviceID: String? = nil) -> CmxLegacyTailscaleAuthorizationEvidence? {
        guard case let .hostPort(host, port) = route.endpoint else { return nil }
        return try? CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: deviceID ?? studio.deviceID, host: host, port: port)
    }

    @Test("Another Mac's advertised loopback never replaces its Tailscale pairing", arguments: [false, true])
    func remoteMacRequiresTailscalePairing(hasGrant: Bool) throws {
        let loopback = try route("debug_loopback", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let tailscale = try route("tailscale", kind: .tailscale, host: "100.64.0.4", priority: 10)
        let selector = DeviceRouteSelector()
        if hasGrant {
            let selection = try selector.select(from: [loopback, tailscale], instance: studio) {
                self.grant(for: $0)
            }
            #expect(selection.route == tailscale)
            #expect(selection.evidence == grant(for: tailscale))
        } else {
            #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
                try selector.select(from: [loopback, tailscale], instance: studio) { _ in nil }
            }
        }
    }

    @Test("Automatic Iroh uses peer admission without creating a Tailscale bearer grant")
    func automaticIrohPrefersAuthenticatedPeer() throws {
        let iroh = try CmxAttachRoute(
            id: "iroh", kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: []),
            priority: 10
        )
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        let selection = try DeviceRouteSelector(allowsIroh: true).select(
            from: [tailscale, iroh], instance: studio
        ) { _ in nil }
        #expect(selection.route == iroh)
        #expect(selection.evidence == nil)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try DeviceRouteSelector().select(from: [tailscale, iroh], instance: studio) { _ in nil }
        }
    }

    @MainActor
    @Test("The production runtime keeps an authorized Tailscale route with or without Iroh", arguments: [false, true])
    func automaticIrohKeepsLegacyFallback(hasAutomaticClient: Bool) async throws {
        let suite = "DeviceRouteSelector-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = makeRuntime(defaults: defaults, hasAutomaticClient: hasAutomaticClient)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 10)

        #expect(runtime.supportedRouteKinds == (hasAutomaticClient ? [.iroh, .tailscale] : [.tailscale]))
        let selection = try runtime.routeSelector.select(from: [tailscale], instance: studio) {
            self.grant(for: $0)
        }
        #expect(selection.route == tailscale)
        let evidence = try #require(selection.evidence)
        #expect(evidence == grant(for: tailscale))
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try runtime.routeSelector.select(from: [tailscale], instance: studio) { _ in nil }
        }
        let peer = try runtime.forPeer(studio)
        let transport = try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
            route: selection.route,
            expectedPeerDeviceID: studio.deviceID,
            authorizationMode: .legacyTailscaleBearer(evidence)
        ))
        await transport.close()
    }

    @Test("Automatic connections never fall back to a saved Tailscale bearer route")
    func automaticTransportDoesNotDowngrade() throws {
        let selector = DeviceRouteSelector(allowsIroh: true, allowsLegacyTailscale: false)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        #expect(selector.supportedKinds == [.iroh])
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["tailscale"])) {
            try selector.select(from: [tailscale], instance: studio) { self.grant(for: $0) }
        }
    }

    @MainActor
    @Test("An unavailable Iroh peer falls back to an authorized Tailscale connection")
    func unavailableIrohConnectsOverAuthorizedTailscale() async throws {
        let iroh = try CmxAttachRoute(
            id: "iroh", kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: [])
        )
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        let evidence = try #require(grant(for: tailscale))
        var attempts: [DeviceRouteSelector.Selection] = []
        let connected = try await DeviceLinkConnectionAttempt(selector: DeviceRouteSelector(allowsIroh: true)).connect(
            routes: [tailscale, iroh], instance: studio, hostName: "Studio",
            grant: { self.grant(for: $0) }
        ) { selection in
            attempts.append(selection)
            if selection.route.kind == .iroh { throw DeviceLinkError.notConnected }
            return selection.route
        } authenticate: { $0 }
        #expect(connected == tailscale)
        #expect(attempts == [.init(route: iroh, evidence: nil), .init(route: tailscale, evidence: evidence)])
    }

    @MainActor
    @Test("Iroh refusals and identity failures never attempt a fallback connection")
    func deniedIrohDoesNotFallBack() async throws {
        let routes = try connectionRoutes()
        let failures: [any Error] = [
            IrxAdmissionDenied(code: .invalidGrant), IrxAdmissionDenied(code: .revoked),
            IrxAdmissionDenied(code: .identityMismatch), IrxAdmissionDenied(code: .protocolMismatch),
            IrxMacPeerAuthorization.Failure.revoked, IrxMacPeerAuthorization.Failure.notDiscoverable,
            DeviceLinkError.identityMismatch, DeviceLinkError.identityUnproven,
            MobileShellConnectionError.authorizationFailed("Denied"), CancellationError(),
        ]
        for failure in failures {
            var attempts: [CmxAttachTransportKind] = []
            await #expect(throws: (any Error).self) {
                try await DeviceLinkConnectionAttempt(selector: DeviceRouteSelector(allowsIroh: true)).connect(
                    routes: routes, instance: studio, hostName: "Studio",
                    grant: { self.grant(for: $0) }
                ) { selection -> CmxAttachRoute in
                    attempts.append(selection.route.kind)
                    if selection.route.kind == .iroh { throw failure }
                    return selection.route
                } authenticate: { $0 }
            }
            #expect(attempts == [.iroh])
        }
    }

    @MainActor
    @Test("Fallback requires a current grant and respects explicit opt-out", arguments: [false, true])
    func connectionFallbackRequiresCurrentGrant(allowsFallback: Bool) async throws {
        let routes = try connectionRoutes()
        var attempts: [CmxAttachTransportKind] = []
        var grantAvailable = true
        await #expect(throws: DeviceLinkError.notConnected) {
            try await DeviceLinkConnectionAttempt(selector: DeviceRouteSelector(
                allowsIroh: true, allowsLegacyTailscale: allowsFallback
            )).connect(
                routes: routes, instance: studio, hostName: "Studio",
                grant: { grantAvailable ? self.grant(for: $0) : nil }
            ) { selection -> CmxAttachRoute in
                attempts.append(selection.route.kind)
                if selection.route.kind == .iroh {
                    if allowsFallback { grantAvailable = false }
                    throw DeviceLinkError.notConnected
                }
                return selection.route
            } authenticate: { $0 }
        }
        #expect(attempts == [.iroh])
    }

    @MainActor
    @Test("Cancellation during an Iroh attempt prevents a fallback dial")
    func cancelledIrohDoesNotFallBack() async throws {
        let routes = try connectionRoutes()
        let task = Task { @MainActor in
            var attempts: [CmxAttachTransportKind] = []
            await #expect(throws: CancellationError.self) {
                try await DeviceLinkConnectionAttempt(selector: DeviceRouteSelector(allowsIroh: true)).connect(
                    routes: routes, instance: studio, hostName: "Studio",
                    grant: { self.grant(for: $0) }
                ) { selection -> CmxAttachRoute in
                    attempts.append(selection.route.kind)
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw DeviceLinkError.notConnected
                } authenticate: { $0 }
            }
            #expect(attempts == [.iroh])
        }
        await task.value
    }

    private func connectionRoutes() throws -> [CmxAttachRoute] {
        try [
            CmxAttachRoute(id: "iroh", kind: .iroh,
                endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: [])),
            route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0),
        ]
    }

    @MainActor
    @Test("An RPC closure after successful Iroh admission never triggers fallback")
    func admittedIrohClosureDoesNotFallBack() async throws {
        let routes = try connectionRoutes()
        var attempts: [CmxAttachTransportKind] = []
        await #expect(throws: MobileShellConnectionError.self) {
            try await DeviceLinkConnectionAttempt(selector: DeviceRouteSelector(allowsIroh: true)).connect(
                routes: routes, instance: studio, hostName: "Studio", grant: { self.grant(for: $0) }
            ) { selection in
                attempts.append(selection.route.kind)
                return selection
            } authenticate: { _ -> Void in
                // RPC deliberately erases a post-admission revocation to this error.
                throw MobileShellConnectionError.connectionClosed
            }
        }
        #expect(attempts == [.iroh])
    }

    @MainActor
    @Test("Unpairing retires the selected Tailscale client even while Iroh remains discoverable", arguments: [false, true])
    func unpairingRetiresFallbackConnection(connected: Bool) async throws {
        let suite = "DeviceRouteSelector-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = makeRuntime(defaults: defaults, hasAutomaticClient: true)
        let routes = try connectionRoutes()
        let tailscale = try #require(routes.first { $0.kind == .tailscale })
        let evidence = try #require(grant(for: tailscale))
        let authorization = DeviceRouteTestAuthorization(evidence: evidence)
        let record = DeviceDirectoryRecord(instance: studio, deviceName: "Studio", platform: "mac",
            bundleID: nil, presenceState: .online, isPaired: true, lastSeenAt: nil, routes: routes,
            ownerUserID: "test", accountTrust: .sameAccount)
        let link = DeviceLink(record: record, runtime: runtime, authorization: authorization)
        link.update(record: record)
        let client = MobileCoreRPCClient(runtime: try runtime.forPeer(studio), route: tailscale,
            ticket: try CmxAttachTicket(workspaceID: "main", terminalID: nil, macDeviceID: studio.deviceID,
                macDisplayName: "Studio", routes: [tailscale]),
            allowsStackAuthFallback: true, legacyTailscaleAuthorizationEvidence: evidence)
        link.connection = .init(client: client, selection: .init(route: tailscale, evidence: evidence))
        if connected { link.transition(link.applyPolicy(.connectSucceeded)) }
        link.authorizationDidChange()
        #expect(link.connection?.client === client)
        #expect(link.isConnected == connected)

        authorization.evidence = nil
        link.authorizationDidChange()
        #expect(link.connection == nil)
        #expect(!link.isConnected)
        #expect(link.phase == .connecting(attempt: 1))
        // The replacement's main-actor task has not run; cancel it before yielding.
        link.stop()
        await #expect(throws: (any Error).self) { try await client.connectTransport() }
        await client.disconnectAndWaitForTransportDrain()
    }

    @MainActor
    @Test("The per-peer runtime retains real fallback transports and their authorization checks")
    func automaticRuntimeKeepsFallbackTransport() async throws {
        let suite = "DeviceRouteSelector-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An explicit selector isolates per-peer registration from the default-selector regression.
        let runtime = makeRuntime(defaults: defaults, hasAutomaticClient: true,
            routeSelector: DeviceRouteSelector(allowsDebugLoopback: true, allowsIroh: true))
        let peer = try runtime.forPeer(studio)
        let iroh = try CmxAttachRoute(
            id: "iroh", kind: .iroh,
            endpoint: .peer(identity: CmxIrohPeerIdentity(endpointID: String(repeating: "a", count: 64)), pathHints: []),
            priority: 10
        )
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        let evidence = try #require(grant(for: tailscale))
        let selection = try peer.routeSelector.select(from: [tailscale, iroh], instance: studio) {
            self.grant(for: $0)
        }
        #expect(selection.route == iroh)
        #expect(selection.evidence == nil)
        let automatic = try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
            route: iroh, expectedPeerDeviceID: studio.deviceID, authorizationMode: .transportAdmission
        ))
        await automatic.close()
        #expect(throws: CmxIrohByteTransportError.missingPeerIntent) {
            try peer.transportFactory.makeTransport(for: iroh)
        }
        let fallback = try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
            route: tailscale, expectedPeerDeviceID: studio.deviceID, authorizationMode: .legacyTailscaleBearer(evidence)
        ))
        await fallback.close()
        #expect(throws: CmxNetworkByteTransportError.authorizationIntentRequired) {
            try peer.transportFactory.makeTransport(for: tailscale)
        }
        let wrongDevice = try #require(grant(for: tailscale, deviceID: "33333333-3333-3333-3333-333333333333"))
        let wrongHost = try CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: studio.deviceID, host: "100.64.0.2", port: 51000)
        let wrongPort = try CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: studio.deviceID, host: "100.64.0.1", port: 51001)
        let invalidModes: [CmxTransportAuthorizationMode] = [
            .stackBearer, .transportAdmission, .legacyTailscaleBearer(wrongDevice),
            .legacyTailscaleBearer(wrongHost), .legacyTailscaleBearer(wrongPort),
        ]
        for mode in invalidModes {
            #expect(throws: CmxNetworkByteTransportError.tailscaleAuthorizationUnavailable) {
                try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
                    route: tailscale, expectedPeerDeviceID: studio.deviceID, authorizationMode: mode
                ))
            }
        }
        let loopback = try route("loop", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let local = try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
            route: loopback, expectedPeerDeviceID: studio.deviceID, authorizationMode: .stackBearer
        ))
        await local.close()
    }

    @MainActor
    @Test("An explicit Iroh-only policy excludes authorized Tailscale from the peer factory")
    func automaticRuntimeRespectsFallbackOptOut() throws {
        let suite = "DeviceRouteSelector-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = makeRuntime(defaults: defaults, hasAutomaticClient: true,
            routeSelector: DeviceRouteSelector(allowsIroh: true, allowsLegacyTailscale: false))
        let peer = try runtime.forPeer(studio)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        let evidence = try #require(grant(for: tailscale))
        #expect(peer.supportedRouteKinds == [.iroh])
        #expect(throws: CmxRouteTransportFactoryError.unsupportedRouteKind(.tailscale)) {
            try peer.transportFactory.makeTransport(for: CmxByteTransportRequest(
                route: tailscale, expectedPeerDeviceID: studio.deviceID, authorizationMode: .legacyTailscaleBearer(evidence)
            ))
        }
    }

    @MainActor
    private func makeRuntime(
        defaults: UserDefaults,
        hasAutomaticClient: Bool,
        routeSelector: DeviceRouteSelector? = nil
    ) -> DeviceLinkRuntime {
        let config = AuthConfig(stack: CMUXAuthConfig(projectId: "test", publishableClientKey: "test"),
            magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback", apiBaseURL: "http://127.0.0.1:1")
        let auth = AuthCoordinator(
            client: StackAuthClient(config: config, tokenStore: .memory, noAutomaticPrefetch: true),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(), config: config,
            launch: AuthLaunchOptions(clearAuthRequested: false, mockDataEnabled: false, environment: [:], includesDevAuth: false))
        let client = hasAutomaticClient ? DeviceIrxClient(context: { throw DeviceLinkError.notConnected },
            journal: IrxJournal(subsystem: "dev.cmux.tests", category: "device-route-selector")) : nil
        return DeviceLinkRuntime(
            tokens: HiveAccountTokenSource(accountScopedAuth: auth,
                identity: AuthenticatedSessionIdentity(generation: 0, accountID: "test")),
            automaticClient: client, routeSelector: routeSelector
        )
    }

    @Test("A Tailscale route dials only with a device-bound grant for its exact peer")
    func tailscaleNeedsGrant() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.1", priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in nil }
        }
        let granted = try #require(grant(for: tailscale))
        let selection = try selector.select(from: [tailscale], instance: studio) { _ in granted }
        #expect(selection.route.id == "ts")
        #expect(selection.evidence == granted)
        // A grant for another device, or for another peer, never authorizes this dial.
        let otherDevice = grant(for: tailscale, deviceID: "33333333-3333-3333-3333-333333333333")
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in otherDevice }
        }
        let otherPeer = try CmxLegacyTailscaleAuthorizationEvidence(macDeviceID: studio.deviceID, host: "100.64.0.9", port: 51000)
        #expect(throws: DeviceRouteSelector.SelectionError.needsAuthorization) {
            try selector.select(from: [tailscale], instance: studio) { _ in otherPeer }
        }
    }

    @Test("The lowest-priority granted Tailscale route wins, ties by id; ungranted routes are passed over")
    func prefersGrantedByPriority() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let b = try route("b", kind: .tailscale, host: "100.64.0.2", priority: 5)
        let a = try route("a", kind: .tailscale, host: "100.64.0.1", priority: 5)
        let z = try route("z", kind: .tailscale, host: "100.64.0.3", priority: 1)
        let all = try selector.select(from: [b, a, z], instance: studio) { self.grant(for: $0) }
        #expect(all.route.id == "z")
        let tie = try selector.select(from: [b, a], instance: studio) { self.grant(for: $0) }
        #expect(tie.route.id == "a")
        let onlyB = try selector.select(from: [b, a, z], instance: studio) { $0.id == "b" ? self.grant(for: $0) : nil }
        #expect(onlyB.route.id == "b")
        #expect(DeviceRouteSelector.ordered([b, a, z]).map(\.id) == ["z", "a", "b"])
    }

    @Test("Loopback is dialable only when the build allows it and only on a loopback host, with no grant")
    func loopbackPolicy() throws {
        let loop = try route("loop", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let selection = try DeviceRouteSelector(allowsDebugLoopback: true).select(from: [loop], instance: studio) { _ in nil }
        #expect(selection.route.id == "loop")
        #expect(selection.evidence == nil)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["debug_loopback"])) {
            try DeviceRouteSelector(allowsDebugLoopback: false).select(from: [loop], instance: studio) { _ in nil }
        }
        let spoofed = try route("spoof", kind: .debugLoopback, host: "100.64.0.4", priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["debug_loopback"])) {
            try DeviceRouteSelector(allowsDebugLoopback: true).select(from: [spoofed], instance: studio) { _ in nil }
        }
    }

    @Test("Priority orders across kinds; an ungranted Tailscale route still lets loopback dial")
    func priorityAcrossKinds() throws {
        let loop = try route("loop", kind: .debugLoopback, host: "127.0.0.1", priority: 0)
        let tailscale = try route("ts", kind: .tailscale, host: "100.64.0.4", priority: 5)
        let selector = DeviceRouteSelector(allowsDebugLoopback: true)
        let byPriority = try selector.select(from: [tailscale, loop], instance: studio) { self.grant(for: $0) }
        #expect(byPriority.route.id == "loop")
        let release = try DeviceRouteSelector(allowsDebugLoopback: false).select(from: [tailscale, loop], instance: studio) { self.grant(for: $0) }
        #expect(release.route.id == "ts")
        let ungranted = try selector.select(from: [tailscale, loop], instance: studio) { _ in nil }
        #expect(ungranted.route.id == "loop")
    }

    @Test("Non-Tailscale hosts and undialable kinds are skipped, never downgraded")
    func skipsUndialableRoutes() throws {
        let selector = DeviceRouteSelector(allowsDebugLoopback: false)
        let lan = try route("lan", kind: .tailscale, host: "192.168.1.20", priority: 0)
        let websocket = try CmxAttachRoute(id: "ws", kind: .websocket, endpoint: .url("wss://relay.example/attach"), priority: 0)
        #expect(throws: DeviceRouteSelector.SelectionError.noDialableRoute(kinds: ["tailscale", "websocket"])) {
            try selector.select(from: [lan, websocket], instance: studio) { self.grant(for: $0) }
        }
        #expect(throws: DeviceRouteSelector.SelectionError.noRoutes) {
            try selector.select(from: [], instance: studio) { _ in nil }
        }
        #expect(selector.supportedKinds == [.tailscale])
        #expect(DeviceRouteSelector(allowsDebugLoopback: true).supportedKinds == [.tailscale, .debugLoopback])
    }

    @Test("The host must prove the exact device and app instance the row dialed")
    func hostIdentity() throws {
        func status(_ object: [String: Any]) throws -> MobileHostStatusResponse {
            try JSONDecoder().decode(MobileHostStatusResponse.self, from: JSONSerialization.data(withJSONObject: object))
        }
        try DeviceLinkHostIdentity.verify(
            status: status(["mac_device_id": studio.deviceID.uppercased(), "mac_instance_tag": " default "]),
            expected: studio
        )
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["capabilities": []]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityUnproven) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID, "mac_instance_tag": ""]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityMismatch) {
            try DeviceLinkHostIdentity.verify(status: status(["mac_device_id": studio.deviceID, "mac_instance_tag": "issue-8001"]), expected: studio)
        }
        #expect(throws: DeviceLinkError.identityMismatch) {
            try DeviceLinkHostIdentity.verify(
                status: status(["mac_device_id": "33333333-3333-3333-3333-333333333333", "mac_instance_tag": "default"]),
                expected: studio
            )
        }
        #expect(throws: DeviceLinkError.malformedResponse("mobile.host.status")) {
            try DeviceLinkHostIdentity.verify(statusResponse: Data("nope".utf8), expected: studio)
        }
        let wire = try JSONSerialization.data(withJSONObject: ["mac_device_id": studio.deviceID, "mac_instance_tag": "default", "capabilities": ["x"]])
        try DeviceLinkHostIdentity.verify(statusResponse: wire, expected: studio)
    }
}
