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
/// routes clear, re-register after an account/team switch even when the
/// routes are unchanged, and re-register on a rename (the display name is part
/// of the dedup key). Also covers the persisted registered-team bookkeeping
/// that sign-out deregistration replays.
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
        displayName: String? = nil
    ) -> DeviceRegistryClient.Registration {
        DeviceRegistryClient.Registration(teamID: team, tag: tag, routes: routes, displayName: displayName)
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

    @Test func renameReRegistersEvenWithUnchangedRoutes() throws {
        // The display name is part of the dedup key: a rename with identical
        // team/tag/routes must re-POST so the phone's list shows the new name
        // on the next tick instead of never.
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let previous = reg(team: "team-a", routes: routes, displayName: "Studio")
        let current = reg(team: "team-a", routes: routes, displayName: "Studio Pro")
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == true)
    }

    @Test func unchangedNameDoesNotReRegister() throws {
        let routes = [try route(host: "100.0.0.1", port: 51000)]
        let previous = reg(team: "team-a", routes: routes, displayName: "Studio")
        let current = reg(team: "team-a", routes: routes, displayName: "Studio")
        #expect(DeviceRegistryClient.shouldReRegister(previous: previous, current: current) == false)
    }

    @Test func initialEmptyRoutesWithANameStillDoNotRegister() {
        // The never-registered baseline adopts the current name, so a Mac with
        // pairing off does not POST just because it has a display name.
        let current = reg(team: "team-a", routes: [], displayName: "Studio")
        #expect(DeviceRegistryClient.shouldReRegister(previous: nil, current: current) == false)
    }

    // MARK: - Registered-team bookkeeping

    @Test func teamMarkerEncodesTheDefaultTeamAsEmpty() {
        // A registration with no explicit team resolves server-side; the
        // persisted marker must replay the same header-less request.
        #expect(DeviceRegistryClient.teamMarker(nil) == "")
        #expect(DeviceRegistryClient.teamMarker("team-a") == "team-a")
    }

    @Test func addingTeamMarkerDedupesAndSorts() {
        let markers = DeviceRegistryClient.addingTeamMarker("team-b", to: ["team-c", "team-a"])
        #expect(markers == ["team-a", "team-b", "team-c"])
        let repeated = DeviceRegistryClient.addingTeamMarker("team-b", to: markers)
        #expect(repeated == ["team-a", "team-b", "team-c"])
    }

    @Test func removingTeamMarkerRemovesOnlyThatTeam() {
        let markers = DeviceRegistryClient.removingTeamMarker("team-b", from: ["team-a", "team-b", "team-c"])
        #expect(markers == ["team-a", "team-c"])
        // Removing an absent marker is a no-op, not an error: a DELETE retry
        // after a partial sign-out must be idempotent.
        #expect(DeviceRegistryClient.removingTeamMarker("team-x", from: markers) == ["team-a", "team-c"])
    }

    @Test func registeredTeamsKeyIsTagScoped() {
        // Parallel tagged dev builds share UserDefaults.standard; the key must
        // isolate their instance rows so one build's sign-out cannot
        // deregister another's.
        #expect(
            DeviceRegistryClient.registeredTeamsDefaultsKey(tag: "default")
                != DeviceRegistryClient.registeredTeamsDefaultsKey(tag: "nightly")
        )
    }
}
