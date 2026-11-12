"""scripts/cmux-next/cargo-locks.py: every tracked Cargo.lock is judged whatever changed, and `fix` rewrites only locks.

2026-11-10: eb4f3eb1d94 changed cmux-tui/Cargo.toml and updated cmux-tui/Cargo.lock only; the cmux-app-ffi workspace
(its own lock, cmux-tui's crates by path) went stale and every feat-cmux-next pull request went red.
"""
from __future__ import annotations

import importlib.util
import io
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from pathlib import Path

# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
_git_fixture_spec = importlib.util.spec_from_file_location(
    "git_fixture_env", os.path.join(os.path.dirname(os.path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = importlib.util.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)

SOURCE = Path(__file__).resolve().parents[1]
SCRIPT = SOURCE / "scripts/cmux-next/cargo-locks.py"


@unittest.skipIf(shutil.which("cargo") is None, "no cargo on this host")
class CargoLocksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        git_fixture_env.init_repo(self.repo, env=self.env)
        # Two workspaces: core (crates a and b) and ffi, its own workspace, which builds a by path.
        self.write("core/Cargo.toml", '[workspace]\nmembers = ["a", "b"]\nresolver = "2"\n')
        for name in ("a", "b"):
            self.write(f"core/{name}/Cargo.toml", f'[package]\nname = "{name}"\nversion = "0.1.0"\nedition = "2021"\n')
            self.write(f"core/{name}/src/lib.rs", "")
        self.write("ffi/Cargo.toml", '[package]\nname = "ffi"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\na = { path = "../core/a" }\n\n[workspace]\n')
        self.write("ffi/src/lib.rs", "")
        for root in ("core", "ffi"):
            self.cargo(root, "generate-lockfile", "--offline")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True,
                              text=True).stdout

    def cargo(self, root, *args):
        done = subprocess.run(["cargo", *args], cwd=self.repo / root, env=self.env, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def locks(self, mode):
        return subprocess.run([sys.executable, "-I", str(SCRIPT), mode, "--repo", str(self.repo)], env=self.env,
                              capture_output=True, text=True)

    def break_ffi(self):
        """a gains a dependency; only core's lock follows (what eb4f3eb1d94 did)."""
        self.write("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\nb = { path = "../b" }\n')
        self.cargo("core", "metadata", "--offline", "--format-version", "1")
        self.git("add", "-A")
        self.git("commit", "-qm", "a uses b")

    def test_matching_locks_pass(self):
        result = self.locks("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("2 workspaces, 0 stale", result.stderr)

    def test_a_manifest_change_in_one_workspace_fails_the_other_workspaces_lock(self):
        self.break_ffi()

        result = self.locks("check")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("stale: ffi/Cargo.lock: does not match its manifests", result.stdout)
        self.assertNotIn("core/Cargo.lock", result.stdout)

    def test_fix_rewrites_only_the_stale_lock_and_then_the_check_passes(self):
        self.break_ffi()

        fixed = self.locks("fix")

        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertIn("fixed: ffi/Cargo.lock", fixed.stdout)
        self.assertEqual(self.git("status", "--porcelain").split(), ["M", "ffi/Cargo.lock"])
        self.assertEqual(self.locks("check").returncode, 0)

    def test_fix_with_nothing_stale_changes_nothing(self):
        fixed = self.locks("fix")

        self.assertEqual(fixed.returncode, 0, fixed.stdout + fixed.stderr)
        self.assertEqual(fixed.stdout.strip(), "")
        self.assertEqual(self.git("status", "--porcelain"), "")



class StaleSpellingTests(unittest.TestCase):
    """Both of cargo's stale-lock spellings under --locked are stale, never unchecked (router review F1 on #40921)."""

    def test_judge_reads_both_spellings(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("cargo_locks", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        spellings = (
            "error: cannot update the lock file /w/Cargo.lock because --locked was passed to prevent this",
            "error: the lock file /w/Cargo.lock needs to be updated but --locked was passed to prevent this",
            "error: cannot create the lock file /w/Cargo.lock because --locked was passed to prevent this",
        )
        for message in spellings:
            with self.subTest(message=message):
                module.cargo = lambda args, cwd, env, message=message, **_: (101, message + "\n")
                self.assertEqual(module.judge(Path("/w"), "", {}), ("stale", ""))
        module.cargo = lambda args, cwd, env, **_: (101, "error: failed to get `x` as a dependency\n")
        self.assertEqual(module.judge(Path("/w"), "", {})[0], "unchecked")


class CiIsStrictTests(unittest.TestCase):
    """CI is the backstop: its lock check runs with --strict, so an unchecked workspace is red (router review F1 on
    #41009: a pinned toolchain or a registry error left a workspace unchecked and the step passed)."""

    def test_rust_workspaces_runs_the_check_strict(self):
        workflow = (SOURCE / ".github/workflows/rust-workspaces.yml").read_text()
        runs = [line for line in workflow.splitlines() if "cargo-locks.py check" in line]
        self.assertTrue(runs)
        for line in runs:
            self.assertIn("--strict", line)


STALE_MESSAGE = "error: cannot update the lock file {lock} because --locked was passed to prevent this\n"
OFFLINE_MISS = "error: no matching package named `serde` found\nattempting to make an HTTP request, but --offline was specified\n"


class BusyRunnerTests(unittest.TestCase):
    """A busy or cold runner makes the lock check slower, never red (cmux#41586, run 43124136001, 2026-11-12).

    On a 2-vCPU runner with an empty cargo home, the check ran eight `cargo update --locked` resolves at once; cargo
    holds its package cache lock for a whole resolve, so they queued on it and each one's 120 s limit counted the
    queue. Five workspaces timed out, 0 were stale, and --strict made the step red on a pull request that changes no
    Rust. The fake cargo here (cargo-locks.py's `cargo` function) needs no toolchain: each workspace answers ok,
    stale, slow (times out under the first limit, resolves under a longer one) or hang (always times out).
    """

    def setUp(self):
        spec = importlib.util.spec_from_file_location("cargo_locks_busy", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-busy-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        git_fixture_env.init_repo(self.repo, env=self.env)
        # core (crate a), ffi (its own workspace, a by path) and other (no path to either).
        self.write("core/Cargo.toml", '[workspace]\nmembers = ["a"]\nresolver = "2"\n')
        self.write("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n')
        self.write("ffi/Cargo.toml", '[package]\nname = "ffi"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[lib]\npath = "src/lib.rs"\n\n[dependencies]\na = { path = "../core/a" }\n\n[workspace]\n')
        self.write("other/Cargo.toml", '[package]\nname = "other"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n')
        for root in ("core", "ffi", "other"):
            self.write(f"{root}/Cargo.lock", "version = 4\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.behaviour = {"core": "ok", "ffi": "ok", "other": "ok"}
        self.calls: list[tuple[str, bool, float]] = []
        self.running = 0
        self.most_running = 0
        self.lock = threading.Lock()
        self.module.cargo = self.fake_cargo
        patcher = unittest.mock.patch.object(
            self.module.shutil, "which", lambda name: "/fake/cargo" if name == "cargo" else None)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True,
                              text=True).stdout

    def commit(self, relative, text):
        self.write(relative, text)
        self.git("add", "-A")
        self.git("commit", "-qm", f"change {relative}")

    def fake_cargo(self, args, cwd, env, timeout=None, **_):
        limit = 120 if timeout is None else timeout
        root = Path(cwd).relative_to(self.repo).as_posix()
        offline = "--offline" in args
        with self.lock:
            self.calls.append((root, offline, limit))
            if not offline:
                self.running += 1
                self.most_running = max(self.most_running, self.running)
        try:
            if not offline:
                time.sleep(0.02)
            kind = self.behaviour[root]
            if kind == "stale":
                return 101, STALE_MESSAGE.format(lock=Path(cwd) / "Cargo.lock")
            if kind == "ok":
                return 0, ""
            if offline:
                return 101, OFFLINE_MISS
            if kind == "slow" and limit > 120:
                return 0, ""
            return 124, f"timed out after {limit}s"
        finally:
            if not offline:
                with self.lock:
                    self.running -= 1

    def run_check(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.object(sys, "stdout", out), unittest.mock.patch.object(sys, "stderr", err):
            code = self.module.main(["check", "--repo", str(self.repo), "--strict", *extra])
        return code, out.getvalue() + err.getvalue()

    def network_limits(self, root):
        return [limit for name, offline, limit in self.calls if name == root and not offline]

    def test_a_stale_lock_still_fails(self):
        self.behaviour["ffi"] = "stale"
        self.behaviour["other"] = "hang"

        code, output = self.run_check()

        self.assertEqual(code, 1, output)
        self.assertIn("stale: ffi/Cargo.lock", output)

    def test_a_timed_out_workspace_the_change_does_not_touch_warns(self):
        self.commit("README.md", "docs only\n")
        self.behaviour["other"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 0, output)
        self.assertIn("other", output)
        self.assertRegex(output, r"warning:.*other")
        # Retried once with a longer limit before it is let through.
        limits = self.network_limits("other")
        self.assertEqual(len(limits), 2, self.calls)
        self.assertGreater(limits[1], limits[0])

    def test_a_timed_out_workspace_the_change_touches_fails(self):
        self.commit("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.2.0"\nedition = "2021"\n')
        self.behaviour["ffi"] = "hang"  # ffi reaches core/a by path

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: ffi", output)
        self.assertEqual(len(self.network_limits("ffi")), 2, self.calls)

    def test_a_slow_workspace_the_change_touches_is_retried_to_completion(self):
        self.commit("other/Cargo.toml",
                    '[package]\nname = "other"\nversion = "0.2.0"\nedition = "2021"\n\n[workspace]\n')
        self.behaviour["other"] = "slow"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 0, output)
        self.assertNotIn("unchecked:", output)
        self.assertEqual(len(self.network_limits("other")), 2, self.calls)

    def test_with_no_base_every_timed_out_workspace_still_fails(self):
        self.behaviour["other"] = "hang"

        code, output = self.run_check()

        self.assertEqual(code, 2, output)

    def test_network_resolves_run_one_at_a_time(self):
        """cargo's package cache lock serializes resolves anyway; run in parallel, the queue eats each limit."""
        self.behaviour = {"core": "slow", "ffi": "slow", "other": "slow"}

        code, output = self.run_check("--jobs", "8")

        self.assertEqual(code, 0, output)
        self.assertEqual(self.most_running, 1, self.calls)


class CiPassesTheBaseTests(unittest.TestCase):
    """The CI step names the change's base, so a timeout in a workspace the change does not touch only warns."""

    def test_rust_workspaces_passes_the_base_to_the_lock_check(self):
        workflow = (SOURCE / ".github/workflows/rust-workspaces.yml").read_text()
        runs = [line for line in workflow.splitlines() if "cargo-locks.py check" in line]
        self.assertTrue(runs)
        for line in runs:
            self.assertIn("--base", line)
        self.assertLess(workflow.index("id: base"), workflow.index("cargo-locks.py check"))


if __name__ == "__main__":
    unittest.main()
