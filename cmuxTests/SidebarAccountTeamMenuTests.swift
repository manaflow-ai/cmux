import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// What the sidebar account popover offers for teams.
@MainActor
@Suite struct SidebarAccountTeamMenuTests {
    private func team(_ id: String, _ name: String) -> AccountTeamSummary {
        AccountTeamSummary(id: id, displayName: name)
    }

    @Test func signedOutShowsNoTeamsAndNoCreate() {
        let presentation = AccountTeamMenuPresentationResolver.resolve(
            teams: [team("a", "Alpha")],
            activeTeamID: "a",
            isSignedIn: false
        )
        #expect(presentation == .signedOut)
        #expect(presentation.showsCreateTeam == false)
    }

    @Test func theActiveTeamIsTheOnlyMarkedRow() {
        let presentation = AccountTeamMenuPresentationResolver.resolve(
            teams: [team("a", "Alpha"), team("b", "Beta"), team("c", "Gamma")],
            activeTeamID: "b",
            isSignedIn: true
        )
        #expect(presentation.rows.map(\.id) == ["a", "b", "c"])
        #expect(presentation.rows.filter(\.isActive).map(\.id) == ["b"])
        #expect(presentation.activeTeamName == "Beta")
    }

    @Test func teamsAreListedInBackendOrder() {
        let presentation = AccountTeamMenuPresentationResolver.resolve(
            teams: [team("z", "Zeta"), team("a", "Alpha")],
            activeTeamID: "a",
            isSignedIn: true
        )
        #expect(presentation.rows.map(\.displayName) == ["Zeta", "Alpha"])
    }

    @Test func anAccountWithNoTeamsStillOffersCreate() {
        // Creating the first team is how a new account starts sharing cloud
        // workspaces at all, so it cannot be gated on already having one.
        let presentation = AccountTeamMenuPresentationResolver.resolve(
            teams: [],
            activeTeamID: nil,
            isSignedIn: true
        )
        #expect(presentation.rows.isEmpty)
        #expect(presentation.showsTeamList == false)
        #expect(presentation.showsCreateTeam)
        #expect(presentation.activeTeamName == nil)
    }

    @Test func anActiveTeamOutsideTheListNamesNothing() {
        // The picker must never label the account with a team the user is not
        // a member of; a stale id marks no row and names no team.
        let presentation = AccountTeamMenuPresentationResolver.resolve(
            teams: [team("a", "Alpha")],
            activeTeamID: "gone",
            isSignedIn: true
        )
        #expect(presentation.rows.contains { $0.isActive } == false)
        #expect(presentation.activeTeamName == nil)
    }

    @Test(arguments: [
        ("", false),
        ("   ", false),
        ("\n\t", false),
        ("Alpha", true),
        ("  Alpha  ", true),
    ])
    func blankTeamNamesAreNotSubmittable(name: String, expected: Bool) {
        #expect(AccountTeamNameValidator.isSubmittable(name) == expected)
    }

    @Test func theCreateFormStartsEmptyAndClearsOnCancel() {
        let state = AccountTeamCreationState()
        state.name = "left over"
        state.failureMessage = "stale"

        state.present()
        #expect(state.isPresentingForm)
        #expect(state.name.isEmpty)
        #expect(state.failureMessage == nil)
        #expect(state.canSubmit == false)

        state.name = "Beta"
        #expect(state.canSubmit)

        state.cancel()
        #expect(state.isPresentingForm == false)
        #expect(state.name.isEmpty)
    }

    @Test func anInFlightCreateCannotBeSubmittedTwice() {
        let state = AccountTeamCreationState()
        state.present()
        state.name = "Beta"
        state.isCreating = true
        #expect(state.canSubmit == false)
    }

    @Test func aLocalizedFailureIsShownInsteadOfTheGenericText() {
        struct Described: LocalizedError {
            var errorDescription: String? { "Name already taken." }
        }
        #expect(SidebarAccountPopover.failureText(for: Described()) == "Name already taken.")

        struct Bare: Error {}
        #expect(SidebarAccountPopover.failureText(for: Bare()).isEmpty == false)
    }
}
