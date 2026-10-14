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
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Tuesday 2026-10-13 15:00 in Los Angeles.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 15))! }

    let macs = [
        MacDevice(id: "off", name: "Off", isOnline: false),
        MacDevice(id: "a", name: "A", isOnline: true),
        MacDevice(id: "b", name: "B", isOnline: true),
    ]

    func ago(days: Int, hours: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: -days, hour: -hours), to: now)!
    }

    func ws(_ id: String, _ mac: String, _ date: Date, branch: String? = nil) -> Workspace {
        Workspace(id: id, macID: mac, title: id, directory: "~/src/\(id)", branch: branch, tabs: [], lastActivityAt: date)
    }

    @Test func bucketsFollowCalendarDays() {
        func bucket(_ date: Date) -> RecencyBucket { RecencyBucket(date, now: now, calendar: calendar) }
        // 00:30 today is Today; 23:30 the day before is Yesterday.
        #expect(bucket(calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 0, minute: 30))!) == .today)
        #expect(bucket(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23, minute: 30))!) == .yesterday)
        #expect(bucket(now.addingTimeInterval(120)) == .today)
        #expect(bucket(ago(days: 2)) == .previous7Days)
        #expect(bucket(ago(days: 7)) == .previous7Days)
        #expect(bucket(ago(days: 8)) == .previous30Days)
        #expect(bucket(ago(days: 30)) == .previous30Days)
        #expect(bucket(ago(days: 31)) == .month(year: 2026, month: 9))
        #expect(bucket(ago(days: 400)) == .month(year: 2025, month: 9))
    }

    @Test func titlesLikeChatGPT() {
        func title(_ bucket: RecencyBucket) -> String { bucket.title(now: now, calendar: calendar) }
        #expect(title(.today) == "Today")
        #expect(title(.yesterday) == "Yesterday")
        #expect(title(.previous7Days) == "Previous 7 Days")
        #expect(title(.previous30Days) == "Previous 30 Days")
        #expect(title(.month(year: 2026, month: 8)) == "August")
        #expect(title(.month(year: 2025, month: 12)) == "December 2025")
    }

    var items: [Workspace] {
        [
            ws("a-old", "a", ago(days: 70)),
            ws("a-today", "a", ago(days: 0, hours: 1)),
            ws("b-yesterday", "b", ago(days: 1)),
            ws("off-week", "off", ago(days: 3), branch: "feat-x"),
            ws("b-today", "b", ago(days: 0, hours: 2)),
            ws("a-month", "a", ago(days: 20)),
            ws("gone", "left-the-team", ago(days: 0)),
        ]
    }

    @Test func allMixesEveryMacNewestFirstUnderRecencyHeaders() {
        let layout = WorkspaceListLayout(scope: .all, macs: macs, workspaces: items, now: now, calendar: calendar)
        #expect(layout.sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August"])
        #expect(layout.sections.map { $0.workspaces.map(\.id) } == [
            ["a-today", "b-today"], ["b-yesterday"], ["off-week"], ["a-month"], ["a-old"],
        ])
        #expect(!layout.isEmpty)
    }

    @Test func oneMacShowsOnlyItsWorkspacesOnlineOrNot() {
        let a = WorkspaceListLayout(scope: .mac("a"), macs: macs, workspaces: items, now: now, calendar: calendar)
        #expect(a.sections.flatMap(\.workspaces).map(\.id) == ["a-today", "a-month", "a-old"])
        #expect(a.sections.map(\.title) == ["Today", "Previous 30 Days", "August"])
        let off = WorkspaceListLayout(scope: .mac("off"), macs: macs, workspaces: items, now: now, calendar: calendar)
        #expect(off.sections.flatMap(\.workspaces).map(\.id) == ["off-week"])
    }

    @Test func emptyMacAndMissingMac() {
        let empty = WorkspaceListLayout(scope: .mac("b"), macs: macs, workspaces: [], now: now, calendar: calendar)
        #expect(empty.isEmpty)
        let gone = WorkspaceListLayout(scope: .mac("zzz"), macs: macs, workspaces: items, now: now, calendar: calendar)
        #expect(gone.scope == .all)
    }

    @Test func searchMatchesNameBranchAndDirectory() {
        func ids(_ query: String, _ scope: MacScope = .all) -> [String] {
            WorkspaceListLayout(scope: scope, macs: macs, workspaces: items, query: query, now: now, calendar: calendar)
                .sections.flatMap(\.workspaces).map(\.id)
        }
        #expect(ids("TODAY") == ["a-today", "b-today"])
        #expect(ids("feat-x") == ["off-week"])
        #expect(ids("src/a-m") == ["a-month"])
        #expect(ids("today", .mac("b")) == ["b-today"])
        #expect(ids("   ") == ids(""))
        #expect(ids("nothing").isEmpty)
    }

    @Test func chipsPutOnlineMacsFirst() {
        #expect(MacScope.chipOrder(macs).map(\.id) == ["a", "b", "off"])
    }

    @Test func newWorkspaceTargetsTheChosenMac() {
        let available = macs.filter(\.isOnline)
        // The chosen Mac wins over the preferred one.
        #expect(MacScope.mac("b").newWorkspaceMac(available: available, fallback: available[0])?.id == "b")
        // An offline chosen Mac cannot take one: no silent fallback to another Mac.
        #expect(MacScope.mac("off").newWorkspaceMac(available: available, fallback: available[0]) == nil)
        #expect(MacScope.all.newWorkspaceMac(available: available, fallback: available[1])?.id == "b")
    }
}

@MainActor @Suite struct WorkspaceManagementTests {
    func make() -> (AppStore, MockWorkspaceCreationBackend, WorkspaceCreator) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let backend = MockWorkspaceCreationBackend(latency: .zero)
        let suite = UserDefaults(suiteName: "cnx.tests.manage.\(UUID().uuidString)")!
        return (store, backend, WorkspaceCreator(store: store, backend: backend, defaults: suite))
    }

    @Test func renameAndCloseApplyAtOnce() async throws {
        let (store, _, creator) = make()
        let ws = try #require(store.workspace(id: "ws-web"))
        creator.rename(ws, to: "  site  ")
        #expect(store.workspace(id: "ws-web")?.title == "site")
        creator.close(try #require(store.workspace(id: "ws-web")))
        #expect(store.workspace(id: "ws-web") == nil)
        await creator.settle()
        #expect(store.workspace(id: "ws-web") == nil)
    }

    @Test func aRefusalUndoesTheChange() async throws {
        let (store, backend, creator) = make()
        var failures: [String] = []
        creator.onManageFailure = { _, what, _ in failures.append(what) }
        let ws = try #require(store.workspace(id: "ws-web"))
        let index = try #require(store.workspaces.firstIndex { $0.id == "ws-web" })
        backend.failNext = "no"
        creator.rename(ws, to: "site")
        await creator.settle()
        #expect(store.workspace(id: "ws-web")?.title == "cmux.com")
        backend.failNext = "no"
        creator.close(ws)
        await creator.settle()
        #expect(store.workspaces.firstIndex { $0.id == "ws-web" } == index)
        #expect(failures == ["Couldn't rename cmux.com", "Couldn't close cmux.com"])
    }

    @Test func offlineMacsAndBlankNamesAreRefused() throws {
        let (store, _, creator) = make()
        let offline = try #require(store.workspace(id: "ws-notes"))
        #expect(!creator.canManage(offline))
        creator.close(offline)
        #expect(store.workspace(id: "ws-notes") != nil)
        let ws = try #require(store.workspace(id: "ws-web"))
        creator.rename(ws, to: "   ")
        #expect(store.workspace(id: "ws-web")?.title == "cmux.com")
    }
}
