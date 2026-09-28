import CmuxCloud
import CmuxCloudTui
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CloudPrivateRouteSelectionTests {
    @Test("Known device identities open one browser carrier without a redundant sidebar link")
    func browserProxyOnlyNeedsPreparationForFirstUse() {
        #expect(CloudMachineLinkManager.browserProxyNeedsTrustedListenerPreparation(deviceFingerprint: nil))
        #expect(!CloudMachineLinkManager.browserProxyNeedsTrustedListenerPreparation(
            deviceFingerprint: CloudTuiClientPaths.carrierDeviceMarker
        ))
        #expect(!CloudMachineLinkManager.browserProxyNeedsTrustedListenerPreparation(deviceFingerprint: "stored-device"))
    }

    private final class RefreshState: @unchecked Sendable {
        var routes: [String] = ["192.0.2.0/24"]
        var refreshes = 0
    }

    private func manager(hub: CloudWireGuardHub? = nil) -> CloudMachineLinkManager {
        CloudMachineLinkManager(
            paths: CloudTuiClientPaths(home: URL(fileURLWithPath: "/tmp/cmux-route-\(UUID().uuidString)")),
            clientURL: nil,
            hub: hub,
            hostThemeColors: { nil }
        )
    }

    private func refreshableHub(state: RefreshState, routesAfterRefresh: [String]) -> CloudWireGuardHub {
        let spawner = CloudWireGuardHubTests.FakeSpawner()
        return CloudWireGuardHub(configuration: .init(
            enroll: { .init(configPath: "/tmp/private-route.conf", routes: state.routes) },
            refreshEnrollment: {
                state.refreshes += 1
                state.routes = routesAfterRefresh
                return .init(configPath: "/tmp/private-route.conf", routes: state.routes)
            },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: URL(fileURLWithPath: "/tmp/private-route-hub-\(UUID().uuidString).sock"),
            spawner: spawner,
            waitUntilReady: { _ in },
            sleep: { try await Task.sleep(for: $0) },
            restartBackoff: [],
            idleGrace: .seconds(3600)
        ))
    }

    @Test("refreshes hub routes before selecting a newly added team address")
    func refreshesForNewTeamAddress() async throws {
        let state = RefreshState()
        let hub = refreshableHub(state: state, routesAfterRefresh: ["10.20.0.0/24"])
        let route = try await manager(hub: hub).resolvedPrivateRoute(
            machineID: "vm-team",
            through: .init(socketPath: "/unused", routes: ["192.0.2.0/24"]),
            addresses: ["10.20.0.2"]
        )
        #expect(route == "ws://10.20.0.2:1337/v1/link")
        #expect(state.refreshes == 1)
        await hub.stop()
    }

    @Test("still rejects an address that remains outside refreshed routes")
    func rejectsAfterUnsuccessfulRefresh() async {
        let state = RefreshState()
        let hub = refreshableHub(state: state, routesAfterRefresh: ["192.0.2.0/24"])
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await manager(hub: hub).resolvedPrivateRoute(
                machineID: "vm-team",
                through: .init(socketPath: "/unused", routes: ["192.0.2.0/24"]),
                addresses: ["10.20.0.2"]
            )
        }
        await hub.stop()
    }

    @Test func freshIPv6OnlyAddressReplacesAnOlderIPv4Route() async throws {
        let route = try await manager().resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["fd00::/8"]),
            fallbackRoute: "ws://10.16.0.2:1337/v1/link",
            addresses: ["fd00::2"]
        )
        #expect(route == "ws://[fd00::2]:1337/v1/link")
    }

    @Test func soleAddressInsideTheEnrolledRoutesWinsAfterFiltering() async throws {
        let route = try await manager().resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["fd00::/8"]),
            fallbackRoute: "ws://10.16.0.2:1337/v1/link",
            addresses: ["10.16.0.2", "fd00::2"]
        )
        #expect(route == "ws://[fd00::2]:1337/v1/link")
    }

    @Test func legacyCallerWithoutAddressCandidatesKeepsItsRoute() async throws {
        let route = try await manager().resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["10.16.0.0/24"]),
            fallbackRoute: "ws://10.16.0.2:1337/v1/link"
        )
        #expect(route == "ws://10.16.0.2:1337/v1/link")
    }

    @Test("Partial attach addresses retain the other discovered family", arguments: [false, true])
    func partialAddressesPreserveFallback(replacesIPv4: Bool) async throws {
        let path = "/tmp/cmux-route-\(UUID().uuidString).sock"
        let hub = try CloudLoopbackPortForwardTests.FakeSocksHub(unixSocketPath: path)
        try await hub.start()
        defer { hub.stop() }
        let manager = manager()
        await manager.setPrivateAddresses(["10.16.0.2", "fd00::2"], for: "vm-test")
        let currentIPv4 = replacesIPv4 ? "10.16.0.3" : "10.16.0.2"
        hub.refusedHosts = [currentIPv4]

        let route = try await manager.resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: path, routes: ["10.16.0.0/24", "fd00::/8"]),
            fallbackRoute: "ws://\(currentIPv4):1337/v1/link",
            addresses: [" \(currentIPv4) ", currentIPv4]
        )

        #expect(route == "ws://[fd00::2]:1337/v1/link")
        #expect(hub.connectTargets.filter { $0.host == currentIPv4 }.count == 1)
        if replacesIPv4 {
            #expect(!hub.connectTargets.contains { $0.host == "10.16.0.2" },
                    "An old address in a replaced family can now belong to another VM")
        }
    }

    @Test("A failed dual-stack probe returns an error so a retry probes both families again")
    func failedProbeDoesNotChooseAnUnreachableRoute() async throws {
        let path = "/tmp/cmux-route-\(UUID().uuidString).sock"
        let hub = try CloudLoopbackPortForwardTests.FakeSocksHub(unixSocketPath: path)
        try await hub.start()
        defer { hub.stop() }
        let manager = manager()
        await manager.setPrivateAddresses(["10.16.0.2", "fd00::2"], for: "vm-test")
        let ready = CloudWireGuardHub.Ready(socketPath: path, routes: ["10.16.0.0/24", "fd00::/8"])
        hub.refusedHosts = ["10.16.0.2", "fd00::2"]

        await #expect(throws: (any Error).self) {
            try await manager.resolvedPrivateRoute(machineID: "vm-test", through: ready)
        }
        hub.refusedHosts = ["10.16.0.2"]
        #expect(try await manager.resolvedPrivateRoute(machineID: "vm-test", through: ready)
                == "ws://[fd00::2]:1337/v1/link")
    }

    @Test("A legacy route outside the enrolled network is rejected by the shared resolver")
    func unenrolledLegacyRouteIsRejected() async {
        await #expect(throws: (any Error).self) {
            try await manager().resolvedPrivateRoute(
                machineID: "vm-test",
                through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["fd00::/8"]),
                fallbackRoute: "ws://10.16.0.2:1337/v1/link"
            )
        }
    }
}
