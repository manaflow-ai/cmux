import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Restorable agent index hook records
extension SocketListenerAcceptPolicyTests {
    func testRestorableAgentIndexLoadsLaunchCommandFromHookStore() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("codex-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "codex-session-123": {
              "sessionId": "codex-session-123",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 123,
              "launchCommand": {
                "launcher": "codex",
                "executablePath": "/usr/local/bin/codex",
                "arguments": [
                  "/usr/local/bin/codex",
                  "--model",
                  "gpt-5.4",
                  "--search",
                  "old prompt"
                ],
                "workingDirectory": "/tmp/repo",
                "environment": {
                  "CODEX_HOME": "/tmp/codex"
                },
                "capturedAt": 122,
                "source": "process"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let index = RestorableAgentSessionIndex.load(homeDirectory: home.path)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.launchCommand?.arguments.first, "/usr/local/bin/codex")
        XCTAssertEqual(
            snapshot.resumeCommand,
            "{ cd -- '/tmp/repo' 2>/dev/null || [ ! -d '/tmp/repo' ]; } && 'env' 'CODEX_HOME=/tmp/codex' '/usr/local/bin/codex' 'resume' 'codex-session-123' '--model' 'gpt-5.4' '--search'"
        )
    }

    func testRestorableAgentIndexUsesNewerProcessFallbackOverStaleOmoHookRecord() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "hook-session": {
              "sessionId": "hook-session",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 10,
              "launchCommand": {
                "launcher": "omo",
                "executablePath": "/usr/local/bin/cmux",
                "arguments": [
                  "/usr/local/bin/cmux",
                  "omo",
                  "--model",
                  "anthropic/claude-sonnet-4-6",
                  "/tmp/repo",
                  "old prompt"
                ],
                "workingDirectory": "/tmp/repo",
                "environment": {
                  "OPENCODE_CONFIG_DIR": "/tmp/opencode"
                },
                "capturedAt": 9,
                "source": "environment"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "process-session",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/repo",
                environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
                capturedAt: 999,
                source: "process"
            )
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: [123]
                ),
            ]
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, "process-session")
        XCTAssertEqual(snapshot.launchCommand?.launcher, "opencode")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

    func testRestorableAgentIndexUsesNewerProcessFallbackForPlainHookRecord() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-agent-hook-store-\(UUID().uuidString)", isDirectory: true)
        let storeDir = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try fileManager.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let storeURL = storeDir.appendingPathComponent("opencode-hook-sessions.json", isDirectory: false)
        let json = """
        {
          "version": 1,
          "sessions": {
            "old-hook-session": {
              "sessionId": "old-hook-session",
              "workspaceId": "\(workspaceId.uuidString)",
              "surfaceId": "\(panelId.uuidString)",
              "cwd": "/tmp/repo",
              "updatedAt": 10,
              "launchCommand": {
                "launcher": "opencode",
                "executablePath": "/opt/homebrew/bin/opencode",
                "arguments": ["/opt/homebrew/bin/opencode"],
                "workingDirectory": "/tmp/repo",
                "source": "environment"
              }
            }
          }
        }
        """
        try json.write(to: storeURL, atomically: true, encoding: .utf8)

        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .opencode,
            sessionId: "live-process-session",
            workingDirectory: "/tmp/repo",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "opencode",
                executablePath: "/opt/homebrew/bin/opencode",
                arguments: ["/opt/homebrew/bin/opencode"],
                workingDirectory: "/tmp/repo",
                environment: nil,
                capturedAt: nil,
                source: "process"
            )
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: home.path,
            fileManager: fileManager,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                    snapshot: detectedSnapshot,
                    updatedAt: 999,
                    processIDs: [456]
                ),
            ]
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, "live-process-session")
        XCTAssertEqual(snapshot.launchCommand?.source, "process")
    }

}
