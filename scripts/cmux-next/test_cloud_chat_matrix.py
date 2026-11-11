#!/usr/bin/env python3
"""cloud-chat-matrix.py offline: every fixture builds, the manifest here and the machine's agree on a
tree with nothing left out, and what a copy leaves out (skips.rs) is left out of the expected tree.
No app and no Cloud: `python3 scripts/cmux-next/test_cloud_chat_matrix.py`."""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("cloud_chat_matrix", HERE / "cloud-chat-matrix.py")
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)


def remote_manifest(folder: Path, canary: str = "") -> dict:
    """MANIFEST_PY as the machine runs it."""
    done = subprocess.run([sys.executable, "-c", matrix.MANIFEST_PY, str(folder), canary, "100000"],
                          capture_output=True, text=True, check=True)
    return json.loads(done.stdout)


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="cwm-test-"))
        self.args = matrix.parse_args(["--cli", "/bin/true", "--out", str(self.root / "out"), "--big-files", "50",
                                       "--monorepo", str(self.root / "mono-source")])

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def test_every_fixture_builds_and_hashes_like_the_machine(self):
        matrix.small_repo(self.root / "mono-source")
        for kind in matrix.WORKSPACES:
            if kind == "big-plain":
                continue  # 128 MiB of random blobs; its shape is the plain folder's
            folder, note = matrix.build_fixture(kind, self.root, self.args, "cmxcanarytest")
            if folder is None:
                self.assertTrue(note.startswith("skipped"), kind)
                continue
            expected = matrix.local_manifest(folder, "cmxcanarytest")
            if not expected["left_out"] or set(expected["left_out"]) == {"symlink"}:
                self.assertEqual(remote_manifest(folder)["sha256"], expected["sha256"], kind)

    def test_secrets_are_left_out_and_the_canary_is_found_where_it_is(self):
        folder, _ = matrix.build_fixture("secrets", self.root, self.args, "cmxcanarytest")
        expected = matrix.local_manifest(folder, "cmxcanarytest")
        self.assertEqual(expected["files"], 1, expected["lines"])  # app.py only
        self.assertGreaterEqual(expected["left_out"]["secret"], 10)
        # A machine that got every file: the canary is found in each secret file.
        self.assertGreaterEqual(len(remote_manifest(folder, "cmxcanarytest")["canary_hits"]), 10)

    def test_heavy_and_symlinks_are_left_out(self):
        folder, _ = matrix.build_fixture("odd-names", self.root, self.args, "")
        expected = matrix.local_manifest(folder, "")
        names = [line.split(" ", 2)[2] for line in expected["lines"]]
        self.assertNotIn("node_modules/pkg/index.js", names)
        self.assertNotIn("build/out.js", names)  # beside package.json
        self.assertIn("with space/file name.txt", names)
        self.assertEqual(expected["left_out"].get("symlink"), 3)

    def test_skip_rules(self):
        self.assertEqual(matrix.skipped("a/.env.local", False, self.root, ".env.local"), "secret")
        self.assertEqual(matrix.skipped("x/.config/gh/hosts.yml", False, self.root, "hosts.yml"), "secret")
        self.assertEqual(matrix.skipped("keys.rs", False, self.root, "keys.rs"), "")
        self.assertEqual(matrix.skipped("target", True, self.root, "target"), "")

    def test_a_claude_start_passes_a_login_only_when_asked(self):
        self.assertEqual(self.args.login, "")
        self.assertEqual(matrix.start_login("claude", self.args.login), [])
        self.assertEqual(matrix.start_login("claude", "none"), ["--login", "none"])
        self.assertEqual(matrix.start_login("codex", "none"), [])

    def test_a_stale_machine_list_refusal_is_asked_again(self):
        self.assertTrue(matrix.list_unread("cloudStartSession unavailable: Couldn't read your Cloud machines, so claude "
                                           "didn't start: a machine named x may already exist."))
        self.assertFalse(matrix.list_unread("claude on x waits for your one-time OK to copy your Claude login"))

    def test_verdict_and_grid(self):
        cell = {"workspace": "secrets", "agent": "claude", "start_exit": 0, "hash_match": True,
                "reply": {"form_ok": True, "word_ok": True, "canary_in_reply": False, "text": "MATRIX_OK"},
                "canary_on_machine": [".env"], "machine_killed": True}
        self.assertIn("SECRET LEAKED", matrix.verdict(cell, "c"))
        cell["result"] = matrix.verdict(cell, "c")
        self.assertIn("LEAK", matrix.grid([cell]))


class LaunchTests(unittest.TestCase):
    def test_socket_travels_only_as_the_next_knob(self):
        argv = matrix.launch_argv("/Applications/cmux.app", "/tmp/cmux-debug-t.sock", None, "staging", "/tmp/c.json")
        envs = [argv[i + 1] for i, word in enumerate(argv) if word == "--env"]
        self.assertEqual(envs, ["CMUX_NEXT_SOCKET_PATH=/tmp/cmux-debug-t.sock", "CMUX_NEXT_CONFIG_FILE=/tmp/c.json"])
        self.assertEqual(argv[-3:], ["--args", "--cloud-backend", "staging"])

    def test_credentials_sign_the_launched_app_in(self):
        argv = matrix.launch_argv("/Applications/cmux.app", "/tmp/s.sock", "/tmp/creds.json", "prod", "/tmp/c.json")
        self.assertIn("CMUX_DEV_AUTH_REPLACE_SESSION=1", argv)
        self.assertFalse(any(word.startswith("CMUX_SOCKET_PATH=") for word in argv))


class GrantTests(unittest.TestCase):
    APP = ["--app", "/Applications/cmux.app", "--cloud-backend", "staging",
           "--expected-api-origin", "https://example.invalid", "--out", "/tmp/x"]

    def test_grant_only_for_the_launched_app(self):
        with self.assertRaises(SystemExit):
            matrix.parse_args(["--cli", "/bin/true", "--out", "/tmp/x", "--grant-claude-login"])
        self.assertTrue(matrix.parse_args([*self.APP, "--grant-claude-login"]).grant_claude_login)

    def test_the_consent_lives_only_in_the_runs_own_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = matrix.scratch_config(Path(folder), True)
            self.assertEqual(json.loads(path.read_text()), {"cloud": {"useMyClaudeLoginOnMyCloudMachines": True}})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(matrix.scratch_config(Path(folder), False).read_text()), {})

    def test_an_app_run_never_reads_the_shared_file_and_cleans_up(self):
        m = matrix.Matrix(matrix.parse_args([*self.APP, "--grant-claude-login"]))
        config = Path(m.env["CMUX_NEXT_CONFIG_FILE"])
        self.assertTrue(config.is_file())
        self.assertNotIn(".config/cmux", str(config))
        m.quit()
        self.assertFalse(config.exists())


class StopTests(unittest.TestCase):
    def test_a_cancelled_run_starts_no_more_cell_work(self):
        import threading
        m = matrix.Matrix(matrix.parse_args(["--cli", "/bin/sleep", "--out", "/tmp/x"]))
        m.stop()
        self.assertTrue(m.run_cell("small-repo", "claude", Path("/tmp"), "", word="w", canary="",
                                   read_only=False)["result"].startswith("skipped"))
        answer = []
        worker = threading.Thread(target=lambda: answer.append(m.cmux("600")))
        worker.start()
        worker.join(5)
        self.assertEqual(answer[0][0], 130)

    def test_stop_ends_the_calls_cells_wait_on(self):
        import threading
        import time
        m = matrix.Matrix(matrix.parse_args(["--cli", "/bin/sleep", "--out", "/tmp/x"]))
        answer = []
        worker = threading.Thread(target=lambda: answer.append(m.cmux("600", timeout=600)))
        worker.start()
        deadline = time.monotonic() + 5
        while not m.children and time.monotonic() < deadline:
            time.sleep(0.05)
        started = time.monotonic()
        m.stop()
        worker.join(10)
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotEqual(answer[0][0], 0)


    def test_a_child_started_while_stopping_is_ended_too(self):
        import threading
        import time
        m = matrix.Matrix(matrix.parse_args(["--cli", "/bin/sleep", "--out", "/tmp/x"]))
        real = matrix.subprocess.Popen

        def popen_then_stop(*args, **kwargs):  # stop() lands after the check, before registration
            child = real(*args, **kwargs)
            m.stop()
            return child
        matrix.subprocess.Popen = popen_then_stop
        try:
            answer = []
            worker = threading.Thread(target=lambda: answer.append(m.cmux("600", timeout=600)))
            started = time.monotonic()
            worker.start()
            worker.join(10)
        finally:
            matrix.subprocess.Popen = real
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotEqual(answer[0][0], 0)

    def test_sigterm_while_the_main_thread_holds_the_lock_does_not_deadlock(self):
        import os
        import signal
        import threading
        import time
        m = matrix.Matrix(matrix.parse_args(["--cli", "/bin/sleep", "--out", "/tmp/x"]))

        class Cancelled(Exception):
            pass

        def handler(signum, frame):
            m.stop()
            raise Cancelled
        previous = signal.signal(signal.SIGTERM, handler)
        answer = []
        worker = threading.Thread(target=lambda: answer.append(m.cmux("600", timeout=600)))
        worker.start()
        deadline = time.monotonic() + 5
        while not m.children and time.monotonic() < deadline:
            time.sleep(0.05)
        started = time.monotonic()
        try:
            with self.assertRaises(Cancelled):
                with m.lock:  # as launch(), sweep() and kill() hold it
                    os.kill(os.getpid(), signal.SIGTERM)
                    time.sleep(5)
        finally:
            signal.signal(signal.SIGTERM, previous)
        worker.join(10)
        self.assertLess(time.monotonic() - started, 5)
        self.assertNotEqual(answer[0][0], 0)


if __name__ == "__main__":
    unittest.main()
