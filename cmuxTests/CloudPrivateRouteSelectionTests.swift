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

    private func manager() -> CloudMachineLinkManager {
        CloudMachineLinkManager(
            paths: CloudTuiClientPaths(home: URL(fileURLWithPath: "/tmp/cmux-route-\(UUID().uuidString)")),
            clientURL: nil,
            hub: nil,
            hostThemeColors: { nil }
        )
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

    // MARK: - Fresh machine dial

    @Test func freshDialOffsetsStartFastAndStopAtTheBudget() {
        let offsets = CloudMachineLinkManager.freshDialOffsets(budget: .seconds(8))
        #expect(Array(offsets.prefix(8)) == [
            .zero, .milliseconds(150), .milliseconds(300), .milliseconds(500),
            .milliseconds(800), .milliseconds(1200), .milliseconds(1600), .milliseconds(2000)
        ])
        #expect(offsets.count > 8)
        #expect(offsets.last.map { $0 <= .seconds(8) } == true)
        #expect(offsets == offsets.sorted())
        #expect(CloudMachineLinkManager.freshDialOffsets(budget: .milliseconds(500))
                == [.zero, .milliseconds(150), .milliseconds(300), .milliseconds(500)])
    }

    /// Records dial attempts and repairs from `@Sendable` closures.
    private final class DialLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRoutes: [String] = []
        private var storedRepairs = 0
        var routes: [String] { lock.withLock { storedRoutes } }
        var repairs: Int { lock.withLock { storedRepairs } }
        func dialed(_ route: String) -> Int {
            lock.withLock {
                storedRoutes.append(route)
                return storedRoutes.count
            }
        }
        func repaired() { lock.withLock { storedRepairs += 1 } }
    }

    @Test func freshDialRetriesUntilTheDaemonAnswersWithoutTouchingTheControlPlane() async throws {
        let log = DialLog()
        let connected = try await manager().connectFreshMachine(
            machineID: "vm-fresh", route: "ws://10.16.0.7:1337/v1/link", session: "cloud",
            budget: .seconds(2), attemptTimeout: .milliseconds(50),
            repair: { log.repaired(); return nil },
            dial: { route, _ in
                guard log.dialed(route) >= 3 else { throw CloudMachineLink.LinkError.timedOut }
                return CloudMachineLink.Connected(socketPath: "/tmp/fresh.sock", session: "cloud")
            }
        )
        #expect(connected == CloudMachineLink.Connected(socketPath: "/tmp/fresh.sock", session: "cloud"))
        #expect(log.routes.count == 3)
        #expect(log.repairs == 0)
    }

    @Test func exhaustedBudgetRepairsThroughTheControlPlaneAndDialsOnceMore() async throws {
        let log = DialLog()
        let repairedRoute = "ws://10.16.0.8:1337/v1/link"
        let connected = try await manager().connectFreshMachine(
            machineID: "vm-fresh", route: "ws://10.16.0.7:1337/v1/link", session: "cloud",
            budget: .milliseconds(300), attemptTimeout: .milliseconds(50),
            repair: { log.repaired(); return repairedRoute },
            dial: { route, _ in
                _ = log.dialed(route)
                guard route == repairedRoute else { throw CloudMachineLink.LinkError.timedOut }
                return CloudMachineLink.Connected(socketPath: "/tmp/repaired.sock", session: "cloud")
            }
        )
        #expect(connected.socketPath == "/tmp/repaired.sock")
        #expect(log.repairs == 1)
        #expect(log.routes == Array(repeating: "ws://10.16.0.7:1337/v1/link", count: 3) + [repairedRoute])
    }

    @Test func aFailedRepairDialSurfacesTheLastLinkError() async throws {
        let log = DialLog()
        await #expect(throws: CloudMachineLink.LinkError.self) {
            try await manager().connectFreshMachine(
                machineID: "vm-fresh", route: "ws://10.16.0.7:1337/v1/link", session: "cloud",
                budget: .milliseconds(150), attemptTimeout: .milliseconds(50),
                repair: { log.repaired(); return nil },
                dial: { route, _ in
                    _ = log.dialed(route)
                    throw CloudMachineLink.LinkError.timedOut
                }
            )
        }
        #expect(log.repairs == 1)
        #expect(log.routes.count == 3, "two budgeted attempts, then exactly one more after the repair")
    }

    @Test func freshDialFailsFastWithoutAClientOrARoute() async {
        let started = ContinuousClock.now
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await manager().connectFreshMachine(
                machineID: "vm-fresh", route: "ws://10.16.0.7:1337/v1/link", session: "cloud"
            )
        }
        await #expect(throws: CloudMachineLinkManager.ManagerError.self) {
            try await manager().connectFreshMachine(machineID: "vm-fresh", route: nil, session: "cloud", dial: { _, _ in
                CloudMachineLink.Connected(socketPath: "/unused", session: "cloud")
            })
        }
        #expect(ContinuousClock.now - started < .seconds(2), "preflight failures never enter the retry schedule")
    }
}
