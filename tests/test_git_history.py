"""tests/git_history.py against a real shallow clone: parallel history tests fetch once, and a
git lock is retried, never reported as "needs history". Only git's own lock line is a lock: a
permission failure or a remote URL with ".lock" in it fails at once (cmux#41716 review F1), and
no script or test under scripts/ or tests/ retries on a ".lock" substring of an error.

    python3 -I tests/test_git_history.py
"""

from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import tempfile
import threading
import time
import types
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent


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
        patch = unittest.mock.patch.object(git_history, "GIT_LOCK_WAIT_SECONDS", 1, create=True)
        patch.start()
        self.addCleanup(patch.stop)
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


    def short_lock_budget(self, seconds: float = 3) -> None:
        # The retry budget knob: a row that must fail fast shows a slip in seconds, not GIT_LOCK_WAIT_SECONDS.
        patch = unittest.mock.patch.object(git_history, "GIT_LOCK_WAIT_SECONDS", seconds, create=True)
        patch.start()
        self.addCleanup(patch.stop)

    def count_fetches(self, stderr: str | None = None) -> list[list[str]]:
        """The `git fetch`es made; with `stderr`, each fails with it (exit 128) instead of running git."""
        fetches: list[list[str]] = []
        real = git_history._git

        def counting(root, *args, **kwargs):
            if args and args[0] == "fetch":
                fetches.append(list(args))
                if stderr is not None:
                    return subprocess.CompletedProcess(["git", *args], 128, stdout="", stderr=stderr)
            return real(root, *args, **kwargs)

        git_history._git = counting
        self.addCleanup(setattr, git_history, "_git", real)
        return fetches

    def no_lock_retry_sleep(self) -> list[float]:
        """git_history's sleeps; the first fails the test, so a fast failure shows as a pause taken, not a time."""
        pauses: list[float] = []

        def sleep(seconds: float) -> None:
            pauses.append(seconds)
            raise AssertionError(f"slept {seconds}s: the error was waited out as a git lock")

        clock = types.SimpleNamespace(monotonic=time.monotonic, sleep=sleep)
        patch = unittest.mock.patch.object(git_history, "time", clock)
        patch.start()
        self.addCleanup(patch.stop)
        return pauses

    def test_a_permission_denied_lock_file_fails_fast_with_its_own_error(self) -> None:
        # cmux#41716 review F1: "Unable to create" and ".lock" are in git's line here too, but nothing holds the lock.
        git_dir = Path(_git(self.clone, "rev-parse", "--path-format=absolute", "--git-dir"))
        if os.geteuid() == 0:
            # root writes a read-only directory: git's words for it, as a non-root CI runner printed them.
            fetches = self.count_fetches(f"fatal: Unable to create '{git_dir}/shallow.lock': Permission denied")
        else:
            (git_dir / git_history.LOCK_FILE).touch()  # the history fetch's own flock file, made before the dir locks
            mode = git_dir.stat().st_mode
            git_dir.chmod(mode & ~0o222)  # git cannot create shallow.lock: Permission denied
            self.addCleanup(git_dir.chmod, mode)
            fetches = self.count_fetches()
        self.short_lock_budget()
        pauses = self.no_lock_retry_sleep()
        reason = git_history.missing_history(self.clone, [self.b], depth=2)
        self.assertIsNotNone(reason)
        self.assertTrue(reason.startswith("needs history: "), reason)
        self.assertIn("Permission denied", reason)
        self.assertNotIn("git lock held", reason)
        self.assertEqual(len(fetches), 1, f"one fetch, no lock retries: {fetches}")
        self.assertEqual(pauses, [], "a permission failure is not waited out as a lock")

    def test_a_remote_url_with_lock_in_it_fails_fast_with_its_own_error(self) -> None:
        # cmux#41716 review F1: real git, an origin whose path ends in ".lock" and does not exist.
        gone = Path(_git(self.clone, "rev-parse", "--path-format=absolute", "--git-dir")).parent.parent / "gone" / "repo.lock"
        _git(self.clone, "remote", "set-url", "origin", f"file://{gone}")
        self.short_lock_budget()
        fetches = self.count_fetches()
        pauses = self.no_lock_retry_sleep()
        reason = git_history.missing_history(self.clone, [self.b], depth=2)
        self.assertIsNotNone(reason)
        self.assertTrue(reason.startswith("needs history: "), reason)
        self.assertIn("repo.lock", reason)
        self.assertNotIn("git lock held", reason)
        self.assertEqual(len(fetches), 1, f"one fetch, no lock retries: {fetches}")
        self.assertEqual(pauses, [], "a bad remote URL is not waited out as a lock")

    def test_git_lock_line_is_retried_on_the_clock_until_the_budget(self) -> None:
        # The other side of the two rows above, on the same fake: git's own lock line is waited out, pause by pause.
        git_dir = Path(_git(self.clone, "rev-parse", "--path-format=absolute", "--git-dir"))
        fetches = self.count_fetches(f"fatal: Unable to create '{git_dir}/shallow.lock': File exists.\n\n"
                                     "Another git process seems to be running in this repository")
        self.short_lock_budget(3)
        now = [0.0]
        pauses: list[float] = []

        def sleep(seconds: float) -> None:
            pauses.append(seconds)
            now[0] += seconds

        clock = types.SimpleNamespace(monotonic=lambda: now[0], sleep=sleep)
        patch = unittest.mock.patch.object(git_history, "time", clock)
        patch.start()
        self.addCleanup(patch.stop)
        reason = git_history.missing_history(self.clone, [self.b], depth=2)
        self.assertIsNotNone(reason)
        self.assertTrue(reason.startswith("git lock held: "), reason)
        self.assertEqual(pauses, [0.5, 1.0], "backs off 0.5 s then 1 s; the next 2 s pause would pass the 3 s budget")
        self.assertEqual(len(fetches), 3, f"a fetch before each pause and one after the last: {fetches}")


class GitLockLine(unittest.TestCase):
    """git_history.git_lock_held: the lock path for git's own lock line, None for every other error."""

    def test_git_lock_line_is_a_held_lock(self) -> None:
        # As git 2.55 printed it on the CI runner for a stale shallow.lock (lockfile.c, unable_to_lock_message).
        held = ("fatal: Unable to create '/w/repo/.git/shallow.lock': File exists.\n\n"
                "Another git process seems to be running in this repository, or the lock file may be stale")
        self.assertEqual(git_history.git_lock_held(held), "/w/repo/.git/shallow.lock")
        self.assertEqual(git_history.git_lock_held(held.replace("fatal:", "error:", 1)), "/w/repo/.git/shallow.lock")

    def test_other_errors_are_not_a_held_lock(self) -> None:
        for stderr in (
            "fatal: Unable to create '/w/repo/.git/shallow.lock': Permission denied",
            "fatal: Unable to create '/w/repo/.git/shallow.lock': Read-only file system",
            "fatal: '/tmp/gone/repo.lock' does not appear to be a git repository\n"
            "fatal: Could not read from remote repository.",
            "fatal: unable to access 'https://example.invalid/team/repo.lock/': Could not resolve host",
            "fatal: Unable to create temporary file '/w/repo/.git/objects/pack/tmp_pack_XXXX': No space left on device",
            "error: some note naming another git process",
            "",
        ):
            with self.subTest(stderr=stderr):
                self.assertIsNone(git_history.git_lock_held(stderr))


# A retry condition that takes an error for a git lock by a substring of it. One of these lines in scripts/ or
# tests/ is the class cmux#41716 review F1 found: match git's whole lock line through git_history.git_lock_held.
# A string that is git's words or a git lock's name: ".lock", "index.lock", ".git/shallow.lock" (not "no gui.lock hold").
_LOCK_WORD = (r"(?:[^\"'\n]*(?:Unable to create|another git process)[^\"'\n]*"
              r"|(?:[^\"'\s]*/)?(?:shallow|index|HEAD|packed-refs|config|FETCH_HEAD|ORIG_HEAD)?\.lock)")
SUBSTRING_LOCK_MATCH = (
    # "x.lock" in err / "Unable to create" in stderr
    re.compile(r"[\"']" + _LOCK_WORD + r"[\"']\s+(?:not\s+)?in\s+[\w.()\[\]]*(?:err|stderr|out|output|text|msg|message)\b"),
    # LOCK_WORDS = (".lock", "Unable to create", ...), a word list a retry tests `any(word in err ...)` against
    re.compile(r"^\s*[A-Z][A-Z0-9_]*\s*(?::[^=]+)?=\s*[(\[{].*[\"'](?:\.lock|Unable to create|another git process)[\"']"),
    # grep -q 'index.lock' / grep -qi "unable to create" on a captured error
    re.compile(r"\bgrep\s+(?:-\w+\s+)*[\"']?[^\s\"']*(?:\\?\.lock\b|[Uu]nable to create|another git process)"),
)
SCANNED = ("scripts", "tests")
SKIPPED_DIRS = {"node_modules", "_vendor", ".git", "__pycache__"}


def substring_lock_matches(text: str) -> list[int]:
    """1-based numbers of the lines in `text` that take an error for a git lock by a substring."""
    return [n for n, line in enumerate(text.splitlines(), 1) if any(p.search(line) for p in SUBSTRING_LOCK_MATCH)]


class NoSubstringLockRetry(unittest.TestCase):
    """The lint row: no retry under scripts/ or tests/ matches git's lock error by a ".lock" substring."""

    def test_the_detector_finds_each_shape_and_passes_the_exact_match(self) -> None:
        bad = (
            'GIT_LOCK_WORDS = (".lock", "Unable to create", "another git process")',
            '        if ".lock" in err:',
            '    if "Unable to create" in result.stderr:',
            '    while "index.lock" in proc.stderr:',
            '    if ".git/shallow.lock" not in output:',
            'if grep -q "index.lock" "$err"; then',
            "grep -qi 'unable to create' \"$log\" && sleep 1",
        )
        for line in bad:
            with self.subTest(line=line):
                self.assertEqual(substring_lock_matches(line), [1])
        good = (
            "        if git_history.git_lock_held(err) is None:",
            '    lock_path = stem + ".lock"',
            '        hits += [f for f in files if f.endswith((".lock", ".sock"))]',
            '        for name in ("shallow.lock", "index.lock", "HEAD.lock"):',
            '    (partial / ".git/index.lock").write_text("")',
            'touch "$tmp/mac/.git/index.lock"',
            '    check("refuses with no gui.lock hold", rc == 2 and "no gui.lock hold" in err, err)',
        )
        for line in good:
            with self.subTest(line=line):
                self.assertEqual(substring_lock_matches(line), [])

    def test_no_script_or_test_retries_on_a_lock_substring(self) -> None:
        found: list[str] = []
        for top in SCANNED:
            for folder, dirs, files in os.walk(REPO / top):
                dirs[:] = [d for d in dirs if d not in SKIPPED_DIRS]
                for name in files:
                    if not name.endswith((".py", ".sh", ".bash")):
                        continue
                    path = Path(folder) / name
                    if path == Path(__file__).resolve():
                        continue  # the detector's own rows
                    try:
                        text = path.read_text(encoding="utf-8")
                    except (UnicodeDecodeError, OSError):
                        continue
                    found += [f"{path.relative_to(REPO)}:{n}" for n in substring_lock_matches(text)]
        self.assertEqual(found, [], "match git's whole lock line with git_history.git_lock_held, not a substring")


if __name__ == "__main__":
    unittest.main()
