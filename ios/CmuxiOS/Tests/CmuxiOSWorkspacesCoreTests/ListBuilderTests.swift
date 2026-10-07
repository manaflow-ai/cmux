import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import Foundation
import Testing

@Suite struct ListBuilderTests {
    let studio = HostID("mac-studio")
    let mini = HostID("mac-mini")
    var hosts: [HostWorkspaces] { MockFixtures.hostWorkspaces(now: Date(timeIntervalSince1970: 1_000_000)) }

    func build(_ preferences: WorkspaceViewPreferences = WorkspaceViewPreferences(), _ hosts: [HostWorkspaces]? = nil) -> WorkspaceListSnapshot {
        WorkspaceListBuilder(preferences: preferences).snapshot(for: hosts ?? self.hosts)
    }

    @Test func byMachineSplitsPinnedGroupsAndRest() {
        let list = build()
        #expect(list.sections.map(\.id) == [
            "host:mac-studio/pinned", "host:mac-studio/group:grp_api", "host:mac-mini/all",
        ])
        #expect(list.sections[0].machine?.name == "Mac Studio")
        #expect(list.sections[1].machine == nil)
        #expect(list.sections[1].kind == .group("API"))
        #expect(list.sections[1].rows.map(\.workspaceID) == ["ws_studio2", "ws_studio3"])
        #expect(list.sections[2].machine?.isReachable == false)
        #expect(list.sections[2].machine?.offlineReason == "Asleep")
        #expect(list.emptyState == nil)
        #expect(!list.allOffline)
        #expect(Set(list.rows.map(\.id)).count == list.rows.count)
    }

    @Test func filters() {
        var p = WorkspaceViewPreferences(filter: .unread)
        #expect(build(p).rows.map(\.workspaceID) == ["ws_studio1", "ws_studio2"])
        p.filter = .needsInput
        #expect(build(p).rows.map(\.workspaceID) == ["ws_studio2"])
        p.filter = .running
        #expect(build(p).rows.map(\.workspaceID) == ["ws_studio1"])
        // A machine with nothing matching is left out under a filter.
        #expect(!build(p).sections.contains { $0.hostID == mini })
    }

    @Test func filterWithNoMatchesIsEmpty() {
        var hosts = self.hosts
        hosts[0].workspaces = hosts[0].workspaces.map { var w = $0; w.unreadCount = 0; return w }
        let list = build(WorkspaceViewPreferences(filter: .unread), hosts)
        #expect(list.sections.isEmpty)
        #expect(list.emptyState == .filterEmpty(.unread))
    }

    @Test func sorts() {
        var p = WorkspaceViewPreferences(sort: .recentActivity, grouping: .flat)
        #expect(build(p).rows.map(\.workspaceID) == ["ws_studio1", "ws_studio2", "ws_studio3", "ws_mini1"])
        p.sort = .name
        #expect(build(p).rows.map(\.title) == ["backend", "cmux", "docs", "release"])
        p.sort = .ownerOrder
        #expect(build(p).rows.map(\.workspaceID) == ["ws_studio1", "ws_studio2", "ws_studio3", "ws_mini1"])
        #expect(build(p).sections.map(\.id) == ["flat"])
    }

    @Test func hiddenAndOrderedMachines() {
        var p = WorkspaceViewPreferences(hostOrder: [mini, studio])
        #expect(build(p).sections.first?.hostID == mini)
        p.hiddenHosts = [mini]
        #expect(!build(p).sections.contains { $0.hostID == mini })
        p.hiddenHosts = [mini, studio]
        #expect(build(p).emptyState == .allHidden)
    }

    @Test func moveRecordsTheFullOrder() {
        var p = WorkspaceViewPreferences()
        p.move(mini, to: 0, in: [studio, mini])
        #expect(p.hostOrder == [mini, studio])
        #expect(p.ordered(hosts, id: \.hostID).map(\.hostID) == [mini, studio])
    }

    @Test func loadingNoMachinesAndEmptyMachine() {
        #expect(WorkspaceListBuilder(preferences: .init()).snapshot(for: nil).emptyState == .loading)
        #expect(build(.init(), []).emptyState == .noMachines)
        let empty = [HostWorkspaces(hostID: studio, hostName: "Mac Studio", isReachable: false, workspaces: [])]
        let list = build(.init(), empty)
        #expect(list.sections.map(\.kind) == [.empty])
        #expect(list.allOffline)
        #expect(build(WorkspaceViewPreferences(grouping: .flat), empty).emptyState == .noWorkspaces)
    }

    @Test func rowsCarryMachineAndCapabilities() throws {
        let row = try #require(build().rows.first { $0.workspaceID == "ws_mini1" })
        #expect(row.machineName == "Mac mini")
        #expect(!row.isReachable)
        #expect(row.machineColor == MachineColor(hostID: mini))
        #expect(row.preview == "Archive step exited with 65")
    }

    @Test func machineColorsAreStable() {
        #expect(MachineColor(hostID: HostID("h_abc")) == MachineColor(hostID: HostID("h_abc")))
        // The empty id hashes to the FNV-1a offset basis: guards against a
        // hash change that would recolor every Mac.
        #expect(MachineColor(hostID: HostID("")) == MachineColor.allCases[Int(0xcbf2_9ce4_8422_2325 % UInt64(9))])
        let colors = Set((0..<40).map { MachineColor(hostID: HostID("h_\($0)")) })
        #expect(colors.count > 4)
    }

    @Test func statusSeverityOrder() {
        #expect([WorkspaceStatus.idle, .running, .waitingForInput, .failed].map(\.severity) == [0, 1, 2, 3])
    }

    @Test func preferencesPersist() {
        let defaults = UserDefaults(suiteName: "c5-tests-\(UUID().uuidString)")!
        let store = WorkspaceViewPreferencesStore(defaults: defaults)
        #expect(store.load() == WorkspaceViewPreferences())
        let saved = WorkspaceViewPreferences(filter: .running, sort: .name, grouping: .flat, hiddenHosts: [mini], hostOrder: [mini])
        store.save(saved)
        #expect(WorkspaceViewPreferencesStore(defaults: defaults).load() == saved)
    }
}
