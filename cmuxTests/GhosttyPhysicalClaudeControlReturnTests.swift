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
        let surfaceView = try #require(findSurfaceView(in: surface.hostedView))

        surface.synchronizePromptInputAgentScope(
            "agentPIDKey:claude.physical-control-return",
            controlReturnIsPromptSubmissionBoundary: true
        )
        surface.recordHumanPromptInput(.unknown)

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(kVK_Return)
        keyEvent.mods = GHOSTTY_MODS_CTRL
        surfaceView.recordPromptOwnershipAfterAcceptedGhosttyKey(keyEvent)

        #expect(
            surface.confirmPromptSubmission(message: "human prompt")
                == .human
        )
        #expect(!surface.hasUnconfirmedHumanPromptInput)
    }

    @Test
    func markedPreeditClaimsHumanPromptOwnership() throws {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        defer { surface.releaseSurfaceForTesting() }
        let surfaceView = try #require(findSurfaceView(in: surface.hostedView))

        surface.synchronizePromptInputAgentScope("agentPIDKey:ime.preedit")
        surfaceView.setMarkedText(
            "ㅎ",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(
            surface.hasUnconfirmedHumanPromptInput,
            "An active AppKit preedit must block automation before a key reaches Ghostty"
        )
    }

    @Test
    func japaneseConversionReturnDoesNotCreatePromptBoundary() throws {
        _ = NSApplication.shared
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            GhosttyNSView.debugGhosttySurfaceKeyEventObserver = nil
            KeyboardLayout.debugInputSourceIdOverride = nil
            cjkIMEInterpretKeyEventsHook = nil
            window.orderOut(nil)
            surface.releaseSurfaceForTesting()
        }

        let contentView = try #require(window.contentView)
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let surfaceView = try #require(findSurfaceView(in: hostedView))
        surface.synchronizePromptInputAgentScope("agentPIDKey:ime.japanese")
        surfaceView.setMarkedText(
            "に",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        KeyboardLayout.debugInputSourceIdOverride = "com.apple.inputmethod.Japanese"
        installCJKIMEInterpretKeyEventsSwizzle()
        cjkIMEInterpretKeyEventsHook = { candidateView, _ in
            guard candidateView === surfaceView else { return false }
            candidateView.insertText(
                "日",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            return true
        }

        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(window.makeFirstResponder(surfaceView))
        surfaceView.keyDown(with: event)

        #expect(
            surface.confirmPromptSubmission(message: "日") == .unmatched,
            "Japanese conversion Return commits text but does not submit the terminal prompt"
        )
        #expect(surface.hasUnconfirmedHumanPromptInput)
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
