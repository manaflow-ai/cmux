import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Workspace explicit browser sources", .serialized)
struct WorkspaceExplicitBrowserSourceTests {
    @Test
    func newBrowserSurfaceUsesExplicitBackgroundSourceProfile() throws {
        let workspace = Workspace()
        let profileA = try makeTemporaryBrowserProfile(named: "Explicit Source")
        let profileB = try makeTemporaryBrowserProfile(named: "Live Focus")
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let browserA = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: true,
            preferredProfileID: profileA.id
        ))
        let browserB = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: true,
            preferredProfileID: profileB.id
        ))
        #expect(workspace.focusedPanelId == browserB.id)

        let created = try #require(workspace.newBrowserSurface(
            inPane: paneID,
            focus: false,
            sourcePanelID: browserA.id
        ))

        #expect(created.profileID == profileA.id)
        #expect(workspace.focusedPanelId == browserB.id)
    }

    @Test
    func newBrowserSurfaceRejectsStaleExplicitSourcePanel() throws {
        let workspace = Workspace()
        let paneID = try #require(workspace.bonsplitController.focusedPaneId)
        let originalPanelIDs = Set(workspace.panels.keys)

        #expect(workspace.newBrowserSurface(
            inPane: paneID,
            focus: false,
            sourcePanelID: UUID()
        ) == nil)
        #expect(Set(workspace.panels.keys) == originalPanelIDs)
    }

    private func makeTemporaryBrowserProfile(
        named prefix: String
    ) throws -> BrowserProfileDefinition {
        try #require(
            BrowserProfileStore.shared.createProfile(
                named: "\(prefix)-\(UUID().uuidString)"
            )
        )
    }
}
