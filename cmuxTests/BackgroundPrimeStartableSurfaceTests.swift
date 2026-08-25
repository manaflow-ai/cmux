import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BackgroundPrimeStartableSurfaceTests {
    // Regression coverage for issue #9769: `BackgroundWorkspacePrimeCoordinator`
    // deliberately keeps a workspace's hidden mount slot retained when its 2s
    // prime pass times out. A surface that can never create a runtime (closing
    // panel, agent-hibernation suspension) therefore pins one of the two global
    // mount slots forever, and background PTY spawn starves app-wide. Such a
    // surface must not count as background-prime work at all.
    @Test func closingSurfaceDoesNotCountAsBackgroundPrimeWork() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        _ = TerminalController.shared.v2WorkspaceCreate(
            params: ["initial_command": "true", "focus": false],
            tabManager: manager
        )
        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })

        // Sanity: with a pending initial command the workspace reports prime work.
        #expect(created.hasBackgroundPrimeTerminalSurfaceStartWork())

        for panel in created.panels.values.compactMap({ $0 as? TerminalPanel }) {
            panel.surface.beginPortalCloseLifecycle(reason: "test.issue9769")
        }

        #expect(
            !created.hasBackgroundPrimeTerminalSurfaceStartWork(),
            "A surface whose lifecycle forbids runtime creation can never satisfy a prime pass; reporting it as prime work pins a background mount slot forever (#9769)."
        )
        #expect(
            created.hasLoadedBackgroundPrimeTerminalSurface(),
            "Priming must consider a workspace with only non-startable surfaces complete so the mount slot is released (#9769)."
        )
    }
}
