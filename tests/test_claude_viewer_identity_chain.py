#!/usr/bin/env python3
"""Compile the actual hook identity and viewer-lease sources and replay the
background-worker identity chain with live kernel processes.

Regression for the admitted-viewer / target-unresolved gap: a detached Claude
worker inherits CMUX_CLAUDE_PID from the `claude --bg` process that started its
session, which exits once the worker owns the conversation. The hook then
reports a dead exported PID while the registered viewer lease names the live
worker, so lease admission must use the live agent that ran the hook.

Works with CommandLineTools that lack the Swift Testing module; no app/socket.
"""
import pathlib
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = '''import Darwin
import Foundation

fileprivate func isAlive(_ pid: Int) -> Bool {
    ClaudeViewerProcessIdentity(pid: pid) != nil
}

let dead = Int(CommandLine.arguments[1])!
let workerPID = Int(CommandLine.arguments[2])!
let viewer = ClaudeViewerProcessIdentity(pid: Int(getpid()))!
let worker = ClaudeViewerProcessIdentity(pid: workerPID)!
precondition(!isAlive(dead), "fixture PID must be dead")
precondition(isAlive(workerPID), "fixture worker must be live")

let lease = ClaudeAttachedViewer(
    attachmentID: UUID().uuidString, worker: worker, viewer: viewer,
    socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString
)
// The stale inherited PID never matches the registered worker.
precondition(!lease.admits(workerPID: dead, socketPath: "/test"))
// Detached worker: neither PID has a controlling terminal.
let chosen = AgentHookDeliveryPolicy().hookAgentPID(
    environmentPID: dead, invocationAgentPID: workerPID,
    controllingTerminal: { _ in nil }, processIsAlive: isAlive
)
precondition(chosen == workerPID, "policy kept the dead exported PID")
precondition(lease.admits(workerPID: chosen!, socketPath: "/test"))
precondition(ClaudeViewerSubscriptions([lease])
    .candidates(workerPID: chosen!, socketPath: "/test").count == 1)
print("PASS: dead exported PID yields the live worker and admits the viewer lease")
'''


class ViewerIdentityChainTests(unittest.TestCase):
    def test_dead_inherited_pid_still_admits_registered_worker_lease(self):
        worker = subprocess.Popen(["/bin/sleep", "30"], start_new_session=True)
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        time.sleep(0.1)
        try:
            with tempfile.TemporaryDirectory(prefix="cmux-viewer-chain-") as directory:
                tmp = pathlib.Path(directory)
                (tmp / "main.swift").write_text(HARNESS)
                source = ROOT / "Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch"
                built = subprocess.run(
                    ["swiftc", *(str(source / name) for name in (
                        "ClaudeViewerProcessIdentity.swift", "ClaudeAttachedViewer.swift",
                        "ClaudeViewerSubscriptions.swift", "AgentHookDeliveryPolicy.swift")),
                    str(tmp / "main.swift"), "-o", str(tmp / "check")],
                    text=True, capture_output=True, timeout=120,
                )
                self.assertEqual(built.returncode, 0, built.stderr)
                checked = subprocess.run(
                    [str(tmp / "check"), str(dead.pid), str(worker.pid)],
                    text=True, capture_output=True, timeout=30,
                )
                self.assertEqual(checked.returncode, 0, checked.stderr)
                print(checked.stdout.strip())
        finally:
            worker.terminate()
            worker.wait(timeout=5)

    def test_policy_source_alone_selects_live_invocation_agent(self):
        harness = '''import Foundation
let policy = AgentHookDeliveryPolicy()
precondition(policy.hookAgentPID(
    environmentPID: 4_242, invocationAgentPID: 4_343,
    controllingTerminal: { _ in nil }, processIsAlive: { _ in true }
) == 4_242)
precondition(policy.hookAgentPID(
    environmentPID: 4_242, invocationAgentPID: 4_343,
    controllingTerminal: { _ in nil }, processIsAlive: { $0 != 4_242 }
) == 4_343)
precondition(policy.hookAgentPID(
    environmentPID: 4_242, invocationAgentPID: nil,
    controllingTerminal: { _ in 0x1001 }, processIsAlive: { $0 != 4_242 }
) == nil)
print("PASS: live/no-tty kept, dead exported PID yields, dead+unknown is nil")
'''
        with tempfile.TemporaryDirectory(prefix="cmux-hook-policy-") as directory:
            tmp = pathlib.Path(directory)
            (tmp / "main.swift").write_text(harness)
            source = ROOT / "Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch/AgentHookDeliveryPolicy.swift"
            built = subprocess.run(
                ["swiftc", str(source), str(tmp / "main.swift"), "-o", str(tmp / "check")],
                text=True, capture_output=True, timeout=120,
            )
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run(
                [str(tmp / "check")], text=True, capture_output=True, timeout=10,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            print(checked.stdout.strip())


if __name__ == "__main__":
    unittest.main(verbosity=2)
