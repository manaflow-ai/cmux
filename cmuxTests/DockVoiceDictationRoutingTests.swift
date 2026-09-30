import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension DockShortcutRoutingTests {
    @Test("Voice dictation follows Dock focus and fails closed for other sidebar modes")
    @MainActor
    func voiceDictationFocusUsesAuthoritativeSidebarOwner() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.withHarness { harness in
                let dockTerminalID = try #require(
                    harness.dock.newSurface(
                        kind: .terminal,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                let dockTerminal = try #require(
                    harness.dock.panels[dockTerminalID] as? TerminalPanel
                )

                // AppKit can still report the main terminal while a Dock
                // surface owns the focus intent. The resolver must follow the
                // window-scoped Dock selection in that transition.
                harness.dock.focusPanel(dockTerminalID)
                #expect(
                    harness.appDelegate.voiceDictationFocusedTerminalTarget()?.panel ===
                        dockTerminal
                )

                // A non-terminal sidebar owns focus, so routing to the main
                // workspace terminal would be unsafe and must fail closed.
                harness.appDelegate.noteRightSidebarKeyboardFocusIntent(
                    mode: .files,
                    in: harness.window
                )
                #expect(
                    harness.appDelegate.voiceDictationFocusedTerminalTarget()?.panel ==
                        nil
                )

                // Even in Dock mode, a focused browser is not an insertable
                // terminal target for this coordinator.
                harness.appDelegate.noteRightSidebarKeyboardFocusIntent(
                    mode: .dock,
                    in: harness.window
                )
                let dockBrowserID = try #require(
                    harness.dock.newSurface(
                        kind: .browser,
                        inPane: harness.rootPane,
                        focus: true
                    )
                )
                harness.dock.focusPanel(dockBrowserID)
                #expect(
                    harness.appDelegate.voiceDictationFocusedTerminalTarget()?.panel ==
                        nil
                )
            }
        }
    }
}
