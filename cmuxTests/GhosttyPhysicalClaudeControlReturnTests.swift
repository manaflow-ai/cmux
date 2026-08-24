import AppKit
import Carbon.HIToolbox
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
@MainActor
@Suite("Ghostty physical Claude control-Return", .serialized)
struct GhosttyPhysicalClaudeControlReturnTests {
    @Test
    func acceptedPhysicalControlReturnCreatesRecoverablePromptBoundary() throws {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        defer { surface.releaseSurfaceForTesting() }
        _ = try #require(findSurfaceView(in: surface.hostedView))

        surface.synchronizePromptInputAgentScope(
            "agentPIDKey:claude.physical-control-return",
            controlReturnIsPromptSubmissionBoundary: true
        )
        surface.recordHumanPromptInput(.unknown)

        surface.recordHumanPromptKey(
            keycode: UInt32(kVK_Return),
            mods: GHOSTTY_MODS_CTRL
        )

        #expect(
            surface.confirmPromptSubmission(message: "human prompt")
                == .human
        )
        #expect(!surface.hasUnconfirmedHumanPromptInput)
    }

    private func findSurfaceView(in view: NSView) -> GhosttyNSView? {
        if let surfaceView = view as? GhosttyNSView {
            return surfaceView
        }
        for subview in view.subviews {
            if let surfaceView = findSurfaceView(in: subview) {
                return surfaceView
            }
        }
        return nil
    }
}
#endif
