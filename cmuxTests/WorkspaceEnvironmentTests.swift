import CmuxTerminal
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Behavior coverage for per-workspace user-defined environment variables
/// (issue #5995): the initial shell inherits them, every later pane/split
/// inherits them, they survive session restore, explicit per-surface env wins,
/// and the managed `CMUX_*` variables can never be clobbered.
@Suite(.serialized)
@MainActor
struct WorkspaceEnvironmentTests {

    // MARK: - Sanitization

    @Test
    func sanitizedWorkspaceEnvironmentTrimsKeysAndDropsBlanks() {
        let result = SurfaceCreationCoordinator.sanitizedWorkspaceEnvironment([
            "  FOO  ": "bar",   // key is trimmed
            "": "ignored",      // blank key is dropped
            "EMPTY": "",        // blank value is dropped (matches additionalEnvironment)
            "OK": "value",
        ])
        #expect(result == ["FOO": "bar", "OK": "value"])
    }

    /// Regression for the Swift→C truncation bypass: a NUL in a key collapses it
    /// at `strdup`/Ghostty, so `"CMUX_SOCKET_PATH\0x"` would dodge the exact-match
    /// protection and overwrite the managed variable. NUL/`=` keys and NUL values
    /// must be rejected at the sanitizer (the single choke point).
    @Test
    func sanitizedWorkspaceEnvironmentRejectsKeysThatTruncateAtTheCBoundary() {
        let result = SurfaceCreationCoordinator.sanitizedWorkspaceEnvironment([
            "CMUX_SOCKET_PATH\u{0}x": "spoofed",  // NUL would truncate to CMUX_SOCKET_PATH
            "BAD=KEY": "v",                        // '=' is never a valid env var name
            "NUL_VALUE": "a\u{0}b",                // NUL in the value
            "GOOD": "value",
        ])
        #expect(result == ["GOOD": "value"])
    }

    // MARK: - Acceptance: initial shell inherits the workspace environment

    @Test
    func initialShellInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        let env = panel.surface.respawnInitialEnvironmentOverrides
        #expect(env["AWS_PROFILE"] == "prod")
        #expect(env["API_BASE"] == "https://api.example.com")
    }

    // MARK: - Acceptance: later panes/splits inherit it, with no per-pane re-export

    @Test
    func laterSurfaceInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod"])
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let second = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false))
        #expect(second.surface.respawnAdditionalEnvironment["AWS_PROFILE"] == "prod")
    }

    /// `newTerminalSplit` is the other later-surface choke point (splitting a
    /// surface into a new pane); it must fold in the workspace environment too.
    @Test
    func splitSurfaceInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod"])
        let firstPanelId = try #require(workspace.focusedPanelId)
        let split = try #require(workspace.newTerminalSplit(
            from: firstPanelId,
            orientation: .horizontal,
            focus: false
        ))
        #expect(split.surface.respawnAdditionalEnvironment["AWS_PROFILE"] == "prod")
    }

    /// The session-index drop path creates a terminal in a freshly split pane via
    /// `splitPaneWithNewTerminal`; it must inherit the workspace environment too.
    @Test
    func splitPaneWithNewTerminalInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod"])
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let panel = try #require(workspace.splitPaneWithNewTerminal(
            targetPane: paneId,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: nil,
            initialInput: nil
        ))
        #expect(panel.surface.respawnAdditionalEnvironment["AWS_PROFILE"] == "prod")
    }

    /// When the last surface exits it is replaced by a fresh local shell via
    /// `createReplacementTerminalPanel`; that shell must inherit the workspace env.
    @Test
    func replacementTerminalInheritsWorkspaceEnvironment() {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod"])
        let replacement = workspace.createReplacementTerminalPanel()
        #expect(replacement.surface.respawnAdditionalEnvironment["AWS_PROFILE"] == "prod")
    }

    /// A new terminal panel records the workspace env (key and value) it was seeded
    /// with, so a later respawn can drop a previous workspace's env when the surface
    /// has been moved (the same panel travels with the move) while preserving an
    /// explicit per-surface override that shares a workspace key.
    @Test
    func newPanelRecordsSeededWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "API_BASE": "https://x"])
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.terminalPanel(for: panelId))
        #expect(panel.seededWorkspaceEnvironment == ["AWS_PROFILE": "prod", "API_BASE": "https://x"])
    }

    /// An explicit per-surface environment (layout `env`, scrollback replay, SSH
    /// startup) overlays the workspace set rather than being discarded.
    @Test
    func explicitSurfaceEnvironmentOverridesWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "SHARED": "workspace"])
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let second = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            startupEnvironment: ["SHARED": "surface", "EXTRA": "x"]
        ))
        let env = second.surface.respawnAdditionalEnvironment
        #expect(env["SHARED"] == "surface")     // explicit wins
        #expect(env["AWS_PROFILE"] == "prod")    // workspace value preserved
        #expect(env["EXTRA"] == "x")
    }

    @Test
    func emptyWorkspaceEnvironmentLeavesSurfaceEnvironmentUntouched() throws {
        let workspace = Workspace()
        let firstPanelId = try #require(workspace.focusedPanelId)
        let paneId = try #require(workspace.paneId(forPanelId: firstPanelId))
        let second = try #require(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            startupEnvironment: ["ONLY": "surface"]
        ))
        #expect(second.surface.respawnAdditionalEnvironment == ["ONLY": "surface"])
    }

    // MARK: - Acceptance: persistence across session restore

    @Test
    func workspaceEnvironmentSurvivesSessionRestore() throws {
        let source = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        #expect(snapshot.environment == ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        #expect(restored.workspaceEnvironment == ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])

        let restoredPanelId = try #require(restored.focusedPanelId)
        let restoredPanel = try #require(restored.terminalPanel(for: restoredPanelId))
        // Restored terminals spawn fresh shells through newTerminalSurface, which
        // threads the workspace environment via additionalEnvironment.
        #expect(restoredPanel.surface.respawnAdditionalEnvironment["AWS_PROFILE"] == "prod")
    }

    @Test
    func emptyWorkspaceEnvironmentIsNotPersisted() {
        let workspace = Workspace()
        #expect(workspace.sessionSnapshot(includeScrollback: false).environment == nil)
    }

    // MARK: - Acceptance: managed CMUX_* variables cannot be clobbered

    /// Workspace env reaches a spawned shell through `additionalEnvironment` /
    /// `initialEnvironmentOverrides`, both of which `mergedStartupEnvironment`
    /// applies only for keys absent from `protectedKeys`. This proves a workspace
    /// env entry can never overwrite the variables the daemon relies on.
    @Test
    func workspaceEnvironmentCannotClobberProtectedCmuxVariables() {
        let merged = TerminalSurface.mergedStartupEnvironment(
            base: ["CMUX_WORKSPACE_ID": "real-id", "TERM": "xterm-ghostty"],
            protectedKeys: ["CMUX_WORKSPACE_ID", "TERM"],
            additionalEnvironment: [
                "CMUX_WORKSPACE_ID": "spoofed",   // must be ignored
                "TERM": "dumb",                    // must be ignored
                "AWS_PROFILE": "prod",             // must be applied
            ],
            initialEnvironmentOverrides: ["CMUX_WORKSPACE_ID": "also-spoofed"],
            ambientEnvironment: [:]
        )
        #expect(merged["CMUX_WORKSPACE_ID"] == "real-id")
        #expect(merged["TERM"] == "xterm-ghostty")
        #expect(merged["AWS_PROFILE"] == "prod")
    }

    // MARK: - Persistence schema (Codable)

    @Test
    func sessionWorkspaceSnapshotEnvironmentRoundTrips() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            environment: ["AWS_PROFILE": "prod"]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.environment == ["AWS_PROFILE": "prod"])
    }

    /// A manifest written before this feature has no `environment` key; it must
    /// decode cleanly with a nil environment (and a nil environment must not bloat
    /// new manifests).
    @Test
    func sessionWorkspaceSnapshotOmitsAndToleratesAbsentEnvironment() throws {
        let snapshot = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
        let data = try JSONEncoder().encode(snapshot)
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])
        #expect(object["environment"] == nil, "nil environment should be omitted from the manifest")
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.environment == nil)
    }

    // MARK: - Config entry point (cmux.json)

    @Test
    func cmuxWorkspaceDefinitionDecodesEnv() throws {
        let json = #"{"name":"Build","env":{"AWS_PROFILE":"prod","API_BASE":"https://api.example.com"}}"#
        let definition = try JSONDecoder().decode(CmuxWorkspaceDefinition.self, from: Data(json.utf8))
        #expect(definition.env == ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
    }

    @Test
    func cmuxWorkspaceDefinitionEnvIsOptional() throws {
        let definition = try JSONDecoder().decode(CmuxWorkspaceDefinition.self, from: Data(#"{"name":"Build"}"#.utf8))
        #expect(definition.env == nil)
    }
}
