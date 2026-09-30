import AppKit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Terminal agent key hints", .serialized)
struct TerminalAgentKeyHintTests {
    private let setting = AgentActionsCatalogSection().keyHints
    private let expandLine = "  ⎿  … +53 lines (ctrl+o to expand)"

    @Test
    func keyHintsAreLiveByDefault() {
        setting.removeValue(in: .standard)
        #expect(setting.value(in: .standard))
        #expect(AgentActionsCatalogSection().keyHintRestStyle.value(in: .standard) == .dotted)
    }

    @Test
    func clickOnAHintInAnAgentPaneSendsItsKey() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        let click = try #require(fixture.panel.agentKeyHintClick(
            line: expandLine, column: 20, inLiveRegion: false, mouseCaptured: false, modifierFlags: []
        ))
        #expect(click.hint.keys == ["ctrl+o"])
        #expect(fixture.panel.pressAgentKeyHint(click))

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 1)
    }

    @Test
    func aTwoChordHintSendsBothChords() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let before = fixture.panel.surface.debugPendingSocketInputForTesting()

        let click = try #require(fixture.panel.agentKeyHintClick(
            line: "  ctrl+b ctrl+b to run in background", column: 4, inLiveRegion: false, mouseCaptured: false, modifierFlags: []
        ))
        fixture.panel.pressAgentKeyHint(click)

        let after = fixture.panel.surface.debugPendingSocketInputForTesting()
        #expect(after.keyEvents == before.keyEvents + 2)
    }

    @Test
    func nothingIsClickableWhileTheSettingIsOff() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.removeValue(in: .standard)
        fixture.workspace.setAgentLifecycle(key: "codex", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "codex", panelId: fixture.panel.id) }

        #expect(fixture.panel.agentKeyHintClick(line: expandLine, column: 20, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil)
    }

    @Test
    func nothingIsClickableWithoutAnAgent() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }

        #expect(fixture.panel.agentKeyHintAgent == nil)
        #expect(fixture.panel.agentKeyHintClick(line: expandLine, column: 20, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil)
    }

    @Test
    func proseAndCellsOutsideTheHintAreNotClickable() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }

        for line in ["Everything is up to date.", "Press ctrl+c again to exit", "Run the end to end tests."] {
            for column in 0..<line.count {
                #expect(fixture.panel.agentKeyHintClick(line: line, column: column, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil, "\(line) @\(column)")
            }
        }
        #expect(fixture.panel.agentKeyHintClick(line: expandLine, column: 5, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil)
    }

    @Test
    func anAgentThatOwnsTheMouseNeedsACommandClick() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "opencode", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "opencode", panelId: fixture.panel.id) }
        let line = "esc interrupt"

        #expect(fixture.panel.agentKeyHintClick(line: line, column: 1, inLiveRegion: true, mouseCaptured: true, modifierFlags: []) == nil)
        #expect(fixture.panel.agentKeyHintClick(line: line, column: 1, inLiveRegion: true, mouseCaptured: true, modifierFlags: [.command])?.hint.keys == ["escape"])
        #expect(fixture.panel.agentKeyHintClick(line: line, column: 1, inLiveRegion: true, mouseCaptured: false, modifierFlags: [.shift]) == nil, "Shift-click extends a selection")
    }

    @Test
    func bareKeysAreClickableOnlyInTheLiveRegion() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }
        let status = "✻ Thinking… (esc to interrupt)"

        #expect(fixture.panel.agentKeyHintClick(line: status, column: 14, inLiveRegion: true, mouseCaptured: false, modifierFlags: [])?.hint.keys == ["escape"])
        #expect(fixture.panel.agentKeyHintClick(line: status, column: 14, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil)
        for line in ["Scroll down to view the full log", "we go up to open the file", "press home to go back"] {
            for column in 0..<line.count {
                #expect(fixture.panel.agentKeyHintClick(line: line, column: column, inLiveRegion: false, mouseCaptured: false, modifierFlags: []) == nil, "\(line) @\(column)")
            }
        }
    }

    @Test
    func aLiveAgentWinsOverAStaleLifecycle() {
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: [:]) == nil)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["claude_code": .idle]) == .claudeCode)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["claude_code": .idle, "codex": .running]) == .codex)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["claude_code": .unknown, "opencode": .needsInput]) == .openCode)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["claude_code": .unknown, "codex": .idle]) == .codex)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["claude_code": .running, "codex": .running]) == .claudeCode)
        #expect(TerminalPanel.agentKeyHintAgent(lifecycleStates: ["gemini": .running]) == nil)
    }

    @Test
    func deferredClickRequiresTheSameHintAgentLifecycleAndPolicy() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }

        let click = try #require(fixture.panel.agentKeyHintClick(
            line: expandLine,
            column: 20,
            inLiveRegion: false,
            mouseCaptured: true,
            modifierFlags: [.command]
        ))
        #expect(fixture.panel.revalidatedAgentKeyHintClick(
            click,
            line: expandLine,
            column: 20,
            inLiveRegion: false,
            mouseCaptured: true,
            modifierFlags: [.command]
        ) == click)
        #expect(fixture.panel.revalidatedAgentKeyHintClick(
            click,
            line: "  ⎿  … +53 lines (ctrl+p to expand)",
            column: 20,
            inLiveRegion: false,
            mouseCaptured: true,
            modifierFlags: [.command]
        ) == nil, "A different hint in the same cell must not inherit the click")

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .running)
        #expect(fixture.panel.revalidatedAgentKeyHintClick(
            click,
            line: expandLine,
            column: 20,
            inLiveRegion: false,
            mouseCaptured: true,
            modifierFlags: [.command]
        ) == nil, "A lifecycle transition cancels the deferred click")

        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        #expect(fixture.panel.revalidatedAgentKeyHintClick(
            click,
            line: expandLine,
            column: 20,
            inLiveRegion: false,
            mouseCaptured: false,
            modifierFlags: [.command]
        ) == nil, "A changed mouse-capture policy cancels even when both policies permit the click")

        _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id)
        fixture.workspace.setAgentLifecycle(key: "codex", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "codex", panelId: fixture.panel.id) }
        #expect(fixture.panel.revalidatedAgentKeyHintClick(
            click,
            line: expandLine,
            column: 20,
            inLiveRegion: false,
            mouseCaptured: true,
            modifierFlags: [.command]
        ) == nil, "A different agent must not inherit the click")
    }

    @Test
    func deferredClosureRejectsChangedFullRowAndRuntimeGeneration() throws {
        let fixture = try makeWorkspaceFixture()
        defer { closeWindow(fixture.windowID) }
        setting.set(true, in: .standard)
        defer { setting.removeValue(in: .standard) }
        fixture.workspace.setAgentLifecycle(key: "claude_code", panelId: fixture.panel.id, lifecycle: .idle)
        defer { _ = fixture.workspace.clearAgentLifecycle(key: "claude_code", panelId: fixture.panel.id) }

        let cell = TerminalAgentKeyHintCell(row: 12, column: 20)
        let viewport = TerminalAgentKeyHintViewportState(
            scrollbarTotal: 24,
            scrollbarOffset: 0,
            scrollbarLength: 24,
            rows: 24,
            columns: 80,
            cursorRow: 20,
            cursorColumn: 0
        )
        let click = try #require(fixture.panel.agentKeyHintClick(
            line: expandLine,
            column: cell.column,
            inLiveRegion: true,
            mouseCaptured: false,
            modifierFlags: []
        ))
        let generation = fixture.panel.surface.runtimeSurfaceGeneration
        let request = TerminalAgentKeyHintDeferredRequest(
            terminalSurfaceIdentity: ObjectIdentifier(fixture.panel.surface),
            runtimeSurfaceGeneration: generation,
            panelIdentity: ObjectIdentifier(fixture.panel),
            cell: cell,
            row: expandLine,
            viewport: viewport,
            click: click,
            modifierFlags: []
        )
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        var currentGeneration = generation
        var currentRow = expandLine
        var currentViewport = viewport
        var fired = 0
        func installDeferredClosure() {
            view.deferAgentKeyHintPress(
                request,
                currentSnapshot: {
                    TerminalAgentKeyHintDeferredSnapshot(
                        terminalSurface: fixture.panel.surface,
                        runtimeSurfaceGeneration: currentGeneration,
                        panel: fixture.panel,
                        cell: cell,
                        row: currentRow,
                        viewport: currentViewport,
                        hasSelection: false,
                        mouseCaptured: false
                    )
                },
                press: { _, _ in fired += 1 }
            )
        }

        installDeferredClosure()
        view.layout()
        view.clearAgentKeyHintHover()
        view.fireAgentKeyHintPendingPress(at: .greatestFiniteMagnitude)
        #expect(fired == 1, "No-op layout and pointer exit must preserve the released deferred callback")

        currentRow = "x ⎿  … +53 lines (ctrl+o to expand)"
        #expect(fixture.panel.agentKeyHintClick(
            line: currentRow,
            column: cell.column,
            inLiveRegion: true,
            mouseCaptured: false,
            modifierFlags: []
        ) == click, "The changed row deliberately keeps the same parsed hint and authorization")
        installDeferredClosure()
        view.fireAgentKeyHintPendingPress(at: .greatestFiniteMagnitude)
        #expect(fired == 1, "Different surrounding row text must cancel even when the same hint stays at the same cells")

        currentRow = expandLine
        installDeferredClosure()
        currentViewport = TerminalAgentKeyHintViewportState(
            scrollbarTotal: 25,
            scrollbarOffset: 0,
            scrollbarLength: 25,
            rows: 25,
            columns: 80,
            cursorRow: 21,
            cursorColumn: 0
        )
        view.layout()
        view.fireAgentKeyHintPendingPress(at: .greatestFiniteMagnitude)
        #expect(fired == 1, "A real viewport/grid change must reject the released deferred callback")

        currentViewport = viewport
        installDeferredClosure()
        currentGeneration &+= 1
        view.fireAgentKeyHintPendingPress(at: .greatestFiniteMagnitude)
        #expect(fired == 1, "A changed terminal runtime generation must cancel the deferred click")
    }

    @Test
    func noOpLayoutKeepsAReleasedDeferredClick() {
        let view = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        var fired = false
        view.agentKeyHintPointer.pressCell = TerminalAgentKeyHintCell(row: 1, column: 2)
        view.agentKeyHintPointer.pendingPress = { fired = true }
        view.agentKeyHintPointer.deferredPress.release(at: 10)

        view.layout()

        #expect(view.agentKeyHintPointer.pressCell == nil)
        #expect(view.agentKeyHintPointer.pendingPress != nil)
        #expect(view.agentKeyHintPointer.deferredPress.deadline != nil)
        view.fireAgentKeyHintPendingPress(at: .greatestFiniteMagnitude)
        #expect(fired)
    }

    @Test
    func tooltipsShowKeysAsGlyphs() {
        #expect(GhosttyNSView.agentKeyHintDisplay("ctrl+o") == "⌃O")
        #expect(GhosttyNSView.agentKeyHintDisplay("shift+tab") == "⇧⇥")
        #expect(GhosttyNSView.agentKeyHintDisplay("escape") == "⎋")
        #expect(GhosttyNSView.agentKeyHintToolTip(keys: ["ctrl+o"], action: "expand", needsCommand: false).contains("⌃O"))
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
            panel.surface.releaseHostedSurfaceForTesting()
            return (windowID, workspace, panel)
        } catch {
            closeWindow(windowID)
            throw error
        }
    }

    private func closeWindow(_ windowID: UUID) {
        let identifier = "cmux.main.\(windowID.uuidString)"
        NSApp.windows.first { $0.identifier?.rawValue == identifier }?.performClose(nil)
    }
}
