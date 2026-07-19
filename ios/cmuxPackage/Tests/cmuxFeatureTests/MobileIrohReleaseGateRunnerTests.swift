#if os(iOS) && DEBUG
import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import Testing
@testable import CmuxIrohReleaseGateSupport

@MainActor
struct MobileIrohReleaseGateRunnerTests {
    @Test
    func configurationRequiresAnExplicitSupportedMode() throws {
        let cache = URL(fileURLWithPath: "/tmp/iroh-gate-tests", isDirectory: true)

        #expect(MobileIrohReleaseGateRunner.Configuration(
            environment: [:],
            cachesDirectory: cache
        ) == nil)
        #expect(MobileIrohReleaseGateRunner.Configuration(
            environment: ["CMUX_IROH_RELEASE_GATE_MODE": "unsupported"],
            cachesDirectory: cache
        ) == nil)

        let configuration = try #require(MobileIrohReleaseGateRunner.Configuration(
            environment: ["CMUX_IROH_RELEASE_GATE_MODE": "relayOnly"],
            cachesDirectory: cache
        ))
        #expect(configuration.mode == .relayOnly)
        #expect(configuration.reportURL.lastPathComponent == "cmux-iroh-release-gate.json")
    }

    @Test(arguments: [
        (CmxIrohTransportVerificationMode.automatic, CmxIrohSelectedTransportPath.direct, "direct"),
        (.automatic, .privateNetwork, "private_network"),
        (.automatic, .managedRelay(provider: "provider", region: "region"), "managed_relay"),
        (.relayOnly, .managedRelay(provider: "provider", region: "region"), "managed_relay"),
        (.relayOnly, .customRelay(displayName: "name", provider: "provider", region: "region"), "custom_relay"),
        (.directOnly, .direct, "direct"),
        (.directOnly, .privateNetwork, "private_network"),
    ])
    func acceptedPathsAreRedacted(
        mode: CmxIrohTransportVerificationMode,
        path: CmxIrohSelectedTransportPath,
        expected: String
    ) {
        #expect(MobileIrohReleaseGateRunner.acceptedPath(path, mode: mode) == expected)
        #expect(!expected.contains("provider"))
        #expect(!expected.contains("region"))
        #expect(!expected.contains("name"))
    }

    @Test(arguments: [
        (CmxIrohTransportVerificationMode.relayOnly, CmxIrohSelectedTransportPath.direct),
        (.relayOnly, .privateNetwork),
        (.directOnly, .managedRelay(provider: "provider", region: "region")),
        (.directOnly, .customRelay(displayName: "name", provider: "provider", region: "region")),
        (.automatic, .unavailable),
        (.relayOnly, .unavailable),
        (.directOnly, .unavailable),
    ])
    func incompatibleOrUnavailablePathsFail(
        mode: CmxIrohTransportVerificationMode,
        path: CmxIrohSelectedTransportPath
    ) {
        #expect(MobileIrohReleaseGateRunner.acceptedPath(path, mode: mode) == nil)
    }

    @Test
    func encodedReportContainsNoTopologyOrIdentityFields() throws {
        let report = MobileIrohReleaseGateRunner.Report(
            schemaVersion: 1,
            mode: "relayOnly",
            passed: true,
            hostStatusVerified: true,
            terminalRoundTripVerified: true,
            workspaceMutationVerified: true,
            routeKind: "iroh",
            selectedPath: "managed_relay",
            failure: nil
        )
        let encoded = try JSONEncoder().encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(Set(object.keys) == [
            "schemaVersion",
            "mode",
            "passed",
            "hostStatusVerified",
            "terminalRoundTripVerified",
            "workspaceMutationVerified",
            "routeKind",
            "selectedPath",
        ])
    }
}
#endif
