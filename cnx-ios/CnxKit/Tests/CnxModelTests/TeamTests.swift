import Testing
@testable import CnxModel

@Suite struct TeamTests {
    @Test func dotsShowOnlineFirstAndOverflow() {
        let macs = (0..<8).map { MacDevice(id: "\($0)", name: "\($0)", isOnline: $0 == 6) }
        let result = Team(id: "t", name: "T", macs: macs).macDots()
        #expect(result.dots == [true, false, false, false, false])
        #expect(result.overflow == 3)
    }

    @Test func defaultColorIsStable() {
        #expect(TeamAppearance(defaultFor: "abc") == TeamAppearance(defaultFor: "abc"))
        #expect(TeamAppearance.palette.contains(TeamAppearance(defaultFor: "abc").colorHex))
    }

    @MainActor @Test func openingTabPrefersLastUsed() {
        let store = AppStore.mock()
        let ws = store.workspaces[0]
        #expect(store.openingTab(for: ws)?.id == "t-claude")
        store.noteOpened(tabID: "t-zsh", in: ws.id)
        #expect(store.openingTab(for: ws)?.id == "t-zsh")
    }
}

@MainActor @Suite struct AccountTeamTests {
    @Test func accountTeamsReplaceMockTeamsAndKeepSelection() {
        let store = AppStore.mock()
        store.applyAccountTeams([
            AppStore.AccountTeam(id: "a", name: "Alpha"),
            AppStore.AccountTeam(id: "b", name: "Beta"),
        ], selectedID: "b")
        #expect(store.teams.map(\.id) == ["a", "b"])
        #expect(store.activeTeamID == "b")
        #expect(store.teams.allSatisfy { TeamAppearance.palette.contains($0.appearance.colorHex) || $0.appearance.emoji != nil })
    }

    @Test func unknownSelectionFallsBackToAMemberTeam() {
        let store = AppStore.mock()
        store.applyAccountTeams([AppStore.AccountTeam(id: "only", name: "Only")], selectedID: "gone")
        #expect(store.activeTeamID == "only")
    }
}
