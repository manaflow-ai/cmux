#!/usr/bin/env python3
"""Compile the real agent-hook environment normalizer and verify its output.

This exercises the caller of `AgentHookDeliveryPolicy.hookAgentPID`, not the
policy alone. It pins the failure mode Finn flagged: when the exported
`CMUX_CLAUDE_PID` is dead and no invocation agent is known, the caller must
clear the stale key instead of forwarding it to admission. Relay and snapshot
semantics must stay unchanged.

Works with CommandLineTools that lack the Swift Testing module; no app/socket.
"""
import pathlib
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

STUBS = '''import Foundation

let agentHookRelayOriginEnvironmentKey = "CMUX_AGENT_HOOK_RELAY_ORIGIN"

struct SocketClient {
    var isRelayBacked = false
    var socketPath = "/test"
}

struct CallerTerminalBinding {
    let workspaceId: String
    let surfaceId: String
}

struct AgentLaunchEnvironmentPolicy {
    func selectedEnvironment(from env: [String: String], kind: String?) -> [String: String] {
        [:]
    }
}

final class CMUXCLI {
    var inferredPID: Int?
    var terminals: [Int: Int64] = [:]
    var route: CallerTerminalBinding?

    static let agentHookRouteSnapshotEnvironmentKey = "CMUX_AGENT_HOOK_ROUTE_SNAPSHOT"

    static func queuedAgentHookDataEnvironmentKeys(agent: String) -> [String] {
        [
            "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_CLAUDE_PID",
            "CMUX_AGENT_HOOK_INVOKER_PID", "CMUX_AGENT_HOOK_INVOKER_START", agentHookRouteSnapshotEnvironmentKey,
        ]
    }

    static func agentHookPIDEnvironmentVariable(agentName: String) -> String {
        "CMUX_CLAUDE_PID"
    }

    func inferredAgentPID() -> Int? { inferredPID }

    func controllingTerminalDevice(of pid: Int) -> Int64? { terminals[pid] }

    func kiroCLIAncestorPID() -> pid_t? { nil }

    func admittedAgentHookRoute(
        processID: Int, client: SocketClient, socketPassword: String?
    ) -> CallerTerminalBinding? { route }
}
'''

HARNESS = '''import Darwin
import Foundation
import CMUXAgentLaunch

let dead = Int(CommandLine.arguments[1])!
let live = Int(getpid())
precondition(ClaudeViewerProcessIdentity(pid: dead) == nil, "fixture PID must be dead")
precondition(ClaudeViewerProcessIdentity(pid: live) != nil, "fixture live PID must exist")

let cli = CMUXCLI()
let client = SocketClient()
let deadEnvironment = ["CMUX_CLAUDE_PID": String(dead), "CMUX_SURFACE_ID": "S"]

// Dead exported PID + unknown invocation agent: clear the stale key.
cli.inferredPID = nil
let unknown = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client, processEnvironment: deadEnvironment,
    runsInHookProcess: true
)
precondition(unknown["CMUX_CLAUDE_PID"] == nil, "stale dead PID leaked: \\(unknown)")
print("PASS: dead exported PID with unknown invocation is cleared")

// Dead exported PID + live invocation agent: the live agent wins.
cli.inferredPID = live
let corrected = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client, processEnvironment: deadEnvironment,
    runsInHookProcess: true
)
precondition(corrected["CMUX_CLAUDE_PID"] == String(live))
print("PASS: dead exported PID yields to the live invocation agent")

// Live exported PID without terminal evidence: kept as before.
let liveEnvironment = ["CMUX_CLAUDE_PID": String(live)]
let kept = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client, processEnvironment: liveEnvironment,
    runsInHookProcess: true
)
precondition(kept["CMUX_CLAUDE_PID"] == String(live))
print("PASS: live exported PID without terminal evidence is kept")

// Relay-backed delivery keeps its portable environment untouched.
let relayed = cli.agentHookOrderingEnvironment(
    agent: "claude", client: SocketClient(isRelayBacked: true),
    processEnvironment: deadEnvironment, runsInHookProcess: true
)
precondition(relayed["CMUX_CLAUDE_PID"] == String(dead))
print("PASS: relay-backed environment unchanged")

// A recorded spool invoker with a dead exported PID behaves like a live hook.
cli.inferredPID = nil
let liveGeneration = ClaudeViewerProcessIdentity(pid: live)!
let liveStart = "\(liveGeneration.seconds) \(liveGeneration.microseconds)"
let spooled = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client,
    processEnvironment: deadEnvironment.merging(
        ["CMUX_AGENT_HOOK_INVOKER_PID": String(live),
         "CMUX_AGENT_HOOK_INVOKER_START": liveStart]) { $1 },
    runsInHookProcess: false
)
precondition(spooled["CMUX_CLAUDE_PID"] == String(live))
precondition(spooled["CMUX_AGENT_HOOK_INVOKER_PID"] == nil)
precondition(spooled["CMUX_AGENT_HOOK_INVOKER_START"] == nil)
print("PASS: recorded spool invoker replaces a dead exported PID")

// A missing or mismatched invoker generation fails closed: the recorded PID
// is not used for routing and the stale exported PID is cleared.
let untrusted = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client,
    processEnvironment: deadEnvironment.merging(
        ["CMUX_AGENT_HOOK_INVOKER_PID": String(live),
         "CMUX_AGENT_HOOK_INVOKER_START": "1 1"]) { $1 },
    runsInHookProcess: false
)
precondition(untrusted["CMUX_CLAUDE_PID"] == nil)
let missing = cli.agentHookOrderingEnvironment(
    agent: "claude", client: client,
    processEnvironment: deadEnvironment.merging(
        ["CMUX_AGENT_HOOK_INVOKER_PID": String(live)]) { $1 },
    runsInHookProcess: false
)
precondition(missing["CMUX_CLAUDE_PID"] == nil)
print("PASS: missing or mismatched invoker generation fails closed")
'''


class HookEnvironmentIdentityTests(unittest.TestCase):
    def test_caller_clears_dead_exported_pid_and_preserves_relay(self):
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        time.sleep(0.1)
        with tempfile.TemporaryDirectory(prefix="cmux-hook-env-") as directory:
            tmp = pathlib.Path(directory)
            (tmp / "Stubs.swift").write_text(STUBS)
            (tmp / "main.swift").write_text(HARNESS)
            package = ROOT / "Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch"
            library = subprocess.run(
                ["swiftc", "-emit-module", "-emit-library",
                 "-module-name", "CMUXAgentLaunch",
                 "-emit-module-path", str(tmp / "CMUXAgentLaunch.swiftmodule"),
                 "-o", str(tmp / "libCMUXAgentLaunch.dylib"),
                 str(package / "AgentHookDeliveryPolicy.swift"),
                 str(package / "ClaudeViewerProcessIdentity.swift")],
                text=True, capture_output=True, timeout=120,
            )
            self.assertEqual(library.returncode, 0, library.stderr)
            built = subprocess.run(
                ["swiftc", "-I", str(tmp), "-L", str(tmp),
                 "-Xlinker", "-rpath", "-Xlinker", str(tmp),
                 "-lCMUXAgentLaunch",
                 str(ROOT / "CLI/CMUXCLI+AgentHookEnvironment.swift"),
                 str(tmp / "Stubs.swift"), str(tmp / "main.swift"),
                 "-o", str(tmp / "check")],
                text=True, capture_output=True, timeout=120,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run(
                [str(tmp / "check"), str(dead.pid)],
                text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            print(checked.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
