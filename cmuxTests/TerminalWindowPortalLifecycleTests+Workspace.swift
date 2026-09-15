import CmuxTerminal
import GhosttyKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
    func makeTrackedTerminalSurface() -> TerminalSurface {
        let workspace = testWorkspace ?? TerminalPortalTestWorkspace()
        testWorkspace = workspace
        XCTAssertTrue(Workspace.portalRenderingEnabled(for: workspace.id))
        let surface = TerminalSurface(
            tabId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        trackedSurfaces.append(surface)
        return surface
    }
}
