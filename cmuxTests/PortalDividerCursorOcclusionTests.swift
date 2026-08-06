import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PortalDividerCursorOcclusionTests {
    @Test func sameTopmostWindowMayAssertCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 10 }

        #expect(occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func overlappingWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 11 }

        #expect(!occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func nilPointerWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in nil }

        #expect(!occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func nilHostWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 10 }

        #expect(!occlusion.mayAssertDividerCursor(in: nil))
    }

    @Test func terminalPortalFindsLeftToolDividerAfterVisibleWorkspaceSidebar() {
        let bounds = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let dockFrame = NSRect(x: 220, y: 0, width: 280, height: 800)
        let workspaceFrame = NSRect(x: 500, y: 0, width: 700, height: 800)

        #expect(
            WindowTerminalHostView.leftToolSidebarDividerX(
                contentFrames: [workspaceFrame],
                dockFrames: [dockFrame],
                bounds: bounds
            ) == 500
        )
    }

    @Test func terminalPortalFindsLeftToolDividerWithWorkspaceSidebarHidden() {
        let bounds = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let dockFrame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let workspaceFrame = NSRect(x: 280, y: 0, width: 920, height: 800)

        #expect(
            WindowTerminalHostView.leftToolSidebarDividerX(
                contentFrames: [workspaceFrame],
                dockFrames: [dockFrame],
                bounds: bounds
            ) == 280
        )
    }

    @Test func browserPortalFindsLeftToolDividerAfterVisibleWorkspaceSidebar() {
        let bounds = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let dockFrame = NSRect(x: 220, y: 0, width: 280, height: 800)
        let workspaceFrame = NSRect(x: 500, y: 0, width: 700, height: 800)

        #expect(
            WindowBrowserHostView.leftToolSidebarDividerX(
                contentFrames: [workspaceFrame],
                dockFrames: [dockFrame],
                bounds: bounds
            ) == 500
        )
    }

    @Test func browserPortalFindsLeftToolDividerWithWorkspaceSidebarHidden() {
        let bounds = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let dockFrame = NSRect(x: 0, y: 0, width: 280, height: 800)
        let workspaceFrame = NSRect(x: 280, y: 0, width: 920, height: 800)

        #expect(
            WindowBrowserHostView.leftToolSidebarDividerX(
                contentFrames: [workspaceFrame],
                dockFrames: [dockFrame],
                bounds: bounds
            ) == 280
        )
    }
}
