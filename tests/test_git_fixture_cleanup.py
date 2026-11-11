#!/usr/bin/env python3
"""The git fixture helpers clean up after themselves under concurrency and caller traps (Codex on cmux#40939).

F1: tests/git_fixture_env.py global_config_for() wrote each new text to `{path}.{pid}` and renamed it into
place. Two threads of one process writing the same text shared that partial name, so one renamed the file away
while the other was still writing it, and the other's rename failed (FileNotFoundError). Each writer now gets
its own mkstemp name in the same folder.

F2: scripts/cmux-next/tests/lib/git-fixture.sh removes its private GIT_CONFIG_GLOBAL folder from an EXIT trap,
and a caller's own `trap CMD EXIT` after sourcing replaced it, so the folder leaked from every such test
(web-bundles-readonly-sources.test.sh's `trap cleanup EXIT`, and 35 more). Callers now hand their cleanup to
git_fixture_trap_exit, which runs it after the helper's, and check-test-determinism.py rule
git-fixture-exit-trap fails a test that traps EXIT directly.

  python3 tests/test_git_fixture_cleanup.py
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "tests" / "git_fixture_env.py"
LIB = ROOT / "scripts" / "cmux-next" / "tests" / "lib" / "git-fixture.sh"
CHECKER = ROOT / "scripts" / "check-test-determinism.py"

# Load the module, then have THREADS threads call global_config_for() for one new text at a time, ROUNDS times.
# Each rename waits a little first, so every writer has written before any renames: the interleaving that a
# shared partial name cannot survive. Prints one line per failure, then the leftover partial files.
RACE = """
import importlib.util, os, sys, threading, time
spec = importlib.util.spec_from_file_location("git_fixture_env", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
THREADS, ROUNDS = 8, 20
module.global_config_text = lambda env: env["TEXT"]
real_replace = os.replace
def slow_replace(src, dst, *args, **kwargs):
    time.sleep(0.02)
    return real_replace(src, dst, *args, **kwargs)
os.replace = slow_replace
failures = []
for round in range(ROUNDS):
    text = f"[user]\\n\\tname = round-{round}\\n"
    barrier = threading.Barrier(THREADS)
    paths = []
    def write():
        barrier.wait()
        try:
            path = module.global_config_for({"TEXT": text})
            paths.append(path)
            if open(path).read() != text:
                failures.append(f"round {round}: {path} does not hold the text")
        except Exception as error:
            failures.append(f"round {round}: {type(error).__name__}: {error}")
    threads = [threading.Thread(target=write) for _ in range(THREADS)]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    if len(set(paths)) > 1:
        failures.append(f"round {round}: {len(set(paths))} paths for one text")
os.replace = real_replace
folder = os.path.dirname(module.GLOBAL_CONFIG)
leftovers = sorted(name for name in os.listdir(folder) if not name.endswith(".gitconfig") or name.startswith("."))
for failure in failures: print(failure)
for name in leftovers: print("leftover", name)
"""


class Env:
    @staticmethod
    def clean(tmp: Path) -> dict[str, str]:
        """This process's env without GIT_*, with a private TMPDIR and an empty HOME."""
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("GIT_") and key not in ("XDG_CONFIG_HOME", "CMUX_GIT_FIXTURE_GLOBAL_DIR")}
        (tmp / "home").mkdir()
        (tmp / "tmpdir").mkdir()
        env.update(HOME=str(tmp / "home"), TMPDIR=str(tmp / "tmpdir"), GIT_CONFIG_NOSYSTEM="1")
        return env


class ConcurrentWriters(unittest.TestCase):
    def test_threads_writing_one_text_never_collide(self):
        with tempfile.TemporaryDirectory(prefix="git-fixture-race-") as tmp:
            done = subprocess.run([sys.executable, "-I", "-c", RACE, str(MODULE)], env=Env.clean(Path(tmp)),
                                  capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertEqual(done.stdout, "", "concurrent global_config_for() calls collided:\n" + done.stdout)


class ShellCleanup(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-trap-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)
        self.tmpdir = Path(self.env["TMPDIR"])

    def bash(self, script: str, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "-c", script, "_", str(LIB), *args], env=self.env, capture_output=True,
                              text=True, timeout=600, stdin=subprocess.DEVNULL, cwd=self.tmp)

    def fixture_folders(self) -> list[str]:
        return sorted(name for name in os.listdir(self.tmpdir) if name.startswith("cmux-git-fixture"))

    def test_real_callers_with_their_own_exit_cleanup_leave_no_folder(self):
        """Run callers that also clean up at exit: whatever they exit with, the helper's folder is gone."""
        callers = [
            ROOT / "scripts/cmux-next/tests/check-no-swiftui.test.sh",
            ROOT / "tests/test_ci_generator_input_freshness.sh",
            ROOT / "scripts/cmux-next/tests/web-bundles-readonly-sources.test.sh",
        ]
        for caller in callers:
            with self.subTest(caller=caller.relative_to(ROOT).as_posix()):
                done = subprocess.run(["bash", str(caller)], env=self.env, capture_output=True, text=True,
                                      timeout=900, stdin=subprocess.DEVNULL, cwd=ROOT)
                self.assertEqual(self.fixture_folders(), [],
                                 f"exit {done.returncode} left the GIT_CONFIG_GLOBAL folder:\n{done.stderr[-2000:]}")

    def test_caller_cleanup_runs_after_the_folder_goes_and_keeps_the_exit_status(self):
        marker = self.tmp / "caller-ran"
        done = self.bash(
            'source "$1"; folder=${GIT_CONFIG_GLOBAL%/*}; [[ -d $folder ]] || exit 9\n'
            'git_fixture_trap_exit \'echo "status=$? folder-gone=$([[ -e $folder ]] && echo no || echo yes)" >"$2"\'\n'
            'exit 7\n', str(marker))
        self.assertEqual(done.returncode, 7, done.stderr)
        self.assertEqual(marker.read_text().strip(), "status=7 folder-gone=yes")
        self.assertEqual(self.fixture_folders(), [])

    def test_an_exit_trap_set_before_sourcing_still_runs(self):
        marker = self.tmp / "early"
        done = self.bash('trap \'echo early >"$2"\' EXIT; source "$1"; source "$1"; exit 3', str(marker))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertEqual(marker.read_text().strip(), "early")
        self.assertEqual(self.fixture_folders(), [])

    def test_every_sourcing_shell_test_leaves_exit_to_the_helper(self):
        """The detector: no file that sources git-fixture.sh traps EXIT itself (rule git-fixture-exit-trap)."""
        done = subprocess.run([sys.executable, "-I", str(CHECKER), "--repo-root", str(ROOT)], capture_output=True,
                              text=True, timeout=600, stdin=subprocess.DEVNULL)
        hits = [line for line in done.stdout.splitlines() if "git-fixture-exit-trap" in line]
        self.assertIn("git-fixture-exit-trap", CHECKER.read_text(), "the checker has no git-fixture-exit-trap rule")
        self.assertEqual(hits, [], "\n".join(hits))


# Each converted caller pattern (git_fixture_trap_exit with a quoted command, a function name, on the mktemp line,
# a later call that replaces an earlier one; a trap set before sourcing), run under `set -euo pipefail`.
# "$2" is the scratch folder for the caller's own temp dir; "$3" the marker its cleanup writes.
CALLER_PATTERNS = {
    "quoted command": (
        'set -euo pipefail; source "$1"; MARKER=$3\n'
        'tmp=$(mktemp -d "$2/caller.XXXXXX")\n'
        'git_fixture_trap_exit \'s=$?; rm -rf "$tmp"; echo "ran $s" >"$MARKER"\'\n'
    ),
    "function name": (
        'set -euo pipefail; source "$1"; MARKER=$3\n'
        'TMP=$(mktemp -d "$2/caller.XXXXXX")\n'
        'cleanup() { local status=$?; git -C "$TMP/repo" worktree remove --force "$TMP/wt" >/dev/null 2>&1 || true; '
        'rm -rf "$TMP"; echo "ran $status" >"$MARKER"; }\n'
        'git_fixture_trap_exit cleanup\n'
        'git_fixture_init "$TMP/repo"; git_q -C "$TMP/repo" commit -q --allow-empty -m x\n'
        'git_q -C "$TMP/repo" worktree add -q --detach "$TMP/wt"\n'
    ),
    "on the mktemp line": (
        'set -euo pipefail; source "$1"; MARKER=$3\n'
        'T=$(mktemp -d "$2/caller.XXXXXX"); git_fixture_trap_exit \'s=$?; rm -rf "$T"; echo "ran $s" >"$MARKER"\'\n'
    ),
    "a later call replaces the first": (
        'set -euo pipefail; source "$1"; MARKER=$3\n'
        'A=$(mktemp -d "$2/caller.XXXXXX"); git_fixture_trap_exit \'echo "wrong cleanup" >"$MARKER"\'\n'
        'B=$(mktemp -d "$2/caller.XXXXXX"); git_fixture_trap_exit \'s=$?; rm -rf "$A" "$B"; echo "ran $s" >"$MARKER"\'\n'
    ),
    "a direct trap after sourcing (the trap wrapper)": (
        'set -euo pipefail; source "$1"; MARKER=$3\n'
        'tmp=$(mktemp -d "$2/caller.XXXXXX"); trap \'s=$?; rm -rf "$tmp"; echo "ran $s" >"$MARKER"\' EXIT INT\n'
    ),
    "a trap set before sourcing": (
        'set -euo pipefail; MARKER=$3\n'
        'tmp=$(mktemp -d "$2/caller.XXXXXX"); trap \'s=$?; rm -rf "$tmp"; echo "ran $s" >"$MARKER"\' EXIT\n'
        'source "$1"\n'
    ),
}
# Two ways a test fails with status 7: `exit 7`, and a command that fails with 7 under errexit.
FAILURES = {"exit 7": "exit 7\n", "errexit": "sh -c 'exit 7'\necho unreachable\n"}


class FailedTestCleanup(unittest.TestCase):
    """A test that fails under `set -euo pipefail` still runs its chained cleanup (Codex F1 (P2) on cmux#41195).

    At 54e23b34 the helper's EXIT trap set $? with `(exit "$status")`, which tripped errexit inside the trap when
    the test had failed, so the caller's cleanup never ran and its temp dirs (and worktrees) stayed behind.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-errexit-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)
        self.tmpdir = Path(self.env["TMPDIR"])
        self.scratch = self.tmp / "scratch"

    def run_case(self, script: str) -> tuple[subprocess.CompletedProcess[str], Path]:
        shutil.rmtree(self.scratch, ignore_errors=True)
        self.scratch.mkdir()
        marker = self.tmp / "marker"
        marker.unlink(missing_ok=True)
        done = subprocess.run(["bash", "-c", script, "_", str(LIB), str(self.scratch), str(marker)], env=self.env,
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, cwd=self.tmp)
        return done, marker

    def test_every_caller_pattern_cleans_up_and_keeps_exit_7(self):
        for pattern, setup in CALLER_PATTERNS.items():
            for failure, tail in FAILURES.items():
                with self.subTest(pattern=pattern, failure=failure):
                    done, marker = self.run_case(setup + tail)
                    self.assertEqual(done.returncode, 7, done.stderr)
                    self.assertNotIn("unreachable", done.stdout)
                    self.assertTrue(marker.exists(), f"the chained cleanup never ran: {done.stderr}")
                    self.assertEqual(marker.read_text().strip(), "ran 7")
                    self.assertEqual(sorted(os.listdir(self.scratch)), [], "the caller's temp dir was left")
                    self.assertEqual(sorted(os.listdir(self.tmpdir)), [], "the fixture folder was left")

    def test_a_passing_test_keeps_exit_0_and_cleans_up(self):
        for pattern, setup in CALLER_PATTERNS.items():
            with self.subTest(pattern=pattern):
                done, marker = self.run_case(setup + "true\n")
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(marker.read_text().strip(), "ran 0")
                self.assertEqual(sorted(os.listdir(self.scratch)), [])
                self.assertEqual(sorted(os.listdir(self.tmpdir)), [])

    def test_a_folder_rm_cannot_finish_still_runs_the_cleanup(self):
        """The folder removal step has the same hole: a failed rm under errexit must not end the trap."""
        if os.geteuid() == 0:
            self.skipTest("root removes a read-only folder; the failing rm cannot be set up")
        script = (
            'set -euo pipefail; source "$1"\n'
            'locked=${GIT_CONFIG_GLOBAL%/*}/locked; mkdir "$locked"; : >"$locked/file"; chmod 500 "$locked"\n'
            'tmp=$(mktemp -d "$2/caller.XXXXXX"); MARKER=$3\n'
            'git_fixture_trap_exit \'s=$?; chmod 700 "$locked"; rm -rf "$tmp"; echo "ran $s" >"$MARKER"\'\n'
            "exit 7\n"
        )
        done, marker = self.run_case(script)
        for root, dirs, _ in os.walk(self.tmpdir):
            for name in dirs:
                os.chmod(os.path.join(root, name), 0o700)
        self.assertEqual(done.returncode, 7, done.stderr)
        self.assertTrue(marker.exists(), f"the chained cleanup never ran after a failed rm: {done.stderr}")
        self.assertEqual(marker.read_text().strip(), "ran 7")
        self.assertEqual(sorted(os.listdir(self.scratch)), [])


class ExitStatusAndDoubleSource(unittest.TestCase):
    """The cmux#41021 review: the EXIT chain must hand the script's status to the caller's action (F1), and a second
    source after GIT_CONFIG_GLOBAL is unset must not lose the first private folder (F2)."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-status-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)
        self.tmpdir = Path(self.env["TMPDIR"])

    def bash(self, script: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["bash", "-c", script, "_", str(LIB)], env=self.env, capture_output=True, text=True,
                              timeout=120, stdin=subprocess.DEVNULL, cwd=self.tmp)

    def assertNoFolder(self, done: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(sorted(os.listdir(self.tmpdir)), [], f"a fixture folder was left: {done.stderr}")

    def test_a_caller_trap_that_exits_with_its_status_keeps_the_failure(self):
        """`trap 'exit "$?"' EXIT` after sourcing, then a failure with 7: the script exits 7, not 0."""
        for errexit in ("", "set -euo pipefail; "):
            for set_trap in ("trap 'exit \"$?\"' EXIT", "git_fixture_trap_exit 'exit \"$?\"'"):
                for failure in ("exit 7", "sh -c 'exit 7'; exit 7"):
                    with self.subTest(errexit=bool(errexit), trap=set_trap, failure=failure):
                        done = self.bash(errexit + 'source "$1"\n' + set_trap + "\n" + failure + "\n")
                        self.assertEqual(done.returncode, 7, done.stderr)
                        self.assertNoFolder(done)

    def test_a_second_source_after_unset_leaves_no_folder(self):
        for errexit in ("", "set -euo pipefail; "):
            with self.subTest(errexit=bool(errexit)):
                done = self.bash(
                    errexit + 'source "$1"\nfirst=$GIT_CONFIG_GLOBAL\nunset GIT_CONFIG_GLOBAL\nsource "$1"\n'
                    '[[ "$GIT_CONFIG_GLOBAL" != "$first" && -f "$first" && -f "$GIT_CONFIG_GLOBAL" ]] || exit 9\n'
                    'git_fixture_trap_exit \'echo chained >"$PWD/chained"\'\nexit 7\n')
                self.assertEqual(done.returncode, 7, done.stderr)
                self.assertEqual((self.tmp / "chained").read_text().strip(), "chained")
                (self.tmp / "chained").unlink()
                self.assertNoFolder(done)


if __name__ == "__main__":
    unittest.main()
