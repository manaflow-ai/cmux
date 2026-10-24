#!/usr/bin/env python3
"""Focused tests for the lifecycle adapter's orchestration seams."""

import unittest

from sandbox_lifecycle import (  # type: ignore[import-not-found]
    FirecrackerLifecycle,
    GVisorLifecycle,
    STATUS_COMPLETED,
    STATUS_TIMEOUT,
    STATUS_UNSUPPORTED,
)


class _Completed:
    def __init__(self, argv):
        self.args = list(argv)
        self.returncode = 0
        self.stdout = ""
        self.stderr = ""


class LifecycleTests(unittest.TestCase):
    def test_firecracker_snapshot_pauses_and_can_resume(self):
        calls = []

        def request(method, path, payload):
            calls.append((method, path, payload))
            return 204, None

        result = FirecrackerLifecycle("unused", request_fn=request).snapshot(
            "/tmp/snapshot", "/tmp/memory", resume_after=True
        )

        self.assertEqual(result.status, STATUS_COMPLETED)
        self.assertEqual([call[1] for call in calls], ["/actions", "/snapshot/create", "/actions"])
        self.assertEqual(calls[0][2], {"action_type": "Pause"})
        self.assertEqual(calls[2][2], {"action_type": "Resume"})
        stamps = [event.monotonic_ns for event in result.events]
        self.assertEqual(stamps, sorted(stamps))

    def test_firecracker_fork_without_launcher_is_explicit(self):
        result = FirecrackerLifecycle("unused").fork("snapshot", "memory")
        self.assertEqual(result.status, STATUS_UNSUPPORTED)
        self.assertIn("launcher", result.error or "")

    def test_gvisor_fork_checkpoint_then_restores_child(self):
        commands = []

        def runner(argv, _timeout):
            commands.append(list(argv))
            return _Completed(argv)

        result = GVisorLifecycle(
            "runsc", root="/runsc", container_id="parent", runner=runner
        ).fork("/checkpoint", "/bundle", child_id="child")

        self.assertEqual(result.status, STATUS_COMPLETED)
        self.assertEqual(commands[0][-2:], ["--leave-running", "parent"])
        self.assertEqual(commands[1][-1], "child")
        child_events = result.metadata["restore"]["events"]
        self.assertIn("guest_ready_not_run", [event["name"] for event in child_events])

    def test_gvisor_timeout_is_not_a_success(self):
        def runner(_argv, _timeout):
            raise TimeoutError("test timeout")

        result = GVisorLifecycle(
            "runsc", root="/runsc", container_id="session", runner=runner
        ).suspend()
        self.assertEqual(result.status, STATUS_TIMEOUT)


if __name__ == "__main__":
    unittest.main()
