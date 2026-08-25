import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("TextBox Escape passthrough", .serialized)
struct TextBoxEscapePassthroughTests {
    @Test
    func runningAgentReceivesEscapeFromTextBox() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "claude_code",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape from TextBox must reach the PTY while the focused agent turn is running"
        )
    }

    @Test
    func runningCampfireAgentReceivesEscapeFromTextBox() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "campfire",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "campfire",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape from TextBox must reach a running Campfire agent"
        )
    }

    @Test
    func focusedTextBoxKeyDownRoutesOneEscapeToRunningAgent() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "claude_code",
                panelId: fixture.panel.id
            )
        }

        let windowIdentifier = "cmux.main.\(fixture.windowID.uuidString)"
        let window = try #require(
            NSApp.windows.first { $0.identifier?.rawValue == windowIdentifier }
        )
        let contentView = try #require(window.contentView)
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        contentView.addSubview(scrollView)
        defer { scrollView.removeFromSuperview() }

        textView.onFocusTextBox = { fixture.panel.textBoxDidBecomeFocused() }
        textView.onEscape = { fixture.panel.handleTextBoxEscape() }
        fixture.panel.hostedView.setVisibleInUI(true)
        fixture.panel.hostedView.setActive(true)
        fixture.panel.hostedView.moveFocus()
        fixture.panel.registerTextBoxInputView(textView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        let sentinelDraft = "unsubmitted sentinel draft"
        textView.string = sentinelDraft
        #expect(window.makeFirstResponder(textView))
        #expect(window.firstResponder === textView)

        let escapeEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        textView.keyDown(with: escapeEvent)

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "A physical Escape handled by the focused TextBox must enqueue exactly one PTY key event"
        )
        #expect(textView.string == sentinelDraft, "Escape must preserve the unsubmitted TextBox draft")
        #expect(fixture.panel.isTextBoxActive, "The first Escape must leave TextBox visible")
        #expect(window.firstResponder !== textView, "The first Escape must transfer focus back to the terminal")
    }

    @Test
    func idleAgentDoesNotReceiveEscapeFromTextBox() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .idle
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "claude_code",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents,
            "Escape must retain TextBox focus behavior when the agent is not running"
        )
    }

    @Test
    func unsupportedRunningLifecycleDoesNotReceiveEscapeFromTextBox() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }

        fixture.workspace.setAgentLifecycle(
            key: "unsupported-agent",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        defer {
            _ = fixture.workspace.clearAgentLifecycle(
                key: "unsupported-agent",
                panelId: fixture.panel.id
            )
        }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents,
            "Unsupported lifecycle keys must not authorize PTY Escape passthrough"
        )
    }

    @Test
    func runningDockAgentReceivesEscapeFromTextBox() {
        let fixture = makeDockFixture()
        defer { fixture.dock.closeAllPanels() }

        fixture.dock.setAgentLifecycle(
            key: "claude_code",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents + 1,
            "Escape passthrough must follow a running agent into the Dock"
        )
    }

    @Test
    func manualDockActivityDoesNotReceiveEscapeFromTextBox() {
        let fixture = makeDockFixture()
        defer { fixture.dock.closeAllPanels() }

        fixture.dock.setAgentLifecycle(
            key: "manual:loader",
            panelId: fixture.panel.id,
            lifecycle: .running
        )
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        fixture.panel.handleTextBoxEscape()

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(
            after.keyEvents == before.keyEvents,
            "Manual loading activity must not be treated as a running agent turn"
        )
    }

    private func makeWorkspaceFixture() throws -> (
        windowID: UUID,
        workspace: Workspace,
        panel: TerminalPanel
    ) {
        let appDelegate = try #require(AppDelegate.shared)
        let windowID = appDelegate.createMainWindow()
        do {
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowID))
            let workspace = try #require(manager.selectedWorkspace)
            let panelID = try #require(workspace.focusedPanelId)
            let panel = try #require(workspace.terminalPanel(for: panelID))

            panel.showTextBoxInputWhenAvailable()
            panel.surface.releaseSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func makeDockFixture() -> (
        dock: DockSplitStore,
        panel: TerminalPanel
    ) {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = TerminalPanel(
            workspaceId: dock.workspaceId,
            runtimeSpawnPolicy: .pacedSessionRestore
        )
        dock.panels[panel.id] = panel
        panel.showTextBoxInputWhenAvailable()
        panel.surface.releaseSurfaceForTesting()
        return (dock, panel)
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
