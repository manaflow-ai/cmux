import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior coverage for per-workspace user-defined environment variables
/// (issue #5995): the initial shell inherits them, every later pane/split
/// inherits them, they survive session restore, explicit per-surface env wins,
/// and the managed `CMUX_*` variables can never be clobbered.
@MainActor
final class WorkspaceEnvironmentTests: XCTestCase {

    // MARK: - Sanitization

    func testSanitizedWorkspaceEnvironmentTrimsKeysAndDropsBlanks() {
        let result = Workspace.sanitizedWorkspaceEnvironment([
            "  FOO  ": "bar",   // key is trimmed
            "": "ignored",      // blank key is dropped
            "EMPTY": "",        // blank value is dropped (matches additionalEnvironment)
            "OK": "value",
        ])
        XCTAssertEqual(result, ["FOO": "bar", "OK": "value"])
    }

    // MARK: - Acceptance: initial shell inherits the workspace environment

    func testInitialShellInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        let env = panel.surface.respawnInitialEnvironmentOverrides
        XCTAssertEqual(env["AWS_PROFILE"], "prod")
        XCTAssertEqual(env["API_BASE"], "https://api.example.com")
    }

    // MARK: - Acceptance: later panes/splits inherit it, with no per-pane re-export

    func testLaterSurfaceInheritsWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod"])
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let second = try XCTUnwrap(workspace.newTerminalSurface(inPane: paneId, focus: false))
        XCTAssertEqual(second.surface.respawnAdditionalEnvironment["AWS_PROFILE"], "prod")
    }

    /// An explicit per-surface environment (layout `env`, scrollback replay, SSH
    /// startup) overlays the workspace set rather than being discarded.
    func testExplicitSurfaceEnvironmentOverridesWorkspaceEnvironment() throws {
        let workspace = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "SHARED": "workspace"])
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let second = try XCTUnwrap(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            startupEnvironment: ["SHARED": "surface", "EXTRA": "x"]
        ))
        let env = second.surface.respawnAdditionalEnvironment
        XCTAssertEqual(env["SHARED"], "surface")     // explicit wins
        XCTAssertEqual(env["AWS_PROFILE"], "prod")    // workspace value preserved
        XCTAssertEqual(env["EXTRA"], "x")
    }

    func testEmptyWorkspaceEnvironmentLeavesSurfaceEnvironmentUntouched() throws {
        let workspace = Workspace()
        let firstPanelId = try XCTUnwrap(workspace.focusedPanelId)
        let paneId = try XCTUnwrap(workspace.paneId(forPanelId: firstPanelId))
        let second = try XCTUnwrap(workspace.newTerminalSurface(
            inPane: paneId,
            focus: false,
            startupEnvironment: ["ONLY": "surface"]
        ))
        XCTAssertEqual(second.surface.respawnAdditionalEnvironment, ["ONLY": "surface"])
    }

    // MARK: - Acceptance: persistence across session restore

    func testWorkspaceEnvironmentSurvivesSessionRestore() throws {
        let source = Workspace(workspaceEnvironment: ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        XCTAssertEqual(snapshot.environment, ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])

        let restored = Workspace()
        restored.restoreSessionSnapshot(snapshot)
        XCTAssertEqual(restored.workspaceEnvironment, ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])

        let restoredPanelId = try XCTUnwrap(restored.focusedPanelId)
        let restoredPanel = try XCTUnwrap(restored.terminalPanel(for: restoredPanelId))
        // Restored terminals spawn fresh shells through newTerminalSurface, which
        // threads the workspace environment via additionalEnvironment.
        XCTAssertEqual(restoredPanel.surface.respawnAdditionalEnvironment["AWS_PROFILE"], "prod")
    }

    func testEmptyWorkspaceEnvironmentIsNotPersisted() {
        let workspace = Workspace()
        XCTAssertNil(workspace.sessionSnapshot(includeScrollback: false).environment)
    }

    // MARK: - Acceptance: managed CMUX_* variables cannot be clobbered

    /// Workspace env reaches a spawned shell through `additionalEnvironment` /
    /// `initialEnvironmentOverrides`, both of which `mergedStartupEnvironment`
    /// applies only for keys absent from `protectedKeys`. This proves a workspace
    /// env entry can never overwrite the variables the daemon relies on.
    func testWorkspaceEnvironmentCannotClobberProtectedCmuxVariables() {
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
        XCTAssertEqual(merged["CMUX_WORKSPACE_ID"], "real-id")
        XCTAssertEqual(merged["TERM"], "xterm-ghostty")
        XCTAssertEqual(merged["AWS_PROFILE"], "prod")
    }

    // MARK: - Persistence schema (Codable)

    func testSessionWorkspaceSnapshotEnvironmentRoundTrips() throws {
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
        XCTAssertEqual(decoded.environment, ["AWS_PROFILE": "prod"])
    }

    /// A manifest written before this feature has no `environment` key; it must
    /// decode cleanly with a nil environment (and a nil environment must not bloat
    /// new manifests).
    func testSessionWorkspaceSnapshotOmitsAndToleratesAbsentEnvironment() throws {
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
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["environment"], "nil environment should be omitted from the manifest")
        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        XCTAssertNil(decoded.environment)
    }

    // MARK: - Config entry point (cmux.json)

    func testCmuxWorkspaceDefinitionDecodesEnv() throws {
        let json = #"{"name":"Build","env":{"AWS_PROFILE":"prod","API_BASE":"https://api.example.com"}}"#
        let definition = try JSONDecoder().decode(CmuxWorkspaceDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(definition.env, ["AWS_PROFILE": "prod", "API_BASE": "https://api.example.com"])
    }

    func testCmuxWorkspaceDefinitionEnvIsOptional() throws {
        let definition = try JSONDecoder().decode(CmuxWorkspaceDefinition.self, from: Data(#"{"name":"Build"}"#.utf8))
        XCTAssertNil(definition.env)
    }
}
