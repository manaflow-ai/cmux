import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct RestorableAgentSessionStalePIDTests {
    @Test func stalePIDHookRecordStillRestoresAndForks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-stale-pid-fork-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        setenv("CMUX_AGENT_HOOK_STATE_DIR", stateDir.path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }

        let ws = UUID()
        let panel = UUID()
        let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        var record = driftedAgentHookRecord(
            launcher: "codex",
            sessionId: sid,
            workspaceId: ws,
            panelId: panel,
            recordedCwd: dir.path,
            launchCwd: dir.path,
            updatedAt: 10
        )
        record["pid"] = 987_654_321
        try writeHookStore(
            root: root,
            storeFilename: "codex-hook-sessions.json",
            sessions: [sid: record]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        let snapshot = try #require(
            index.snapshot(workspaceId: ws, panelId: panel),
            "A dead saved PID must not erase the restorable/forkable session snapshot."
        )

        #expect(snapshot.sessionId == sid)
        #expect(index.processIDs(workspaceId: ws, panelId: panel) == [])
        #expect(!index.hasLiveProcess(workspaceId: ws, panelId: panel))
        let fork = try #require(snapshot.forkCommand)
        #expect(fork.contains("'fork' '\(sid)'"), "codex fork command expected; got: \(fork)")
    }

    @Test func newerStalePIDHookRecordDoesNotReplaceLivePanelRecord() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-live-pid-preserved-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let previousHookStateDir = getenv("CMUX_AGENT_HOOK_STATE_DIR").map { String(cString: $0) }
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        setenv("CMUX_AGENT_HOOK_STATE_DIR", stateDir.path, 1)
        defer {
            if let previousHookStateDir {
                setenv("CMUX_AGENT_HOOK_STATE_DIR", previousHookStateDir, 1)
            } else {
                unsetenv("CMUX_AGENT_HOOK_STATE_DIR")
            }
        }

        let ws = UUID()
        let panel = UUID()
        let livePID = 12_345
        let liveSID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let staleSID = "ffffffff-1111-2222-3333-444444444444"
        var liveRecord = driftedAgentHookRecord(
            launcher: "codex",
            sessionId: liveSID,
            workspaceId: ws,
            panelId: panel,
            recordedCwd: dir.path,
            launchCwd: dir.path,
            updatedAt: 10
        )
        liveRecord["pid"] = livePID
        var staleRecord = driftedAgentHookRecord(
            launcher: "codex",
            sessionId: staleSID,
            workspaceId: ws,
            panelId: panel,
            recordedCwd: dir.path,
            launchCwd: dir.path,
            updatedAt: 20
        )
        staleRecord["pid"] = 987_654_321
        try writeHookStore(
            root: root,
            storeFilename: "codex-hook-sessions.json",
            sessions: [
                liveSID: liveRecord,
                staleSID: staleRecord,
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [:],
            processArgumentsProvider: { pid in
                guard pid == livePID else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/codex"],
                    environment: [
                        "CMUX_WORKSPACE_ID": ws.uuidString,
                        "CMUX_SURFACE_ID": panel.uuidString,
                    ]
                )
            }
        )
        let snapshot = try #require(
            index.snapshot(workspaceId: ws, panelId: panel),
            "A newer dead hook record must not overwrite scoped live process evidence."
        )

        #expect(snapshot.sessionId == liveSID)
        #expect(index.processIDs(workspaceId: ws, panelId: panel) == [livePID])
        #expect(index.hasLiveProcess(workspaceId: ws, panelId: panel))
    }

    private func driftedAgentHookRecord(
        launcher: String,
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": launcher,
                "executablePath": "/usr/local/bin/\(launcher)",
                "arguments": ["/usr/local/bin/\(launcher)"],
                "workingDirectory": launchCwd,
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func writeHookStore(
        root: URL,
        storeFilename: String,
        sessions: [String: [String: Any]]
    ) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDir.appendingPathComponent(storeFilename, isDirectory: false),
            options: .atomic
        )
    }
}
