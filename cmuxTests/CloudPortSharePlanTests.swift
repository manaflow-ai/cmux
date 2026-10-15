import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Share… used to read only the first publication of a port: with a public
/// link beside a private one it reported the port private and narrowed only one
/// link, and a double Share created two publications.
@MainActor
@Suite struct CloudPortSharePlanTests {
    private static func publication(_ id: String, port: Int = 3000, vm: String = "vm-1", _ mode: VMPublicationAccessMode) -> VMPublication {
        VMPublication(
            id: id, hostname: "\(id).example.test", url: "https://\(id).example.test", domainKind: "generated",
            vmID: vm, port: port, accessMode: mode, teamID: nil, state: "active", routingRevision: 1, verification: nil
        )
    }

    @Test func statusIsTheWidestAudienceAmongAllThePortsPublications() {
        let plan = CloudPortSharePlan(
            publications: [
                Self.publication("a", .personal),
                Self.publication("b", .public),
                Self.publication("c", .team),
                Self.publication("other-port", port: 4000, .public),
                Self.publication("other-vm", vm: "vm-2", .public),
            ],
            machineID: "vm-1",
            port: 3000
        )
        #expect(plan.current == .public)
        #expect(plan.publications.map(\.id) == ["b", "c", "a"])
        #expect(plan.primary?.id == "b")
        #expect(!plan.opensToPublic(.public))
    }

    @Test func aChosenAudienceAppliesToEveryPublicationThatDiffers() {
        let plan = CloudPortSharePlan(
            publications: [Self.publication("a", .personal), Self.publication("b", .public), Self.publication("c", .team)],
            machineID: "vm-1",
            port: 3000
        )
        #expect(plan.updates(to: .personal).map(\.id) == ["b", "c"])
        #expect(plan.updates(to: .public).map(\.id) == ["c", "a"])
    }

    @Test func anUnsharedPortHasNoStatusAndNeedsCreation() {
        let plan = CloudPortSharePlan(publications: [], machineID: "vm-1", port: 3000)
        #expect(plan.current == nil)
        #expect(plan.primary == nil)
        #expect(plan.opensToPublic(.public))
        #expect(!plan.opensToPublic(.team))
    }

    @Test func aSecondShareForTheSamePortDoesNotStartWhileTheFirstRuns() {
        #expect(CloudPortShareFlow.beginFlow(machineID: "vm-test-share", port: 3000))
        #expect(!CloudPortShareFlow.beginFlow(machineID: "vm-test-share", port: 3000))
        #expect(CloudPortShareFlow.beginFlow(machineID: "vm-test-share", port: 3001))
        CloudPortShareFlow.endFlow(machineID: "vm-test-share", port: 3000)
        CloudPortShareFlow.endFlow(machineID: "vm-test-share", port: 3001)
        #expect(CloudPortShareFlow.beginFlow(machineID: "vm-test-share", port: 3000))
        CloudPortShareFlow.endFlow(machineID: "vm-test-share", port: 3000)
    }
}
