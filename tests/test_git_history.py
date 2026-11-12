"""tests/git_history.py against a real shallow clone: parallel history tests fetch once, and a
git lock is retried, never reported as "needs history".

    python3 -I tests/test_git_history.py
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Loaded by path: `python3 -I` puts no script folder on sys.path.
git_fixture_env = _load("git_fixture_env")
git_history = _load("git_history")

THREADS = 8


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
                          env=git_fixture_env.fixture_env(), stdin=subprocess.DEVNULL).stdout.strip()


class ShallowClone(unittest.TestCase):
    """An origin with commits A <- B <- C and a depth-1 clone of C: B and its parent A are missing."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        origin = git_fixture_env.init_repo(root / "origin", "-b", "main")
        _git(origin, "config", "uploadpack.allowAnySHA1InWant", "true")
        shas = []
        for name in ("a", "b", "c"):
            (origin / name).write_text(name)
            _git(origin, "add", name)
            _git(origin, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", name)
            shas.append(_git(origin, "rev-parse", "HEAD"))
        self.a, self.b, _ = shas
        self.clone = git_fixture_env.clone_repo(f"file://{origin}", root / "clone", "--depth", "1")
        self.assertEqual(_git(self.clone, "rev-parse", "--is-shallow-repository"), "true")
        self.assertFalse(git_history.has_commit(self.clone, self.b, depth=2))

    def count_fetches(self) -> list[list[str]]:
        fetches: list[list[str]] = []
        real = git_history._git
        lock = threading.Lock()

        def counting(root, *args, **kwargs):
            if args and args[0] == "fetch":
                with lock:
                    fetches.append(list(args))
            return real(root, *args, **kwargs)

        git_history._git = counting
        self.addCleanup(setattr, git_history, "_git", real)
        return fetches

    def test_parallel_history_tests_all_pass_with_exactly_one_fetch(self) -> None:
        fetches = self.count_fetches()
        start = threading.Barrier(THREADS)
        results: list[object] = [None] * THREADS

        def need(i: int) -> None:
            start.wait()
            try:
                results[i] = git_history.missing_history(self.clone, [self.b], depth=2)
            except Exception as exc:  # noqa: BLE001 - the thread's error is the test's finding
                results[i] = exc

        threads = [threading.Thread(target=need, args=(i,)) for i in range(THREADS)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(120)
        self.assertEqual(results, [None] * THREADS, "every parallel history test finds its commits")
        self.assertEqual(len(fetches), 1, f"one fetch for {THREADS} parallel callers, not {fetches}")
        self.assertTrue(git_history.has_commit(self.clone, self.b, depth=2))
        self.assertTrue(git_history.has_commit(self.clone, self.a))

    def test_a_git_lock_held_by_another_process_is_retried_not_needs_history(self) -> None:
        shallow_lock = Path(_git(self.clone, "rev-parse", "--path-format=absolute", "--git-dir")) / "shallow.lock"
        shallow_lock.write_text("")  # what another `git fetch` into this clone holds while it runs
        timer = threading.Timer(0.7, shallow_lock.unlink)
        timer.start()
        self.addCleanup(timer.cancel)
        self.assertIsNone(git_history.missing_history(self.clone, [self.b], depth=2))

    def hold_shallow_lock(self, seconds: float | None) -> None:
        shallow_lock = Path(_git(self.clone, "rev-parse", "--path-format=absolute", "--git-dir")) / "shallow.lock"
        shallow_lock.write_text("")  # what another `git fetch` into this clone holds while it runs
        if seconds is None:
            self.addCleanup(shallow_lock.unlink, missing_ok=True)
            return
        timer = threading.Timer(seconds, shallow_lock.unlink)
        timer.start()
        self.addCleanup(timer.cancel)

    def test_a_git_lock_held_past_four_quick_retries_is_still_waited_out(self) -> None:
        # cmux#41434 review: four retries (3 s in all) and a slow concurrent fetch came back as "needs history".
        self.hold_shallow_lock(4.5)
        self.assertIsNone(git_history.missing_history(self.clone, [self.b], depth=2))

    def test_a_git_lock_that_never_frees_is_lock_contention_not_needs_history(self) -> None:
        self.hold_shallow_lock(None)
        old = getattr(git_history, "GIT_LOCK_WAIT_SECONDS", None)
        git_history.GIT_LOCK_WAIT_SECONDS = 1
        self.addCleanup(setattr, git_history, "GIT_LOCK_WAIT_SECONDS", old)
        reason = git_history.missing_history(self.clone, [self.b], depth=2)
        self.assertIsNotNone(reason)
        self.assertTrue(reason.startswith("git lock held: "), reason)
        self.assertNotIn("needs history", reason)

    def test_a_commit_origin_lacks_is_still_needs_history(self) -> None:
        reason = git_history.missing_history(self.clone, ["0" * 40], depth=1)
        self.assertIsNotNone(reason)
        self.assertTrue(reason.startswith("needs history: " + "0" * 40), reason)

    def test_require_history_fails_on_ci_and_skips_elsewhere(self) -> None:
        for ci, outcome in (("true", AssertionError), ("", unittest.SkipTest)):
            with self.subTest(CI=ci):
                old = os.environ.get("CI")
                os.environ["CI"] = ci
                try:
                    with self.assertRaisesRegex(outcome, "^needs history: "):
                        git_history.require_history(self.clone, ["0" * 40])
                finally:
                    if old is None:
                        os.environ.pop("CI", None)
                    else:
                        os.environ["CI"] = old


if __name__ == "__main__":
    unittest.main()
