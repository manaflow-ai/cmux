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
ROOTS = ("core", "core/inner", "core/vendored", "ffi", "other")
OFFLINE_MISS = "error: no matching package named `serde` found\nattempting to make an HTTP request, but --offline was specified\n"


class BusyFixture(unittest.TestCase):
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
        # Inside core's tree but not core's: inner has a [workspace] of its own (as cmux-tui/crates/cmux-app-ffi
        # does), and vendored is in core's `exclude` (as cmux-tui/crates/cmux-rd-host is). Each has its own lock.
        self.write("core/Cargo.toml", '[workspace]\nmembers = ["a"]\nexclude = ["vendored"]\nresolver = "2"\n')
        self.write("core/inner/Cargo.toml",
                   '[package]\nname = "inner"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n')
        self.write("core/vendored/Cargo.toml", '[package]\nname = "vendored"\nversion = "0.1.0"\nedition = "2021"\n')
        for root in ROOTS:
            self.write(f"{root}/Cargo.lock", "version = 4\n")
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.behaviour = dict.fromkeys(ROOTS, "ok")
        # Seconds the fake resolves take: a hung one uses up its whole limit. The check reads its clock through
        # cargo-locks.py's `clock`, so no test waits for real.
        self.now = 0.0
        self.module.clock = lambda: self.now
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
            if kind == "stale-hang":
                # Stale under --locked; the rewrite `fix` runs (no --locked) hangs for its whole limit.
                if "--locked" in args:
                    return 101, STALE_MESSAGE.format(lock=Path(cwd) / "Cargo.lock")
                with self.lock:
                    self.now += limit
                return 124, f"timed out after {limit:g}s"
            if kind == "stale":
                return 101, STALE_MESSAGE.format(lock=Path(cwd) / "Cargo.lock")
            if kind == "ok":
                return 0, ""
            if offline:
                return 101, OFFLINE_MISS
            if kind == "slow" and limit > 120:
                with self.lock:
                    self.now += 121
                return 0, ""
            with self.lock:
                self.now += limit
            return 124, f"timed out after {limit:g}s"
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



class BusyRunnerTests(BusyFixture):
    """The busy-runner cases (BusyFixture's docstring)."""

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
        self.behaviour = dict.fromkeys(ROOTS, "slow")

        code, output = self.run_check("--jobs", "8", "--base", self.base)

        self.assertEqual(code, 0, output)
        self.assertEqual(self.most_running, 1, self.calls)


class NestedWorkspaceTests(BusyFixture):
    """A workspace's tree is not all its own: a Cargo.toml below it with a [workspace] of its own, or in its
    `exclude`, is another workspace (cmux#41742 review F1: a change only in cmux-tui/crates/cmux-app-ffi counted as
    touching cmux-tui, so cmux-tui's timeout failed CI instead of warning)."""

    def test_a_change_in_a_nested_workspace_does_not_touch_the_outer_one(self):
        self.commit("core/inner/Cargo.toml",
                    '[package]\nname = "inner"\nversion = "0.2.0"\nedition = "2021"\n\n[workspace]\n')
        self.behaviour["core"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 0, output)
        self.assertRegex(output, r"warning:.*cargo-locks: core timed out")

    def test_a_change_in_an_excluded_package_does_not_touch_the_workspace_that_excludes_it(self):
        self.commit("core/vendored/Cargo.toml",
                    '[package]\nname = "vendored"\nversion = "0.2.0"\nedition = "2021"\n')
        self.behaviour["core"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 0, output)
        self.assertRegex(output, r"warning:.*cargo-locks: core timed out")

    def test_the_nested_workspace_itself_is_still_touched(self):
        self.commit("core/inner/Cargo.toml",
                    '[package]\nname = "inner"\nversion = "0.2.0"\nedition = "2021"\n\n[workspace]\n')
        self.behaviour["core/inner"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: core/inner", output)

    def test_a_change_in_the_outer_workspace_still_touches_it(self):
        self.commit("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.2.0"\nedition = "2021"\n')
        self.behaviour["core"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: core", output)

    def test_a_change_in_a_member_beside_the_root_touches_it(self):
        """A member outside the root's tree with no path dependency on it (cmux-app-ffi's workspace takes in
        ../cmux-rd-ffi and its siblings) shares the root's lock."""
        self.write("ffi/Cargo.toml", '[package]\nname = "ffi"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[lib]\npath = "src/lib.rs"\n\n[dependencies]\na = { path = "../core/a" }\n\n'
                   '[workspace]\nmembers = ["../ffi-side"]\n')
        self.write("ffi-side/Cargo.toml", '[package]\nname = "side"\nversion = "0.1.0"\nedition = "2021"\n'
                   'workspace = "../ffi"\n')
        self.git("add", "-A")
        self.git("commit", "-qm", "sibling member")
        base = self.git("rev-parse", "HEAD").strip()
        self.commit("ffi-side/Cargo.toml", '[package]\nname = "side"\nversion = "0.2.0"\nedition = "2021"\n'
                    'workspace = "../ffi"\n')
        self.behaviour["ffi"] = "hang"

        code, output = self.run_check("--base", base)

        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: ffi", output)

    def test_a_nested_workspace_reached_by_path_is_still_followed(self):
        """Another workspace that uses a package inside the nested one by path is touched by a change there."""
        self.commit("other/Cargo.toml", '[package]\nname = "other"\nversion = "0.1.0"\nedition = "2021"\n\n'
                    '[dependencies]\ninner = { path = "../core/inner" }\n\n[workspace]\n')
        self.base = self.git("rev-parse", "HEAD").strip()
        self.commit("core/inner/Cargo.toml",
                    '[package]\nname = "inner"\nversion = "0.2.0"\nedition = "2021"\n\n[workspace]\n')
        self.behaviour["other"] = "hang"

        code, output = self.run_check("--base", self.base)

        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: other", output)


class InheritedPathTests(BusyFixture):
    """A `{ workspace = true }` dependency is the path its workspace's [workspace.dependencies] names: a change there
    touches every workspace that reaches it (cmux#41767 review: cmux-next-ios/rust reaches cmux-tui crates that way,
    so a change to a shared crate left it "untouched" and its timeout warned instead of failing). Here `other` plays
    cmux-next-ios/rust and `core` cmux-tui; `other` hangs, and every row must fail."""

    CORE = '[workspace]\nmembers = ["a", "b"]\nexclude = ["vendored"]\nresolver = "2"\n\n[workspace.dependencies]\n'

    def reaches(self, other_dependencies: str, core_dependencies: str = "", a_dependencies: str = "",
                extra: dict[str, str] | None = None) -> None:
        """Commits the shape as the new base: OTHER's [workspace.dependencies], CORE's, and crate a's."""
        self.write("other/Cargo.toml", '[package]\nname = "other"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\na = { workspace = true }\n\n[workspace]\n\n[workspace.dependencies]\n'
                   + other_dependencies)
        self.write("core/Cargo.toml", self.CORE + core_dependencies)
        self.write("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\n' + a_dependencies)
        for relative, text in (extra or {}).items():
            self.write(relative, text)
        self.git("add", "-A")
        self.git("commit", "-qm", "shape")
        self.base = self.git("rev-parse", "HEAD").strip()
        self.behaviour["other"] = "hang"

    def assert_fails(self, changed: str, text: str) -> None:
        self.commit(changed, text)
        code, output = self.run_check("--base", self.base)
        self.assertEqual(code, 2, output)
        self.assertIn("unchecked: other", output)

    def test_a_change_to_a_shared_crate_it_inherits_touches_it(self):
        """The review's row: a cmux-tui crate changes and cmux-next-ios/rust, which names it in its
        [workspace.dependencies], times out."""
        self.reaches('a = { path = "../core/a" }\n')
        self.assert_fails("core/a/Cargo.toml", '[package]\nname = "a"\nversion = "0.2.0"\nedition = "2021"\n')

    def test_a_path_the_shared_crate_inherits_from_its_own_workspace_touches_it(self):
        """Two hops: a inherits `shared` from core's [workspace.dependencies], a path outside core's tree."""
        self.reaches('a = { path = "../core/a" }\n', core_dependencies='shared = { path = "../shared" }\n',
                     a_dependencies="shared = { workspace = true }\n",
                     extra={"shared/Cargo.toml": '[package]\nname = "shared"\nversion = "0.1.0"\nedition = "2021"\n'})
        self.assert_fails("shared/Cargo.toml", '[package]\nname = "shared"\nversion = "0.2.0"\nedition = "2021"\n')

    def test_an_inherited_path_into_a_nested_workspace_touches_it(self):
        """a inherits `inner` from core, and inner has a [workspace] of its own inside core's tree."""
        self.reaches('a = { path = "../core/a" }\n', core_dependencies='inner = { path = "inner" }\n',
                     a_dependencies="inner = { workspace = true }\n")
        self.assert_fails("core/inner/Cargo.toml",
                          '[package]\nname = "inner"\nversion = "0.2.0"\nedition = "2021"\n\n[workspace]\n')

    def test_a_sibling_member_the_shared_crate_uses_is_followed_out_of_the_tree(self):
        """a uses its sibling b by path, and b uses ext outside core's tree: b is in core's tree but still read."""
        self.reaches('a = { path = "../core/a" }\n', a_dependencies='b = { path = "../b" }\n',
                     extra={"core/b/Cargo.toml": '[package]\nname = "b"\nversion = "0.1.0"\nedition = "2021"\n\n'
                            '[dependencies]\next = { path = "../../ext" }\n',
                            "ext/Cargo.toml": '[package]\nname = "ext"\nversion = "0.1.0"\nedition = "2021"\n'})
        self.assert_fails("ext/Cargo.toml", '[package]\nname = "ext"\nversion = "0.2.0"\nedition = "2021"\n')

    def test_a_patched_crates_inherited_path_touches_the_workspace_that_patches_it(self):
        """other patches pz by path (as cmux-next-ios/rust patches smoltcp), and pz inherits q from its own
        [workspace.dependencies]."""
        self.reaches('a = { path = "../core/a" }\n\n[patch.crates-io]\npz = { path = "../pz" }\n', extra={
            "pz/Cargo.toml": '[package]\nname = "pz"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n\n'
                             '[workspace.dependencies]\nq = { path = "../q" }\n\n[dependencies]\nq = { workspace = true }\n',
            "q/Cargo.toml": '[package]\nname = "q"\nversion = "0.1.0"\nedition = "2021"\n'})
        self.assert_fails("q/Cargo.toml", '[package]\nname = "q"\nversion = "0.2.0"\nedition = "2021"\n')

    def test_an_inherited_dependency_with_no_path_reaches_nothing(self):
        """A registry dependency inherited from core is not a path: a change elsewhere still only warns."""
        self.reaches('a = { path = "../core/a" }\n', core_dependencies='serde = "1"\n',
                     a_dependencies="serde = { workspace = true }\n",
                     extra={"shared/Cargo.toml": '[package]\nname = "shared"\nversion = "0.1.0"\nedition = "2021"\n'})
        self.commit("shared/Cargo.toml", '[package]\nname = "shared"\nversion = "0.2.0"\nedition = "2021"\n')
        code, output = self.run_check("--base", self.base)
        self.assertEqual(code, 0, output)
        self.assertRegex(output, r"warning:.*cargo-locks: other timed out")


class FixSharesTheDeadlineTests(BusyFixture):
    """--deadline bounds the whole run, `fix`'s rewrites and their re-checks included (cmux#41767 review F3: the
    deadline stopped at check(), and `fix --deadline 1.1` ran 1.44 s)."""

    def run_fix(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.object(sys, "stdout", out), unittest.mock.patch.object(sys, "stderr", err):
            code = self.module.main(["fix", "--repo", str(self.repo), *extra])
        return code, out.getvalue() + err.getvalue()

    def test_a_hanging_rewrite_stops_at_the_deadline(self):
        self.behaviour["core"] = "stale-hang"

        code, output = self.run_fix("--deadline", "150")

        self.assertEqual(code, 0, output)
        self.assertLessEqual(self.now, 150, f"fix ran {self.now:g}s past a 150s deadline: {self.calls}")
        self.assertIn("left: core/Cargo.lock", output)

    def test_no_base_fix_keeps_the_default_deadline(self):
        """The base autofix runs `fix` with no base and no --deadline: NO_BASE_DEADLINE bounds it too."""
        self.behaviour["core"] = "stale-hang"
        self.behaviour["ffi"] = "stale-hang"

        code, output = self.run_fix()

        self.assertEqual(code, 0, output)
        self.assertLessEqual(self.now, self.module.NO_BASE_DEADLINE, f"fix ran {self.now:g}s: {self.calls}")


class CargoStopsItsWholeGroupTests(unittest.TestCase):
    """cargo() on a timeout leaves nothing of cargo's process group running (cmux#41767 review F1: after SIGTERM the
    cleanup stopped once cargo exited, so a child that ignored SIGTERM and closed stderr survived). Real processes:
    a fake `cargo` on PATH whose child does exactly that."""

    STUBBORN = (
        "import os, signal, sys, time\n"
        "path = os.environ['STUBBORN_PID']\n"
        "if os.fork() == 0:\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "    with open(path + '.tmp', 'w') as out:\n"
        "        out.write(str(os.getpid()))\n"
        "    os.replace(path + '.tmp', path)\n"
        "    for fd in (0, 1, 2):\n"
        "        os.close(fd)\n"
        "    time.sleep(60)\n"
        "    os._exit(0)\n"
        "while not os.path.exists(path):\n"
        "    time.sleep(0.01)\n"
        "time.sleep(60)\n")

    def setUp(self):
        spec = importlib.util.spec_from_file_location("cargo_locks_group", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-group-")
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)
        (self.tmp / "bin").mkdir()
        cargo = self.tmp / "bin" / "cargo"
        cargo.write_text(f"#!{sys.executable}\n" + self.STUBBORN)
        cargo.chmod(0o755)
        self.pid_file = self.tmp / "child.pid"
        self.addCleanup(self.stop_child)

    def child(self) -> int:
        return int(self.pid_file.read_text()) if self.pid_file.exists() else 0

    def stop_child(self):
        if self.child():
            try:
                os.kill(self.child(), 9)  # only the child this test's fake cargo started
            except (ProcessLookupError, PermissionError):
                pass

    def alive(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        try:
            return Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
        except (OSError, IndexError):
            return True

    def test_a_child_that_ignores_sigterm_and_closes_stderr_is_killed(self):
        env = {**os.environ, "PATH": f"{self.tmp / 'bin'}:{os.environ['PATH']}", "STUBBORN_PID": str(self.pid_file)}

        code, _ = self.module.cargo(["update", "--workspace", "--locked"], self.tmp, env, timeout=1)

        self.assertEqual(code, 124)
        self.assertTrue(self.child(), "the fake cargo's child never started")
        self.assertFalse(self.alive(self.child()), "cargo's child ignored SIGTERM and outlived the timeout")


def gate_lock_check_timeout() -> float:
    """The pre-push gate's outer limit on the lock check, read from prepush-gate.py's cargo_lock_drift: the
    `timeout=` of its run(...) call, a number or a module-level name for one."""
    import ast
    tree = ast.parse((SOURCE / "scripts/cmux-next/prepush-gate.py").read_text())
    constants = {target.id: node.value.value for node in tree.body if isinstance(node, ast.Assign)
                 and isinstance(node.value, ast.Constant) for target in node.targets if isinstance(target, ast.Name)}
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "cargo_lock_drift")
    for node in ast.walk(function):
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "run":
            for keyword in node.keywords:
                if keyword.arg == "timeout":
                    value = keyword.value
                    return float(value.value if isinstance(value, ast.Constant) else constants[value.id])
    raise AssertionError("cargo_lock_drift runs the lock check with no timeout")


class NoBaseBudgetTests(BusyFixture):
    """With no --base the check still ends inside its callers' outer limits (cmux#41742 review F2: the budget was
    off with no base, so serial network resolves could run past the pre-push gate's own limit on the check, and the
    gate then skipped the lock check entirely)."""

    def lenient(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.object(sys, "stdout", out), unittest.mock.patch.object(sys, "stderr", err):
            code = self.module.main(["check", "--repo", str(self.repo), *extra])
        return code, out.getvalue() + err.getvalue()

    def test_slow_resolves_with_no_base_finish_inside_the_gates_limit(self):
        """As the gate runs it: no --base, no --strict, and every workspace's network resolve hangs."""
        self.behaviour = dict.fromkeys(ROOTS, "hang")

        code, output = self.lenient()

        self.assertEqual(code, 0, output)
        self.assertLess(self.now, gate_lock_check_timeout(), (output, self.calls))
        self.assertIn("unchecked: other", output)

    def test_the_deadline_the_gate_passes_is_kept(self):
        self.behaviour = dict.fromkeys(ROOTS, "hang")

        code, output = self.lenient("--deadline", "150")

        self.assertEqual(code, 0, output)
        self.assertLessEqual(self.now, 150, (output, self.calls))

    def test_strict_with_no_base_stays_inside_the_budget_and_fails(self):
        self.behaviour = dict.fromkeys(ROOTS, "hang")

        code, output = self.run_check()

        self.assertEqual(code, 2, output)
        self.assertLess(self.now, gate_lock_check_timeout(), (output, self.calls))

    def test_quick_resolves_with_no_base_are_all_judged(self):
        self.behaviour["ffi"] = "stale"

        code, output = self.lenient()

        self.assertEqual(code, 1, output)
        self.assertIn("stale: ffi/Cargo.lock", output)
        self.assertNotIn("unchecked:", output)

    def test_the_gate_passes_a_deadline_below_its_own_limit(self):
        import ast
        tree = ast.parse((SOURCE / "scripts/cmux-next/prepush-gate.py").read_text())
        function = next(node for node in tree.body
                        if isinstance(node, ast.FunctionDef) and node.name == "cargo_lock_drift")
        source = ast.unparse(function)
        self.assertIn("'--deadline'", source)


class CiPassesTheBaseTests(unittest.TestCase):
    """The CI step names the change's base, so a timeout in a workspace the change does not touch only warns."""

    def test_rust_workspaces_passes_the_base_to_the_lock_check(self):
        workflow = (SOURCE / ".github/workflows/rust-workspaces.yml").read_text()
        runs = [line for line in workflow.splitlines() if "cargo-locks.py check" in line]
        self.assertTrue(runs)
        for line in runs:
            self.assertIn("--base", line)
        self.assertLess(workflow.index("id: base"), workflow.index("cargo-locks.py check"))


REGISTRY = "registry+https://github.com/rust-lang/crates.io-index"


def lock_text(own: tuple[str, str], *crates: tuple[str, str]) -> str:
    """A Cargo.lock with the workspace's own package OWN (no source) and registry CRATES."""
    blocks = [f'[[package]]\nname = "{own[0]}"\nversion = "{own[1]}"\n']
    blocks += [f'[[package]]\nname = "{name}"\nversion = "{version}"\nsource = "{REGISTRY}"\nchecksum = "00"\n'
               for name, version in crates]
    return "version = 4\n\n" + "\n".join(blocks)


class NewCratesTests(unittest.TestCase):
    """A Cargo.lock change adds no crate-version that no lock at the base has unless a Cargo.toml in the change
    asks for it (cmux#42155: a lock "alignment" said it added no crate-version and added seven). Git only."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cmux-cargo-locks-new-")
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.env = git_fixture_env.fixture_env({
            **os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "F", "GIT_AUTHOR_EMAIL": "f@e",
            "GIT_COMMITTER_NAME": "F", "GIT_COMMITTER_EMAIL": "f@e"})
        self.env.pop("PR_BODY", None)
        git_fixture_env.init_repo(self.repo, env=self.env)
        # one uses serde 1.0.1; two, its own workspace, already has serde 1.0.2.
        self.one_manifest = '[package]\nname = "one"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nserde = "1"\n'
        self.write("one/Cargo.toml", self.one_manifest)
        self.write("one/Cargo.lock", lock_text(("one", "0.1.0"), ("serde", "1.0.1")))
        self.write("two/Cargo.toml", '[package]\nname = "two"\nversion = "0.1.0"\nedition = "2021"\n\n'
                   '[dependencies]\nserde = "1"\n')
        self.write("two/Cargo.lock", lock_text(("two", "0.1.0"), ("serde", "1.0.2")))
        self.git("add", "-A")
        self.git("commit", "-qm", "base")
        self.base = self.git("rev-parse", "HEAD").strip()

    def write(self, relative, text):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True,
                              text=True).stdout

    def change(self, files, message="change"):
        for relative, text in files.items():
            self.write(relative, text)
        self.git("add", "-A")
        self.git("commit", "-qm", message)

    def new_crates(self, body=None):
        env = dict(self.env)
        if body is not None:
            env["PR_BODY"] = body
        return subprocess.run([sys.executable, "-I", str(SCRIPT), "new-crates", "--repo", str(self.repo),
                               "--base", self.base], env=env, capture_output=True, text=True)

    def test_a_lock_only_change_adding_a_crate_version_fails(self):
        self.change({"one/Cargo.lock": lock_text(("one", "0.1.0"), ("serde", "1.0.3"))})

        result = self.new_crates()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("new crate: serde 1.0.3 in one/Cargo.lock", result.stdout)
        self.assertIn("Cargo-Lock-New-Crates:", result.stderr)

    def test_a_lock_only_change_to_a_version_another_base_lock_has_passes(self):
        self.change({"one/Cargo.lock": lock_text(("one", "0.1.0"), ("serde", "1.0.2"))})

        result = self.new_crates()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")

    def test_a_dependency_added_in_a_manifest_with_its_lock_lines_passes(self):
        self.change({"one/Cargo.toml": self.one_manifest + 'log = "0.4"\n',
                     "one/Cargo.lock": lock_text(("one", "0.1.0"), ("log", "0.4.0"), ("serde", "1.0.1"))})

        result = self.new_crates()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_manifest_change_outside_the_dependency_tables_does_not_excuse_it(self):
        self.change({"one/Cargo.toml": self.one_manifest.replace('edition = "2021"\n',
                                                                 'edition = "2021"\ndescription = "x"\n'),
                     "one/Cargo.lock": lock_text(("one", "0.1.0"), ("serde", "1.0.3"))})

        result = self.new_crates()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_a_members_own_version_bump_is_not_a_new_crate(self):
        self.change({"one/Cargo.toml": self.one_manifest.replace('version = "0.1.0"', 'version = "0.2.0"'),
                     "one/Cargo.lock": lock_text(("one", "0.2.0"), ("serde", "1.0.1"))})

        self.assertEqual(self.new_crates().returncode, 0)

    def test_the_opt_out_line_in_the_pull_request_body_or_a_commit_passes(self):
        self.change({"one/Cargo.lock": lock_text(("one", "0.1.0"), ("serde", "1.0.3"))})

        self.assertEqual(self.new_crates(body="Fixes a CVE.\n\nCargo-Lock-New-Crates: serde 1.0.3 fixes X\n")
                         .returncode, 0)
        self.assertEqual(self.new_crates(body="Cargo-Lock-New-Crates:\n").returncode, 1)
        self.git("commit", "-q", "--allow-empty", "-m", "bump\n\nCargo-Lock-New-Crates: cargo update for X")
        self.assertEqual(self.new_crates().returncode, 0)

    def test_ci_runs_it_on_pull_requests_with_the_base_and_the_body(self):
        workflow = (SOURCE / ".github/workflows/rust-workspaces.yml").read_text()
        step = workflow[workflow.index("cargo-locks.py new-crates") - 600:workflow.index("cargo-locks.py new-crates")]
        self.assertIn("github.event_name == 'pull_request'", step)
        self.assertIn("PR_BODY: ${{ github.event.pull_request.body }}", step)
        self.assertLess(workflow.index("id: base"), workflow.index("cargo-locks.py new-crates --base \"$BASE_SHA\""))


if __name__ == "__main__":
    unittest.main()
