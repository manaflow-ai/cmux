import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CloudPrivateRouteSelectionTests {
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

    @Test func soleIPv4AddressInsideTheEnrolledRoutesWinsAfterFiltering() async throws {
        let route = try await manager().resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["10.16.0.0/24"]),
            fallbackRoute: "ws://[fd00::2]:1337/v1/link",
            addresses: ["fd00::2", "10.16.0.2"]
        )
        #expect(route == "ws://10.16.0.2:1337/v1/link")
    }

    @Test func legacyCallerWithoutAddressCandidatesKeepsItsRoute() async throws {
        let route = try await manager().resolvedPrivateRoute(
            machineID: "vm-test",
            through: CloudWireGuardHub.Ready(socketPath: "/unused", routes: ["10.16.0.0/24"]),
            fallbackRoute: "ws://10.16.0.2:1337/v1/link"
        )
        #expect(route == "ws://10.16.0.2:1337/v1/link")
    }
}
