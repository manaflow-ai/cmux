import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct CmuxTopAccountingGroupingTests {
    @Test func canonicalProcessNameUsesPathBasenameOnlyForTruncatedNames() {
        #expect(cmuxTopCanonicalProcessName(
            name: "com.apple.WebKi",
            path: "/System/Library/com.apple.WebKit.WebContent"
        ) == "com.apple.WebKit.WebContent")
        #expect(cmuxTopCanonicalProcessName(name: "node", path: "/usr/local/bin/node") == "node")
        #expect(cmuxTopCanonicalProcessName(name: "com.apple.WebKi", path: nil) == "com.apple.WebKi")
        #expect(cmuxTopCanonicalProcessName(
            name: "abcdefghijklmnop",
            path: "/usr/bin/other-helper"
        ) == "abcdefghijklmnop")
        #expect(cmuxTopCanonicalProcessName(
            name: "COM.APPLE.WEBKI",
            path: "/System/Library/com.apple.WebKit.Networking"
        ) == "com.apple.WebKit.Networking")
    }

    @Test func programRowsExcludeVersionedCodingAgentProcesses() throws {
        let firstAgent = try SpawnedVersionedClaudeProcess.start()
        let secondAgent = try SpawnedVersionedClaudeProcess.start()
        defer {
            firstAgent.terminate()
            secondAgent.terminate()
        }

        let snapshot = snapshot([
            process(pid: firstAgent.pid, name: "2.1.204", path: SpawnedVersionedClaudeProcess.executablePath),
            process(pid: secondAgent.pid, name: "2.1.204", path: SpawnedVersionedClaudeProcess.executablePath),
            process(pid: 9_001, name: "worker", path: "/usr/bin/worker"),
            process(pid: 9_002, name: "worker", path: "/usr/bin/worker")
        ])
        let pids: Set<Int> = [firstAgent.pid, secondAgent.pid, 9_001, 9_002]

        let programNames = snapshot.programSummaryPayload(for: pids).compactMap { $0["name"] as? String }
        let codingAgentNames = snapshot.codingAgentSummaryPayload(for: pids).compactMap {
            $0["display_name"] as? String
        }

        #expect(programNames.contains("worker"))
        #expect(!programNames.contains("2.1.204"))
        #expect(codingAgentNames == ["Claude Code"])
    }

    @Test func agentClassificationStaysConsistentWithinSnapshotAfterProcessExit() throws {
        let agent = try SpawnedVersionedClaudeProcess.start()
        defer { agent.terminate() }

        let snapshot = snapshot([
            process(pid: agent.pid, name: "2.1.204", path: SpawnedVersionedClaudeProcess.executablePath),
            process(pid: 9_003, name: "worker", path: "/usr/bin/worker")
        ])
        let pids: Set<Int> = [agent.pid, 9_003]

        // Classify while the process is alive, as the coding_agents section does.
        #expect(snapshot.codingAgentSummaryPayload(for: pids).count == 1)

        // Reap the process; live KERN_PROCARGS2 reads for this PID now fail.
        agent.terminate()

        // The same snapshot must keep the classification for every payload section.
        let programNames = snapshot.programSummaryPayload(for: pids).compactMap { $0["name"] as? String }
        #expect(!programNames.contains("2.1.204"))
        #expect(snapshot.codingAgentSummaryPayload(for: pids).count == 1)
    }

    @Test func programRowsUseCanonicalUntruncatedDisplayName() {
        let snapshot = snapshot([
            process(pid: 101, name: "com.apple.WebKi", path: "/System/Library/com.apple.WebKit.WebContent"),
            process(pid: 102, name: "com.apple.WebKi", path: "/System/Library/com.apple.WebKit.WebContent")
        ])

        let programs = snapshot.programSummaryPayload(for: [101, 102])
        let names = programs.compactMap { $0["name"] as? String }

        #expect(names == ["com.apple.WebKit.WebContent"])
    }

    @Test func memoryDiagnosticsFoldAgentsAndCanonicalizeChildGroups() throws {
        let firstAgent = try SpawnedVersionedClaudeProcess.start()
        let secondAgent = try SpawnedVersionedClaudeProcess.start()
        defer {
            firstAgent.terminate()
            secondAgent.terminate()
        }

        let appPID = 42
        let snapshot = snapshot([
            process(pid: appPID, parentPID: 0, name: "cmux", path: "/Applications/cmux.app/cmux"),
            process(pid: firstAgent.pid, parentPID: appPID, name: "2.1.204", path: SpawnedVersionedClaudeProcess.executablePath),
            process(pid: secondAgent.pid, parentPID: appPID, name: "2.1.204", path: SpawnedVersionedClaudeProcess.executablePath),
            process(pid: 201, parentPID: appPID, name: "com.apple.WebKi", path: "/System/Library/com.apple.WebKit.WebContent"),
            process(pid: 202, parentPID: appPID, name: "com.apple.WebKi", path: "/System/Library/com.apple.WebKit.WebContent"),
            process(pid: 203, parentPID: appPID, name: "node", path: "/usr/local/bin/node"),
            process(pid: 204, parentPID: appPID, name: "Node", path: "/usr/local/bin/Node")
        ])

        let payload = snapshot.memoryDiagnosticPayload(appPID: appPID, topGroupLimit: 10)
        let children = try #require(payload["children"] as? [String: Any])
        let groups = try #require(children["groups"] as? [[String: Any]])
        let groupNames = groups.compactMap { $0["name"] as? String }
        let groupIds = groups.compactMap { $0["id"] as? String }

        #expect(groupNames.contains("Claude Code"))
        #expect(groupNames.contains("com.apple.WebKit.WebContent"))
        // Group ids stay lowercased (stable row identity); names keep display casing.
        #expect(groupIds.contains("claude code"))
        #expect(groupIds.contains("com.apple.webkit.webcontent"))
        #expect(!groupNames.contains("2.1.204"))
        #expect(!groupNames.contains("com.apple.WebKi"))
        // Casing variants of the same executable fold into one group.
        #expect(groupNames.filter { $0.lowercased() == "node" }.count == 1)
    }

    @Test func snapshotParserHonorsExplicitlyEmptyProgramTotals() {
        func windowPayload() -> [String: Any] {
            [
                "id": "window-1",
                "ref": "window:1",
                "processes": [
                    ["pid": 101, "name": "2.1.204", "resources": ["cpu_percent": 1.0, "resident_bytes": 100]],
                    ["pid": 202, "name": "2.1.204", "resources": ["cpu_percent": 2.0, "resident_bytes": 200]],
                ],
            ]
        }

        // Present-but-empty program_totals means the backend intentionally has no
        // program aggregates (e.g. the only repeated processes are coding agents);
        // the client must not recreate them from process rows.
        let explicitlyEmpty = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": [:],
            "program_totals": [] as [[String: Any]],
            "windows": [windowPayload()],
        ])
        #expect(explicitlyEmpty.aggregateRows.isEmpty)

        // Absent program_totals is a legacy payload; client-side fallback applies.
        let legacyAbsent = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": [:],
            "windows": [windowPayload()],
        ])
        #expect(legacyAbsent.aggregateRows.map(\.title) == ["2.1.204"])
    }

    @Test func totalsMemoryBytesRemainClampedSum() {
        let snapshot = snapshot([
            process(pid: 301, name: "first", memoryBytes: Int64.max - 4, residentBytes: 1),
            process(pid: 302, name: "second", memoryBytes: 10, residentBytes: 1)
        ])

        let payload = snapshot.summaryPayload(for: [301, 302])

        #expect(payload["memory_bytes"] as? Int64 == Int64.max)
    }

    private func snapshot(_ processes: [CmuxTopProcessInfo]) -> CmuxTopProcessSnapshot {
        CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
    }

    private func process(
        pid: Int,
        parentPID: Int = 0,
        name: String,
        path: String? = nil,
        memoryBytes: Int64 = 1024,
        residentBytes: Int64 = 512
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: parentPID,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: nil,
            cmuxSurfaceID: nil,
            cmuxAttributionReason: nil,
            processGroupID: nil,
            terminalProcessGroupID: nil,
            cpuPercent: 0,
            memoryBytes: memoryBytes,
            residentBytes: residentBytes,
            virtualBytes: 0,
            threadCount: 1
        )
    }
}

private final class SpawnedVersionedClaudeProcess {
    static let executablePath = "/Users/example/.local/share/claude/versions/2.1.204"

    let process: Process
    let pid: Int

    private init(process: Process) {
        self.process = process
        self.pid = Int(process.processIdentifier)
    }

    static func start() throws -> SpawnedVersionedClaudeProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "exec -a '\(executablePath)' /bin/sleep 30"]
        try process.run()
        let fixture = SpawnedVersionedClaudeProcess(process: process)
        try fixture.waitForReadableArguments()
        return fixture
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
    }

    private func waitForReadableArguments() throws {
        for _ in 0..<100 {
            let arguments = CmuxTopProcessSnapshot.processArgumentsAndEnvironment(for: pid)?.arguments ?? []
            if arguments.contains(where: { $0.contains("/.local/share/claude/versions/") }) {
                return
            }
            usleep(20_000)
        }
        throw SpawnedVersionedClaudeProcessError.argumentsUnavailable
    }
}

private enum SpawnedVersionedClaudeProcessError: Error {
    case argumentsUnavailable
}
