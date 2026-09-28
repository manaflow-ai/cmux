import AppKit
import CmuxSettings
import CmuxTerminalCore
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
    func tooltipsShowKeysAsGlyphs() {
        #expect(GhosttyNSView.agentKeyHintDisplay("ctrl+o") == "⌃O")
        #expect(GhosttyNSView.agentKeyHintDisplay("shift+tab") == "⇧⇥")
        #expect(GhosttyNSView.agentKeyHintDisplay("escape") == "⎋")
        #expect(GhosttyNSView.agentKeyHintToolTip(keys: ["ctrl+o"], action: "expand", needsCommand: false).contains("⌃O"))
    }

    @Test
    func tooltipsAddThePhysicalKeysWhenTheyDiffer() throws {
        let o = try #require(PhysicalKey(karabinerKeyCode: "o"))
        let capsLock = PhysicalKeyAdvice(
            keyboardNames: ["Built-in"],
            appliesToEveryKeyboard: true,
            chords: [PhysicalKeyChord(modifiers: [.capsLock], key: o)],
            notes: [PhysicalKeyNote(physical: .capsLock, sends: .leftControl)],
            viaKarabinerRule: false
        )
        let external = PhysicalKeyAdvice(
            keyboardNames: ["External Keyboard"],
            appliesToEveryKeyboard: false,
            chords: [PhysicalKeyChord(modifiers: [.leftCommand], key: o)],
            notes: [],
            viaKarabinerRule: true
        )
        let plain = GhosttyNSView.agentKeyHintToolTip(keys: ["ctrl+o"], action: "expand", needsCommand: false)
        #expect(!plain.contains("\n"))

        let lines = GhosttyNSView.agentKeyHintToolTip(
            keys: ["ctrl+o"],
            action: "expand",
            needsCommand: false,
            physicalKeys: [capsLock, external]
        ).components(separatedBy: "\n")
        #expect(lines.count == 3)
        #expect(lines[0] == plain)
        #expect(lines[1].contains("⇪O"))
        #expect(lines[1].contains(GhosttyNSView.agentKeyHintKeyName(.capsLock)))
        #expect(lines[1].contains(GhosttyNSView.agentKeyHintKeyName(.leftControl)))
        #expect(!lines[1].contains("Built-in"))
        #expect(lines[2].contains("External Keyboard"))
        #expect(lines[2].contains("⌘O"))
        #expect(lines[2].contains("Karabiner-Elements"))
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
