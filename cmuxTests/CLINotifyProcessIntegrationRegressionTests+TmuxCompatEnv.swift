import XCTest
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Tmux compat launch env
extension CLINotifyProcessIntegrationRegressionTests {
    // E2E for #4920: the REAL CLI launcher env builder (configureTmuxCompatEnvironment, exercised via
    // the hidden __debug-tmux-compat-env seam) must stamp the LAUNCH surface (the launcher's own
    // inherited env), not the operator's focused pane returned by system.identify. Without the fix it
    // stamped the focused surface (A), desyncing CMUX_SURFACE_ID from CMUX_PANEL_ID and jumbling codex
    // into the wrong surface on reload.
    func testTmuxCompatEnvStampsLaunchSurfaceNotFocusedPane() throws {
        let cliPath = try bundledCLIPath()
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-spawn-id-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let socketPath = tmpDir.appendingPathComponent("sock").path
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer { Darwin.close(listenerFD); unlink(socketPath) }
        let state = MockSocketServerState()

        // The operator's FOCUSED pane is surface A (what system.identify returns).
        let focusedWorkspace = "11111111-1111-1111-1111-111111111111"
        let focusedSurface = "22222222-2222-2222-2222-222222222222"
        let handled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }
            if method == "system.identify" {
                return self.v2Response(id: id, ok: true, result: [
                    "focused": [
                        "workspace_id": focusedWorkspace,
                        "surface_id": focusedSurface,
                        "pane_id": "%1",
                    ],
                ])
            }
            // resolveWorkspaceId / tmuxCanonicalPaneId fail gracefully (CLI uses try?).
            return self.v2Response(id: id, ok: false, error: ["code": "unsupported", "message": method])
        }

        // ...but the launcher RUNS in surface B (its own inherited env). Tab id is surface-scoped, so
        // it is distinct from the workspace id.
        let launchWorkspace = "33333333-3333-3333-3333-333333333333"
        let launchSurface = "44444444-4444-4444-4444-444444444444"
        let launchTab = "55555555-5555-5555-5555-555555555555"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["__debug-tmux-compat-env"],
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_WORKSPACE_ID": launchWorkspace,
                "CMUX_SURFACE_ID": launchSurface,
                "CMUX_PANEL_ID": launchSurface,
                "CMUX_TAB_ID": launchTab,
                "HOME": tmpDir.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: 30
        )
        wait(for: [handled], timeout: 30)

        XCTAssertTrue(
            result.stdout.contains("CMUX_SURFACE_ID=\(launchSurface)"),
            "launcher must stamp the LAUNCH surface; stdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
        )
        XCTAssertFalse(
            result.stdout.contains("CMUX_SURFACE_ID=\(focusedSurface)"),
            "launcher must NOT stamp the focused surface; stdout:\n\(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("CMUX_WORKSPACE_ID=\(launchWorkspace)"), result.stdout)
        // Matched-pair invariant: SURFACE == PANEL (the desync is exactly the bug). The surface-scoped
        // tab id passes through untouched.
        XCTAssertTrue(result.stdout.contains("CMUX_PANEL_ID=\(launchSurface)"), result.stdout)
        XCTAssertTrue(result.stdout.contains("CMUX_TAB_ID=\(launchTab)"), result.stdout)
    }
}
