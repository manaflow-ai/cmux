import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for AppKit interactions with a projected tmux pane.
@MainActor
@Suite(.serialized)
struct RemoteTmuxProjectedFocusInteractionTests {
    typealias Harness = RemoteTmuxMirrorPaneInputMappingTests.Harness

    @Test
    func splitPaneForwardsPointerActivationThroughProjectedFocus() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)

        let inactivePane = try #require(mirror.panel(forPane: 4))
        let activePane = try #require(mirror.panel(forPane: 5))
        #expect(harness.workspace.focusedPanelId != activePane.id)
        #expect(harness.workspace.isFocusedTerminalInputSurface(activePane.id))

        activePane.hostedView.surfaceView.desiredFocus = true
        inactivePane.hostedView.surfaceView.desiredFocus = true

        #expect(activePane.hostedView.surfaceView.terminalPointerShouldForwardActivation())
        #expect(!inactivePane.hostedView.surfaceView.terminalPointerShouldForwardActivation())
    }

    @Test
    func splitPaneMountedSearchFieldAcceptsProjectedFocus() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let mirror = try splitInitiallySinglePaneWindow(in: harness)
        let activePane = try #require(mirror.panel(forPane: 5))
        let window = try #require(
            NSApp.windows.first {
                $0.identifier?.rawValue == "cmux.main.\(harness.windowId.uuidString)"
            }
        )
        let hostedView = activePane.hostedView
        let searchState = TerminalSurface.SearchState(needle: "")
        defer {
            activePane.surface.searchState = nil
            hostedView.setSearchOverlay(searchState: nil)
        }

        window.makeKeyAndOrderFront(nil)
        hostedView.setVisibleInUI(true)
        hostedView.setActive(true)
        hostedView.moveFocus()
        activePane.surface.searchState = searchState
        hostedView.setSearchOverlay(searchState: searchState)

        #expect(waitUntil { self.editableTextField(in: hostedView) != nil })
        let searchField = try #require(editableTextField(in: hostedView))
        #expect(
            waitUntil {
                window.firstResponder === searchField
                    || searchField.currentEditor() === window.firstResponder
            },
            "Cmd-F must focus the mounted field for the projected active pane"
        )
    }

    private func splitInitiallySinglePaneWindow(
        in harness: Harness
    ) throws -> RemoteTmuxWindowMirror {
        harness.publishListWindows([
            "@2 f92f,80x24,0,0,4 f92f,80x24,0,0,4 [] zsh",
        ])
        try harness.drainThroughPaneRects([
            2: ["%4 0 0 80 24 1 off :0 \"host\""],
        ])
        let initialMirror = try harness.mirror()

        harness.connection.handleMessageForTesting(.layoutChange(
            windowId: 2,
            layout: "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0,5}",
            visibleLayout: nil,
            zoomed: false
        ))
        try harness.drainThroughPaneRects([2: [
            "%4 0 0 60 40 0 off :0 \"host\"",
            "%5 61 0 59 40 1 off :1 \"host\"",
        ]])
        harness.connection.handleMessageForTesting(
            .windowPaneChanged(windowId: 2, paneId: 5)
        )

        let mirror = try harness.mirror()
        #expect(mirror === initialMirror)
        #expect(mirror.activePaneId == 5)
        return mirror
    }

    private func editableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = editableTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.01))
        } while Date.now < deadline
        return condition()
    }
}
