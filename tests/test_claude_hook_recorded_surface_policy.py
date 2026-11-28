#!/usr/bin/env python3
"""Compile the real hook delivery policy and verify the recorded-surface veto.

Regression for the background-viewer Stop gap: an older queued event can
rewrite the session record back to the pane that launched the agent after the
viewer lease was admitted. When the current invocation carries an
admission-time route snapshot (resolved from the live worker and an admitted
viewer), that stale record must not veto the snapshot.

Works with CommandLineTools that lack the Swift Testing module; no app/socket.
"""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HARNESS = '''import Foundation
let policy = AgentHookDeliveryPolicy()
// Snapshot from admission wins over a lagging, still-listed record.
precondition(!policy.recordedSurfaceVetoes(
    invocationSurfaceId: "viewer", recordedSurfaceId: "launcher",
    recordedSurfaceIsListed: true, viewerSnapshot: true))
// Without a snapshot the original fail-closed rule keeps rejecting.
precondition(policy.recordedSurfaceVetoes(
    invocationSurfaceId: "viewer", recordedSurfaceId: "launcher",
    recordedSurfaceIsListed: true, viewerSnapshot: false))
// Equal surfaces never veto.
precondition(!policy.recordedSurfaceVetoes(
    invocationSurfaceId: "viewer", recordedSurfaceId: "viewer",
    recordedSurfaceIsListed: true, viewerSnapshot: false))
// A record the app no longer lists does not veto.
precondition(!policy.recordedSurfaceVetoes(
    invocationSurfaceId: "viewer", recordedSurfaceId: "launcher",
    recordedSurfaceIsListed: false, viewerSnapshot: false))
// A missing invocation surface cannot form a veto.
precondition(!policy.recordedSurfaceVetoes(
    invocationSurfaceId: nil, recordedSurfaceId: "launcher",
    recordedSurfaceIsListed: true, viewerSnapshot: false))
print("PASS: snapshot bypasses a listed stale record; non-snapshot veto preserved")
'''


class RecordedSurfacePolicyTests(unittest.TestCase):
    def test_snapshot_bypasses_stale_listed_record(self):
        with tempfile.TemporaryDirectory(prefix="cmux-recorded-surface-") as directory:
            tmp = pathlib.Path(directory)
            (tmp / "main.swift").write_text(HARNESS)
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
