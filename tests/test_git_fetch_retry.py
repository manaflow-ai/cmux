#!/usr/bin/env python3
"""The warm nightly-next builder's git fetches are bounded and retried (scripts/ci/git_fetch_retry.py).

Run 40466772597 attempt 2 hung in `git fetch origin <sha>` for 62 min, then died
with "early EOF / fetch-pack: invalid index-pack output", killing the nightly.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import git_fetch_retry as retry  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "nightly.yml"
WARM_STEP = "Checkout build ref (warm nightly-next builder)"


class Run(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.sleeps: list[float] = []
        self.logs: list[str] = []

    def run_with(self, statuses: list[int], tries: int = 3, leave=None) -> tuple[int, list[list[str]]]:
        calls: list[list[str]] = []
        results = iter(statuses)

        def runner(command, timeout):
            calls.append(list(command))
            self.assertEqual(timeout, 600)
            if leave:
                leave()
            return next(results)

        status = retry.run(["git", "fetch", "origin", "abc"], tries=tries, timeout=600, repo=self.repo,
                           runner=runner, sleep=self.sleeps.append, log=self.logs.append)
        return status, calls

    def test_first_success_runs_once(self) -> None:
        status, calls = self.run_with([0])
        self.assertEqual((status, len(calls), self.sleeps), (0, 1, []))

    def test_every_try_sets_the_low_speed_abort(self) -> None:
        _, calls = self.run_with([128, 0])
        for call in calls:
            self.assertEqual(call[:5], ["git", "-c", f"http.lowSpeedLimit={retry.LOW_SPEED_BYTES}",
                                        "-c", f"http.lowSpeedTime={retry.LOW_SPEED_SECONDS}"])
            self.assertEqual(call[5:], ["fetch", "origin", "abc"])

    def test_failures_retry_with_backoff_then_give_up_with_the_last_status(self) -> None:
        status, calls = self.run_with([128, retry.TIMEOUT_EXIT, 128])
        self.assertEqual((status, len(calls)), (128, 3))
        self.assertEqual(self.sleeps, list(retry.BACKOFF_SECONDS))
        self.assertTrue(any("timed out" in line for line in self.logs))

    def test_a_retry_that_succeeds_returns_zero(self) -> None:
        status, calls = self.run_with([128, 0])
        self.assertEqual((status, len(calls), self.sleeps), (0, 2, [retry.BACKOFF_SECONDS[0]]))

    def test_a_failed_try_leaves_no_partial_pack_or_lock(self) -> None:
        git = self.repo / ".git"
        old_lock = git / "refs" / "remotes" / "origin" / "old.lock"
        old_lock.parent.mkdir(parents=True)
        old_lock.write_text("someone else's")
        os.utime(old_lock, (time.time() - 3600, time.time() - 3600))
        module = git / "modules" / "ghostty"
        (module / "objects" / "pack").mkdir(parents=True)
        (module / "HEAD").write_text("ref: refs/heads/main\n")

        def leave() -> None:
            (git / "objects" / "pack").mkdir(parents=True, exist_ok=True)
            (git / "objects" / "pack" / "tmp_pack_x").write_text("partial")
            (git / "shallow.lock").write_text("")
            (module / "objects" / "pack" / "tmp_idx_y").write_text("partial")

        self.run_with([128, 0], leave=leave)
        # The second try left them again and succeeded: only the failed try's leftovers were removed,
        # so check after a final failure instead.
        self.run_with([128], tries=1, leave=leave)
        self.assertEqual(list((git / "objects" / "pack").glob("tmp_*")), [])
        self.assertFalse((git / "shallow.lock").exists())
        self.assertEqual(list((module / "objects" / "pack").glob("tmp_*")), [])
        # A lock older than the try is not ours.
        self.assertTrue(old_lock.exists())

    def test_a_failed_try_removes_the_submodule_it_half_made(self) -> None:
        git = self.repo / ".git"
        kept = git / "modules" / "ghostty"
        (kept / "objects").mkdir(parents=True)
        (kept / "HEAD").write_text("ref: refs/heads/main\n")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".gitmodules").write_text('[submodule "ghostty"]\n\tpath = ghostty\n'
                                               '[submodule "ghostty-next"]\n\tpath = ghostty-next\n')
        (self.repo / "ghostty").mkdir()
        (self.repo / "ghostty" / ".git").write_text("gitdir: ../.git/modules/ghostty\n")
        half = git / "modules" / "ghostty-next"

        def leave() -> None:
            (half / "objects" / "pack").mkdir(parents=True, exist_ok=True)
            (half / "config.lock").write_text("")
            (self.repo / "ghostty-next").mkdir(exist_ok=True)
            (self.repo / "ghostty-next" / ".git").write_text("gitdir: ../.git/modules/ghostty-next\n")

        self.run_with([128], tries=1, leave=leave)
        self.assertFalse(half.exists())
        self.assertFalse((self.repo / "ghostty-next").exists())
        # What existed before the try stays.
        self.assertTrue((kept / "HEAD").exists())
        self.assertTrue((self.repo / "ghostty" / ".git").exists())

    def test_a_half_made_nested_path_submodule_and_its_worktree_are_removed(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".gitmodules").write_text('[submodule "vendor/lib"]\n\tpath = vendor/lib\n')
        half = self.repo / ".git" / "modules" / "vendor" / "lib"

        def leave() -> None:
            (half / "objects").mkdir(parents=True, exist_ok=True)
            (self.repo / "vendor" / "lib").mkdir(parents=True, exist_ok=True)
            (self.repo / "vendor" / "lib" / ".git").write_text("gitdir: ../../.git/modules/vendor/lib\n")

        self.run_with([128], tries=1, leave=leave)
        self.assertFalse((self.repo / ".git" / "modules" / "vendor").exists())
        self.assertFalse((self.repo / "vendor" / "lib").exists())

    def test_a_third_level_submodule_worktree_is_removed(self) -> None:
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".gitmodules").write_text('[submodule "a"]\n\tpath = a\n')
        a, b = self.repo / "a", self.repo / "a" / "b"
        b.mkdir(parents=True)
        (a / ".gitmodules").write_text('[submodule "b"]\n\tpath = b\n')
        (b / ".gitmodules").write_text('[submodule "c"]\n\tpath = c\n')
        kept = self.repo / ".git" / "modules" / "a"
        (kept / "modules" / "b" / "objects").mkdir(parents=True)
        (kept / "HEAD").write_text("ref: refs/heads/main\n")
        (kept / "modules" / "b" / "HEAD").write_text("ref: refs/heads/main\n")
        half = kept / "modules" / "b" / "modules" / "c"

        def leave() -> None:
            (half / "objects").mkdir(parents=True, exist_ok=True)
            (b / "c").mkdir(exist_ok=True)
            (b / "c" / ".git").write_text("gitdir: ../../../.git/modules/a/modules/b/modules/c\n")

        self.run_with([128], tries=1, leave=leave)
        self.assertFalse(half.exists())
        self.assertFalse((b / "c").exists())
        self.assertTrue((kept / "modules" / "b" / "HEAD").exists())

    def test_a_fresh_config_lock_is_removed(self) -> None:
        git = self.repo / ".git"
        git.mkdir()

        def leave() -> None:
            (git / "config.lock").write_text("")

        self.run_with([128], tries=1, leave=leave)
        self.assertFalse((git / "config.lock").exists())

    def test_only_git_commands(self) -> None:
        with self.assertRaises(ValueError):
            retry.low_speed_command(["curl", "x"])


class DanglingSubmodules(unittest.TestCase):
    """A reused workspace that lost .git/modules keeps submodule checkouts whose .git file names nothing.
    `submodule update --init --force` cannot repair them (the warm nightly-next builder, 2026-10-28:
    "could not get a repository handle for submodule 'ghostty'", then "not a git repository:
    ghostty/../.git/modules/ghostty"); before each try of an update they are removed so it clones again."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                    "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow",
                    "GIT_CONFIG_VALUE_0": "always"}
        self.sub = root / "ghostty-src"
        self.git("init", "-q", "-b", "main", str(self.sub))
        (self.sub / "f").write_text("ghostty\n")
        self.git("-C", str(self.sub), "add", "f")
        self.git("-C", str(self.sub), "commit", "-qm", "g")
        self.repo = root / "ws"
        self.git("init", "-q", "-b", "main", str(self.repo))
        self.git("-C", str(self.repo), "submodule", "add", "-q", str(self.sub), "ghostty")
        self.git("-C", str(self.repo), "commit", "-qm", "superproject")
        self.logs: list[str] = []

    def git(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["git", *args], check=True, capture_output=True, text=True, env=self.env)

    def update(self, runner=None) -> int:
        command = ["git", "-C", str(self.repo), "submodule", "update", "--init", "--force", "--recursive"]
        real = lambda cmd, timeout: subprocess.run(cmd, env=self.env, capture_output=True).returncode  # noqa: E731
        return retry.run(command, tries=1, timeout=60, repo=self.repo, runner=runner or real,
                         sleep=lambda _s: None, log=self.logs.append)

    def test_a_checkout_whose_git_dir_is_gone_is_cloned_again(self) -> None:
        shutil.rmtree(self.repo / ".git" / "modules")
        bare = subprocess.run(["git", "-C", str(self.repo), "submodule", "update", "--init", "--force"],
                              env=self.env, capture_output=True, text=True)
        self.assertNotEqual(bare.returncode, 0)  # what the nightly hit, without the helper
        self.assertEqual(self.update(), 0)
        self.assertEqual((self.repo / "ghostty" / "f").read_text(), "ghostty\n")
        self.assertTrue((self.repo / ".git" / "modules" / "ghostty" / "HEAD").is_file())
        self.assertTrue(any("which is gone" in line for line in self.logs))

    def test_a_half_made_git_dir_is_removed_with_its_checkout(self) -> None:
        modules = self.repo / ".git" / "modules" / "ghostty"
        shutil.rmtree(modules)
        (modules / "objects").mkdir(parents=True)  # no HEAD
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [self.repo / "ghostty"])
        self.assertFalse(modules.exists())
        self.assertTrue((self.repo / "ghostty").is_dir())
        self.assertEqual(list((self.repo / "ghostty").iterdir()), [])

    def test_a_healthy_checkout_and_its_untracked_files_stay(self) -> None:
        (self.repo / "ghostty" / "build-cache").write_text("warm\n")
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [])
        self.assertEqual(self.update(), 0)
        self.assertEqual((self.repo / "ghostty" / "build-cache").read_text(), "warm\n")

    def test_a_dangling_nested_checkout_is_dropped(self) -> None:
        inner = self.repo / "ghostty" / "vendor"
        inner.mkdir()
        (self.repo / "ghostty" / ".gitmodules").write_text('[submodule "vendor"]\n\tpath = vendor\n')
        (inner / ".git").write_text("gitdir: ../../.git/modules/ghostty/modules/vendor\n")
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [inner])
        self.assertTrue((self.repo / "ghostty" / ".git").is_file())  # the healthy parent stays

    def test_nothing_outside_the_repository_is_touched(self) -> None:
        outside = Path(self.temp.name) / "outside"
        (outside / "victim").mkdir(parents=True)
        (outside / "victim" / "keep").write_text("x\n")
        (outside / "victim" / ".git").write_text("gitdir: ../nowhere\n")
        (self.repo / "keep").mkdir()
        (self.repo / "keep" / ".git").write_text("gitdir: ../nowhere\n")
        (self.repo / "keep" / "work").write_text("x\n")
        (self.repo / ".gitmodules").write_text('[submodule "a"]\n\tpath = ../outside/victim\n'
                                               '[submodule "b"]\n\tpath = link/victim\n'
                                               '[submodule "c"]\n\tpath = link/../keep\n')
        (self.repo / "link").symlink_to(outside)
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [])
        self.assertEqual((outside / "victim" / "keep").read_text(), "x\n")
        self.assertEqual((self.repo / "keep" / "work").read_text(), "x\n")

    def test_a_gitdir_reached_through_a_symlink_is_judged_where_git_reaches_it(self) -> None:
        live = Path(self.temp.name) / "outside" / "child"
        live.mkdir(parents=True)
        shutil.move(str(self.repo / ".git" / "modules" / "ghostty"), str(live.parent / "live"))
        (self.repo / ".git" / "modules" / "link").symlink_to(live)
        (self.repo / "ghostty" / ".git").write_text("gitdir: ../.git/modules/link/../live\n")
        (self.repo / "ghostty" / "work").write_text("x\n")
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [])
        self.assertEqual((self.repo / "ghostty" / "work").read_text(), "x\n")

    def test_a_symlinked_modules_root_is_never_emptied(self) -> None:
        outside = Path(self.temp.name) / "elsewhere"
        (outside / "ghostty" / "objects").mkdir(parents=True)  # no HEAD: looks half-made
        shutil.rmtree(self.repo / ".git" / "modules")
        (self.repo / ".git" / "modules").symlink_to(outside)
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append), [self.repo / "ghostty"])
        self.assertTrue((outside / "ghostty" / "objects").is_dir())

    def test_only_limits_the_drop_to_the_named_paths(self) -> None:
        shutil.rmtree(self.repo / ".git" / "modules")
        (self.repo / "ghostty" / "cache").write_text("warm\n")
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append, only=["ghostty-next"]), [])
        self.assertEqual((self.repo / "ghostty" / "cache").read_text(), "warm\n")
        self.assertEqual(retry.drop_dangling_submodules(self.repo, self.logs.append, only=["ghostty"]),
                         [self.repo / "ghostty"])

    def test_an_update_of_named_paths_drops_only_under_them(self) -> None:
        shutil.rmtree(self.repo / ".git" / "modules")
        (self.repo / "ghostty" / "cache").write_text("warm\n")
        retry.run(["git", "submodule", "update", "--init", "--", "ghostty-next"], tries=1, timeout=60,
                  repo=self.repo, runner=lambda c, t: 0, sleep=lambda _s: None, log=self.logs.append)
        self.assertEqual((self.repo / "ghostty" / "cache").read_text(), "warm\n")

    def test_named_paths_scope_the_drop_with_or_without_a_separator(self) -> None:
        for command in (["git", "submodule", "update", "--init", "ghostty-next"],
                        ["git", "-C", "ghostty", "-c", "a=b", "submodule", "update", "--depth", "1", "ghostty-next"]):
            with self.subTest(command=command):
                shutil.rmtree(self.repo / ".git" / "modules", ignore_errors=True)
                (self.repo / "ghostty").mkdir(exist_ok=True)
                (self.repo / "ghostty" / ".git").write_text("gitdir: ../.git/modules/ghostty\n")
                (self.repo / "ghostty" / "cache").write_text("warm\n")
                retry.run(command, tries=1, timeout=60, repo=self.repo, runner=lambda c, t: 0,
                          sleep=lambda _s: None, log=self.logs.append)
                self.assertEqual((self.repo / "ghostty" / "cache").read_text(), "warm\n")
        low = retry.low_speed_command
        self.assertEqual(retry.submodule_update_paths(low(["git", "-c", "protocol.version=2", "-c",
                                                           "core.hooksPath=/dev/null", "submodule", "update", "--init",
                                                           "--force", "--depth=1", "--recursive"])), [])
        self.assertEqual(retry.submodule_update_paths(["git", "submodule", "update", "--", "a", "b"]), ["a", "b"])
        self.assertIsNone(retry.submodule_update_paths(["git", "-C", "update", "fetch"]))
        self.assertIsNone(retry.submodule_update_paths(["git", "submodule", "sync"]))
        self.assertEqual(retry.submodule_update_paths(["git", "submodule", "--quiet", "update", "--init"]), [])
        self.assertEqual(retry.submodule_update_paths(["git", "submodule", "-q", "update", "x"]), ["x"])

    def test_the_cli_only_drops(self) -> None:
        shutil.rmtree(self.repo / ".git" / "modules")
        result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/git_fetch_retry.py"),
                                 "--drop-dangling-submodules", "--repo", str(self.repo)],
                                capture_output=True, text=True, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("which is gone", result.stdout)
        self.assertEqual(list((self.repo / "ghostty").iterdir()), [])

    def test_only_a_submodule_update_drops_checkouts(self) -> None:
        shutil.rmtree(self.repo / ".git" / "modules")
        retry.run(["git", "fetch", "origin", "abc"], tries=1, timeout=60, repo=self.repo, runner=lambda c, t: 0,
                  sleep=lambda _s: None, log=self.logs.append)
        self.assertTrue((self.repo / "ghostty" / ".git").is_file())
        self.assertTrue(retry.is_submodule_update(retry.low_speed_command(
            ["git", "-c", "protocol.version=2", "submodule", "update", "--init"])))
        self.assertFalse(retry.is_submodule_update(["git", "submodule", "sync"]))


class RunOnce(unittest.TestCase):
    def test_a_hung_command_and_its_children_are_killed_at_the_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "child-alive"
            script = f"(sleep 30; touch {marker}) & sleep 30"
            started = time.monotonic()
            status = retry.run_once(["sh", "-c", script], timeout=1)
            self.assertEqual(status, retry.TIMEOUT_EXIT)
            self.assertLess(time.monotonic() - started, 15)

    def test_a_child_that_ignores_sigterm_is_killed_before_run_once_returns(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp) / "child-survived"
            child = (f"import os, signal, time\n"
                     f"if os.fork() == 0:\n"
                     f"    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                     f"    time.sleep(4)\n"
                     f"    open({str(marker)!r}, 'w').close()\n"
                     f"else:\n"
                     f"    time.sleep(30)\n")
            original = retry.KILL_GRACE_SECONDS
            retry.KILL_GRACE_SECONDS = 1
            try:
                status = retry.run_once([sys.executable, "-c", child], timeout=1)
            finally:
                retry.KILL_GRACE_SECONDS = original
            self.assertEqual(status, retry.TIMEOUT_EXIT)
            time.sleep(4)
            self.assertFalse(marker.exists())

    def test_the_exit_status_passes_through(self) -> None:
        self.assertEqual(retry.run_once(["sh", "-c", "exit 3"], timeout=10), 3)

    def test_the_cli_runs_a_real_git(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(["git", "init", "-q", temp], check=True)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/ci/git_fetch_retry.py"), "--tries", "1",
                                     "--timeout", "30", "--repo", temp, "--", "git", "-C", temp, "status", "--short"],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)


class Workflow(unittest.TestCase):
    def test_the_warm_fetch_and_submodule_update_are_bounded(self) -> None:
        doc = yaml.safe_load(WORKFLOW.read_text())
        step = next(s for s in doc["jobs"]["build-nightly-app"]["steps"] if s.get("name") == WARM_STEP)
        script = step["run"]
        self.assertEqual(step["env"]["WORKFLOW_SHA"], "${{ github.sha }}")
        # The helper is taken from the workflow commit into RUNNER_TEMP, before anything touches the clone.
        self.assertIn('fetch_retry="$RUNNER_TEMP/git_fetch_retry.py"', script)
        self.assertLess(script.index('git show "$WORKFLOW_SHA:scripts/ci/git_fetch_retry.py"'),
                        script.index("git -c protocol.version=2 fetch"))
        self.assertIn('python3 "$fetch_retry" --tries 3 --timeout 600 --repo "$GITHUB_WORKSPACE" -- "$@"', script)
        for command in ('git -c protocol.version=2 fetch --no-tags --no-recurse-submodules origin "$BUILD_SHA"',
                        "git -c protocol.version=2 -c core.hooksPath=/dev/null submodule update --init --force"
                        " --depth=1 --recursive"):
            with self.subTest(command=command):
                self.assertIn("retry " + command, script)
                # Never also run bare.
                self.assertEqual(script.count(command), 1)

    def test_the_retry_wrapper_runs_from_a_fresh_workspace(self) -> None:
        # Extract the helper-fetch lines and the retry function and run them where the workspace has no
        # script and the workflow commit is not local: the cp/curl fallbacks must not abort under set -e.
        doc = yaml.safe_load(WORKFLOW.read_text())
        step = next(s for s in doc["jobs"]["build-nightly-app"]["steps"] if s.get("name") == WARM_STEP)
        script = step["run"]
        start = script.index('fetch_retry="$RUNNER_TEMP/git_fetch_retry.py"')
        end = script.index("started=$SECONDS")
        with tempfile.TemporaryDirectory() as temp:
            workspace, runner_temp = Path(temp) / "ws", Path(temp) / "tmp"
            workspace.mkdir()
            runner_temp.mkdir()
            subprocess.run(["git", "init", "-q", str(workspace)], check=True)
            body = ("set -euo pipefail\ncurl() { return 7; }\n" + script[start:end]
                    + 'retry git status --short\necho done\n')
            env = {**os.environ, "RUNNER_TEMP": str(runner_temp), "GITHUB_WORKSPACE": str(workspace),
                   "GITHUB_REPOSITORY": "o/r", "WORKFLOW_SHA": "0" * 40}
            result = subprocess.run(["bash", "-c", body], cwd=workspace, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("unavailable; running git once with the low-speed abort", result.stdout)
            self.assertTrue(result.stdout.strip().endswith("done"))
            # With the helper in the workflow commit's objects, it is used.
            (workspace / "scripts/ci").mkdir(parents=True)
            (workspace / "scripts/ci/git_fetch_retry.py").write_text((ROOT / "scripts/ci/git_fetch_retry.py").read_text())
            subprocess.run(["git", "-C", str(workspace), "add", "."], check=True)
            subprocess.run(["git", "-C", str(workspace), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
                           check=True)
            sha = subprocess.run(["git", "-C", str(workspace), "rev-parse", "HEAD"], check=True, capture_output=True,
                                 text=True).stdout.strip()
            (workspace / "scripts/ci/git_fetch_retry.py").unlink()
            result = subprocess.run(["bash", "-c", body], cwd=workspace, env={**env, "WORKFLOW_SHA": sha},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("unavailable", result.stdout)


if __name__ == "__main__":
    unittest.main()
