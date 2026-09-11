import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSwitchBrowserTests {
    @Test
    func interactionReadinessUsesTheDestinationWorkspaceBoundary() {
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let capturedWebView = WKWebView(frame: .zero)
        let focusedWebView = WKWebView(frame: .zero)
        let coordinator = WorkspaceSwitchCoordinator(
            beginRendererProtection: { _, _, _ in },
            endRendererProtection: { _ in }
        )

        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: nil,
            targetTerminalView: nil,
            targetRendererPresented: false,
            targetRenderedFrameSequence: 0
        )
        coordinator.beginPresentation(
            WorkspaceSwitchPresentationTarget(
                workspaceID: targetWorkspaceID,
                contentKind: .browser,
                terminalSurfaceID: nil,
                terminalView: nil,
                terminalRendererPresented: false,
                terminalRenderedFrameSequence: 0,
                browserWebView: capturedWebView,
                portalPresented: true,
                interactionReady: false,
                requiresInteraction: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )
        coordinator.sourceDidRetire(workspaceID: sourceWorkspaceID)
        #expect(coordinator.isMeasuringSwitch)

        coordinator.noteBrowserInteractionReady(
            workspaceID: targetWorkspaceID,
            webView: focusedWebView
        )

        #expect(!coordinator.isMeasuringSwitch)
    }
}
