import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class OpenCodeBridgeTests: XCTestCase {
    func testOMOResumeBehaviorParsesSessionContinueAndForkFlags() {
        let behavior = OMOResumeBehavior(commandArgs: [
            "--continue",
            "--session",
            "ses_parent",
            "--fork",
        ])

        XCTAssertTrue(behavior.continueLatestSession)
        XCTAssertEqual(behavior.sessionHint, "ses_parent")
        XCTAssertTrue(behavior.hasFork)
        XCTAssertFalse(behavior.shouldBackfillImmediately)
    }

    func testOMOBridgeStateStoreResetsAndPersistsChildren() throws {
        let stateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omo-bridge-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stateURL) }
        defer { try? FileManager.default.removeItem(at: stateURL.appendingPathExtension("lock")) }

        let store = OMOBridgeStateStore(processEnv: [
            "CMUX_OMO_STATE_PATH": stateURL.path
        ])

        try store.reset(workspaceId: "workspace_root", leaderSurfaceId: "surface_root")
        try store.mutate { state in
            state.rootSessionId = "ses_root"
            state.children["ses_child"] = OMOBridgeChildRecord(
                sessionId: "ses_child",
                surfaceId: "surface_child",
                paneId: "pane_child",
                title: "General",
                createdAt: 10,
                updatedAt: 10
            )
        }

        let state = try store.load()
        XCTAssertEqual(state.workspaceId, "workspace_root")
        XCTAssertEqual(state.leaderSurfaceId, "surface_root")
        XCTAssertEqual(state.rootSessionId, "ses_root")
        XCTAssertEqual(state.children["ses_child"]?.surfaceId, "surface_child")
        XCTAssertEqual(state.children["ses_child"]?.title, "General")
    }

    func testOMOAttachCommandWrapsChildAttachAndCleanup() {
        let cli = CMUXCLI(args: ["cmux"])
        let command = cli.omoAttachCommand(
            serverURL: "http://127.0.0.1:4096",
            sessionId: "ses_child",
            openCodeExecutablePath: "/usr/local/bin/opencode",
            configDirectory: "/tmp/omo config",
            processEnvironment: [
                "CMUX_OMO_CMUX_BIN": "/usr/local/bin/cmux",
                "OPENCODE_SERVER_PASSWORD": "secret-value",
            ],
            shimDirectoryPath: "/tmp/omo-bin"
        )

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -lc "))
        XCTAssertTrue(command.contains("CMUX_OMO_ROLE=child"))
        XCTAssertTrue(command.contains("OPENCODE_CONFIG_DIR"))
        XCTAssertTrue(command.contains("OPENCODE_SERVER_PASSWORD"))
        XCTAssertTrue(command.contains("session delete"))
        XCTAssertTrue(command.contains("attach http://127.0.0.1:4096 --session ses_child"))
    }
}
