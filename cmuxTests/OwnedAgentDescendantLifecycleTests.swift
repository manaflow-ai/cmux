import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct OwnedAgentDescendantLifecycleTests {
    @Test("Closing one managed agent reaps its descendants and preserves another session")
    func closeReclaimsOnlyTheExpiredOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = AgentSessionProcessStore()
        let second = AgentSessionProcessStore()
        var identities: [AgentPIDProcessIdentity] = []
        defer {
            first.closeAll()
            second.closeAll()
            // The red baseline leaks the fixture child. Clean only these exact
            // process generations, never a process discovered by name or ancestry.
            for identity in identities where AgentPIDProcessIdentity(pid: identity.pid) == identity {
                _ = kill(identity.pid, SIGKILL)
            }
        }
        let firstRecord = directory.appendingPathComponent("first.json")
        let secondRecord = directory.appendingPathComponent("second.json")
        _ = try await first.start(plan: plan(record: firstRecord), workingDirectory: directory.path)
        let firstProcesses = try await fixtureIdentities(record: firstRecord)
        identities += firstProcesses
        _ = try await second.start(plan: plan(record: secondRecord), workingDirectory: directory.path)
        let secondProcesses = try await fixtureIdentities(record: secondRecord)
        identities += secondProcesses

        first.closeAll()
        let firstExited = await waitForExit(firstProcesses)
        #expect(firstExited, "An expired managed agent owner left its helper descendant running")
        #expect(secondProcesses.allSatisfy { AgentPIDProcessIdentity(pid: $0.pid) == $0 },
                "Closing another session must preserve this active owner's processes")
        second.closeAll()
        let secondExited = await waitForExit(secondProcesses)
        #expect(secondExited)
    }

    private func plan(record: URL) -> AgentSessionLaunchPlan {
        let script = """
        import json, os, signal, subprocess, sys
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen(['/bin/sleep', '600'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with open(sys.argv[1], 'w') as output:
            json.dump([os.getpid(), child.pid], output)
        while True:
            signal.pause()
        """
        return AgentSessionLaunchPlan(
            provider: .claude,
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", script, record.path],
            environment: ProcessInfo.processInfo.environment
        )
    }

    private func fixtureIdentities(record: URL) async throws -> [AgentPIDProcessIdentity] {
        for _ in 0..<500 {
            if let data = try? Data(contentsOf: record),
               let pids = try? JSONDecoder().decode([pid_t].self, from: data), pids.count == 2 {
                return try pids.map { try #require(AgentPIDProcessIdentity(pid: $0)) }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Fixture did not publish its process identities")
        throw CocoaError(.fileReadUnknown)
    }

    private func waitForExit(_ identities: [AgentPIDProcessIdentity]) async -> Bool {
        for _ in 0..<700 {
            if identities.allSatisfy({ AgentPIDProcessIdentity(pid: $0.pid) != $0 }) { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}
