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
