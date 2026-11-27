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
import time
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
# tests/git_history.py fetches FIX into a shallow clone, or says "needs history" (a failure on CI).
_git_history = importlib.util.spec_from_file_location(
    "git_history",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_history.py"),
)
git_history = importlib.util.module_from_spec(_git_history)
_git_history.loader.exec_module(git_history)

SCRIPT = Path(__file__).resolve().parent.parent / "hot-apply.py"
ROOT = SCRIPT.parents[2]
FIX = "a186694568df6a1ad8b5a32d0f4466cb33c03d7f"  # cmux#37155: cmux-tui/crates/cmux-wg only


def run_git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True)


def key_of(sha):
    return subprocess.run([sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", sha],
                          cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


class HotApplyRust(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # FIX and its parent: a shallow CI checkout fetches them; one that cannot fails there, never skips.
        git_history.require_history(ROOT, [FIX], depth=2)

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
                        CMUX_HOT_KEYS_BASE=(self.tmp / "hot-keys").as_uri(),  # none published: plan diffs
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"),
                        # Never the person's own web-dev.json or overlay.
                        CMUX_NEXT_CONFIG_FILE=str(self.tmp / "config/cmux-next.json"),
                        CMUX_WEB_OVERLAY_DIR=str(self.tmp / "overlay"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def test_plan_names_a_web_dev_pointer_the_app_refuses(self):
        abi = self.app / "Contents/Resources/CmuxNext_CmuxNextPages.bundle/Contents/Resources/pages/web-abi.json"
        abi.parent.mkdir(parents=True)
        abi.write_text('{"abi": 7}\n')
        (self.tmp / "overlay").mkdir()
        (self.tmp / "overlay/manifest.json").write_text(json.dumps({"commit": "01192304", "abi": 4}))
        (self.tmp / "config").mkdir()
        (self.tmp / "config/web-dev.json").write_text(json.dumps({"overlay": str(self.tmp / "overlay"), "enabled": True}))
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertEqual(plan["refused_overlay"]["abi"], 4)
        self.assertTrue(any("drop-refused-overlay" in note for note in plan["notes"]), plan["notes"])
        # plan only reads: the pointer is still there.
        self.assertIn("overlay", json.loads((self.tmp / "config/web-dev.json").read_text()))

    def team_signed_app(self):
        """The app as a NIGHTLY is: its main executable signed by TEAM."""
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base, "CFBundleExecutable": "cmux"}, handle)
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/cmux").write_bytes(macho("com.cmuxterm.app.nightly", TEAM))

    def test_a_team_signed_app_keeps_its_daemon_from_an_ad_hoc_build(self):
        # 2026-11-15: a NIGHTLY (Team-signed, b1f76a2) took 20a18ceaa's ad-hoc tree build; its daemon could
        # verify no app connection, so the Cloud machine list failed until rollback put the signed one back.
        self.team_signed_app()
        adhoc = macho("cmux_tui-8cc59fe5f00f9770", adhoc=True, pad=4096)
        self.publish(adhoc, hashlib.sha256(adhoc).hexdigest())
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 3, err)
        self.assertNotIn("rust", receipt["parts"])
        why = receipt["left"]["Rust (the published build is not signed as this app is)"][0]
        self.assertIn("ad-hoc", why)
        self.assertIn(TEAM, why)
        self.assertEqual(self.sha(), self.old)  # nothing swapped
        # --unsigned-daemon takes it, and the receipt says what breaks.
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust", "--unsigned-daemon")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), hashlib.sha256(adhoc).hexdigest())
        self.assertIn("ad-hoc", receipt["steps"]["unsigned_daemon"])

    def test_a_team_signed_app_takes_a_build_of_its_own_team(self):
        self.team_signed_app()
        signed = macho("cmux_tui", TEAM)
        self.publish(signed, hashlib.sha256(signed).hexdigest())
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], ["rust"])

    def test_a_binary_not_signed_as_the_app_is_refused_before_anything_changes(self):
        self.team_signed_app()
        local = self.tmp / "local-cmux"
        local.write_bytes(macho("cmux_tui", "ZZZZZ99999"))
        signed = macho("cmux_tui", TEAM)
        self.publish(signed, hashlib.sha256(signed).hexdigest())
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust", "--binary", str(local))
        self.assertEqual(code, 1, err)
        self.assertIn("ZZZZZ99999", receipt["error"])
        self.assertEqual(self.sha(), self.old)

    def publish_team_signed(self, files, team=None):
        """cmux-tui-team-signed.yml's set for the tree: FILES (bin file -> bytes) signed by TEAM, each under its
        sha256, and the completion.json naming them; every other companion the build has none of."""
        signed = self.tmp / "tree" / self.key / "team-signed"
        entries = {file: None for file in ("cmux", "cmux-app-host", "cmux-cloud", "cmux-browser-host",
                                           "cmux-tui-host", "cmux-holder", "cmux-agent-screen-detection")}
        for file, body in files.items():
            digest = hashlib.sha256(body).hexdigest()
            (signed / digest).mkdir(parents=True, exist_ok=True)
            (signed / digest / file).write_bytes(body)
            entries[file] = {"sha256": digest, "unsigned_sha256": "0" * 64, "size": len(body)}
        (signed / "completion.json").write_text(json.dumps({
            "schema": 1, "key": self.key, "target": self.name.removeprefix("cmux-tui-"), "team": team or TEAM,
            "commit": FIX, "files": entries}))
        return {file: hashlib.sha256(body).hexdigest() for file, body in files.items()}

    def test_a_team_signed_app_takes_the_team_signed_set_over_the_ad_hoc_tree(self):
        # cmuxterm-hq#11364: CI signs each tree's darwin build with the nightly's team, so the rust part
        # reaches a NIGHTLY instead of being held back.
        self.team_signed_app()
        adhoc = macho("cmux_tui-8cc59fe5f00f9770", adhoc=True, pad=4096)
        self.publish(adhoc, hashlib.sha256(adhoc).hexdigest())
        (self.app / "Contents/Resources/bin/cmux-holder").write_bytes(b"the app's holder")
        signed = self.publish_team_signed({"cmux": macho("cmux", TEAM), "cmux-cloud": macho("cmux-cloud", TEAM)})
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--app", str(self.app)],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertIn("rust", plan["parts"])
        self.assertEqual(plan["build"], f"team-signed ({TEAM})")
        self.assertNotIn("Rust (the published build is not signed as this app is)", plan["left"])
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], ["rust"])
        self.assertEqual(receipt["steps"]["build"], f"team-signed ({TEAM})")
        self.assertEqual(self.sha(), signed["cmux"])
        bin_ = self.app / "Contents/Resources/bin"
        self.assertEqual(hashlib.sha256((bin_ / "cmux-cloud").read_bytes()).hexdigest(), signed["cmux-cloud"])
        self.assertFalse((bin_ / "cmux-holder").exists())  # the signed build has none, as the tree's has none
        code, receipt, err = self.hot("rollback", "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), self.old)
        self.assertEqual((bin_ / "cmux-holder").read_bytes(), b"the app's holder")

    def test_an_ad_hoc_app_keeps_taking_the_ad_hoc_tree(self):
        self.publish_team_signed({"cmux": macho("cmux", TEAM)})
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["steps"]["build"], "ad-hoc")
        self.assertEqual(self.sha(), self.new)

    def test_a_team_signed_set_of_another_team_is_not_taken(self):
        self.team_signed_app()
        adhoc = macho("cmux_tui-8cc59fe5f00f9770", adhoc=True, pad=4096)
        self.publish(adhoc, hashlib.sha256(adhoc).hexdigest())
        self.publish_team_signed({"cmux": macho("cmux", "ZZZZZ99999")}, team="ZZZZZ99999")
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 3, err)
        self.assertIn("Rust (the published build is not signed as this app is)", receipt["left"])
        self.assertEqual(self.sha(), self.old)

    def test_a_team_signed_file_that_does_not_hash_to_its_completion_is_refused(self):
        self.team_signed_app()
        adhoc = macho("cmux_tui-8cc59fe5f00f9770", adhoc=True, pad=4096)
        self.publish(adhoc, hashlib.sha256(adhoc).hexdigest())
        signed = self.publish_team_signed({"cmux": macho("cmux", TEAM)})
        (self.tmp / "tree" / self.key / "team-signed" / signed["cmux"] / "cmux").write_bytes(b"not it")
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--parts", "rust")
        self.assertEqual(code, 1, err)
        self.assertIn("does not hash", receipt["error"])
        self.assertEqual(self.sha(), self.old)

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

    def test_the_receipt_times_each_phase_and_stderr_prints_them(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        phases = receipt["phases"]
        for name in ("plan", "key", "fetch", "verify", "backup", "swap"):
            self.assertIn(name, phases)
        # Exclusive phases: together they never exceed the run.
        self.assertLessEqual(sum(phases.values()), receipt["seconds"] + 0.01)
        self.assertRegex(err, r"hot-apply: apply \d+\.\d s: ")
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertIn("rollback", receipt["phases"])

    def test_a_dry_run_fetches_and_verifies_and_changes_nothing(self):
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app), "--dry-run")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["action"], "dry-run")
        self.assertEqual(receipt["steps"]["rust"]["to"], self.new)
        self.assertIn("fetch", receipt["phases"])
        self.assertNotIn("swap", receipt["phases"])
        self.assertEqual(self.sha(), self.old)
        state = self.tmp / "state"
        self.assertFalse((state / "last.json").exists())  # `rollback` never reads a dry run
        self.assertEqual(json.loads((state / "history.jsonl").read_text().splitlines()[-1])["action"], "dry-run")
        self.assertTrue((state / "builds" / self.new / "cmux").is_file())

    def test_base_stands_in_for_an_app(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base,
                               "--app", str(self.tmp / "no such app")], capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["parts"], ["rust"])
        code, _, err = self.hot("apply", FIX, "--app", str(self.app), "--base", self.base)
        self.assertEqual(code, 2, err)  # a real apply reads the app's own commit


    def test_after_a_prefetch_apply_fetches_nothing(self):
        code, receipt, err = self.hot("prefetch", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["action"], "prefetch")
        self.assertEqual(self.sha(), self.old)
        # files.cmux.com goes away: everything apply needs is in the state folder, by content.
        subprocess.run(["rm", "-rf", str(self.tmp / "tree"), str(self.tmp / "commits")], check=True)
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], ["rust"])
        self.assertNotIn("fetch", receipt["phases"])
        self.assertEqual(self.sha(), self.new)

    def test_a_kept_build_that_no_longer_hashes_is_fetched_again(self):
        code, _, err = self.hot("prefetch", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        (self.tmp / "state" / "builds" / self.new / "cmux").write_bytes(b"#!/bin/sh\necho rot\n")
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertIn("fetch", receipt["phases"])
        self.assertEqual(self.sha(), self.new)

    def test_a_completion_without_this_host_s_binary_is_not_kept(self):
        (self.tmp / "tree" / self.key / "completion.json").write_text(json.dumps({"key": self.key, "binaries": {}}))
        code, _, _ = self.hot("prefetch", FIX, "--app", str(self.app))
        self.assertEqual(code, 1)
        self.publish(self.new_body, self.new)  # the build for this host lands later
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), self.new)

    def test_a_build_the_app_already_runs_is_skipped(self):
        code, _, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        code, receipt, err = self.hot("apply", FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["applied"], [])
        self.assertEqual(receipt["unchanged"], ["rust"])
        self.assertNotIn("swap", receipt["phases"])
        # The rollback still puts back the build that ran before the first apply.
        code, receipt, err = self.hot("rollback")
        self.assertEqual(code, 0, err)
        self.assertEqual(self.sha(), self.old)


class HotKeys(unittest.TestCase):
    """`plan` from both commits' published hot keys: no checkout, no diff, no key computed here."""

    @classmethod
    def setUpClass(cls):
        git_history.require_history(ROOT, [FIX], depth=2)
        cls.base = run_git("rev-parse", f"{FIX}^").stdout.strip()

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-keys-"))
        (self.tmp / "keys").mkdir()
        (self.tmp / "empty").mkdir()
        self.env = dict(os.environ, CMUX_HOT_KEYS_BASE=(self.tmp / "keys").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"),
                        CMUX_HOT_APPLY_TUI_BASE=(self.tmp / "tree").as_uri(),
                        CMUX_NEXT_CONFIG_FILE=str(self.tmp / "config/cmux-next.json"),
                        CMUX_WEB_OVERLAY_DIR=str(self.tmp / "overlay"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def publish(self, sha, **changed):
        keys = {"schema": 1, "commit": sha, "tree_key": "1" * 40, "web": "0" * 64, "web_key": "2" * 64, "web_abi": 3,
                "shell": "3" * 64, "ffi": "4" * 64, "helpers": "5" * 64, **changed}
        (self.tmp / "keys" / f"{sha}.json").write_text(json.dumps(keys))

    def plan(self, *extra):
        # --repo is an empty folder: nothing here can diff or key either commit.
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app",
                               str(self.tmp / "none"), "--repo", str(self.tmp / "empty"), *extra],
                              capture_output=True, text=True, env=self.env)
        return done.returncode, json.loads(done.stdout) if done.stdout.startswith("{") else None, done.stderr

    def test_the_two_commits_keys_say_what_the_diff_says(self):
        keys = {}
        for sha in (self.base, FIX):
            done = subprocess.run([sys.executable, str(SCRIPT), "keys", sha], capture_output=True, text=True, env=self.env)
            self.assertEqual(done.returncode, 0, done.stderr)
            keys[sha] = json.loads(done.stdout)
            (self.tmp / "keys" / f"{sha}.json").write_text(done.stdout)
        # cmux#37155 changed cmux-wg only: the daemon and the mobile host's inputs, nothing the app links.
        self.assertNotEqual(keys[FIX]["tree_key"], keys[self.base]["tree_key"])
        self.assertNotEqual(keys[FIX]["helpers"], keys[self.base]["helpers"])
        for same in ("shell", "ffi", "web", "web_key", "web_abi"):
            self.assertEqual(keys[FIX][same], keys[self.base][same], same)
        code, plan, err = self.plan()
        self.assertEqual(code, 0, err)
        self.assertEqual(plan["via"], "published keys")
        self.assertEqual(plan["parts"], ["rust"])
        self.assertEqual(list(plan["left"]), ["bundled helpers (cmux-mobile-host, ...)"])
        self.assertEqual(plan["tree_key"], key_of(FIX))

    def test_a_swift_change_is_left_and_a_web_change_applies(self):
        self.publish(self.base)
        self.publish(FIX, shell="6" * 64, web="b" * 64, web_key="7" * 64)
        code, plan, err = self.plan()
        self.assertEqual(code, 0, err)
        self.assertEqual(plan["parts"], ["web"])
        self.assertEqual(plan["web_key"], "7" * 64)
        self.assertEqual(list(plan["left"]), ["Swift, resources and manifests"])

    def test_a_new_web_abi_keeps_the_web(self):
        self.publish(self.base)
        self.publish(FIX, web="b" * 64, web_key="a" * 64, web_abi=4)
        code, plan, err = self.plan()
        self.assertEqual(code, 3, err)
        self.assertEqual(plan["parts"], [])
        self.assertEqual(list(plan["left"]), ["web ABI"])

    def test_an_ffi_change_is_planned_from_the_diff(self):
        # The app FFI may swap warm (cmux#43548), and which files changed decides it: the keys hand the pair over.
        self.publish(self.base)
        self.publish(FIX, tree_key="8" * 40, ffi="9" * 64)
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app", str(self.tmp / "none")],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertNotIn("via", plan)
        self.assertEqual(plan["parts"], ["rust"])  # cmux#37155's real diff: no FFI file

    def test_the_keys_plan_keeps_a_team_signed_apps_daemon_from_an_ad_hoc_build(self):
        # The published-keys plan checks the signature as the diff plan does (2026-11-15's Cloud list failure).
        app = self.tmp / "cmux NIGHTLY.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        with open(app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base, "CFBundleExecutable": "cmux"}, handle)
        (app / "Contents/MacOS/cmux").write_bytes(macho("com.cmuxterm.app.nightly", TEAM))
        self.publish(self.base)
        self.publish(FIX, tree_key="8" * 40)
        name = f"cmux-tui-{'aarch64' if platform.machine() in ('arm64', 'aarch64') else 'x86_64'}-" + (
            "apple-darwin" if sys.platform == "darwin" else "unknown-linux-musl")
        tree = self.tmp / "tree" / ("8" * 40)
        tree.mkdir(parents=True)
        (tree / name).write_bytes(macho("cmux_tui-8cc59fe5f00f9770", adhoc=True, pad=4096))
        (tree / "completion.json").write_text(json.dumps({"key": "8" * 40, "binaries": {name: "a" * 64}}))
        run = [sys.executable, str(SCRIPT), "plan", FIX, "--app", str(app), "--repo", str(self.tmp / "empty")]
        done = subprocess.run(run, capture_output=True, text=True, env=self.env)
        plan = json.loads(done.stdout)
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertEqual(plan["via"], "published keys")
        self.assertEqual(plan["parts"], [])
        self.assertIn(TEAM, " ".join(plan["left"]["Rust (the published build is not signed as this app is)"]))
        done = subprocess.run([*run, "--unsigned-daemon"], capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(json.loads(done.stdout)["parts"], ["rust"])

    def test_equal_keys_are_a_no_op(self):
        self.publish(self.base)
        self.publish(FIX)
        code, plan, err = self.plan()
        self.assertEqual(code, 0, err)
        self.assertEqual((plan["parts"], plan["left"]), ([], {}))

    def test_a_missing_or_malformed_key_file_falls_back_to_the_diff(self):
        self.publish(self.base)
        (self.tmp / "keys" / f"{FIX}.json").write_text(json.dumps({"schema": 1, "commit": FIX}))
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app", str(self.tmp / "none")],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        plan = json.loads(done.stdout)
        self.assertNotIn("via", plan)
        self.assertEqual(plan["parts"], ["rust"])

    def test_a_record_without_web_abi_or_a_broken_kept_one_falls_back(self):
        # Review of #43558 (F1): a record missing web_abi was taken and kept, and a web change then raised KeyError.
        self.publish(self.base)
        self.publish(FIX, web="b" * 64, web_key="7" * 64)
        record = json.loads((self.tmp / "keys" / f"{FIX}.json").read_text())
        del record["web_abi"]
        (self.tmp / "keys" / f"{FIX}.json").write_text(json.dumps(record))
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app", str(self.tmp / "none")],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("via", json.loads(done.stdout))
        self.assertFalse((self.tmp / "state" / "keys" / "hot" / f"{FIX}.json").exists())
        # A kept record that is not whole (an older hot-apply wrote it) is not read either.
        kept = self.tmp / "state" / "keys" / "hot" / f"{FIX}.json"
        kept.write_text(json.dumps(record))
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app", str(self.tmp / "none")],
                              capture_output=True, text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("via", json.loads(done.stdout))

    def test_a_miss_is_asked_once_then_kept(self):
        self.publish(self.base)  # FIX has none yet
        code, plan, err = self.plan()
        self.assertNotEqual(plan and plan.get("via"), "published keys", err)
        self.assertTrue((self.tmp / "state" / "keys" / "hot" / f"{FIX}.missing").exists())
        # CI publishes FIX's keys now: within the hour the kept miss stands, and nothing is fetched.
        self.publish(FIX, web="b" * 64, web_key="7" * 64)
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", FIX, "--base", self.base, "--app", str(self.tmp / "none")],
                              capture_output=True, text=True, env=self.env)
        self.assertNotIn("via", json.loads(done.stdout), done.stderr)
        # Past the hour it is asked again and taken.
        os.utime(self.tmp / "state" / "keys" / "hot" / f"{FIX}.missing", (0, 0))
        code, plan, err = self.plan()
        self.assertEqual(plan["via"], "published keys", err)
        self.assertEqual(plan["parts"], ["web"])


SHIM = "a3bead27e6599480e2d2654816f9ecdff99ecaf2"  # cmux#43239's remote browser host: Rust plus csrc/rb_shim.mm and .h


class NativeSources(unittest.TestCase):
    """C, Objective-C and Zig inside cmux-tui ride the Rust part: the tree build compiles them."""

    @classmethod
    def setUpClass(cls):
        git_history.require_history(ROOT, [SHIM], depth=2)

    def test_a_companion_s_objective_c_shim_is_not_left_for_a_nightly(self):
        tmp = Path(tempfile.mkdtemp(prefix="hot-apply-native-"))
        try:
            env = dict(os.environ, CMUX_HOT_APPLY_STATE_DIR=str(tmp / "state"),
                       CMUX_HOT_APPLY_TUI_BASE=(tmp / "tree").as_uri())  # nothing published: plan only
            base = run_git("rev-parse", f"{SHIM}^").stdout.strip()
            done = subprocess.run([sys.executable, str(SCRIPT), "plan", SHIM, "--base", base, "--app", str(tmp / "none")],
                                  capture_output=True, text=True, env=env)
            plan = json.loads(done.stdout)
            self.assertEqual(plan["parts"], ["rust"], done.stderr)
            left = [p for paths in plan["left"].values() for p in paths]
            self.assertFalse([p for p in left if p.endswith((".mm", ".h"))], plan["left"])
        finally:
            subprocess.run(["rm", "-rf", str(tmp)])



class OtherSessions(unittest.TestCase):
    """--restart-sessions: another session's daemon from the app's bin (a Chief's) is handed to the new build
    with `server restart` on its socket, as the app's own is handed off; without it, it is named and left."""

    APP_SOCK, CHIEF_SOCK = "/tmp/cmux-app-test.sock", "/tmp/cmux-chief-test.sock"

    def setUp(self):
        spec = importlib.util.spec_from_file_location("hot_apply_sessions_under_test", SCRIPT)
        self.hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_sessions_under_test"] = self.hot
        spec.loader.exec_module(self.hot)
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-sessions-"))
        self.target = self.tmp / "cmux NIGHTLY.app/Contents/Resources/bin/cmux"
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"old")
        self.target.with_name("cmux-tui").symlink_to("cmux")
        self.new = self.tmp / "new"
        self.new.write_bytes(b"new")
        self.want = hashlib.sha256(b"new").hexdigest()
        self.pids = {self.APP_SOCK: 100, self.CHIEF_SOCK: 200}
        self.restarted, self.restart_works, self.surfaces, self.state_dirs = [], True, [], []
        self.exes = {}
        test = self

        class Swapper:
            def __init__(self, _cli, socket, state=None):
                self.socket = socket

            def owner(self, _cli, timeout=60):
                return (test.pids[self.socket], test.exes.get(self.socket, test.target)) if self.socket in test.pids else None

            @staticmethod
            def app_file(exe):
                return exe

            def app_handoff(self, new, _pid, target):
                target.write_bytes(new.read_bytes())
                test.pids[self.socket] += 1

        real_run = self.hot.subprocess.run

        def run(argv, **kwargs):
            if argv[-2:] == ["server", "restart"]:
                sock = argv[argv.index("--socket") + 1]
                test.restarted.append(sock)
                test.surfaces.append(Path(argv[0]).name)
                test.state_dirs.append((kwargs.get("env") or {}).get("CMUX_TUI_STATE_DIR"))
                if test.restart_works is True:
                    test.pids[sock] += 1
                elif test.restart_works == "gone":
                    del test.pids[sock]
                return subprocess.CompletedProcess(argv, 0 if test.restart_works is True else 1, "{}",
                                                   '{"code":"server.different_state"}')
            return real_run(argv, **kwargs)

        self.hot.load = lambda name, file: type("rust_live", (), {"Swapper": Swapper})
        self.hot.find_sockets = lambda app, cli: [self.APP_SOCK, self.CHIEF_SOCK]
        self.hot.subprocess.run = run
        self.addCleanup(setattr, self.hot.subprocess, "run", real_run)
        self.hot.outside_login_session = lambda: False
        # The Chief's daemon keeps its session in its own state dir, as on Leo's NIGHTLY.
        self.real_owner_state_dir = self.hot.owner_state_dir
        self.hot.owner_state_dir = lambda pid: "/u/.cmux/chief/default/tui" if pid == 200 else None

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def test_the_restart_runs_in_the_daemon_s_own_state_dir(self):
        # Without it the restart's ensure read the default root and refused (server.different_state, 8568ebc).
        self.swap(True)
        self.assertEqual(self.state_dirs, ["/u/.cmux/chief/default/tui"])

    def test_owner_state_dir_reads_the_value_up_to_the_next_variable(self):
        real_run = self.hot.subprocess.run
        self.hot.subprocess.run = lambda argv, **kw: subprocess.CompletedProcess(
            argv, 0, "/A/cmux --headless --session c HOME=/u CMUX_TUI_STATE_DIR=/u/.cmux/chief/a b/tui TERM=x\n", "")
        try:
            self.assertEqual(self.real_owner_state_dir(1), "/u/.cmux/chief/a b/tui")
        finally:
            self.hot.subprocess.run = real_run

    def swap(self, sessions):
        return self.hot.swap_cmux(self.target.parents[3], self.new, self.want, None, self.tmp / "state", sessions)

    def test_a_daemon_on_a_retired_copy_of_the_app_is_left_and_the_live_one_takes_the_swap(self):
        # Leo's NIGHTLY, 2026-11-15: cmux-app.sock's daemon outlived an update and ran the copy the updater
        # moved to nightly-update/backup/retired, so the apply refused ("not this app's") and changed nothing.
        retired_sock = "/tmp/cmux-app.sock"
        self.pids[retired_sock] = 300
        self.exes[retired_sock] = self.tmp / "retired/cmux NIGHTLY.app/Contents/Resources/bin/cmux"
        self.hot.find_sockets = lambda app, cli: [retired_sock, self.APP_SOCK, self.CHIEF_SOCK]
        step = self.swap(False)
        self.assertEqual(step["socket"], self.APP_SOCK)
        self.assertEqual((step["old_pid"], step["new_pid"]), (100, 101))
        self.assertEqual([one["socket"] for one in step["left_on_retired_copy"]], [retired_sock])
        self.assertEqual(step["left_on_old_build"], [self.CHIEF_SOCK])
        self.assertEqual(self.pids[retired_sock], 300)

    def test_not_asked_names_the_chief_s_daemon_and_leaves_it(self):
        step = self.swap(False)
        self.assertEqual(step["left_on_old_build"], [self.CHIEF_SOCK])
        self.assertIn("not asked", step["left_on_old_build_why"])
        self.assertEqual(self.restarted, [])
        self.assertEqual(self.pids[self.CHIEF_SOCK], 200)

    def test_asked_hands_the_chief_s_daemon_over_too(self):
        step = self.swap(True)
        self.assertNotIn("left_on_old_build", step)
        self.assertEqual(self.restarted, [self.CHIEF_SOCK])
        # On `cmux`, `server` is the machine server and refuses --socket: the cmux-tui link keeps the lifecycle.
        self.assertEqual(self.surfaces, ["cmux-tui"])
        self.assertEqual([(s["socket"], s["old_pid"], s["new_pid"]) for s in step["sessions"]],
                         [(self.CHIEF_SOCK, 200, 201)])
        self.assertEqual((step["old_pid"], step["new_pid"]), (100, 101))  # the app's own, as before

    def test_from_ssh_on_macos_it_is_left_and_says_why(self):
        self.hot.outside_login_session = lambda: True
        step = self.swap(True)
        self.assertEqual(step["left_on_old_build"], [self.CHIEF_SOCK])
        self.assertIn("ssh", step["left_on_old_build_why"])
        self.assertEqual(self.restarted, [])

    def test_a_refused_restart_still_served_is_left_and_named_the_rest_moves(self):
        # A Chief whose owner serves another state directory refuses (server.different_state, cmux bf0d3da):
        # its owner still serves, so it keeps its build and the apply goes on.
        self.restart_works = "refuse"
        step = self.swap(True)
        self.assertEqual(step["left_on_old_build"], [self.CHIEF_SOCK])
        self.assertIn("refused", step["left_on_old_build_why"])
        self.assertIn("server.different_state", step["sessions"][0]["left"])
        self.assertEqual(self.pids[self.CHIEF_SOCK], 200)
        self.assertEqual((step["old_pid"], step["new_pid"]), (100, 101))

    def test_a_restart_that_leaves_no_owner_raises_so_the_apply_puts_back(self):
        self.restart_works = "gone"
        with self.assertRaises(RuntimeError) as caught:
            self.swap(True)
        self.assertIn(self.CHIEF_SOCK, str(caught.exception))


class FirstStatus(unittest.TestCase):
    """find_sockets asks every socket of a daemon at once: one that never answers (a Chief's holds one) no longer
    costs the full timeout before the daemon's own socket answers."""

    def setUp(self):
        spec = importlib.util.spec_from_file_location("hot_apply_first_status_under_test", SCRIPT)
        self.hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_first_status_under_test"] = self.hot
        spec.loader.exec_module(self.hot)
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-first-status-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.cli = self.tmp / "cmux"
        # `--socket NAME --json server status`: a name ending in hang.sock never answers, the rest name pid 42.
        self.cli.write_text('#!/bin/sh\ncase "$2" in *hang.sock) exec sleep 30 ;; esac\necho \'{"pid": 42}\'\n')
        self.cli.chmod(0o755)

    def test_the_answering_socket_wins_without_waiting_on_the_hung_one(self):
        t0 = time.monotonic()
        name, unanswered = self.hot.first_status(self.cli, ["/tmp/a-hang.sock", "/tmp/b-daemon.sock"], "42")
        self.assertEqual((name, unanswered), ("/tmp/b-daemon.sock", []))
        self.assertLess(time.monotonic() - t0, 5)

    def test_only_hung_sockets_are_reported_unanswered(self):
        name, unanswered = self.hot.first_status(self.cli, ["/tmp/a-hang.sock"], "42", timeout=0.5)
        self.assertEqual((name, unanswered), (None, ["/tmp/a-hang.sock"]))

    def test_another_pid_is_no_match(self):
        name, unanswered = self.hot.first_status(self.cli, ["/tmp/b-daemon.sock"], "7")
        self.assertEqual((name, unanswered), (None, []))


ADOPTED = "b6236a4e4ea648236cef9d0ca2ffa4ed78fe0693"  # before #43477 added a tree input
ADOPTED_KEY = "b3a5a6a29766bec348f384673782f35495bc794b"  # files.cmux.com/cmux-tui/<ADOPTED>/manifest.json treeKey


class TreeKey(unittest.TestCase):
    """A commit's tree key is the one CI published it under: its own key script over its own inputs list,
    whatever this checkout's say. With this checkout's (#43477 added an input), ADOPTED keyed to a tree
    nothing was published under, and hot-apply found no build for any commit before it."""

    @classmethod
    def setUpClass(cls):
        git_history.require_history(ROOT, [ADOPTED], depth=2)

    def test_a_commit_before_an_inputs_change_keys_as_ci_published_it(self):
        spec = importlib.util.spec_from_file_location("hot_apply_key_under_test", SCRIPT)
        hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_key_under_test"] = hot
        spec.loader.exec_module(hot)
        self.assertEqual(hot._tree_key(ROOT, ADOPTED), ADOPTED_KEY)


FFI ="2c58afdd5f8ac95146fed0cc3c472aee5af31562"  # cmux#43373: cmux-tui/bindings/rust, which the app links


class LiveFrom(unittest.TestCase):
    """`live-from SHA`: the app commits that can take SHA's daemon build live, for the signed Mac live update file."""

    @classmethod
    def setUpClass(cls):
        git_history.require_history(ROOT, [FIX, FFI], depth=4)

    def live_from(self, sha, limit):
        done = subprocess.run([sys.executable, str(SCRIPT), "live-from", sha, "--max", str(limit)],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout)

    def test_a_daemon_only_commit_reaches_back_past_itself(self):
        out = self.live_from(FIX, 3)
        self.assertEqual(out["live_from"][0], FIX)
        self.assertEqual(len(out["live_from"]), 3)
        self.assertIsNone(out["floor"])  # no FFI change within the limit

    def test_a_commit_that_changes_rust_the_app_links_is_its_own_floor(self):
        out = self.live_from(FFI, 5)
        self.assertEqual((out["live_from"], out["floor"]), ([FFI], FFI))
        self.assertTrue(all(p.startswith("cmux-tui/bindings/rust/") for p in out["floor_paths"]), out["floor_paths"])


class WebCache(unittest.TestCase):
    """web_bundles(): a web key's bundles fetched once, checked on each use, bounded."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-web-test-"))
        os.environ["CMUX_HOT_APPLY_STATE_DIR"] = str(self.tmp / "state")
        spec = importlib.util.spec_from_file_location("hot_apply_web_under_test", SCRIPT)
        self.hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_web_under_test"] = self.hot
        spec.loader.exec_module(self.hot)
        self.fetched = []

        def fetch_web(key, out):
            self.fetched.append(key)
            (out / "pages").mkdir(parents=True)
            (out / "pages/index.html").write_text(f"<p>{key}</p>")
        self.hot.fetch_web = fetch_web

    def tearDown(self):
        os.environ.pop("CMUX_HOT_APPLY_STATE_DIR", None)
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def test_a_key_is_fetched_once_and_again_when_its_files_change(self):
        key = "a" * 64
        state = self.tmp / "state"
        root = self.hot.web_bundles(key, state)
        self.assertEqual(self.hot.web_bundles(key, state), root)
        self.assertEqual(self.fetched, [key])
        (root / "pages/index.html").write_text("tampered")
        self.hot.web_bundles(key, state)
        self.assertEqual(self.fetched, [key, key])
        self.assertEqual((root / "pages/index.html").read_text(), f"<p>{key}</p>")

    def test_only_the_newest_keys_stay(self):
        state = self.tmp / "state"
        for i in range(self.hot.WEB_KEEP + 3):
            root = self.hot.web_bundles(f"{i:064x}", state)
            os.utime(root, (1000 + i, 1000 + i))
        self.hot.prune_web(state)
        kept = sorted(p.name for p in (state / "web").iterdir() if not p.name.startswith("."))
        self.assertEqual(len(kept), self.hot.WEB_KEEP)
        self.assertNotIn(f"{0:064x}", kept)

    def test_an_overlay_holding_the_key_is_unchanged(self):
        commit = "c" * 40
        key = "d" * 64

        class Live:
            def overlay_paths(inner):
                return self.tmp / "overlay", None
        (self.tmp / "overlay").mkdir()
        (self.tmp / "overlay/manifest.json").write_text(json.dumps({"commit": commit}))
        self.assertFalse(self.hot.web_unchanged(Live(), key))  # its key was never computed here
        keys = self.tmp / "state/keys/web"
        keys.mkdir(parents=True)
        (keys / commit).write_text(key + "\n")
        self.assertTrue(self.hot.web_unchanged(Live(), key))
        self.assertFalse(self.hot.web_unchanged(Live(), "e" * 64))


class Phases(unittest.TestCase):
    def test_an_inner_phase_pauses_the_outer_one(self):
        spec = importlib.util.spec_from_file_location("hot_apply_phases_under_test", SCRIPT)
        hot = importlib.util.module_from_spec(spec)
        sys.modules["hot_apply_phases_under_test"] = hot
        spec.loader.exec_module(hot)
        clock = iter([0.0, 1.0, 3.0, 4.0, 10.0])
        real = hot.time.monotonic
        hot.time.monotonic = lambda: next(clock)
        try:
            phases = hot.Phases()  # 0
            with phases("plan"):  # 1
                with phases("key"):  # 3
                    pass  # 4
            # 10: plan ran 1-3 and 4-10, key 3-4
        finally:
            hot.time.monotonic = real
        self.assertEqual(phases.rounded(), {"plan": 8.0, "key": 1.0})


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
                # One lsof for every process (-p a,b,...): each pid's line, then its sockets.
                asked = argv[argv.index("-p") + 1].split(",")
                return subprocess.CompletedProcess(argv, 0, "".join(f"p{pid}\nn{procs[pid][2]}\n" for pid in asked), "")
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
                asked = argv[argv.index("-p") + 1].split(",")  # one lsof for every process
                return subprocess.CompletedProcess(argv, 0, "".join(f"p{pid}\nn{procs[pid]}\n" for pid in asked), "")
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
                asked = argv[argv.index("-p") + 1].split(",")  # one lsof for every process
                return subprocess.CompletedProcess(argv, 0, "".join(f"p{pid}\nn{procs[pid]}\n" for pid in asked), "")
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
                asked = argv[argv.index("-p") + 1].split(",")  # one lsof for every process
                return subprocess.CompletedProcess(argv, 0, "".join(f"p{pid}\nn{self.procs[pid][2]}\n" for pid in asked), "")
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


FFI_FIX = "2d7bfe48c026a2382c834b04007492dd92c88e3b"  # cmux-layout-reducer only: an app FFI input
FFI_FIX_PIN = "387615ca1bafb7d63f255da52edde22e64132fe5"  # the release FFI_FIX^ pins: the additive check diffs it


class HotApplyFFI(unittest.TestCase):
    """The ffi part: a commit that changes only the Rust the app links, against an app carrying it as a library."""

    @classmethod
    def setUpClass(cls):
        # The pairing check diffs the app's pinned source against FFI_FIX: a shallow checkout (CI, Linux) lacks it.
        git_history.require_history(ROOT, [FFI_FIX, FFI_FIX_PIN], depth=2)
        sys.path.insert(0, str(SCRIPT.parent))
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import hot_apply_ffi
        cls.ffi = hot_apply_ffi

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-ffi-test-"))
        self.base = run_git("rev-parse", f"{FFI_FIX}^").stdout.strip()
        self.app = self.tmp / "cmux NIGHTLY.app"
        (self.app / "Contents/Resources/bin").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base, "CFBundleExecutable": "cmux"}, handle)
        self.releases = self.tmp / "releases"
        self.env = dict(os.environ, CMUX_HOT_APPLY_FFI_BASE=self.releases.as_uri(),
                        CMUX_HOT_APPLY_TUI_BASE=(self.tmp / "tree").as_uri(),
                        CMUX_HOT_APPLY_COMMIT_BASE=(self.tmp / "commits").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def hot(self, *args):
        done = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, env=self.env)
        out = done.stdout.strip()
        if out.startswith("{") and "\n" in out and not out.splitlines()[-1].startswith("{"):
            return done.returncode, json.loads(out), done.stderr  # plan: indented JSON
        lines = out.splitlines()
        return done.returncode, (json.loads(lines[-1]) if lines and lines[-1].startswith("{") else None), done.stderr

    def carry_dylib(self):
        (self.app / "Contents/Frameworks").mkdir(parents=True, exist_ok=True)
        (self.app / self.ffi.DYLIB).write_bytes(b"old library")

    def publish(self, member="CCmuxAppFFI.xcframework/macos-arm64_x86_64/libcmux_app_ffi.dylib", body=b"new library"):
        import io
        import zipfile
        tag = self.releases / f"cmux-app-ffi-{FFI_FIX}"
        tag.mkdir(parents=True, exist_ok=True)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as zipped:
            zipped.writestr(member, body)
        archive = buffer.getvalue()
        (tag / "CCmuxAppFFI.xcframework.zip").write_bytes(archive)
        digest = hashlib.sha256(archive).hexdigest()
        (tag / "SHA256SUMS").write_text(f"{digest}  CCmuxAppFFI.xcframework.zip\n")
        return digest

    def test_plan_takes_the_ffi_part_for_an_app_carrying_the_library(self):
        self.carry_dylib()
        code, plan, err = self.hot("plan", FFI_FIX, "--app", str(self.app))
        self.assertEqual(code, 0, err)
        self.assertIn("ffi", plan["parts"])
        self.assertIn("rust", plan["parts"])  # the daemon part rides with it
        self.assertNotIn("Rust the app links (FFI)", plan["left"])
        self.assertEqual(plan["ffi"]["source"], FFI_FIX)
        self.assertEqual(plan["ffi"]["release"], f"cmux-app-ffi-{FFI_FIX}")
        self.assertTrue(all(p.startswith("cmux-tui/crates/cmux-layout-reducer") for p in plan["ffi"]["files"]))

    def test_an_app_linking_the_ffi_statically_leaves_it_with_why(self):
        code, plan, err = self.hot("plan", FFI_FIX, "--app", str(self.app))
        self.assertNotIn("ffi", plan["parts"], err)
        self.assertIn("Rust the app links (FFI)", plan["left"])
        self.assertTrue(any("links the app FFI statically" in note for note in plan["notes"]), plan["notes"])

    def test_a_branch_s_ffi_is_left(self):
        self.carry_dylib()
        code, plan, err = self.hot("plan", FFI_FIX, "--app", str(self.app), "--branch")
        self.assertNotIn("ffi", plan["parts"], err)
        self.assertTrue(any("branch" in note for note in plan["notes"]), plan["notes"])

    def test_a_dry_run_fetches_and_checks_the_published_library(self):
        digest = self.publish()
        code, receipt, err = self.hot("apply", FFI_FIX, "--base", self.base, "--dry-run", "--parts", "ffi")
        self.assertEqual(code, 0, err)
        self.assertEqual(receipt["steps"]["ffi"]["archive_sha256"], digest)
        self.assertEqual(Path(receipt["steps"]["ffi"]["copy"]).read_bytes(), b"new library")

    def test_an_unpublished_release_says_so(self):
        code, receipt, err = self.hot("apply", FFI_FIX, "--base", self.base, "--dry-run", "--parts", "ffi")
        self.assertIn("not published", " ".join(receipt["left"]["ffi"]), err)

    def test_a_release_from_before_the_dylib_is_left(self):
        self.publish(member="CCmuxAppFFI.xcframework/macos-arm64_x86_64/libcmux_app_ffi.a")
        code, receipt, err = self.hot("apply", FFI_FIX, "--base", self.base, "--dry-run", "--parts", "ffi")
        self.assertIn("carries no libcmux_app_ffi.dylib", " ".join(receipt["left"]["ffi"]), err)

    def test_an_archive_that_does_not_hash_to_its_sums_changes_nothing(self):
        self.publish()
        sums = self.releases / f"cmux-app-ffi-{FFI_FIX}" / "SHA256SUMS"
        sums.write_text(f"{'0' * 64}  CCmuxAppFFI.xcframework.zip\n")
        code, receipt, err = self.hot("apply", FFI_FIX, "--base", self.base, "--dry-run", "--parts", "ffi")
        self.assertNotEqual(code, 0)
        self.assertIn("does not hash", receipt["error"], err)
        self.assertFalse((self.tmp / "state" / "ffi").exists())

    def test_a_developer_id_app_takes_the_library_only_as_asked(self):
        saved = self.ffi.signature, self.ffi.validates_no_libraries
        try:
            self.ffi.signature = lambda path: {"team": "TEAM123456", "runtime": True, "adhoc": False}
            self.ffi.validates_no_libraries = lambda path: False
            with self.assertRaises(self.ffi.Left) as left:
                self.ffi.how_to_sign(self.app, None, False)
            self.assertIn("--sign-identity", str(left.exception))
            self.assertEqual(self.ffi.how_to_sign(self.app, "Developer ID Application: X", False), "identity")
            self.assertEqual(self.ffi.how_to_sign(self.app, None, True), "reseal")
            # A NIGHTLY's signature disables library validation (cmux.nightly.entitlements): an ad hoc library loads.
            self.ffi.validates_no_libraries = lambda path: True
            self.assertEqual(self.ffi.how_to_sign(self.app, None, False), "adhoc")
            self.ffi.signature = lambda path: {"team": None, "runtime": False, "adhoc": True}
            self.ffi.validates_no_libraries = lambda path: False
            self.assertEqual(self.ffi.how_to_sign(self.app, None, False), "adhoc")
        finally:
            self.ffi.signature, self.ffi.validates_no_libraries = saved

    def test_the_app_opens_through_launchd_where_open_fails(self):
        # A terminal of the app outlives `cmux app quit --keep-sessions`, but `open` fails there (error -600), and
        # over ssh: the user's GUI domain opens the app, and the one-shot agent goes once the app answers.
        calls = []

        def run(*args, check=True):
            calls.append(args)
            failed = args[0] == "open"
            return subprocess.CompletedProcess(args, 1 if failed else 0, "",
                                               "_LSOpenURLsWithCompletionHandler() failed with error -600." if failed else "")

        saved = self.ffi._run, self.ffi.answering_pid, self.ffi.app_pid, self.ffi.STAY_SECONDS
        try:
            self.ffi._run = run
            self.ffi.answering_pid = lambda app: 4242
            self.ffi.app_pid = lambda app: 4242
            self.ffi.STAY_SECONDS = 0
            step = self.ffi.launch(self.app, 4141)
        finally:
            self.ffi._run, self.ffi.answering_pid, self.ffi.app_pid, self.ffi.STAY_SECONDS = saved
        self.assertEqual((step["pid"], step["opened_via"]), (4242, "launchd"))
        self.assertEqual([c[:2] for c in calls], [("open", str(self.app)), ("launchctl", "bootstrap"),
                                                  ("launchctl", "bootout")])
        plist = Path(calls[1][3])
        self.assertFalse(plist.parent.exists(), "the one-shot agent's plist is removed")
        self.assertEqual(calls[2][2], f"gui/{os.getuid()}/{plist.stem}")


REPIN = "01936a9c77c22a3735bee357aa417eb7f0bf110e"  # app-ffi-repin: app-ffi-pin.json and Package.swift's checksum line
REPIN_FROM = "e238ea5486824ff4fc766954d4bc91d37b90af0c"  # the release its parent pins
REPIN_TO = "fcd50f439039123ef3e0425d74655159d4011798"  # the release it pins


class HotApplyFFIPin(unittest.TestCase):
    """The ffi part for a commit that only moves the pin: an app links the release its commit pins, which lags its
    FFI sources until app-ffi-repin lands, so the re-pin commit is what brings the app's library up to date."""

    @classmethod
    def setUpClass(cls):
        git_history.require_history(ROOT, [REPIN, REPIN_FROM, REPIN_TO], depth=2)
        sys.path.insert(0, str(SCRIPT.parent))
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        import hot_apply_ffi
        cls.ffi = hot_apply_ffi

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-ffi-pin-test-"))
        self.base = run_git("rev-parse", f"{REPIN}^").stdout.strip()
        self.app = self.tmp / "cmux NIGHTLY.app"
        (self.app / "Contents/Resources/bin").mkdir(parents=True)
        with open(self.app / "Contents/Info.plist", "wb") as handle:
            plistlib.dump({"CMUXCommit": self.base, "CFBundleExecutable": "cmux"}, handle)
        self.env = dict(os.environ, CMUX_HOT_APPLY_FFI_BASE=(self.tmp / "releases").as_uri(),
                        CMUX_HOT_APPLY_TUI_BASE=(self.tmp / "tree").as_uri(),
                        CMUX_HOT_APPLY_COMMIT_BASE=(self.tmp / "commits").as_uri(),
                        CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def plan(self, *args):
        done = subprocess.run([sys.executable, str(SCRIPT), "plan", REPIN, *args], capture_output=True, text=True,
                              env=self.env)
        self.assertIn(done.returncode, (0, 3), done.stderr)  # 3: something is left for a new app
        return json.loads(done.stdout)

    def test_a_commit_that_moves_the_pin_takes_the_ffi_part(self):
        (self.app / "Contents/Frameworks").mkdir(parents=True)
        (self.app / self.ffi.DYLIB).write_bytes(b"old library")
        plan = self.plan("--app", str(self.app))
        self.assertIn("ffi", plan["parts"], plan)
        self.assertEqual(plan["ffi"]["source"], REPIN_TO)
        self.assertEqual(plan["ffi"]["release"], f"cmux-app-ffi-{REPIN_TO}")
        self.assertEqual(plan["ffi"]["app_pin_source"], REPIN_FROM)
        self.assertEqual(plan["ffi"]["via"], "pin")
        # The pin file and Package.swift's checksum line are the ffi part's change, not Swift that needs an app.
        self.assertEqual(plan["left"], {}, plan)
        self.assertEqual(self.plan("--base", self.base)["ffi"]["source"], REPIN_TO)

    def test_an_app_linking_the_ffi_statically_still_needs_an_app_for_a_new_pin(self):
        plan = self.plan("--app", str(self.app))
        self.assertNotIn("ffi", plan["parts"])
        self.assertTrue(any("links the app FFI statically" in note for note in plan["notes"]), plan["notes"])

    def test_pin_packaging_is_only_the_pin(self):
        self.assertEqual(self.ffi.pin_packaging(ROOT, self.base, REPIN),
                         {self.ffi.PIN_FILE, self.ffi.PACKAGE_SWIFT})
        # Package.swift with more than the checksum line changed is Swift again.
        self.assertNotIn(self.ffi.PACKAGE_SWIFT, self.ffi.pin_packaging(ROOT, REPIN_FROM, REPIN))


def load_hot(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def macho(identifier, team=None, adhoc=False, pad=0):
    """A minimal arm64 Mach-O whose code signature names IDENTIFIER and TEAM (ad-hoc: no team, CS_ADHOC),
    the signature PAD bytes in, as a large binary's sits at its end."""
    import struct
    strings = identifier.encode() + b"\0"
    team_at = 0
    if team:
        team_at = 52 + len(strings)
        strings += team.encode() + b"\0"
    cd = struct.pack(">IIIIIIIIIBBBBII", 0xFADE0C02, 52 + len(strings), 0x20400, 0x2 if adhoc else 0,
                     0, 52, 0, 0, 0, 32, 2, 0, 12, 0, 0) + struct.pack(">I", team_at) + strings
    blob = struct.pack(">III", 0xFADE0CC0, 20 + len(cd), 1) + struct.pack(">II", 0, 20) + cd
    offset = 32 + 16 + pad
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0)
    return header + struct.pack("<IIII", 0x1D, 16, offset, len(blob)) + b"\0" * pad + blob


TEAM = "ABCDE12345"


class CodeSignatures(unittest.TestCase):
    """hot-apply reads a Mach-O's Team ID itself (no codesign on Linux): ad-hoc and unsigned are no team."""

    def setUp(self):
        self.hot = load_hot("hot_apply_sig_under_test")
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-webabi-sig-test-"))

    def tearDown(self):
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def team(self, body):
        (self.tmp / "bin").write_bytes(body)
        return self.hot.file_team(self.tmp / "bin"), self.hot.url_team((self.tmp / "bin").as_uri())

    def test_a_team_signature_names_its_team_by_file_and_by_url(self):
        self.assertEqual(self.team(macho("com.cmuxterm.app.nightly", TEAM, pad=300_000)), (TEAM, TEAM))

    def test_ad_hoc_and_unsigned_have_no_team(self):
        # CI's tree builds: `cmux_tui-8cc59fe5f00f9770`, ad-hoc (the 2026-11-15 run's 3a81a2e8 tree key).
        self.assertEqual(self.team(macho("cmux_tui-8cc59fe5f00f9770", adhoc=True)), (None, None))
        self.assertEqual(self.team(b"#!/bin/sh\necho new\n"), (None, None))

    def test_a_fat_file_is_read_by_its_first_slice(self):
        import struct
        slice_ = macho("cmux", TEAM)
        fat = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(">IIIII", 0x0100000C, 0, 4096, len(slice_), 12)
        self.assertEqual(self.team(fat + b"\0" * (4096 - len(fat)) + slice_)[0], TEAM)


class RefusedOverlayRollback(unittest.TestCase):
    """Rollback puts back what the app served: an overlay it refused (another web ABI) was its bundled pages."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hot-apply-webabi-rollback-test-"))
        self.overlay = self.tmp / "overlay"
        self.web_dev = self.tmp / "config/web-dev.json"
        self.web_dev.parent.mkdir(parents=True)
        self.saved_env = dict(os.environ)
        os.environ.update(CMUX_HOT_APPLY_STATE_DIR=str(self.tmp / "state"),
                          CMUX_NEXT_CONFIG_FILE=str(self.tmp / "config/cmux-next.json"),
                          CMUX_WEB_OVERLAY_DIR=str(self.overlay))
        self.hot = load_hot("hot_apply_webabi_overlay_under_test")
        self.live = self.hot.load("live_apply_loop", "live-apply.py")
        self.app = self.tmp / "cmux NIGHTLY.app"
        abi = self.app / self.hot.APP_ABI
        abi.parent.mkdir(parents=True)
        abi.write_text('{"abi": 7}\n')

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved_env)
        subprocess.run(["rm", "-rf", str(self.tmp)])

    def install(self, commit, abi, **web_dev):
        gen = self.overlay / f".gen-{commit[:8]}"
        (gen / "pages/settings").mkdir(parents=True)
        (gen / "pages/settings/index.html").write_text(commit)
        link = self.overlay / "pages"
        if link.is_symlink():
            link.unlink()
        link.symlink_to(f".gen-{commit[:8]}/pages")
        (self.overlay / "manifest.json").write_text(json.dumps({"commit": commit, "abi": abi}))
        self.web_dev.write_text(json.dumps({"overlay": str(self.overlay), "enabled": True, **web_dev}))

    def apply_then_put_back(self, prior_abi, check_at_apply=True, **web_dev):
        self.install("01192304" + "0" * 32, prior_abi, **web_dev)
        snap = self.hot.overlay_snapshot(self.live)
        if check_at_apply:
            snap = self.hot.in_effect(snap, 7, self.overlay)
        self.install("20a18cea" + "0" * 32, 7, **web_dev)  # the apply's overlay
        return snap, self.hot.put_back(self.app, {"web": snap}, None, self.tmp / "state", self.live)["web"]

    def test_a_refused_prior_overlay_rolls_back_to_the_bundled_pages(self):
        snap, out = self.apply_then_put_back(4)
        self.assertEqual(snap["refused"]["abi"], 4)  # the undo record says so from the apply on
        self.assertTrue(out["ok"])
        self.assertEqual(out["in_effect"], "the app's bundled pages")
        self.assertEqual(out["dropped_refused_pointer"]["commit"], "01192304" + "0" * 32)
        self.assertFalse(self.web_dev.exists())  # nothing else was in it

    def test_an_undo_written_before_the_check_rolls_back_to_the_bundled_pages_too(self):
        _, out = self.apply_then_put_back(4, check_at_apply=False)
        self.assertEqual(out["in_effect"], "the app's bundled pages")
        self.assertFalse(self.web_dev.exists())

    def test_the_dev_server_entry_stays_when_the_pointer_goes(self):
        _, out = self.apply_then_put_back(4, server="http://127.0.0.1:4200/", token="t" * 48)
        kept = json.loads(self.web_dev.read_text())
        self.assertNotIn("overlay", kept)
        self.assertEqual(kept["server"], "http://127.0.0.1:4200/")

    def test_a_served_prior_overlay_comes_back(self):
        snap, out = self.apply_then_put_back(7)
        self.assertNotIn("refused", snap)
        self.assertEqual(out["commit"], "01192304" + "0" * 32)
        self.assertEqual(json.loads(self.web_dev.read_text())["overlay"], str(self.overlay))
        self.assertEqual((self.overlay / "pages/settings/index.html").read_text(), "01192304" + "0" * 32)

    def drop(self):
        done = subprocess.run([sys.executable, str(SCRIPT), "drop-refused-overlay", "--app", str(self.app)],
                              capture_output=True, text=True, env=os.environ)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout.strip().splitlines()[-1])

    def test_drop_refused_overlay_cleans_an_install_left_pointing_at_one(self):
        self.install("01192304" + "0" * 32, 4, gallery="http://127.0.0.1:4178/")
        receipt = self.drop()
        self.assertEqual(receipt["dropped"]["abi"], 4)
        self.assertEqual(json.loads(self.web_dev.read_text()), {"enabled": True, "gallery": "http://127.0.0.1:4178/"})
        self.assertIsNone(self.drop()["dropped"])  # once is enough
        self.assertFalse((self.tmp / "state/last.json").exists())  # `rollback` is not moved by it

    def test_drop_refused_overlay_leaves_a_served_pointer(self):
        self.install("20a18cea" + "0" * 32, 7)
        self.assertIsNone(self.drop()["dropped"])
        self.assertIn("overlay", json.loads(self.web_dev.read_text()))


if __name__ == "__main__":
    unittest.main()
