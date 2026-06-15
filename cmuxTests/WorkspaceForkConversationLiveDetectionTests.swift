import Combine
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceForkConversationLiveDetectionTests: XCTestCase {
    private func makeForkableCodexSnapshot(
        sessionId: String = "019dad34-d218-7943-b81a-eddac5c87951",
        workingDirectory: String = "/tmp/fork repo"
    ) -> SessionRestorableAgentSnapshot {
        SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "codex",
                executablePath: "/Users/example/.bun/bin/codex",
                arguments: ["/Users/example/.bun/bin/codex"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }

    private func processSnapshot(
        workspace: Workspace,
        panelId: UUID,
        processId: Int,
        name: String,
        path: String
    ) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: name,
                    path: path,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspace.id,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                ),
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    func testForkConversationContextMenuAvailabilityUsesProcessDetectedLiveIndex() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = SharedLiveAgentIndex.loadIndexForRefresh(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (makeForkableCodexSnapshot(), 123, Set([4_242]), .explicit)]
        )

        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
    }

    func testForkConversationContextMenuAvailabilityUsesLiveCodexProcessDetection() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_242
        let sessionId = "019dad34-d218-7943-b81a-eddac5c87951"
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot(workspace: workspace, panelId: panelId, processId: processId, name: "codex", path: "/tmp/codex"),
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/tmp/codex", "resume", sessionId, "--model", "gpt-5.4"],
                    environment: ["PWD": "/tmp/fork repo", "CODEX_HOME": "/tmp/codex"]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            fileManager: FileManager.default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.launchCommand?.arguments.first, "/tmp/codex")
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("'fork' '\(sessionId)'") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Live Codex processes should be indexed by their cmux panel")
    }

    func testForkConversationContextMenuAvailabilityUsesLiveCodexThreadEnvironment() throws {
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_243
        let sessionId = "019ec88f-6b52-78e2-ac9b-d8d211ee4d15"
        let processArguments = [
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
            "-c",
            "openai_base_url=\"http://subrouter-team:31415/v1\"",
        ]
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot(
                workspace: workspace,
                panelId: panelId,
                processId: processId,
                name: "codex",
                path: "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"
            ),
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: processArguments,
                    environment: [
                        "PWD": "/tmp/fork repo",
                        "CODEX_THREAD_ID": sessionId,
                    ]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            fileManager: FileManager.default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .codex)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.launchCommand?.arguments, processArguments)
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("'fork' '\(sessionId)'") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Interactive Codex processes should fall back to CODEX_THREAD_ID")
    }

    func testForkConversationContextMenuAvailabilityUsesLiveClaudeTranscriptDetection() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-claude-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectDir = configDir
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "11111111-1111-1111-1111-111111111111"
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try """
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let processId = 4_244
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: []),
            fileManager: fm,
            processSnapshot: processSnapshot(
                workspace: workspace,
                panelId: panelId,
                processId: processId,
                name: "claude.exe",
                path: "/opt/homebrew/bin/claude"
            ),
            capturedAt: 123,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["claude"],
                    environment: [
                        "PWD": cwd.path,
                        "CLAUDE_CONFIG_DIR": configDir.path,
                    ]
                )
            }
        )
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: detectedSnapshots
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspace.id, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .claude)
        XCTAssertEqual(snapshot.sessionId, sessionId)
        XCTAssertEqual(snapshot.workingDirectory, cwd.path)
        XCTAssertEqual(index.processIDs(workspaceId: workspace.id, panelId: panelId), Set([processId]))
        XCTAssertTrue(snapshot.forkCommand?.contains("--fork-session") == true)
        XCTAssertTrue(workspace.canForkAgentConversationFromPanel(panelId, liveAgentIndex: index))
        XCTAssertNotNil(detectedSnapshots[key], "Live Claude processes should be indexed from their transcript")
    }

    func testSharedLiveAgentIndexRefreshPublishesWorkspaceAfterNewIndexIsReadable() throws {
        SharedLiveAgentIndex.shared.resetForTesting()
        let workspace = Workspace()
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspace.id, panelId: panelId)
        let index = SharedLiveAgentIndex.loadIndexForRefresh(
            homeDirectory: FileManager.default.temporaryDirectory.path,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [key: (makeForkableCodexSnapshot(), 123, Set([4_242]), .explicit)]
        )

        var workspacePublishedAfterIndexWasReadable = false
        let cancellable = workspace.objectWillChange.sink { _ in
            workspacePublishedAfterIndexWasReadable = workspace.canForkAgentConversationFromPanel(
                panelId,
                liveAgentIndex: SharedLiveAgentIndex.shared.index
            )
        }
        defer {
            cancellable.cancel()
            SharedLiveAgentIndex.shared.resetForTesting()
        }

        SharedLiveAgentIndex.shared.replaceIndexForTesting(index)

        XCTAssertTrue(
            workspacePublishedAfterIndexWasReadable,
            "Tab context-menu availability must be invalidated after the refreshed live-agent index is readable"
        )
    }
}
