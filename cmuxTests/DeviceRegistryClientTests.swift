import Foundation
import Testing
import CMUXMobileCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the Mac device-registry re-registration policy. `statusUpdates()` fires
/// on connection changes as well as route changes, so the client must skip a
/// POST when only the connection set changed, register the off-state once when
/// routes clear, and re-register after an account/team switch even when the
/// routes are unchanged.
@Suite struct DeviceRegistryClientTests {
    private func route(host: String, port: Int, id: String = "r") throws -> CmxAttachRoute {
        try CmxAttachRoute(
            id: id,
            kind: .tailscale,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    private func reg(
        team: String?,
        tag: String = "default",
        routes: [CmxAttachRoute],
        sessions: [CmxLiveSession] = []
    ) -> DeviceRegistryClient.Registration {
        DeviceRegistryClient.Registration(teamID: team, tag: tag, routes: routes, sessions: sessions)
    }

    private func liveSession(
        id: String = "workspace-1",
        title: String = "Handoff",
        status: CmxLiveSessionStatus = .idle
    ) -> CmxLiveSession {
        CmxLiveSession(
            id: id,
            workspaceID: id,
            title: title,
            agent: "codex",
            status: status,
            lastActivityAt: 1_800_000_000
        )
    }

    @Test func initialEmptyRoutesDoNotRegister() {
        // Pairing off at launch: nothing was ever advertised, nothing to publish.
        let current = reg(team: "team-a", routes: [])
        #expect(DeviceRegistryClient.shouldReRegister(previous: nil, current: current) == false)
    }

    @Test func firstNonEmptyRoutesRegister() throws {
        let current = reg(team: "team-a", routes: [try route(host: "100.0.0.1", port: 51000)])
        #expect(DeviceRegistryClient.shouldReRegister(previous: nil, current: current) == true)
    }

    @Test func identicalScopeSkipsRegistration() throws {
        // A connection-only status tick: same team/tag/routes, must not re-POST.
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let previous = reg(team: "team-a", routes: routes)
        let current = reg(team: "team-a", routes: routes)
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == false)
    }

    @Test func changedRoutesReRegister() throws {
        // The Mac moved networks / rebound to a new port.
        let previous = reg(team: "team-a", routes: [try route(host: "100.0.0.1", port: 51000)])
        let current = reg(team: "team-a", routes: [try route(host: "100.9.9.9", port: 51999)])
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func changedLiveSessionStateReRegistersWithUnchangedRoutes() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let previous = reg(team: "team-a", routes: routes, sessions: [liveSession(status: .working)])
        let current = reg(team: "team-a", routes: routes, sessions: [liveSession(status: .needsInput)])
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func forcedLeaseRenewalReRegistersUnchangedLiveSessions() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let registration = reg(team: "team-a", routes: routes, sessions: [liveSession()])

        #expect(DeviceRegistryClient.shouldReRegister(
            previous: registration,
            current: registration,
            force: true
        ))
    }

    @Test func pairingOffSuppressesSessionDiscovery() {
        #expect(DeviceRegistryClient.advertisedSessions(routes: [], sessions: [liveSession()]).isEmpty)
    }

    @Test func advertisedSessionsStayWithinTheRegistrationWireBudget() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let oversizedTitle = String(repeating: "🚀", count: 10_000)
        let sessions = (0..<50).map { index in
            liveSession(id: "workspace-\(index)", title: oversizedTitle)
        }

        let advertised = DeviceRegistryClient.advertisedSessions(routes: routes, sessions: sessions)
        let encoded = try JSONEncoder().encode(advertised)
        let requestBody = try #require(DeviceRegistryClient.registrationBody(
            deviceID: "00000000-0000-4000-8000-000000000000",
            tag: "default",
            routes: routes,
            sessions: advertised,
            displayName: "Mac"
        ))

        #expect(encoded.count <= DeviceRegistryClient.maximumLiveSessionPayloadBytes)
        #expect(requestBody.count <= DeviceRegistryClient.maximumRequestBytes)
        #expect(advertised.allSatisfy { $0.title.unicodeScalars.count <= 160 })
    }

    @Test func registrationUsesCloudRendezvousRouteDisclosure() throws {
        let directAddress = "8.8.8.8:49152"
        let route = try CmxAttachRoute(
            id: "iroh",
            kind: .iroh,
            endpoint: .peer(
                identity: CmxIrohPeerIdentity(
                    endpointID: String(repeating: "a", count: 64)
                ),
                pathHints: [
                    try CmxIrohPathHint(
                        kind: .directAddress,
                        value: directAddress,
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                    try CmxIrohPathHint(
                        kind: .relayURL,
                        value: "https://relay.example.test/",
                        source: .native,
                        privacyScope: .publicInternet
                    ),
                ]
            )
        )
        let body = try #require(DeviceRegistryClient.registrationBody(
            deviceID: "00000000-0000-4000-8000-000000000000",
            tag: "default",
            routes: [route],
            sessions: [liveSession()],
            displayName: "Mac"
        ))
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(!text.contains(directAddress))
        #expect(text.contains("relay.example.test"))
    }

    @Test func teamSwitchReRegistersEvenWithUnchangedRoutes() throws {
        // Account/team switch with the same routes must register in the new team.
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let previous = reg(team: "team-a", routes: routes)
        let current = reg(team: "team-b", routes: routes)
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func clearingRoutesRegistersOnceToPublishOffState() throws {
        // Pairing turned off after having registered: publish the now-empty set
        // once so the registry no longer advertises stale routes for this Mac.
        let previous = reg(team: "team-a", routes: [try route(host: "100.0.0.1", port: 51000)])
        let current = reg(team: "team-a", routes: [])
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func stillEmptyAfterClearDoesNotReRegister() {
        // Once the empty off-state has been published, repeated empty ticks in
        // the same scope are no-ops.
        let previous = reg(team: "team-a", routes: [])
        let current = reg(team: "team-a", routes: [])
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == false)
    }
}
