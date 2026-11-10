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

    def test_verdict_and_grid(self):
        cell = {"workspace": "secrets", "agent": "claude", "start_exit": 0, "hash_match": True,
                "reply": {"form_ok": True, "word_ok": True, "canary_in_reply": False, "text": "MATRIX_OK"},
                "canary_on_machine": [".env"], "machine_killed": True}
        self.assertIn("SECRET LEAKED", matrix.verdict(cell, "c"))
        cell["result"] = matrix.verdict(cell, "c")
        self.assertIn("LEAK", matrix.grid([cell]))


class LaunchTests(unittest.TestCase):
    def test_socket_travels_only_as_the_next_knob(self):
        argv = matrix.launch_argv("/Applications/cmux.app", "/tmp/cmux-debug-t.sock", None, "staging")
        envs = [argv[i + 1] for i, word in enumerate(argv) if word == "--env"]
        self.assertEqual(envs, ["CMUX_NEXT_SOCKET_PATH=/tmp/cmux-debug-t.sock"])
        self.assertEqual(argv[-3:], ["--args", "--cloud-backend", "staging"])

    def test_credentials_sign_the_launched_app_in(self):
        argv = matrix.launch_argv("/Applications/cmux.app", "/tmp/s.sock", "/tmp/creds.json", "prod")
        self.assertIn("CMUX_DEV_AUTH_REPLACE_SESSION=1", argv)
        self.assertFalse(any(word.startswith("CMUX_SOCKET_PATH=") for word in argv))


if __name__ == "__main__":
    unittest.main()
