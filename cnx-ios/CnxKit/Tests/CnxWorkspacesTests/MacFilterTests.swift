import CnxModel
import Foundation
import Testing
@testable import CnxWorkspaces

@MainActor @Suite struct MacFilterTests {
    let suite = "cnx.tests.macfilter.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    let team = Team(id: "t1", name: "One", macs: [
        MacDevice(id: "a", name: "Studio", isOnline: true),
        MacDevice(id: "b", name: "Air", isOnline: false),
    ])
    let other = Team(id: "t2", name: "Two", macs: [MacDevice(id: "c", name: "mini", isOnline: true)])

    @Test func defaultsToAllMacs() {
        let filter = MacFilter(defaults: defaults)
        #expect(filter.scope(in: team) == .all)
        #expect(filter.scope(in: nil) == .all)
    }

    @Test func remembersTheMacPerTeamAcrossLaunches() {
        let filter = MacFilter(defaults: defaults)
        filter.select(.mac("b"), in: "t1")
        filter.select(.mac("c"), in: "t2")
        let relaunched = MacFilter(defaults: defaults)
        #expect(relaunched.scope(in: team) == .mac("b"))
        #expect(relaunched.scope(in: other) == .mac("c"))
        relaunched.select(.all, in: "t1")
        #expect(MacFilter(defaults: defaults).scope(in: team) == .all)
        #expect(MacFilter(defaults: defaults).scope(in: other) == .mac("c"))
    }

    @Test func aMacThatLeftTheTeamReadsAsAllMacs() {
        let filter = MacFilter(defaults: defaults)
        filter.select(.mac("b"), in: "t1")
        var shrunk = team
        shrunk.macs.removeAll { $0.id == "b" }
        #expect(filter.scope(in: shrunk) == .all)
        // A Mac from another team never applies here.
        filter.select(.mac("c"), in: "t1")
        #expect(filter.scope(in: team) == .all)
    }

    @Test func theFilterIsAnAccountPreference() {
        #expect(AppStore.isAccountPreference(MacFilter.keyPrefix + "t1"))
    }
}

@Suite struct WorkspaceListLayoutTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let macs = [
        MacDevice(id: "off", name: "Off", isOnline: false),
        MacDevice(id: "a", name: "A", isOnline: true),
        MacDevice(id: "b", name: "B", isOnline: true),
    ]

    func ws(_ id: String, _ mac: String, _ age: TimeInterval, _ title: String? = nil) -> Workspace {
        Workspace(id: id, macID: mac, title: title ?? id, directory: "~", tabs: [], lastActivityAt: now.addingTimeInterval(-age))
    }

    var items: [Workspace] { [ws("a1", "a", 60), ws("a2", "a", 10), ws("o1", "off", 5), ws("x", "gone", 1)] }

    @Test func allMacsGroupsOnlineFirstAndSortsInside() {
        let layout = WorkspaceListLayout(scope: .all, macs: macs, workspaces: items, sort: .recent, showsOffline: true)
        #expect(layout.isGrouped)
        #expect(layout.sections.map(\.id) == ["a", "b", "off"])
        #expect(layout.sections[0].workspaces.map(\.id) == ["a2", "a1"])
        #expect(layout.sections[1].workspaces.isEmpty)
        #expect(layout.sections[2].workspaces.map(\.id) == ["o1"])
        #expect(!layout.isEmpty)
    }

    @Test func hidingOfflineMacsDropsTheirSections() {
        let layout = WorkspaceListLayout(scope: .all, macs: macs, workspaces: items, sort: .recent, showsOffline: false)
        #expect(layout.sections.map(\.id) == ["a", "b"])
    }

    @Test func oneMacIsFlatAndIgnoresShowOffline() {
        let a = WorkspaceListLayout(scope: .mac("a"), macs: macs, workspaces: items, sort: .name, showsOffline: false)
        #expect(!a.isGrouped)
        #expect(a.sections.map(\.id) == ["a"])
        #expect(a.sections[0].workspaces.map(\.id) == ["a1", "a2"])
        let off = WorkspaceListLayout(scope: .mac("off"), macs: macs, workspaces: items, sort: .recent, showsOffline: false)
        #expect(off.sections.map(\.id) == ["off"])
        #expect(off.sections[0].workspaces.map(\.id) == ["o1"])
    }

    @Test func emptyMacAndMissingMac() {
        let b = WorkspaceListLayout(scope: .mac("b"), macs: macs, workspaces: items, sort: .recent, showsOffline: true)
        #expect(b.isEmpty)
        let gone = WorkspaceListLayout(scope: .mac("zzz"), macs: macs, workspaces: items, sort: .recent, showsOffline: true)
        #expect(gone.scope == .all && gone.isGrouped)
    }

    @Test func titleAndNewWorkspaceTarget() {
        #expect(MacScope.all.title(macs: macs) == "All Macs")
        #expect(MacScope.mac("b").title(macs: macs) == "B")
        #expect(MacScope.mac("zzz").title(macs: macs) == "All Macs")
        let available = macs.filter(\.isOnline)
        // The filtered Mac wins over the preferred one.
        #expect(MacScope.mac("b").newWorkspaceMac(available: available, fallback: available[0])?.id == "b")
        // An offline filtered Mac cannot take one: no silent fallback to another Mac.
        #expect(MacScope.mac("off").newWorkspaceMac(available: available, fallback: available[0]) == nil)
        #expect(MacScope.all.newWorkspaceMac(available: available, fallback: available[1])?.id == "b")
    }
}

@Suite struct WorkspaceRowModelTests {
    let now = Date()

    @Test func tabKindsInAFixedOrderWithCounts() {
        let tabs = [
            WorkspaceTab(id: "1", kind: .browser, title: "b"),
            WorkspaceTab(id: "2", kind: .terminal, title: "t"),
            WorkspaceTab(id: "3", kind: .agent, title: "Claude"),
            WorkspaceTab(id: "4", kind: .terminal, title: "t2"),
        ]
        let summary = TabKindSummary(tabs)
        #expect(summary.entries.map(\.kind) == [.agent, .terminal, .browser])
        #expect(summary.entries.map(\.count) == [1, 2, 1])
        #expect(summary.spoken == "1 agent, 2 terminals, 1 browser tab")
        #expect(TabKindSummary([]).entries.isEmpty)
    }

    @Test func activityLine() {
        let agent = WorkspaceTab(id: "c", kind: .agent, title: "Claude", subtitle: "Refactor", harness: "claude")
        let term = WorkspaceTab(id: "t", kind: .terminal, title: "zsh", subtitle: "~/x")
        func w(_ tabs: [WorkspaceTab], attention: Bool = false, working: Bool = false) -> Workspace {
            Workspace(id: "w", macID: "m", title: "w", directory: "~", tabs: tabs, lastActivityAt: now,
                      needsAttention: attention, isWorking: working)
        }
        #expect(WorkspaceActivity(w([term, agent], attention: true, working: true)) == .needsYou(agent: "Claude", detail: "Refactor"))
        #expect(WorkspaceActivity(w([term, agent], working: true)) == .working(agent: "Claude", detail: "Refactor"))
        #expect(WorkspaceActivity(w([term, agent])) == .idle("Claude: Refactor"))
        #expect(WorkspaceActivity(w([term])) == .idle("~/x"))
        #expect(WorkspaceActivity(w([])) == .idle(nil))
    }
}
