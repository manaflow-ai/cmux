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
import importlib.util  # noqa: E402

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

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
                        CMUX_HOT_APPLY_COMMIT_BASE=(self.tmp / "commits").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def publish(self, body, digest, listed=None):
        tree = self.tmp / "tree" / self.key
        tree.mkdir(parents=True, exist_ok=True)
        (tree / self.name).write_bytes(body)
        (tree / f"{self.name}.sha256").write_text(f"{digest}  {self.name}\n")
        (tree / "completion.json").write_text(json.dumps({"key": self.key, "binaries": {self.name: listed or digest}}))
        (tree / "source.json").write_text(json.dumps({"commit": FIX}))
        self.publish_companions({})

    def publish_companions(self, bodies):
        """The commit-addressed build source.json names, with these companions (file -> bytes)."""
        built = self.tmp / "commits" / FIX
        built.mkdir(parents=True, exist_ok=True)
        triple = self.name.removeprefix("cmux-tui-")
        artifacts = {"cmux-app-host": "app-host", "cmux-cloud": "cloud-server", "cmux-holder": "holder"}
        binaries = {}
        for file, body in bodies.items():
            asset = f"cmux-tui-{artifacts[file]}-{triple}"
            (built / asset).write_bytes(body)
            binaries[asset] = hashlib.sha256(body).hexdigest()
        (built / "manifest.json").write_text(json.dumps({"binaries": binaries}))

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
        self.assertEqual(receipt["steps"]["rust"]["acpmux"], [{"home": str(self.tmp / "home"), "restarted": True,
                                                            "own_environment": False}])
        # Once for the apply, once for the rollback, each on the home and never on the inherited socket: a
        # status read of the running daemon (whose launch environment the restart reuses), then the restart.
        home = self.tmp / "home"
        self.assertEqual(log.read_text().splitlines(),
                         [f"{home}||--json daemon status", f"{home}||daemon restart"] * 2)

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

    def side_commit(self, tree_of, message):
        """A commit on FIX's parent with TREE_OF's tree: a branch that never merged."""
        tree = run_git("rev-parse", f"{tree_of}^{{tree}}").stdout.strip()
        done = subprocess.run(["git", "-C", str(ROOT), "-c", "user.name=t", "-c", "user.email=t@localhost",
                               "commit-tree", tree, "-p", self.base, "-m", message],
                              capture_output=True, text=True, check=True)
        return done.stdout.strip()

    def test_a_branch_head_from_before_the_app_takes_its_daemon_with_branch(self):
        # The app was built after the PR branched, with no Rust change since: the PR's daemon fits it.
        app = self.side_commit(self.base, "app: no Rust change after the fork")
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": app}, handle)
        head = self.side_commit(FIX, "the PR: FIX's Rust")
        code, receipt, _ = self.hot("apply", head, "--app", str(self.app))
        self.assertEqual(code, 3)
        self.assertIn("unrelated", receipt["left"])
        self.assertEqual(self.sha(), self.old)
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", head, "--branch", "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        plan = json.loads(done.stdout)
        self.assertEqual((plan["parts"], plan["fork"], plan["published"]), (["rust"], self.base, True))
        code, receipt, err = self.hot("apply", head, "--branch", "--parts", "rust", "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), self.new)

    def test_a_branch_lacking_the_app_s_rust_is_refused(self):
        # The app has FIX's Rust, which the branch (forked before it) does not: its daemon would drop it.
        app = self.side_commit(FIX, "app: FIX's Rust after the fork")
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": app}, handle)
        head = self.side_commit(self.base, "the PR: no Rust")
        code, receipt, _ = self.hot("apply", head, "--branch", "--app", str(self.app))
        self.assertEqual(code, 3)
        self.assertIn("has Rust that", receipt["left"]["unrelated"][0])
        self.assertEqual(self.sha(), self.old)

    def test_an_unpublished_tree_says_so_and_binary_swaps_a_given_build(self):
        subprocess.run(["rm", "-rf", str(self.tmp / "tree")], check=True)
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertFalse(json.loads(done.stdout)["published"])
        built = self.tmp / "built-cmux"
        built.write_bytes(self.new_body)
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--binary", str(built))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), self.new)

    def test_companions_go_in_with_the_daemon_and_come_back_on_rollback(self):
        # The app host is the build's; the holder the app has is gone from the build; the cloud
        # server is new in it. The daemon then runs no sibling of another build.
        app_host = self.app / "Contents/Resources/bin/cmux-app-host"
        holder = self.app / "Contents/Resources/bin/cmux-holder"
        app_host.write_bytes(b"old host")
        holder.write_bytes(b"old holder")
        self.publish_companions({"cmux-app-host": b"new host", "cmux-cloud": b"new cloud"})
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(app_host.read_bytes(), b"new host")
        self.assertFalse(holder.exists())
        self.assertEqual((self.app / "Contents/Resources/bin/cmux-cloud").read_bytes(), b"new cloud")
        self.assertTrue((self.app / "Contents/Resources/bin/cmux-tui").is_symlink(), "a link is left alone")
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertEqual(app_host.read_bytes(), b"old host")
        self.assertEqual(holder.read_bytes(), b"old holder")
        self.assertFalse((self.app / "Contents/Resources/bin/cmux-cloud").exists())
        self.assertEqual(self.sha(), self.old)

    def test_a_binary_brings_the_companions_beside_it(self):
        built = self.tmp / "dev/bin"
        built.mkdir(parents=True)
        (built / "cmux").write_bytes(self.new_body)
        (built / "cmux-app-host").write_bytes(b"dev host")
        app_host = self.app / "Contents/Resources/bin/cmux-app-host"
        app_host.write_bytes(b"old host")
        code, _, err = self.hot("apply", FIX, "--app", str(self.app), "--binary", str(built / "cmux"))
        self.assertEqual(code, 0, err)
        self.assertEqual(app_host.read_bytes(), b"dev host")

    def test_a_commit_the_app_already_has_is_a_no_op(self):
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": FIX}, handle)
        code, receipt, err = self.hot("apply", self.base, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], [])
        self.assertIn("the app already contains SHA", receipt["notes"])
        self.assertEqual(self.sha(), self.old)


class Fetch(unittest.TestCase):
    """fetch() against files.cmux.com, which answers Python's default user agent with 403."""

    def test_fetch_names_itself_rather_than_python_urllib(self):
        import importlib.util
        import io
        spec = importlib.util.spec_from_file_location("hot_apply_fetch_under_test", SCRIPT)
        hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_fetch_under_test"] = hot
        spec.loader.exec_module(hot)
        sent = []

        def urlopen(request, timeout=None):
            # The fleet proof, 2026-11-07: completion.json came back "HTTP Error 403: Forbidden".
            agent = request.get_header("User-agent") if hasattr(request, "get_header") else None
            sent.append(agent)
            if not agent or agent.startswith("Python-urllib"):
                raise hot.urllib.error.HTTPError(str(request), 403, "Forbidden", {}, None)
            return io.BytesIO(b"{}")
        real = hot.urllib.request.urlopen
        hot.urllib.request.urlopen = urlopen
        try:
            self.assertEqual(hot.fetch("https://files.cmux.com/cmux-tui/tree/k/completion.json"), b"{}")
        finally:
            hot.urllib.request.urlopen = real
        self.assertTrue(sent[0].startswith("cmux-hot-apply"))


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

    def stub_acpmux(self, with_daemon):
        """The copy's acpmux daemon (bin/acpmux, a link to bin/cmux), and with WITH_DAEMON its cmux-tui
        daemon too; `server status` on acpmux's socket hangs, as it serves another protocol."""
        prefix = str(self.app / self.hot.BIN)
        procs = {"5151": (f"{prefix}/acpmux", "daemon run --ready-fd 3", "/home/u/.acpmux/builds/x/acpmux.sock")}
        if with_daemon:
            procs["4242"] = (f"{prefix}/cmux-tui", "--session s server", "/tmp/s.sock")

        def run(argv, **kwargs):
            if argv[0] == "ps":
                full = argv[-1] == "pid=,command="
                return subprocess.CompletedProcess(argv, 0, "".join(
                    f"{pid} {exe}{' ' + args if full else ''}\n" for pid, (exe, args, _) in procs.items()), "")
            if argv[0] == "lsof":
                pid = argv[argv.index("-p") + 1]
                return subprocess.CompletedProcess(argv, 0, f"p{pid}\nn{procs[pid][2]}\n", "")
            sock = argv[argv.index("--socket") + 1]
            if "acpmux" in sock:
                raise subprocess.TimeoutExpired(argv, 10)
            return subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', "")
        self.hot.subprocess.run = run

    def test_the_acpmux_daemon_beside_the_terminal_daemon_is_skipped(self):
        self.stub_acpmux(with_daemon=True)
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_copy_running_only_acpmux_has_no_terminal_daemon(self):
        # The fleet proof's fresh nightly copy, 2026-11-06: acpmux ran, the terminal daemon did not yet.
        self.stub_acpmux(with_daemon=False)
        self.assertIsNone(self.hot.find_socket(self.app, Path("cmux")))

    def test_a_daemon_that_answers_is_found(self):
        self.stub(lambda argv: subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', ""))
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_daemon_whose_argv0_is_its_bare_name_is_found_by_its_executable(self):
        self.stub(lambda argv: subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', ""), argv0="cmux-tui")
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_the_apps_own_session_is_picked_over_its_chiefs(self):
        # The fleet proof's copy, 2026-11-07, ran a cmux-chief-... daemon beside cmux-app--... from bin/.
        prefix = str(self.app / self.hot.BIN)
        procs = {"3001": "/v/T/cmux-tui-501/cmux-chief-e8875805.sock", "3002": "/v/T/cmux-tui-501/cmux-app--c117.sock"}

        def run(argv, **kwargs):
            if argv[0] == "ps":
                return subprocess.CompletedProcess(argv, 0, "".join(f"{pid} {prefix}/cmux-tui --headless\n" for pid in procs), "")
            if argv[0] == "lsof":
                pid = argv[argv.index("-p") + 1]
                return subprocess.CompletedProcess(argv, 0, f"p{pid}\nn{procs[pid]}\n", "")
            sock = argv[argv.index("--socket") + 1]
            return subprocess.CompletedProcess(argv, 0, '{"pid": %s}' % next(p for p, n in procs.items() if n == sock), "")
        self.hot.subprocess.run = run
        self.assertEqual(self.hot.find_sockets(self.app, Path("cmux")), [procs["3002"], procs["3001"]])
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), procs["3002"])

    def test_a_hung_app_session_is_not_passed_over_for_the_chiefs(self):
        prefix = str(self.app / self.hot.BIN)
        procs = {"3001": "/v/T/cmux-tui-501/cmux-chief-e8875805.sock", "3002": "/v/T/cmux-tui-501/cmux-app--c117.sock"}

        def run(argv, **kwargs):
            if argv[0] == "ps":
                return subprocess.CompletedProcess(argv, 0, "".join(f"{pid} {prefix}/cmux-tui --headless\n" for pid in procs), "")
            if argv[0] == "lsof":
                pid = argv[argv.index("-p") + 1]
                return subprocess.CompletedProcess(argv, 0, f"p{pid}\nn{procs[pid]}\n", "")
            if "cmux-app" in argv[argv.index("--socket") + 1]:
                raise subprocess.TimeoutExpired(argv, 10)
            return subprocess.CompletedProcess(argv, 0, '{"pid": 3001}', "")
        self.hot.subprocess.run = run
        with self.assertRaises(RuntimeError):
            self.hot.find_sockets(self.app, Path("cmux"))

    def test_an_app_under_a_folder_holding_the_bin_segment_is_found(self):
        self.app = Path(f"/Apps/{self.hot.BIN}/old/cmux NIGHTLY.app")
        self.stub(lambda argv: subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', ""))
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_daemon_started_through_a_linked_folder_is_found(self):
        # The fleet proof, 2026-11-07: the copy was given as /private/tmp/..., and its daemon ran as
        # /tmp/.../bin/cmux-tui (macOS links /tmp to /private/tmp), so neither path form matched.
        with tempfile.TemporaryDirectory() as tmp:
            real = Path(tmp, "private-tmp")
            (real / "cmux NIGHTLY.app" / self.hot.BIN).mkdir(parents=True)
            Path(tmp, "tmp").symlink_to(real)
            self.app = real / "cmux NIGHTLY.app"
            linked = Path(tmp, "tmp", "cmux NIGHTLY.app", self.hot.BIN, "cmux-tui")

            def run(argv, **kwargs):
                if argv[0] == "ps":
                    return subprocess.CompletedProcess(argv, 0, f"4242 {linked} --headless --session s\n", "")
                if argv[0] == "lsof":
                    return subprocess.CompletedProcess(argv, 0, "p4242\nn/tmp/s.sock\n", "")
                return subprocess.CompletedProcess(argv, 0, '{"pid": 4242}', "")
            self.hot.subprocess.run = run
            self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    @unittest.skipUnless(Path("/proc/self/exe").exists(), "Linux /proc")
    def test_a_linux_daemon_with_only_its_basename_in_ps_is_found_by_proc_exe(self):
        # A real process whose executable is in the app: a copy of sleep at APP/Contents/Resources/bin.
        tmp = Path(tempfile.mkdtemp(prefix="hot-apply-proc-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)])
        self.app = tmp / "cmux NIGHTLY.app"
        bin_dir = self.app / self.hot.BIN
        bin_dir.mkdir(parents=True)
        sleeper = bin_dir / "cmux-tui"
        sleeper.write_bytes(Path(subprocess.run(["sh", "-c", "command -v sleep"], capture_output=True,
                                                text=True).stdout.strip()).resolve().read_bytes())
        sleeper.chmod(0o755)
        child = subprocess.Popen(["cmux-tui", "30"], executable=str(sleeper))
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)

        def run(argv, **kwargs):
            if argv[0] == "ps":  # basename only, as /proc/self/exe re-runs show
                return subprocess.CompletedProcess(argv, 0, f"{child.pid} cmux-tui\n", "")
            if argv[0] == "lsof":
                return subprocess.CompletedProcess(argv, 0, f"p{child.pid}\nn/tmp/s.sock\n", "")
            return subprocess.CompletedProcess(argv, 0, f'{{"pid": {child.pid}}}', "")
        self.hot.subprocess.run = run
        self.assertEqual(self.hot.find_socket(self.app, Path("cmux")), "/tmp/s.sock")

    def test_a_status_that_never_answers_is_not_taken_for_no_daemon(self):
        def hang(argv):
            raise subprocess.TimeoutExpired(argv, 10)
        self.stub(hang)
        with self.assertRaisesRegex(RuntimeError, "never answered on /tmp/s.sock"):
            self.hot.find_socket(self.app, Path("cmux"))



class RunningAcpmux(unittest.TestCase):
    """--restart-acpmux: the acpmux daemons running from the app's bin folder are found and restarted, each
    with its own launch environment, and never one whose chats a restart would lose."""

    CHIEF = "/u/.cmux/chief/default/acpmux"

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("hot_apply_acpmux_under_test", SCRIPT)
        self.hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_acpmux_under_test"] = self.hot
        spec.loader.exec_module(self.hot)
        self.app = Path("/Apps/cmux NIGHTLY.app")
        self.real_run = self.hot.subprocess.run
        self.calls = []
        prefix = str(self.app / self.hot.BIN)
        # A team Mac, 2026-11-10: the NIGHTLY's bin ran a Chief daemon, an agent host and session tails.
        self.procs = {"52164": (f"{prefix}/acpmux", "daemon run", f"{self.CHIEF}/acpmux.sock"),
                      "14106": (f"{prefix}/acpmux", "__agent-host", "/u/host.sock"),
                      "14567": (f"{prefix}/acpmux", "--json session tail x -f", f"{self.CHIEF}/acpmux.sock"),
                      "14315": (f"{prefix}/cmux", "mcp serve", "/u/mcp.sock"),
                      "23925": ("/Other.app/Contents/Resources/bin/acpmux", "daemon run", "/u/.acpmux/acpmux.sock")}
        self.status = {self.CHIEF: {"pid": 52164, "home": self.CHIEF, "build": "c230bb58a 2026-10-29",
                                    "agentHosts": True, "store": {"mode": "local"}}}
        self.envs = {52164: {"ACPMUX_CHIEF_MUX_HOME": "/u/.cmux/chief/default", "ACPMUX_SOCKET": "/u/own.sock",
                             "CMUX_NEXT_CUA_SOCKET": "/u/cua.sock"}}
        self.hot.process_env = lambda pid: dict(self.envs[pid]) if pid in self.envs else None

        def run(argv, **kwargs):
            env = kwargs.get("env") or {}
            self.calls.append((list(argv), dict(env)))
            if argv[0] == "ps" and "-p" in argv:
                exe, args, _ = self.procs[argv[-1]]
                return subprocess.CompletedProcess(argv, 0, f"{exe} {args}\n", "")
            if argv[0] == "ps":
                full = argv[-1] == "pid=,command="
                return subprocess.CompletedProcess(argv, 0, "".join(
                    f"{pid} {exe}{' ' + args if full else ''}\n" for pid, (exe, args, _) in self.procs.items()), "")
            if argv[0] == "lsof":
                pid = argv[argv.index("-p") + 1]
                return subprocess.CompletedProcess(argv, 0, f"p{pid}\nn{self.procs[pid][2]}\n", "")
            if argv[1:] == ["--json", "daemon", "status"]:
                home = env.get("ACPMUX_HOME") or str(Path(env["ACPMUX_SOCKET"]).parent)
                if home not in self.status:
                    return subprocess.CompletedProcess(argv, 1, "", "no daemon")
                return subprocess.CompletedProcess(argv, 0, json.dumps(self.status[home]), "")
            if argv[1:] == ["daemon", "restart"]:
                old = self.status[env["ACPMUX_HOME"]]["pid"]
                self.status[env["ACPMUX_HOME"]]["pid"] = old + 1  # the new daemon, with the env it was given
                self.envs[old + 1] = {k: v for k, v in env.items() if k != "ACPMUX_HOME"}
                return subprocess.CompletedProcess(argv, 0, "", "")
            raise AssertionError(argv)
        self.hot.subprocess.run = run

    def tearDown(self):
        self.hot.subprocess.run = self.real_run

    def test_only_the_apps_daemons_are_found_with_their_homes(self):
        found = self.hot.running_acpmux(self.app)
        self.assertEqual(found, [{"pid": 52164, "home": self.CHIEF, "socket": f"{self.CHIEF}/acpmux.sock",
                                  "build": "c230bb58a 2026-10-29",
                                  "keeps_chats": True, "env_readable": True}])

    def test_the_multicall_daemon_is_found_too(self):
        prefix = str(self.app / self.hot.BIN)
        self.procs["52164"] = (f"{prefix}/cmux", "acp daemon run", f"{self.CHIEF}/acpmux.sock")
        self.assertEqual([d["pid"] for d in self.hot.running_acpmux(self.app)], [52164])

    def test_the_restart_runs_with_the_daemons_own_environment(self):
        done = self.hot.restart_acpmux(self.app, [self.CHIEF], {self.CHIEF: 52164})
        self.assertEqual((done[0]["old_pid"], done[0]["new_pid"], done[0]["own_environment"]), (52164, 52165, True))
        env = next(env for argv, env in self.calls if argv[1:] == ["daemon", "restart"])
        # Its Chief home and Computer Use socket kept; by home, never a socket (its own or an inherited one).
        self.assertEqual(env, {"ACPMUX_CHIEF_MUX_HOME": "/u/.cmux/chief/default", "CMUX_NEXT_CUA_SOCKET": "/u/cua.sock",
                               "ACPMUX_HOME": self.CHIEF})

    def test_an_unreadable_environment_is_not_restarted(self):
        self.envs.pop(52164)
        with self.assertRaises(RuntimeError):
            self.hot.restart_acpmux(self.app, [self.CHIEF], {self.CHIEF: 52164})
        self.assertFalse([argv for argv, _ in self.calls if argv[1:] == ["daemon", "restart"]])
        self.assertFalse(self.hot.running_acpmux(self.app)[0]["env_readable"])

    def test_a_memory_store_without_agent_hosts_is_not_one_that_keeps_its_chats(self):
        self.assertTrue(self.hot.keeps_its_chats({"agentHosts": True, "store": {"mode": "memory"}}))
        self.assertTrue(self.hot.keeps_its_chats({"agentHosts": False, "store": {"mode": "local"}}))
        self.assertFalse(self.hot.keeps_its_chats({"agentHosts": False, "store": {"mode": "memory"}}))
        self.status[self.CHIEF].update(agentHosts=False, store={"mode": "memory"})
        self.assertFalse(self.hot.running_acpmux(self.app)[0]["keeps_chats"])

    def test_a_daemon_still_on_its_old_pid_fails_the_step(self):
        real = self.hot.subprocess.run

        def no_new_daemon(argv, **kwargs):
            if argv[1:] == ["daemon", "restart"]:
                return subprocess.CompletedProcess(argv, 0, "", "")
            return real(argv, **kwargs)
        self.hot.subprocess.run = no_new_daemon
        with self.assertRaises(RuntimeError):
            self.hot.restart_acpmux(self.app, [self.CHIEF], {self.CHIEF: 52164})

    def test_a_daemon_serving_its_own_socket_keeps_it(self):
        # #40219 review P2: a daemon started with ACPMUX_SOCKET and serving there (not at its home's default)
        # is found there and comes back on that socket.
        custom = "/u/custom/acpmux.sock"
        self.status["/u/custom"] = self.status.pop(self.CHIEF)  # the fake answers by the socket's folder
        self.envs[52164]["ACPMUX_SOCKET"] = custom
        real = self.hot.subprocess.run

        def by_socket(argv, **kwargs):
            env = kwargs.get("env") or {}
            if argv[1:] == ["daemon", "restart"]:
                self.calls.append((list(argv), dict(env)))
                entry = self.status["/u/custom"]
                entry["pid"] += 1
                return subprocess.CompletedProcess(argv, 0, "", "")
            if argv[1:] == ["--json", "daemon", "status"] and "ACPMUX_HOME" in env:
                return subprocess.CompletedProcess(argv, 1, "", "no daemon")  # nothing at the home's default
            return real(argv, **kwargs)
        self.hot.subprocess.run = by_socket
        done = self.hot.restart_acpmux(self.app, [self.CHIEF], {self.CHIEF: 52164}, {self.CHIEF: custom})
        self.assertEqual(done[0]["new_pid"], 52165)
        env = next(env for argv, env in self.calls if argv[1:] == ["daemon", "restart"])
        self.assertEqual(env["ACPMUX_SOCKET"], custom)

    def test_a_daemon_whose_status_does_not_answer_is_reported(self):
        # #40219 Codex F2: never dropped from discovery, so the receipt names it as left on the old build.
        self.status.clear()
        self.assertEqual(self.hot.running_acpmux(self.app),
                         [{"pid": 52164, "home": None, "build": "", "keeps_chats": False, "env_readable": False,
                           "status_unreadable": True}])

    def test_an_ssh_session_on_macos_restarts_nothing(self):
        # #40219 Codex F1: there launchd would start the daemon without its launch environment.
        saved = (self.hot.sys.platform, dict(os.environ))
        try:
            self.hot.sys.platform = "darwin"
            os.environ["SSH_CONNECTION"] = "1 2 3 4"
            self.assertTrue(self.hot.outside_login_session())
            os.environ.pop("SSH_CONNECTION")
            os.environ.pop("SSH_TTY", None)
            self.assertFalse(self.hot.outside_login_session())
        finally:
            self.hot.sys.platform = saved[0]
            os.environ.clear()
            os.environ.update(saved[1])

    def test_an_empty_environment_is_an_unreadable_one(self):
        # #40219 review P2: a process always starts with some environment; none read means it is hidden.
        reloaded = __import__("importlib.util").util
        spec = reloaded.spec_from_file_location("hot_apply_env_under_test", SCRIPT)
        fresh = reloaded.module_from_spec(spec)
        spec.loader.exec_module(fresh)
        self.assertIsNone(fresh.process_env(2 ** 22 + 12345))  # no such process
        self.assertIsNotNone(fresh.process_env(os.getpid()))


if __name__ == "__main__":
    unittest.main()
