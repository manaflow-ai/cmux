#!/usr/bin/env python3
"""bench_launch.py never cuts off a live same-tag app (review 2 of pl-fleet-gui).

1. `check` against a bundle whose app already runs refuses with tag-in-use, and its stop() must not run the tag
   teardown: that teardown ends every process of the bundle, which here is the live app, not one this run started.
2. The pre-launch socket probe unlinks only a socket nothing listens on: a socket that accepts but does not answer in
   time (a busy main thread, a long restore) belongs to a live app of the tag (another bundle path).

Runs on any Mac, no GUI session or build needed (BENCH_LAUNCH_ANY_SESSION=1, a copy of /bin/sleep stands in for the
app's executable). Signals only the processes it starts.

    python3 scripts/cmux-next/tests/test_bench_launch.py
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_launch as bl  # noqa: E402


def fake_bundle(folder: str, tag: str) -> str:
    """A `cmux DEV <tag>.app` whose main executable is a copy of /bin/sleep."""
    app = os.path.join(os.path.realpath(folder), f"cmux DEV {tag}.app")
    macos = os.path.join(app, "Contents/MacOS")
    os.makedirs(macos)
    shutil.copy2("/bin/sleep", os.path.join(macos, "cmux DEV"))
    return app


class TagInUseTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="bench-launch-test-")
        self.tag = f"bl-test-{os.getpid()}"
        self.started: list[subprocess.Popen] = []

    def tearDown(self):
        for process in self.started:
            if process.poll() is None:
                process.kill()  # the exact process this test started
                process.wait()
        shutil.rmtree(self.folder, ignore_errors=True)

    def test_a_check_refused_as_tag_in_use_leaves_the_running_app_alive(self):
        app = fake_bundle(self.folder, self.tag)
        live = subprocess.Popen([os.path.join(app, "Contents/MacOS/cmux DEV"), "300"])
        self.started.append(live)
        result = subprocess.run(
            [sys.executable, str(HERE / "bench_launch.py"), "check", "--app", app, "--timeout", "5",
             "--out", os.path.join(self.folder, "out")],
            env=dict(os.environ, BENCH_LAUNCH_ANY_SESSION="1"), capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("tag-in-use", result.stdout)
        self.assertIsNone(live.poll(), "the refused check's teardown ended the live app of the bundle:\n" + result.stdout)

    def test_a_socket_that_accepts_but_does_not_answer_is_in_use(self):
        path = os.path.join(self.folder, "silent.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(4)  # never accepts or answers: connect() still succeeds through the backlog
        try:
            self.assertTrue(bl.socket_in_use(path), "a live socket that answers slowly counted as free")
        finally:
            listener.close()

    def test_a_socket_nothing_listens_on_is_free(self):
        path = os.path.join(self.folder, "stale.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.close()  # the file stays, nothing listens: connect() is refused
        self.assertTrue(os.path.exists(path))
        self.assertFalse(bl.socket_in_use(path))
        self.assertFalse(bl.socket_in_use(os.path.join(self.folder, "missing.sock")))

    def test_the_state_socket_and_its_tmp_link_are_probed_once(self):
        target = os.path.join(self.folder, "state.sock")
        open(target, "w").close()
        link = os.path.join(self.folder, "link.sock")
        os.symlink(target, link)
        self.assertEqual(bl.unique_paths([target, link]), [target])


if __name__ == "__main__":
    unittest.main()
