#!/usr/bin/env python3
"""hot-apply.py: a merged commit's Rust part swapped into an app's bin/cmux and rolled back.

Runs on any host (Linux included): no app, no fleet, no network. This checkout's history stands in
for feat-cmux-next (cmux#37155, a cmux-wg fix, after its parent); a file:// tree stands in for
files.cmux.com/cmux-tui/tree; the app is a folder with an Info.plist and a bin/cmux, and no daemon
runs from it, so the swap is the file alone.

    python3 -m unittest scripts/cmux-next/tests/test_hot_apply.py
"""
import hashlib
import json
import os
import plistlib
import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "hot-apply.py"
ROOT = SCRIPT.parents[2]
FIX = "a186694568df6a1ad8b5a32d0f4466cb33c03d7f"  # cmux#37155: cmux-tui/crates/cmux-wg only


def run_git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def key_of(sha):
    return subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", sha],
                          cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


@unittest.skipUnless(run_git("cat-file", "-e", f"{FIX}^{{commit}}").returncode == 0, "needs cmux#37155 in history")
class HotApplyRust(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-test-"))
        self.base = run_git("rev-parse", f"{FIX}^").stdout.strip()
        self.app = self.tmp / "cmux NIGHTLY.app"
        (self.app / "Contents/Resources/bin").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base}, handle)
        self.cmux = self.app / "Contents/Resources/bin/cmux"
        self.cmux.write_bytes(b"#!/bin/sh\necho old\n")
        self.cmux.chmod(0o755)
        (self.app / "Contents/Resources/bin/cmux-tui").symlink_to("cmux")
        self.old = hashlib.sha256(self.cmux.read_bytes()).hexdigest()
        self.key = key_of(FIX)
        arch = "aarch64" if platform.machine() in ("arm64", "aarch64") else "x86_64"
        self.name = f"cmux-tui-{arch}-apple-darwin" if sys.platform == "darwin" else f"cmux-tui-{arch}-unknown-linux-musl"
        self.new_body = b"#!/bin/sh\necho new\n"
        self.new = hashlib.sha256(self.new_body).hexdigest()
        self.publish(self.new_body, self.new)
        self.env = dict(os.environ, CMUX_HOT_APPLY_TUI_BASE=(self.tmp / "tree").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def publish(self, body, digest, listed=None):
        tree = self.tmp / "tree" / self.key
        tree.mkdir(parents=True, exist_ok=True)
        (tree / self.name).write_bytes(body)
        (tree / f"{self.name}.sha256").write_text(f"{digest}  {self.name}\n")
        (tree / "completion.json").write_text(json.dumps({"key": self.key, "binaries": {self.name: listed or digest}}))

    def hot(self, *args):
        done = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=self.env)
        lines = done.stdout.strip().splitlines()
        return done.returncode, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None), done.stderr

    def sha(self):
        return hashlib.sha256(self.cmux.read_bytes()).hexdigest()

    def test_plan_takes_the_daemon_part(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertEqual(plan["parts"], ["rust"])
        # cmux-mobile-host builds from cmux-wg too: it keeps the nightly's build, and says so.
        self.assertEqual(list(plan["left"]), ["bundled helpers (cmux-mobile-host, ...)"])
        self.assertEqual(plan["tree_key"], self.key)

    def test_apply_then_rollback_restores_the_prior_sha(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], ["rust"])
        self.assertEqual(receipt["steps"]["rust"]["from"], self.old)
        self.assertEqual(receipt["steps"]["rust"]["running_sha256"], self.new)
        self.assertEqual(self.sha(), self.new)
        self.assertTrue((self.app / "Contents/Resources/bin/cmux-tui").is_symlink())
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertTrue(receipt["ok"])
        self.assertEqual(receipt["steps"]["rust"]["running_sha256"], self.old)
        self.assertEqual(self.sha(), self.old)

    def test_a_nightly_s_short_commit_stamp_is_resolved(self):
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base[:11]}, handle)
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["base"], self.base)

    def test_a_hung_daemon_status_changes_nothing(self):
        stub = self.tmp / "stub"
        stub.mkdir()
        (stub / "ps").write_text(f"#!/bin/sh\necho '4242 {self.app}/Contents/Resources/bin/cmux-tui server'\n")
        (stub / "lsof").write_text("#!/bin/sh\nprintf 'p4242\\nn/tmp/hung.sock\\n'\n")
        # The app's own bin/cmux answers `server status` by hanging past find_socket's 10 s.
        self.cmux.write_bytes(b"#!/bin/sh\nexec sleep 30\n")
        self.old = self.sha()
        for name in ("ps", "lsof"):
            (stub / name).chmod(0o755)
        self.env["PATH"] = f"{stub}:{self.env['PATH']}"
        code, receipt, _ = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.assertIn("never answered", receipt["error"])
        self.assertEqual(self.sha(), self.old)

    def test_a_short_stamp_missing_here_fetches_the_branch(self):
        clone = self.tmp / "clone"
        subprocess.run(["git", "init", "-q", str(clone)], check=True)
        objects = run_git("rev-parse", "--path-format=absolute", "--git-common-dir").stdout.strip() + "/objects"
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base[:11]}, handle)
        spec = __import__("importlib.util").util.spec_from_file_location("hot_apply_fetch", SCRIPT)
        hot = __import__("importlib.util").util.module_from_spec(spec)
        sys.modules["hot_apply_fetch"] = hot
        spec.loader.exec_module(hot)
        fetched = []
        real = hot.subprocess.run

        def run(argv, **kwargs):
            if argv[:4] == ["git", "-C", str(clone), "fetch"]:
                fetched.append(argv)
                # The fetch brings the nightly's commit: here, this checkout's objects.
                (clone / ".git/objects/info/alternates").write_text(objects + "\n")
                return subprocess.CompletedProcess(argv, 0, "", "")
            return real(argv, **kwargs)
        hot.subprocess.run = run
        self.assertEqual(hot.app_commit(self.app, clone), self.base)
        self.assertEqual(fetched[0][-2:], ["origin", "feat-cmux-next"])

    def test_a_rollback_that_fails_can_be_tried_again(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        kept = self.tmp / "state/builds" / self.old / "cmux"
        good = kept.read_bytes()
        kept.write_bytes(b"#!/bin/sh\necho damaged\n")
        code, receipt, _ = self.hot("rollback")
        self.assertEqual(code, 1)
        self.assertFalse(receipt["ok"])
        self.assertIn("rust", receipt["undo"])
        kept.write_bytes(good)
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertTrue(receipt["ok"])
        self.assertEqual(self.sha(), self.old)

    def test_an_acpmux_home_restarts_its_own_daemon_not_an_inherited_socket_s(self):
        log = self.tmp / "acpmux.log"
        acpmux = self.app / "Contents/Resources/bin/acpmux"
        acpmux.write_text(f'#!/bin/sh\necho "$ACPMUX_HOME|${{ACPMUX_SOCKET:-}}|$*" >> {log}\n')
        acpmux.chmod(0o755)
        self.env["ACPMUX_SOCKET"] = str(self.tmp / "other.sock")
        code, _, err = self.hot("apply", FIX, "--app", str(self.app), "--acpmux-home", str(self.tmp / "home"))
        self.assertEqual(code, 0, err)
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["steps"]["rust"]["acpmux"], [{"home": str(self.tmp / "home"), "restarted": True}])
        # Once for the apply, once for the rollback, each on the home and never on the inherited socket.
        self.assertEqual(log.read_text().splitlines(), [f"{self.tmp / 'home'}||daemon restart"] * 2)

    def test_a_binary_that_does_not_hash_to_its_published_sha_changes_nothing(self):
        self.publish(b"#!/bin/sh\necho tampered\n", self.new)
        code, receipt, _ = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.assertTrue(receipt["rolled_back"])
        self.assertIn("does not hash", receipt["error"])
        self.assertEqual(self.sha(), self.old)

    def test_checksum_files_that_disagree_change_nothing(self):
        self.publish(self.new_body, self.new, listed="0" * 64)
        code, receipt, _ = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.assertEqual(self.sha(), self.old)

    def test_a_commit_the_app_already_has_is_a_no_op(self):
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": FIX}, handle)
        code, receipt, err = self.hot("apply", self.base, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], [])
        self.assertIn("the app already contains SHA", receipt["notes"])
        self.assertEqual(self.sha(), self.old)


class FindSocket(unittest.TestCase):
    """find_socket with ps, lsof and the daemon's `server status` stubbed."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("hot_apply_under_test", SCRIPT)
        self.hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_under_test"] = self.hot
        spec.loader.exec_module(self.hot)
        self.app = Path("/Apps/cmux NIGHTLY.app")
        self.real_run = self.hot.subprocess.run

    def tearDown(self):
        self.hot.subprocess.run = self.real_run

    def stub(self, status, argv0=None):
        prefix = str(self.app / self.hot.BIN)

        def run(argv, **kwargs):
            if argv[0] == "ps" and argv[-1] == "pid=,comm=":
                return subprocess.CompletedProcess(argv, 0, f"4242 {prefix}/cmux-tui\n", "")
            if argv[0] == "ps":
                return subprocess.CompletedProcess(argv, 0, f"4242 {argv0 or prefix + '/cmux-tui'} --session s server\n", "")
            if argv[0] == "lsof":
                return subprocess.CompletedProcess(argv, 0, "p4242\nn/tmp/s.sock\n", "")
            return status(argv)
        self.hot.subprocess.run = run

    def test_a_daemon_that_answers_is_found(self):
        self.stub(lambda argv: subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', ""))
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_daemon_whose_argv0_is_its_bare_name_is_found_by_its_executable(self):
        self.stub(lambda argv: subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', ""), argv0="cmux-tui")
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_status_that_never_answers_is_not_taken_for_no_daemon(self):
        def hang(argv):
            raise subprocess.TimeoutExpired(argv, 10)
        self.stub(hang)
        with self.assertRaisesRegex(RuntimeError, "never answered on /tmp/s.sock"):
            self.hot.find_socket(self.app, Path("cmux"))


if __name__ == "__main__":
    unittest.main()
