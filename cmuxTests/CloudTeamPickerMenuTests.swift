import AppKit
import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud team picker menu")
struct CloudTeamPickerMenuTests {
    private let teams = [
        AccountTeamSummary(id: "team-long", displayName: "Benjamin Swerdlow's Team With A Long Name"),
        AccountTeamSummary(id: "team-alpha", displayName: "Alpha Squad"),
    ]

    private func item(_ menu: NSMenu, _ identifier: String) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == identifier }
    }

    @Test func checksTheActiveTeamAndKeepsFullNames() throws {
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-long", isSwitching: false,
            onSelect: { _ in }, onCreate: {}
        )
        let long = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-long")))
        let alpha = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha")))
        #expect(long.title == "Benjamin Swerdlow's Team With A Long Name")
        #expect(long.state == .on)
        #expect(alpha.state == .off)
        #expect(long.isEnabled && alpha.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.createTeamIdentifier)?.isEnabled == true)
        #expect(item(menu, CloudTeamPickerMenu.switchingStatusIdentifier) == nil)
        #expect(menu.items.last?.identifier?.rawValue == CloudTeamPickerMenu.createTeamIdentifier)
    }

    @Test func pendingSwitchShowsStatusAndDisablesEveryAction() throws {
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-alpha", isSwitching: true,
            onSelect: { _ in }, onCreate: {}
        )
        let status = try #require(menu.items.first)
        #expect(status.identifier?.rawValue == CloudTeamPickerMenu.switchingStatusIdentifier)
        #expect(!status.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha"))?.state == .on)
        #expect(menu.items.filter(\.isEnabled).isEmpty)
    }

    @Test func noMembershipShowsLoadingAndStillOffersCreate() {
        let menu = CloudTeamPickerMenu.make(
            teams: [], selectedTeamID: nil, isSwitching: false,
            onSelect: { _ in }, onCreate: {}
        )
        #expect(item(menu, CloudTeamPickerMenu.loadingTeamsIdentifier)?.isEnabled == false)
        #expect(item(menu, CloudTeamPickerMenu.createTeamIdentifier)?.isEnabled == true)
    }

    @Test func itemsRunTheirActions() throws {
        var selected: [String] = []
        var createCount = 0
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-long", isSwitching: false,
            onSelect: { selected.append($0.id) }, onCreate: { createCount += 1 }
        )
        let alpha = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha")))
        menu.performActionForItem(at: menu.index(of: alpha))
        let create = try #require(item(menu, CloudTeamPickerMenu.createTeamIdentifier))
        menu.performActionForItem(at: menu.index(of: create))
        #expect(selected == ["team-alpha"])
        #expect(createCount == 1)
    }
}
