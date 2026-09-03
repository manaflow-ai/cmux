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

    private func reg(team: String?, tag: String = "default", routes: [CmxAttachRoute]) -> DeviceRegistryClient.Registration {
        DeviceRegistryClient.Registration(teamID: team, tag: tag, routes: routes)
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

    private func response(retryAfter: String?) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://cmux.com/api/devices"))
        var headers: [String: String] = [:]
        if let retryAfter { headers["Retry-After"] = retryAfter }
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ))
    }

    @Test("a throttled registry response supplies its retry floor")
    func retryAfterParsing() throws {
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: "60")) == 60)
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: " 30 ")) == 30)
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: nil)) == nil)
        // An HTTP-date Retry-After, a zero, a negative, and anything beyond a
        // day are all refused so a malformed header cannot silence the client.
        #expect(try DeviceRegistryClient.retryAfterSeconds(
            response(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: "0")) == nil)
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: "-5")) == nil)
        #expect(try DeviceRegistryClient.retryAfterSeconds(response(retryAfter: "90000")) == nil)
    }

    @Test("registration failures back off instead of retrying on the next status tick")
    func failureBackoffGrows() {
        // A failed POST leaves the registration scope unrecorded, so every
        // connection or pairing transition used to spend another request.
        let schedule = DeviceRegistryClient.retrySchedule
        let first = schedule.delay(
            failureCount: 0, retryAfterSeconds: nil, jitterUnitInterval: 0)
        let third = schedule.delay(
            failureCount: 2, retryAfterSeconds: nil, jitterUnitInterval: 0)
        let saturated = schedule.delay(
            failureCount: 99, retryAfterSeconds: nil, jitterUnitInterval: 0)
        #expect(first == 5)
        #expect(third == 20)
        #expect(saturated == 600)
    }

    @Test("a server retry floor outranks the local backoff")
    func failureBackoffHonorsRetryAfter() {
        let schedule = DeviceRegistryClient.retrySchedule
        let throttled = schedule.delay(
            failureCount: 0, retryAfterSeconds: 120, jitterUnitInterval: 0)
        #expect(throttled == 120)
    }
}
