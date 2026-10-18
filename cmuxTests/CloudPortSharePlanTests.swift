import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Share used to read only the first publication of a port: with a public link
/// beside a private one it reported the port private and narrowed only one link,
/// and a double Share created two publications. Rows showed no audience at all
/// until a menu opened. The plan itself is covered in CmuxSurfaceCatalogModel;
/// these cover the app's bridge, store, badge and menu.
@MainActor
@Suite struct CloudPortSharePlanTests {
    private static func publication(
        _ id: String, port: Int = 3000, vm: String = "vm-1", _ mode: VMPublicationAccessMode, domainKind: String = "generated"
    ) -> VMPublication {
        VMPublication(
            id: id, hostname: "\(id).example.test", url: "https://\(id).example.test", domainKind: domainKind,
            vmID: vm, port: port, accessMode: mode, teamID: nil, state: "active", routingRevision: 1, verification: nil
        )
    }

    private static func refs(_ publications: [VMPublication]) -> [CloudPortPublicationRef] {
        publications.map(CloudPortPublicationRef.init)
    }

    @Test func theAppPlanReadsEveryPublicationOfThePort() {
        let plan = CloudPortSharePlan(
            publications: Self.refs([
                Self.publication("a", .personal),
                Self.publication("b", .public),
                Self.publication("c", .team, domainKind: "custom"),
                Self.publication("other-port", port: 4000, .public),
            ]),
            machineID: "vm-1",
            port: 3000
        )
        #expect(plan.current == .public)
        #expect(plan.publications.map(\.id) == ["b", "c", "a"])
        #expect(plan.steps(to: .stopSharing) == [.delete(id: "b"), .update(id: "c", .personal), .delete(id: "a")])
    }

    @Test func disabledPublicationsDoNotKeepAStoppedPortShared() {
        let disabled = VMPublication(
            id: "disabled", hostname: "disabled.example.test", url: "https://disabled.example.test",
            domainKind: "generated", vmID: "vm-1", port: 3000, accessMode: .personal,
            teamID: nil, state: "disabled", routingRevision: 2, verification: nil
        )
        let plan = CloudPortSharePlan(
            publications: [CloudPortPublicationRef(disabled)], machineID: "vm-1", port: 3000
        )

        #expect(plan.current == .unshared)
        #expect(plan.steps(to: .stopSharing).isEmpty)
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

    @Test func theStoreHidesTheBadgeUntilReadThenFollowsAShareChange() async throws {
        var listed = Self.refs([Self.publication("a", .team)])
        var reads = 0
        let store = CloudPortSharingStore(now: { Date(timeIntervalSince1970: 1_000) }) {
            reads += 1
            return listed
        }
        #expect(store.sharing(machineID: "vm-1", port: 3000) == nil)
        #expect(CloudTreePortPresentation.audienceBadge(store.sharing(machineID: "vm-1", port: 3000)) == nil)

        try await store.reload()
        #expect(store.sharing(machineID: "vm-1", port: 3000) == .team)
        #expect(store.sharing(machineID: "vm-1", port: 5173) == .unshared)
        #expect(reads == 1)

        // Inside the TTL, rows appearing ask again without a read.
        store.requestRefresh()
        #expect(reads == 1)

        listed = Self.refs([Self.publication("a", .public)])
        try await store.reload()
        #expect(store.sharing(machineID: "vm-1", port: 3000) == .public)
        #expect(CloudTreePortPresentation.audienceBadge(.public)?.kind == .public)
    }

    @Test func invalidationDuringAReadSchedulesAnAuthoritativeFollowUp() async throws {
        var listed = Self.refs([Self.publication("a", .team)])
        var reads = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        let store = CloudPortSharingStore(now: { Date(timeIntervalSince1970: 1_000) }) {
            reads += 1
            if reads == 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseFirst = continuation
                }
            }
            return listed
        }

        store.requestRefresh()
        try await Self.waitUntil { reads == 1 }
        #expect(reads == 1)
        listed = Self.refs([Self.publication("a", .public)])
        store.invalidate()
        releaseFirst?.resume()

        try await Self.waitUntil {
            reads == 2 && store.sharing(machineID: "vm-1", port: 3000) == .public
        }
        #expect(reads == 2)
        #expect(store.sharing(machineID: "vm-1", port: 3000) == .public)
    }

    @Test func invalidationDuringAReloadSchedulesAFollowUpRead() async throws {
        var listed = Self.refs([Self.publication("a", .team)])
        var reads = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        let store = CloudPortSharingStore(now: { Date(timeIntervalSince1970: 1_000) }) {
            reads += 1
            if reads == 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseFirst = continuation
                }
            }
            return listed
        }

        let reload = Task { try await store.reload() }
        try await Self.waitUntil { reads == 1 }
        // A CLI share commits while the share flow's reload is still reading.
        listed = Self.refs([Self.publication("a", .public)])
        store.invalidate()
        #expect(reads == 1)
        releaseFirst?.resume()
        _ = try await reload.value

        try await Self.waitUntil {
            reads == 2 && store.sharing(machineID: "vm-1", port: 3000) == .public
        }
        #expect(reads == 2)
    }

    @Test func anOlderReadFinishingLastDoesNotReplaceANewerList() async throws {
        var reads = 0
        var releaseFirst: CheckedContinuation<Void, Never>?
        let store = CloudPortSharingStore(now: { Date(timeIntervalSince1970: 1_000) }) {
            reads += 1
            if reads == 1 {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    releaseFirst = continuation
                }
                return Self.refs([Self.publication("a", .team)])
            }
            return Self.refs([Self.publication("a", .public)])
        }

        let older = Task { try await store.reload() }
        try await Self.waitUntil { reads == 1 }
        _ = try await store.reload()
        #expect(store.sharing(machineID: "vm-1", port: 3000) == .public)
        releaseFirst?.resume()
        _ = try await older.value
        #expect(store.sharing(machineID: "vm-1", port: 3000) == .public)
        #expect(reads == 2)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }

    @Test func theBadgeIsPrivateTeamOrPublic() {
        #expect(CloudTreePortPresentation.audienceBadge(.unshared)?.kind == .private)
        #expect(CloudTreePortPresentation.audienceBadge(.personal)?.kind == .private)
        #expect(CloudTreePortPresentation.audienceBadge(.team)?.title == "Team")
        #expect(CloudTreePortPresentation.audienceBadge(.public)?.symbolName == "globe")
        #expect(CloudTreePortPresentation.audienceBadge(.public)?.help.contains("anyone") == true)
    }

    @Test func theShareMenuChecksTheAudienceAndOffersStopSharingOnlyWithALink() {
        let unshared = CloudPortShareMenuModel(
            plan: CloudPortSharePlan(publications: [], machineID: "vm-1", port: 3000), hasLoaded: true
        )
        #expect(unshared.status.hasPrefix("Private"))
        #expect(unshared.audiences.allSatisfy { !$0.isChecked && $0.isEnabled })
        // Public still asks: its row carries the ellipsis.
        #expect(unshared.audiences.last?.title.hasSuffix("\u{2026}") == true)
        #expect(unshared.audiences.first?.title.hasSuffix("\u{2026}") == false)
        #expect(unshared.linkActions.allSatisfy { !$0.isEnabled })

        let team = CloudPortShareMenuModel(
            plan: CloudPortSharePlan(publications: Self.refs([Self.publication("a", .team)]), machineID: "vm-1", port: 3000),
            hasLoaded: true
        )
        #expect(team.audiences.map(\.isChecked) == [false, true, false])
        #expect(team.linkActions.allSatisfy { $0.isEnabled })
        #expect(team.linkActions.last?.action == .change(.stopSharing))
        #expect(team.linkActions.last?.isDestructive == true)

        let unread = CloudPortShareMenuModel(
            plan: CloudPortSharePlan(publications: [], machineID: "vm-1", port: 3000), hasLoaded: false
        )
        #expect(unread.audiences.allSatisfy { !$0.isEnabled })
    }

    @Test func theRowTooltipNamesTheAudienceOnceKnown() {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: .cloud("vm"), port: 3000, directURL: "http://10.0.0.7:3000")
        let presentation = CloudTreePortPresentation(resource: resource)
        #expect(presentation.shareTarget?.machineID == "vm")
        #expect(presentation.shareTarget?.port == 3000)
        #expect(presentation.toolTip(sharing: nil)?.contains("Private") == true)
        #expect(presentation.toolTip(sharing: .public)?.contains("anyone") == true)
    }
}
