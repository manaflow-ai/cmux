#!/usr/bin/env python3
"""Compile actual lease-policy sources and exercise local kernel identities.

Works with CommandLineTools that lack the Swift Testing module; no app/socket.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = 'import Darwin\nimport Foundation\nlet identity = ClaudeViewerProcessIdentity(pid: Int(getpid()))!\nlet lease = ClaudeAttachedViewer(attachmentID: UUID().uuidString, worker: identity, viewer: identity,\n  socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString)\nprecondition(lease.admits(workerPID: Int(getpid()), socketPath: "/test"))\nprecondition(!lease.admits(workerPID: Int(getpid()) + 1, socketPath: "/test"))\nprecondition(!lease.admits(workerPID: Int(getpid()), socketPath: "/wrong"))\nvar obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lease)) as! [String:Any]\nvar v = obj["viewer"] as! [String:Any]; v["seconds"] = 1; obj["viewer"] = v\nlet stale = try JSONDecoder().decode(ClaudeAttachedViewer.self, from: JSONSerialization.data(withJSONObject: obj))\nprecondition(!stale.admits(workerPID: Int(getpid()), socketPath: "/test"))\nprint("PASS: live process, wrong worker/socket, recycled generation")\n\nlet second = ClaudeAttachedViewer(attachmentID: UUID().uuidString, worker: identity, viewer: identity,\n socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString, attachedAt: lease.attachedAt+1)\nlet both = ClaudeViewerSubscriptions().adding(lease).adding(second)\nprecondition(both.candidates(workerPID: identity.pid, socketPath: "/test").map(\\.attachmentID) == [second.attachmentID,lease.attachmentID])\nlet clockStep = ClaudeAttachedViewer(attachmentID: UUID().uuidString, worker: identity, viewer: identity,\n socketPath: "/test", workspaceID: UUID().uuidString, surfaceID: UUID().uuidString, attachedAt: lease.attachedAt-100)\nlet stepped = ClaudeViewerSubscriptions().adding(lease).adding(clockStep)\nprecondition(stepped.candidates(workerPID: identity.pid, socketPath: "/test").map(\\.attachmentID) == [clockStep.attachmentID,lease.attachmentID])\nlet legacy = try JSONDecoder().decode(ClaudeAttachedViewer.self, from: JSONSerialization.data(withJSONObject: obj))\nprecondition(legacy.displacedSurface == nil && legacy.displacedWorkspace == nil)\nlet olderClosed = both.removing(attachmentID: lease.attachmentID, viewerPID: identity.pid, socketPath: "/test")\nprecondition(olderClosed.viewers == [second])\nprecondition(both.removing(attachmentID: lease.attachmentID, viewerPID: identity.pid, socketPath: "/other").viewers.count == 2)\nprint("PASS: newest viewer, independent close, foreign-socket close rejected")\n'

class ViewerPolicyTests(unittest.TestCase):
    def test_process_generation_socket_scope_and_independent_close(self):
        with tempfile.TemporaryDirectory(prefix="cmux-viewer-policy-") as directory:
            tmp = pathlib.Path(directory)
            (tmp / "main.swift").write_text(HARNESS)
            source = ROOT / "Packages/macOS/CMUXAgentLaunch/Sources/CMUXAgentLaunch"
            built = subprocess.run(["swiftc", *(str(source / name) for name in (
                "ClaudeViewerProcessIdentity.swift", "ClaudeAttachedViewer.swift", "ClaudeViewerSubscriptions.swift")),
                str(tmp / "main.swift"), "-o", str(tmp / "check")], text=True, capture_output=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stderr)
            checked = subprocess.run([str(tmp / "check")], text=True, capture_output=True, timeout=10)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            print(checked.stdout.strip())

if __name__ == "__main__":
    unittest.main()
