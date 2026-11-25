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
import random
import re
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
# Ways a test body fails under `set -e`, with the status the script must keep: `exit 7`, `false` (errexit, 1), and
# a command that fails with 7 under errexit.
FAILURES = {
    "exit 7": ("exit 7\n", 7),
    "false": ("false\necho unreachable\n", 1),
    "errexit 7": ("sh -c 'exit 7'\necho unreachable\n", 7),
}


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

    def test_every_caller_pattern_cleans_up_and_keeps_the_failing_status(self):
        for pattern, setup in CALLER_PATTERNS.items():
            for failure, (body, status) in FAILURES.items():
                with self.subTest(pattern=pattern, failure=failure):
                    done, marker = self.run_case(setup + body)
                    self.assertEqual(done.returncode, status, done.stderr)
                    self.assertNotIn("unreachable", done.stdout)
                    self.assertTrue(marker.exists(), f"the chained cleanup never ran: {done.stderr}")
                    self.assertEqual(marker.read_text().strip(), f"ran {status}")
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


# A line that calls git_fixture_trap_exit (not a comment naming it).
TRAP_EXIT_CALL = re.compile(r"^[^#]*\bgit_fixture_trap_exit\b")
# The callers cmux#41447 moved to git_fixture_trap_exit; each must be among those run below.
CMUX_41447_CALLERS = (
    "scripts/ci/tests/feat-parity-check.test.sh",
    "scripts/ci/tests/ios-sim-fetch-commit.test.sh",
    "scripts/ci/tests/run-webviews-tests-retry.test.sh",
    "scripts/cmux-next/tests/check-react-pages.test.sh",
)
# Logs every path mktemp makes (the caller's own temp dirs and the helper's folder), wherever it puts them.
MKTEMP_LOG = 'mktemp() { local p; p=$(command mktemp "$@") || return; printf "%s\\n" "$p" >>"$PROBE_LOG"; printf "%s\\n" "$p"; }\n'


def trap_exit_callers() -> list[str]:
    """Tracked shell files that hand their exit cleanup to git_fixture_trap_exit."""
    listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z", "--", "*.sh"], capture_output=True, text=True,
                            check=True, timeout=120, stdin=subprocess.DEVNULL).stdout.split("\0")
    lib = LIB.relative_to(ROOT).as_posix()
    return [rel for rel in listed if rel and rel != lib and (ROOT / rel).is_file()
            and any(TRAP_EXIT_CALL.match(line) for line in (ROOT / rel).read_text(errors="replace").splitlines())]


class EveryTrapExitCallerUnderErrexit(unittest.TestCase):
    """Every real caller of git_fixture_trap_exit, failed under `set -e` right after its call, leaves nothing.

    Codex F1 (P1) on cmux#41447: at 505f0f5c the helper's EXIT trap restored the status with `(exit "$status")`,
    which under `set -e` ended the trap before the caller's cleanup ran, so a failing feat-parity-check.test.sh (and
    each caller #41447 converted) left its temp workspace. Each caller here runs as itself (its own lines up to and
    including its first git_fixture_trap_exit, from its own folder), then fails with `false`.
    """

    def test_each_caller_keeps_status_1_and_removes_every_temp_dir(self):
        callers = trap_exit_callers()
        self.assertFalse(set(CMUX_41447_CALLERS) - set(callers), "a cmux#41447 caller no longer calls the helper")
        for rel in callers:
            with self.subTest(caller=rel):
                tmp = Path(tempfile.mkdtemp(prefix="git-fixture-caller-"))
                self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)], check=False)
                env = Env.clean(tmp)
                log = tmp / "mktemp.log"
                env["PROBE_LOG"] = str(log)
                lines = (ROOT / rel).read_text(errors="replace").splitlines()
                cut = next(index for index, line in enumerate(lines) if TRAP_EXIT_CALL.match(line))
                head = "\n".join(lines[:cut + 1]).replace("${BASH_SOURCE[0]}", "$0")
                done = subprocess.run(["bash", "-c", MKTEMP_LOG + head + "\nset -e\nfalse\necho unreachable\n",
                                       str(ROOT / rel)], env=env, capture_output=True, text=True, timeout=300,
                                      stdin=subprocess.DEVNULL, cwd=ROOT)
                self.assertEqual(done.returncode, 1, done.stderr[-2000:])
                self.assertNotIn("unreachable", done.stdout)
                made = log.read_text().split() if log.exists() else []
                self.assertTrue(made, f"{rel} made no temp dir before its git_fixture_trap_exit")
                left = [path for path in made if os.path.lexists(path)]
                self.assertEqual(left, [], f"{rel} failed under set -e and left: {left}\n{done.stderr[-2000:]}")
                self.assertEqual(sorted(os.listdir(env["TMPDIR"])), [], "the fixture folder was left")


class SavedTrapAndSubshellSource(unittest.TestCase):
    """The review of hq#9676, ported (guard-causes-the-harm): the helper's own EXIT guard skipped the cleanup it exists
    for.

    F1: `saved=$(trap -p EXIT); eval "$saved"` handed the helper's own dispatcher to the wrapper as the caller's
    action, so at exit the dispatcher eval'd itself until bash segfaulted and the caller's cleanup never ran.
    F2: `(unset GIT_CONFIG_GLOBAL; source lib)` made a folder in the subshell, but the guard read the parent's trap
    text (a subshell still shows it) and never armed EXIT there, so the subshell's folder stayed behind.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-saved-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)
        self.tmpdir = Path(self.env["TMPDIR"])

    def bash(self, script: str, *args: str) -> subprocess.CompletedProcess[str]:
        subprocess.run(["rm", "-rf", str(self.tmpdir)], check=True)
        self.tmpdir.mkdir()
        return subprocess.run(["bash", "-c", script, "_", str(LIB), *args], env=self.env, capture_output=True,
                              text=True, timeout=120, stdin=subprocess.DEVNULL, cwd=self.tmp)

    def test_sourcing_twice_and_restoring_a_saved_exit_trap_runs_the_caller_cleanup_once(self):
        for saved in ("saved=$(trap -p EXIT)", "saved=$(trap -p)"):
            with self.subTest(saved=saved):
                marker = self.tmp / "cleanup"
                marker.unlink(missing_ok=True)
                done = self.bash('trap \'echo cleanup >>"$2"\' EXIT\nsource "$1"\nsource "$1"\n'
                                 + saved + '\neval "$saved"\nexit 5\n', str(marker))
                self.assertEqual(done.returncode, 5, f"exit {done.returncode} (-11 is a segfault): "
                                                     f"{done.stderr[-2000:]}")
                self.assertTrue(marker.exists(), "the caller's cleanup never ran")
                self.assertEqual(marker.read_text(), "cleanup\n", "the caller's cleanup did not run exactly once")
                self.assertEqual(sorted(os.listdir(self.tmpdir)), [], "a fixture folder was left")

    def test_a_subshell_source_removes_both_folders(self):
        for errexit in ("", "set -euo pipefail; "):
            with self.subTest(errexit=bool(errexit)):
                marker = self.tmp / "folders"
                marker.unlink(missing_ok=True)
                done = self.bash(
                    errexit + 'source "$1"\nfirst=${GIT_CONFIG_GLOBAL%/*}\n'
                    '(unset GIT_CONFIG_GLOBAL; source "$1"; second=${GIT_CONFIG_GLOBAL%/*}\n'
                    ' [[ -d $second && $second != "$first" ]] || exit 9; echo "$second" >"$2")\n'
                    '[[ -d $first ]] || exit 8\nexit 0\n', str(marker))
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertTrue(marker.exists(), "the subshell never made its own folder, so this case tests nothing")
                self.assertEqual(sorted(os.listdir(self.tmpdir)), [], f"a fixture folder was left: {done.stderr}")


    def test_a_saved_exit_trap_comes_back_after_it_was_cleared(self):
        """The review of hq#9715 F2, ported: `saved=$(trap -p EXIT); trap - EXIT; eval "$saved"` must bring the
        caller's action back. `trap -p` printed this file's own dispatcher, the restore ignored it, and the cleared
        action stayed gone. Under `set -e` too: a dispatcher that restores $? with `(exit "$status")` is stopped by
        errexit before the restored action runs (cmux#41195 F1, cmux#41677)."""
        for errexit in ("", "set -euo pipefail; "):
            for when in ("before", "after"):
                for saved in ("saved=$(trap -p EXIT)", "saved=$(trap -p)"):
                    with self.subTest(errexit=bool(errexit), trap_set=when, saved=saved):
                        marker = self.tmp / "cleanup"
                        marker.unlink(missing_ok=True)
                        set_trap = 'trap \'echo cleanup >>"$2"\' EXIT\n'
                        script = (errexit + (set_trap if when == "before" else "") + 'source "$1"\n'
                                  + (set_trap if when == "after" else "")
                                  + saved + '\ntrap - EXIT\neval "$saved"\nexit 5\n')
                        done = self.bash(script, str(marker))
                        self.assertEqual(done.returncode, 5, done.stderr[-2000:])
                        self.assertTrue(marker.exists(), f"the restored cleanup never ran: {done.stderr[-2000:]}")
                        self.assertEqual(marker.read_text(), "cleanup\n")
                        self.assertEqual(sorted(os.listdir(self.tmpdir)), [], "a fixture folder was left")

    def test_trap_p_still_lists_other_signals_and_nothing_for_a_cleared_exit(self):
        done = self.bash('source "$1"\ntrap \'echo int\' INT\ntrap \'echo bye\' EXIT\ntrap -p\necho ---\n'
                         'trap - EXIT\ntrap -p EXIT\necho ---\ntrap -p INT\n')
        self.assertEqual(done.returncode, 0, done.stderr)
        listed, cleared, int_only = done.stdout.split("---\n")
        self.assertIn("trap -- 'echo int' SIGINT", listed)
        self.assertIn("trap -- 'echo bye' EXIT", listed)
        self.assertNotIn("_git_fixture", listed, "trap -p showed the helper's own dispatcher")
        self.assertEqual(cleared, "")
        self.assertEqual(int_only.strip(), "trap -- 'echo int' SIGINT")


class TrapMatchesTheBuiltin(unittest.TestCase):
    """The file's `trap` wrapper must print and do what bash's own builtin does, for every form a caller writes.

    Follow-ups to the reviews of hq#9715 and cmux#41713. F1: `trap '' EXIT` was kept as an empty string, the same as
    no caller trap, so `trap -p EXIT` printed nothing instead of `trap -- '' EXIT` and a saved ignored trap was lost.
    F2: `trap -p --` read `--` as a signal name, so the listing showed the helper's dispatcher and not the caller's
    EXIT action. The class of bug is the wrapper reading its arguments differently from the builtin, so this row runs
    each form once under the wrapper and once in plain bash and compares stdout, the exit status and stderr (minus the
    `FILE: line N:` prefix, which names the wrapper's file). Each form also exits through its EXIT action, so what
    runs at exit is compared too. Run on the CI runner's bash and in the `bash:3.2` image (macOS /bin/bash).

    The review of cmux#41772 / hq#9759 (Codex) added the trap state around the wrapper. F1: git_fixture_trap_exit kept
    the "ignored" mark, so `trap '' EXIT; git_fixture_trap_exit 'echo unexpected'; trap '' EXIT; exit 3` printed
    "unexpected". F2: a caller's DEBUG trap ran for the wrapper's own steps and the exit dispatcher's, and a RETURN
    trap set through the wrapper ran as the wrapper returned. The sweep found the dispatcher's status step tripping a
    caller's ERR trap, and the wrapper's own failing steps tripping it again under set -E."""

    def test_a_debug_trap_still_set_at_exit_sees_one_dispatcher_step(self):
        """A DEBUG trap still set at exit runs before each command of the caller's EXIT action, as in plain bash, and
        once more for the dispatcher's first step (the step that hides it, which no trap can skip). It ran seven
        more times before the action and once after it."""
        script = ('n=0; trap \'n=$((n+1)); echo "debug $n"\' DEBUG\n'
                  'trap \'echo "bye $?"; echo "bye again"\' EXIT\nexit 3\n')
        for errexit in ("", "set -euo pipefail\n"):
            with self.subTest(errexit=bool(errexit)):
                tmpdir = self.tmp / f"tmpdir-debug-at-exit-{bool(errexit)}"
                tmpdir.mkdir()
                plain = self.run_side(errexit + script, tmpdir)
                wrapped = self.run_side(errexit + 'source "$1"\n' + script, tmpdir)
                self.assertEqual(plain[1:], (3, ""))
                self.assertEqual(wrapped[1:], (3, ""), wrapped)
                plain_lines, wrapped_lines = plain[0].splitlines(), wrapped[0].splitlines()
                self.assertEqual([line for line in wrapped_lines if not line.startswith("debug")],
                                 [line for line in plain_lines if not line.startswith("debug")])
                self.assertEqual(len(wrapped_lines), len(plain_lines) + 1, wrapped[0])
                self.assertEqual(sorted(os.listdir(tmpdir)), [], "a fixture folder was left")

    # (name, script lines). Each line is followed by `echo "rc=$?"`, and every script ends with a full `trap -p`
    # listing and `exit 3`, so the EXIT action runs and its $? is printed.
    CASES = [
        ("trap and trap -p with nothing set", [r"trap", r"trap -p", r"trap -p EXIT"]),
        ("trap lists everything", [r"""trap 'echo int' INT""", r"""trap 'echo "bye $?"' EXIT""", r"trap"]),
        ("trap -p", [r"""trap 'echo int' INT""", r"""trap 'echo "bye $?"' EXIT""", r"trap -p"]),
        ("trap -p EXIT", [r"""trap 'echo "bye $?"' EXIT""", r"trap -p EXIT"]),
        ("trap -p -- EXIT", [r"""trap 'echo "bye $?"' EXIT""", r"trap -p -- EXIT"]),
        ("trap -p --", [r"""trap 'echo int' INT""", r"""trap 'echo "bye $?"' EXIT""", r"trap -p --"]),
        ("trap -p -- round trip", [r"""trap 'echo "bye $?"' EXIT""", r"saved=$(trap -p --)", r"trap - EXIT",
                                   r'eval "$saved"']),
        ("trap -l", [r"trap -l", r"trap -lp", r"trap -p -l"]),
        ("trap - EXIT", [r"""trap 'echo "bye $?"' EXIT""", r"trap - EXIT", r"trap -p EXIT"]),
        ("trap '' EXIT", [r"trap '' EXIT", r"trap -p EXIT"]),
        ("ignored EXIT round trip", [r"trap '' EXIT", r"saved=$(trap -p EXIT)", r"trap - EXIT", r'eval "$saved"',
                                     r"trap -p EXIT"]),
        ("ignored EXIT round trip, whole listing", [r"trap '' EXIT", r"""trap 'echo int' INT""",
                                                    r"saved=$(trap -p)", r"trap - EXIT INT", r'eval "$saved"']),
        ("ignored before sourcing", [r"trap -p EXIT"]),
        ("ignore after an ignored reset", [r"trap '' EXIT", r"trap - EXIT", r"trap '' EXIT", r"trap -p EXIT",
                                           r"""trap 'echo "bye $?"' EXIT""", r"trap - EXIT", r"trap '' EXIT",
                                           r"trap -p EXIT"]),
        ("ignored and reset before sourcing", [r"trap '' EXIT", r"trap -p EXIT"]),
        ("trap -- action EXIT", [r"""trap -- 'echo "bye $?"' EXIT""", r"trap -p EXIT"]),
        ("trap action 0", [r"""trap 'echo "bye $?"' 0""", r"trap -p 0"]),
        ("trap action 00", [r"""trap 'echo "bye $?"' 00""", r"trap -p 00"]),
        ("SIGEXIT is not a signal", [r"""trap 'echo "bye $?"' SIGEXIT""", r"trap -p SIGEXIT", r"trap - SIGEXIT"]),
        ("lowercase exit", [r"""trap 'echo "bye $?"' exit""", r"trap -p exit", r"trap -p Exit"]),
        ("lowercase exit reset", [r"""trap 'echo "bye $?"' EXIT""", r"trap - Exit"]),
        ("lowercase sigexit", [r"""trap 'echo "bye $?"' sigexit"""]),
        ("several signals in one call", [r"""trap 'echo many' INT EXIT TERM""", r"trap -p INT EXIT TERM",
                                         r"trap - INT EXIT", r"trap -p TERM EXIT INT"]),
        ("trap EXIT resets", [r"""trap 'echo "bye $?"' EXIT""", r"trap EXIT", r"trap -p",
                              r"""trap 'echo "bye $?"' EXIT""", r"trap -- EXIT"]),
        ("a digit first resets every signal", [r"""trap 'echo "bye $?"' EXIT""", r"""trap 'echo int' INT""",
                                               r"trap 0 INT"]),
        ("trap 0 resets", [r"""trap 'echo "bye $?"' EXIT""", r"trap 0"]),
        ("an invalid signal keeps the valid ones", [r"""trap 'echo "bye $?"' NOPE EXIT INT""", r"trap -p NOPE EXIT"]),
        ("usage", [r"trap x"]),
        ("usage after --", [r"trap -- -p"]),
        ("usage with an empty action", [r"trap ''"]),
        ("an unknown option", [r"trap -x"]),
        ("an option-looking signal", [r"trap -p -- -x"]),
        ("quotes in the action", [r"""trap 'echo "it'\''s $?"' EXIT""", r"saved=$(trap -p EXIT)", r"trap - EXIT",
                                  r'eval "$saved"', r"trap -p EXIT"]),
        ("a blank line inside an action", [r"trap $'echo a\n\necho b' INT", r"""trap 'echo "bye $?"' EXIT""",
                                           r"trap -p"]),
        # Review of cmux#41772 / hq#9759, F1: git_fixture_trap_exit left the "ignored" mark set.
        ("git_fixture_trap_exit clears the ignored mark", [r"trap '' EXIT", r"git_fixture_trap_exit 'echo unexpected'",
                                                          r"trap '' EXIT"]),
        ("git_fixture_trap_exit '' after an ignored reset", [r"trap '' EXIT", r"trap - EXIT", r"git_fixture_trap_exit ''",
                                                             r"trap -p EXIT", r"""git_fixture_trap_exit 'echo "bye $?"'""",
                                                             r"trap -p EXIT"]),
        ("git_fixture_trap_exit replaces an action", [r"git_fixture_trap_exit 'echo first'",
                                                      r"""git_fixture_trap_exit 'echo "bye $?"'""", r"trap -p EXIT"]),
        # F2: the caller's DEBUG and RETURN traps ran for the wrapper's own steps. Each row counts or prints what the
        # trap saw, then resets it with the builtin: inside a shell function (the wrapper is one) bash hides DEBUG,
        # RETURN and ERR from `trap -p` and puts a reset one back on return, which no function can change.
        ("a DEBUG trap set through the wrapper", [r"n=0", r"trap 'n=$((n+1))' DEBUG", r"trap 'echo int' INT",
                                                  r"trap -p INT", r"""trap 'echo "bye $?"' EXIT""",
                                                  r"builtin trap - DEBUG", r'echo "debug ran $n times"']),
        ("DEBUG and INT in one call", [r"n=0", r"trap 'n=$((n+1))' DEBUG INT", r"trap -p INT", r"builtin trap - DEBUG",
                                       r'echo "debug ran $n times"']),
        ("DEBUG and EXIT in one call", [r"n=0", r"trap 'n=$((n+1))' DEBUG EXIT", r"trap -p EXIT",
                                        r"builtin trap - DEBUG", r'echo "debug ran $n times"']),
        ("DEBUG ignored through the wrapper", [r"builtin trap 'echo debug' DEBUG", r"trap '' DEBUG", r"echo quiet",
                                               r"builtin trap -p DEBUG", r"builtin trap - DEBUG"]),
        ("a DEBUG trap set with the builtin", [r"n=0", r"builtin trap 'n=$((n+1))' DEBUG", r"trap 'echo int' INT",
                                               r"trap -p INT", r"""trap 'echo "bye $?"' EXIT""",
                                               r"builtin trap - DEBUG", r'echo "debug ran $n times"']),
        ("a RETURN trap set through the wrapper", [r"""trap 'echo "return from ${FUNCNAME[0]-top}"' RETURN""",
                                                   r"f() { :; }; f", r"source /dev/null", r"trap 'echo int' INT",
                                                   r"builtin trap -p RETURN", r"builtin trap - RETURN"]),
        ("RETURN and INT in one call", [r"""trap 'echo "return from ${FUNCNAME[0]-top}"' RETURN INT""",
                                        r"source /dev/null", r"builtin trap -p RETURN", r"builtin trap - RETURN"]),
        ("a RETURN trap set with the builtin", [r"""builtin trap 'echo "return from ${FUNCNAME[0]-top}"' RETURN""",
                                                r"trap 'echo int' INT", r"source /dev/null", r"builtin trap - RETURN"]),
        # The sweep: the exit dispatcher's own steps tripped a caller's ERR trap (three cmux tests set one before
        # sourcing, and a failed test printed a second "exited" line), and the wrapper's own failing steps under set -E.
        ("ERR set through the wrapper, still set at exit", [r"""trap 'echo "err $?"' ERR""",
                                                            r"""trap 'echo "bye $?"' EXIT""", r"false"]),
        ("ERR set before sourcing, still set at exit", [r"""trap 'echo "bye $?"' EXIT""", r"false"]),
        ("ERR under set -E, still set at exit", [r"set -E", r"""trap 'echo "err $?"' ERR""",
                                                 r"""trap 'echo "bye $?"' EXIT""", r"f() { false; }; f"]),
        ("failing trap calls under set -E", [r"set -E", r"""trap 'echo "err $?"' ERR""", r"trap 'echo x' NOPE",
                                             r"trap -p NOPE", r"trap -x", r"trap x"]),
        ("the EXIT action sees the exit command and its status",
         [r"""trap 'echo "cmd=$BASH_COMMAND status=$?"' EXIT""", r"false"]),
        # Review of cmux#41810 / hq#9795: the wrapper isn't plain trap. An EXIT action that set a DEBUG trap had it
        # fire on the dispatcher's appended `exit` (this exited 99, not 3); signals were joined with the caller's
        # IFS (neither trap set, status 0); an action ending in a backslash ran into the appended exit; and the
        # status step tripped ERR with a DEBUG trap live and no EXIT action.
        ("an EXIT action that sets a DEBUG trap", [r"""trap 'trap "exit 99" DEBUG' EXIT"""]),
        ("signals under a caller's IFS", [r"IFS=:", r"trap 'n=1' DEBUG ERR", r"builtin trap -p DEBUG ERR",
                                          r"builtin trap - DEBUG ERR", r"trap 'echo int' INT TERM", r"trap -p INT TERM"]),
        ("an EXIT action ending in a backslash", [r"trap 'echo bye\' EXIT"]),
        ("ERR and DEBUG still set at exit, no EXIT action", [r"""trap 'echo "err $?"' ERR""", r"trap : DEBUG"]),
        # Review of cmux#41844 F1: the wrapper read the caller's traps through a fixed fd 4, so a caller's own fd 4
        # took the reads: a DEBUG trap writing to it under set -T, or xtrace with BASH_XTRACEFD=4, put its text into
        # the step the wrapper ran next, which exited 127 before the body ran.
        ("a DEBUG trap writing to the caller's fd 4 under set -T", [r"exec 4>/dev/null", r"set -T",
                                                                   r"trap 'printf debug >&4' DEBUG",
                                                                   r"trap 'echo int' INT", r"trap -p INT",
                                                                   r"builtin trap - DEBUG"]),
        ("xtrace to the caller's fd 4", [r"exec 4>/dev/null", r"BASH_XTRACEFD=4", r"set -x", r"trap 'echo int' INT",
                                         r"trap -p INT", r"set +x"]),
        # Review of hq#9835 F1: under set -T the wrapper set DEBUG to ignored for its own steps, and bash keeps an
        # "ignored" mark on a signal once it was ignored, so a later `trap '' DEBUG` did nothing.
        ("set -T, then ignore DEBUG", [r"set -T", r"trap 'n=1' INT", r"trap '' DEBUG", r"builtin trap -p DEBUG"]),
        ("the ignored mark outlives set -T", [r"set -T", r"trap 'n=1' INT", r"set +T", r"trap '' DEBUG",
                                              r"builtin trap -p DEBUG"]),
        # Review of cmux#41922 F1: the wrapper suspended an ignored DEBUG trap with `:`, which cleared bash's
        # "ignored" mark, so after `trap - DEBUG` a second `trap '' DEBUG` took effect where plain bash's does not.
        ("ignore, reset, ignore DEBUG under set -T", [r"set -T", r"trap '' DEBUG", r"trap - DEBUG", r"trap '' DEBUG",
                                                      r"trap -p DEBUG", r"builtin trap -p DEBUG"]),
    ]
    # Set before the script (and before sourcing, under the wrapper).
    BEFORE = {"ignored before sourcing": "trap '' EXIT\n",
              "ignored and reset before sourcing": "trap '' EXIT\ntrap - EXIT\n",
              "ERR set before sourcing, still set at exit": "trap 'echo \"err $?\"' ERR\n"}
    # Plain bash has no git_fixture_trap_exit: there it is `trap CMD EXIT`.
    PLAIN = dict.fromkeys([name for name, _ in CASES if name.startswith("git_fixture_trap_exit")],
                          'git_fixture_trap_exit() { builtin trap -- "$1" EXIT; }\n')
    # These keep ERR set until exit, so they end on the builtin's listing of it (the wrapper's own `trap -p` runs in
    # a function, where bash hides ERR).
    TAIL = dict.fromkeys([name for name, _ in CASES if "still set at exit" in name or name.startswith("failing trap")],
                         "echo ==\nbuiltin trap -p ERR\nexit 3\n")
    PREFIX = re.compile(r"^.*?\bline \d+: ", re.M)

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-builtin-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)

    def run_side(self, script: str, tmpdir: Path) -> tuple[str, int, str]:
        done = subprocess.run(["bash", "-c", script, "_", str(LIB)], env={**self.env, "TMPDIR": str(tmpdir)},
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, cwd=self.tmp)
        return done.stdout, done.returncode, self.PREFIX.sub("", done.stderr)

    def test_every_trap_form_matches_the_builtin(self):
        for errexit in ("", "set -euo pipefail\n"):
            for number, (name, lines) in enumerate(self.CASES):
                with self.subTest(errexit=bool(errexit), form=name):
                    # A TMPDIR per form, so a folder one form leaves is charged to that form alone.
                    tmpdir = self.tmp / f"tmpdir-{bool(errexit)}-{number}"
                    tmpdir.mkdir()
                    body = "".join(f'{line}\necho "rc=$?"\n' for line in lines) + self.TAIL.get(
                        name, "echo ==\ntrap -p\nexit 3\n")
                    before = errexit + self.BEFORE.get(name, "")
                    plain = self.run_side(before + self.PLAIN.get(name, "") + body, tmpdir)
                    wrapped = self.run_side(before + 'source "$1"\n' + body, tmpdir)
                    self.assertEqual(wrapped, plain, f"script:\n{before}{body}")
                    self.assertEqual(sorted(os.listdir(tmpdir)), [], "a fixture folder was left")


class RandomTraps:
    """One seeded case for RandomTrapsMatchTheBuiltin: shell options and IFS before sourcing, then trap calls on EXIT,
    DEBUG, ERR and RETURN (actions that install, ignore or reset other traps, nested two deep, some ending in a
    backslash or a failing step), plain steps, and an exit status. Every action prints a tag (E1, D2, ...), and the
    signals each tag was set on are kept, so the comparison knows which lines a DEBUG trap printed. A leaf whose
    signals include DEBUG also prints the first word of the command it ran before and the function it ran in
    (`D2:trap@top 0`): the function is how the comparison tells a run for the wrapper's own steps (`@trap`,
    `@_git_fixture_exit_prep`, which plain bash never shows) from the caller's. The word alone cannot: inside a trap
    action BASH_COMMAND stays the command the trap interrupted. The tags of leaves that fail are kept (`fails`):
    only those can run an ERR trap from inside a DEBUG run."""

    SIGNALS = ["EXIT", "DEBUG", "ERR", "RETURN"]
    IFS_VALUES = [None, ":", "", " ", "x", "EDX"]
    STEPS = ["false", "true", "f", "g", "source /dev/null", "echo body", "(exit 5)", "false || true", "trap -p EXIT"]

    def __init__(self, seed: int):
        self.r = random.Random(seed)
        self.count = 0
        self.signals_of: dict[str, set[str]] = {}
        self.fails: set[str] = set()
        self.flags = [flag for flag in ("-E", "-T", "-e") if self.r.random() < 0.3]

    @staticmethod
    def quote(text: str) -> str:
        return "'" + text.replace("'", "'\\''") + "'"

    def leaf(self, signals: list[str]) -> str:
        self.count += 1
        tag = f"{signals[0][0]}{self.count}"
        self.signals_of[tag] = set(signals)
        shown = f"{tag}:${{BASH_COMMAND%% *}}@${{FUNCNAME[0]-top}}" if "DEBUG" in signals else tag
        choice = self.r.randrange(7)
        if choice == 0:
            return f'echo "{shown}"\\'
        if choice == 1:
            self.fails.add(tag)
            return f'echo "{shown} $?"; false'
        if choice == 2 and signals[0] == "EXIT":
            return f'echo "{shown} $?"; exit {self.r.choice([0, 4, 99])}'
        if "DEBUG" in signals:
            return f'echo "{shown} $?"'
        if signals[0] == "RETURN":
            return f'echo "{tag} ${{FUNCNAME[0]-top}}"'
        return f'echo "{tag} $?"'

    def reset(self, signals: list[str]) -> str:
        """`trap - SIGNAL...`, through the builtin for the resets no function can make (bash puts DEBUG and RETURN
        back as a function returns unless set -T is on, and ERR unless set -E is: see the wrapper)."""
        needs = {"DEBUG": "-T", "RETURN": "-T", "ERR": "-E"}
        wrapped = [s for s in signals if s not in needs or needs[s] in self.flags]
        builtin = [s for s in signals if s not in wrapped]
        return "; ".join(([f"trap - {' '.join(wrapped)}"] if wrapped else [])
                         + ([f"builtin trap - {' '.join(builtin)}"] if builtin else []))

    def action(self, signals: list[str], depth: int) -> str:
        if depth < 2 and self.r.random() < 0.35:
            inner = self.r.sample(self.SIGNALS, self.r.choice([1, 1, 2]))
            op = self.r.random()
            if op < 0.7:
                install = f"trap {self.quote(self.action(inner, depth + 1))} {' '.join(inner)}"
            elif op < 0.85:
                install = f"trap '' {' '.join(inner)}"
            else:
                install = self.reset(inner)
            parts = [self.leaf(signals), install]
            self.r.shuffle(parts)
            if parts[0].endswith("\\"):  # a trailing backslash only ends an action
                parts.reverse()
            return "; ".join(parts)
        return self.leaf(signals)

    def step(self) -> str:
        if self.r.randrange(10) < 4:
            signals = self.r.sample(self.SIGNALS, self.r.choice([1, 1, 1, 2, 3]))
            op = self.r.random()
            if op < 0.75:
                return f"trap {self.quote(self.action(signals, 0))} {' '.join(signals)}"
            if op < 0.88:
                return f"trap '' {' '.join(signals)}"
            return self.reset(signals)
        if "-T" in self.flags and "-E" in self.flags and self.r.random() < 0.1:
            return "trap -p"  # with both on, a function sees every trap, so the whole listing must match
        return self.r.choice(self.STEPS)

    def script(self) -> tuple[str, str]:
        """(before, body): `before` runs before sourcing the file, `body` after it."""
        before = [f"set {flag}" for flag in self.flags]
        ifs = self.r.choice(self.IFS_VALUES)
        if ifs is not None:
            before.append(f"IFS={self.quote(ifs)}")
        before.append("f() { false; }; g() { :; }")
        body = [self.step() for _ in range(self.r.randint(1, 6))]
        body += ["echo @exit", self.r.choice(["exit 0", "exit 3", "false", "true", "exit 141"])]
        return "\n".join(before) + "\n", "\n".join(body) + "\n"

    def signals(self, line: str) -> set[str]:
        tag = re.match(r"([A-Z]\d+)", line)
        return self.signals_of.get(tag.group(1), set()) if tag else set()

    def tag_fn(self, line: str) -> tuple[str | None, str | None]:
        """(tag, the function a DEBUG leaf ran in), or (tag, None) for a line no DEBUG leaf printed. A leaf that ends
        in a backslash prints one after the function's name, and only that one is set aside here: a second is no
        function's name, so the line is compared as the caller's (review of hq#9885 F1)."""
        found = re.match(r"([A-Z]\d+)(?::(\S*))?", line[:-1] if line.endswith("\\") else line)
        if not found:
            return None, None
        token = found.group(2)
        return found.group(1), (token.rsplit("@", 1)[1] if token is not None and "@" in token else None)

    @staticmethod
    def own(fn: str | None) -> bool:
        """A function of the wrapper's: plain bash has no function named trap, and no _git_fixture_ ones."""
        return fn is not None and (fn == "trap" or fn.startswith("_git_fixture") or fn.startswith("git_fixture"))

    def internal(self, line: str) -> bool:
        tag, fn = self.tag_fn(line)
        return bool(tag and "DEBUG" in self.signals_of.get(tag, set()) and self.own(fn))

    def normal(self, line: str) -> str:
        """The caller's own function names in a DEBUG line made `*`, and bash's FUNCNAME loss after errexit in a
        function (it drops FUNCNAME once the EXIT trap calls any function) made `*` in a RETURN line. A trailing
        backslash (an action ending in one prints it) is kept and compared exactly: dropping every one hid a run that
        lost it or doubled it (review of hq#9885 F1)."""
        tag, fn = self.tag_fn(line)
        if fn is not None and not self.own(fn):
            line = re.sub(r"^([A-Z]\d+:\S*)@[^\s\\]*", r"\1@*", line)
        return re.sub(r"^(R\d+) (?:f|g|top)(\\?)$", r"\1 *\2", line)

    def skip_err(self, lines: list[str], at: int, tag: str) -> int:
        """At most one ERR run right after a DEBUG run at a wrapper step, and only when that DEBUG leaf fails. An
        action set on both DEBUG and ERR prints the same line for either run, so such a line counts once per signal:
        as this ERR run, which runs inside the wrapper only under set -E (review of cmux#41922 F2, seed 1238)."""
        if (tag in self.fails and at < len(lines) and "ERR" in self.signals(lines[at])
                and (not self.internal(lines[at]) or "-E" in self.flags)):
            return at + 1
        return at

    def allowed(self, plain: tuple[str, int, str], wrapped: tuple[str, int, str]) -> bool:
        """The documented differences, each bounded by count and position (see RandomTrapsMatchTheBuiltin). Status
        and stderr always match. A DEBUG run in a function of the wrapper's is allowed only where the bound puts it:
        under set -T, at most three per wrapper call (bash's run as the function is entered, then `local`, then the
        suspend), right after the DEBUG run at that call; and under set -T at exit, at most two in
        _git_fixture_exit_prep (entry, then its suspend), once. One more DEBUG run is allowed once, for
        the dispatcher's first step, after the last line the script body printed, and prep's two come right after it.
        Each may be followed by one ERR run when its DEBUG leaf fails (under set -E, inside the wrapper). After those
        are taken out, the wrapped output must equal the plain one line for line: no DEBUG line may go missing and no
        other line may be added."""
        if plain[1:] != wrapped[1:]:
            return False
        p = [self.normal(line) for line in plain[0].splitlines()]
        w = [self.normal(line) for line in wrapped[0].splitlines()]
        traced = "-T" in self.flags
        kept: list[str] = []
        anchor = None  # the tag of the kept DEBUG run just before: a wrapper call there may show one group
        err_ok = False
        prep_at = None  # where in `kept` prep's steps came: they must follow the dispatcher's first step
        at = 0
        while at < len(w):
            line = w[at]
            tag, fn = self.tag_fn(line)
            if self.internal(line):
                # Any DEBUG tag: a DEBUG action that sets another DEBUG trap changes which one runs for the wrapper's
                # next step (seed 32: E7's action set D6, whose own action set D5).
                if not traced or anchor is None:
                    return False
                if fn == "trap":
                    limit = 3
                elif fn == "_git_fixture_exit_prep" and prep_at is None:
                    prep_at, limit = len(kept), 2
                else:
                    return False
                count = 0
                while count < limit and at < len(w) and self.internal(w[at]) and self.tag_fn(w[at])[1] == fn:
                    count += 1
                    at = self.skip_err(w, at + 1, self.tag_fn(w[at])[0])
                anchor = None
                continue
            kept.append(line)
            if fn is not None and tag and "DEBUG" in self.signals_of.get(tag, set()):
                anchor, err_ok = tag, tag in self.fails
            elif anchor and err_ok and "ERR" in self.signals(line):
                err_ok = False  # the plain run's own ERR run for that DEBUG run: the group may still follow it
            else:
                anchor = None
            at += 1
        if kept == p:
            return prep_at is None
        # The dispatcher's first step: one DEBUG run (and its ERR run when it fails), after the body's last line.
        # Prep's steps, when shown, come right after it: prep is that step (review of hq#9885 F2: bounded by count
        # alone, they passed anywhere a DEBUG run came before them, inside the body too).
        extra = len(kept) - len(p)
        if extra not in (1, 2):
            return False
        body_end = max((index + 1 for index, line in enumerate(kept) if not self.tag_fn(line)[0]), default=0)
        starts = range(body_end, len(kept) - extra + 1) if prep_at is None else [prep_at - extra]
        for start in starts:
            if start < body_end:
                return False
            block = kept[start:start + extra]
            tag = self.tag_fn(block[0])[0]
            if (kept[:start] + kept[start + extra:] == p and "DEBUG" in self.signals(block[0])
                    and (extra == 1 or (tag in self.fails and "ERR" in self.signals(block[1])))):
                return True
        return False


class RandomTrapsAllowanceIsBounded(unittest.TestCase):
    """The detector for the detector (review of cmux#41844 / hq#9835 F2): the comparator used to drop every DEBUG
    line under set -T and accept any number of extra ERR lines, so it passed the regressions it is meant to catch.
    Each row here is a wrapped output the bound forbids, which RandomTraps.allowed must reject, and one it permits.
    The lines are what the leaves print: `D1:WORD@FUNCTION STATUS` for the DEBUG leaf, `E2 STATUS` for the ERR one."""

    PLAIN = "D1:echo@top 0\nbody\nD1:trap@top 0\nD1:echo@top 0\n@exit\nD1:exit@top 0\n"
    # Bash's run as the wrapper is entered (BASH_COMMAND is still the call), `local`, then the suspend.
    GROUP = ('D1:trap@trap 0\nE2 1\nD1:local@trap 0\nE2 1\n'
             'D1:"${_git_fixture_suspend_cmd[${#_git_fixture_t_debug}@trap 0\n')
    # Inside the EXIT trap BASH_COMMAND stays the command that exited, so the dispatcher's first step reads `exit`.
    DISPATCH = "D1:exit@top 3\n"
    PREP = 'D1:exit@_git_fixture_exit_prep 0\nD1:"${_git_fixture_suspend_cmd[${#2}@_git_fixture_exit_prep 0\n'

    def judge(self, flags: list[str], wrapped: str) -> bool:
        case = RandomTraps(0)
        case.flags = flags
        case.signals_of = {"D1": {"DEBUG"}, "E2": {"ERR"}}
        case.fails = {"D1"}
        return case.allowed((self.PLAIN, 3, ""), (wrapped, 3, ""))

    def forbidden(self) -> list[tuple[str, str]]:
        """(name, wrapped output) rows the bound forbids, each one past an allowance."""
        lines = self.PLAIN.splitlines(keepends=True)
        head, tail = "".join(lines[:3]), "".join(lines[3:])
        return [
            ("every DEBUG line dropped", "".join(line for line in lines if not line.startswith("D"))),
            ("1000 DEBUG/ERR pairs added", self.PLAIN + "D1:echo@top 0\nE2 1\n" * 1000),
            ("1000 wrapper groups after one trap call", head + self.GROUP * 1000 + tail),
            ("four wrapper steps in one call", head + self.GROUP + "D1:local@trap 0\n" + tail),
            ("two ERR runs after one wrapper step", head + self.GROUP.replace("E2 1\n", "E2 1\nE2 1\n", 1) + tail),
            ("a group with no DEBUG run before it", self.GROUP + self.PLAIN),
            ("a group after a line no DEBUG trap printed", "".join(lines[:2]) + self.GROUP + "".join(lines[2:])),
            ("the dispatcher's step twice", self.PLAIN + self.DISPATCH * 2),
            ("the dispatcher's step before the body", self.DISPATCH + self.PLAIN),
            ("prep's steps twice", self.PLAIN + self.DISPATCH + self.PREP * 2),
            # Review of hq#9885 F2: prep's allowance was bounded by count, not by place. Prep runs from the EXIT trap,
            # right after the dispatcher's first step, never inside the body.
            ("prep's steps before the body ends", head + self.PREP + tail),
            ("prep's steps before the body ends, the dispatcher's step after it",
             head + self.PREP + tail + self.DISPATCH),
        ]

    def test_the_allowance_rejects_what_its_bound_forbids(self):
        for flags in (["-T"], []):
            for name, wrapped in self.forbidden():
                with self.subTest(flags=flags, row=name):
                    self.assertFalse(self.judge(flags, wrapped), name)

    def test_the_allowance_accepts_what_its_bound_permits(self):
        lines = self.PLAIN.splitlines(keepends=True)
        head, tail = "".join(lines[:3]), "".join(lines[3:])
        self.assertTrue(self.judge(["-T"], head + self.GROUP + tail + self.DISPATCH + self.PREP))
        self.assertTrue(self.judge([], self.PLAIN + self.DISPATCH + "E2 1\n"))
        self.assertFalse(self.judge([], head + self.GROUP + tail), "without set -T no wrapper step is seen")
        self.assertFalse(self.judge([], self.PLAIN + self.DISPATCH + self.PREP), "without set -T prep is not seen")

    def test_a_shared_debug_and_err_action_counts_once_per_signal(self):
        """Review of cmux#41922 F2 (seed 1238: `trap '...; false' ERR DEBUG RETURN` under set -ET): one action set on
        DEBUG and ERR prints the same line for its DEBUG run at a wrapper step and for the ERR run that run's failure
        starts, and skip_err took no line a DEBUG leaf printed, so each ERR run counted as one more wrapper step. Such
        a line is that DEBUG run's ERR run once, and only under set -E (without it no ERR trap runs in a function)."""
        case = RandomTraps(0)
        case.signals_of, case.fails = {"E1": {"ERR", "DEBUG"}}, {"E1"}
        plain = "E1:trap@top 0\nE1:trap@top 1\n@exit\n"
        step = ('E1:trap@trap 0\nE1:trap@trap 1\nE1:local@trap 0\nE1:local@trap 1\n'
                'E1:"${_git_fixture_suspend_cmd[${#_git_fixture_t_debug}@trap 0\n'
                'E1:"${_git_fixture_suspend_cmd[${#_git_fixture_t_debug}@trap 1\n')
        head, tail = "E1:trap@top 0\nE1:trap@top 1\n", "@exit\n"

        def judge(flags: list[str], wrapped: str) -> bool:
            case.flags = flags
            return case.allowed((plain, 3, ""), (wrapped, 3, ""))

        self.assertTrue(judge(["-T", "-E"], head + step + tail), "three steps, each with its ERR run")
        self.assertFalse(judge(["-T"], head + step + tail), "without set -E those are six DEBUG runs")
        self.assertFalse(judge(["-T", "-E"], head + step + step.splitlines(keepends=True)[0] + tail),
                         "a fourth DEBUG run")
        self.assertFalse(judge(["-T", "-E"], head + step.replace("@trap 1\n", "@trap 1\nE1:trap@trap 1\n", 1) + tail),
                         "two ERR runs after one DEBUG run")

    def test_an_action_ending_in_a_backslash_is_compared_exactly(self):
        """Review of hq#9885 F1: the comparator dropped every trailing backslash before comparing, so a wrapped run
        that lost the one an action's output ends in, or doubled it, matched plain bash. A leaf that ends in a
        backslash prints exactly one (`D1:echo@top\\`, `E2\\`); only the parse of a DEBUG line's function sets it
        aside."""
        case = RandomTraps(0)
        case.signals_of, case.fails, case.flags = {"D1": {"DEBUG"}, "E2": {"ERR"}}, set(), ["-T"]
        plain = "D1:echo@top\\\nE2\\\n@exit\n"
        self.assertTrue(case.allowed((plain, 3, ""), (plain, 3, "")))
        for name, wrapped in (("the DEBUG line's backslash lost", "D1:echo@top\nE2\\\n@exit\n"),
                              ("the DEBUG line's backslash doubled", "D1:echo@top\\\\\nE2\\\n@exit\n"),
                              ("the ERR line's backslash lost", "D1:echo@top\\\nE2\n@exit\n"),
                              ("the ERR line's backslash doubled", "D1:echo@top\\\nE2\\\\\n@exit\n")):
            with self.subTest(row=name):
                self.assertFalse(case.allowed((plain, 3, ""), (wrapped, 3, "")), name)


class RandomTrapsMatchTheBuiltin(unittest.TestCase):
    """The detector for the class "the wrapper isn't plain trap" (review of cmux#41810 / hq#9795): seeded random trap
    programs, each run through plain bash and through the file's wrapper, compared on stdout, exit status and stderr
    (minus the `FILE: line N:` prefix). The review's four cases each fail here at the base (cmux 86713638, hq 9b216fe6):
    an EXIT action that set a DEBUG trap had it fire on the dispatcher's appended `exit` (`trap 'trap "exit 99" DEBUG'
    EXIT; exit 3` exited 99), signals were joined with the caller's IFS (`IFS=:` set neither DEBUG nor ERR, and the
    call still succeeded), an action ending in a backslash ran into the appended exit, and the dispatcher's status
    step tripped ERR when a DEBUG trap was live and no EXIT action was set.

    The allow-list, each entry bounded by count and position in RandomTraps.allowed (the review of cmux#41844 / hq#9835
    F2 found it dropping every DEBUG line under set -T and taking any number of ERR lines, so it could not fail;
    RandomTrapsAllowanceIsBounded holds it to the bound): one run of a DEBUG trap still set at exit, for the
    dispatcher's first step (test_a_debug_trap_still_set_at_exit_sees_one_dispatcher_step); under set -T, three runs
    per wrapper call (entry, `local`, the suspend), right after the run for that `trap` call, and two at exit; one ERR run after each of those when
    the DEBUG action fails; and bash's own FUNCNAME loss after errexit in a function (any function the EXIT trap
    calls drops it: `set -e; f() { false; }; trap 'g; echo "${FUNCNAME[0]-top}"' EXIT; f` prints top). A DEBUG
    action prints the function it ran in, which is how a run for the wrapper's own step is told from the caller's.
    Seeds are fixed so a failure names the program that shows it; GIT_FIXTURE_TRAP_SEEDS=N runs
    more."""

    SEEDS = int(os.environ.get("GIT_FIXTURE_TRAP_SEEDS", "300"))
    PREFIX = re.compile(r"^.*?\bline \d+: ", re.M)

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="git-fixture-random-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)], check=False)
        self.env = Env.clean(self.tmp)

    def run_side(self, script: str) -> tuple[str, int, str]:
        done = subprocess.run(["bash", "-c", script, "_", str(LIB)], env=self.env, capture_output=True, text=True,
                              timeout=60, stdin=subprocess.DEVNULL, cwd=self.tmp)
        return done.stdout, done.returncode, self.PREFIX.sub("", done.stderr)

    def test_random_trap_programs_match_the_builtin(self):
        failures = []
        for seed in range(self.SEEDS):
            case = RandomTraps(seed)
            before, body = case.script()
            plain = self.run_side(before + body)
            wrapped = self.run_side(before + 'source "$1"\n' + body)
            if not case.allowed(plain, wrapped):
                failures.append(f"seed {seed}:\n{before}{body}plain:   {plain!r}\nwrapped: {wrapped!r}")
        self.assertEqual(failures, [], f"{len(failures)} of {self.SEEDS} differ; first:\n" + "\n\n".join(failures[:3]))
        self.assertEqual(sorted(os.listdir(self.env["TMPDIR"])), [], "a fixture folder was left")


class CallerIFS(unittest.TestCase):
    """The differential sweep of the review of cmux#41810 / hq#9795 found the file splitting git's redirect list with
    the caller's IFS: under `IFS=:` the list was one word, so a test run from a git hook kept GIT_DIR and its fixture
    commits went to the hook's repository. Red at the base (GIT_DIR and GIT_INDEX_FILE survived sourcing)."""

    def test_a_caller_ifs_still_unsets_the_repo_redirects(self):
        tmp = Path(tempfile.mkdtemp(prefix="git-fixture-ifs-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)], check=False)
        env = Env.clean(tmp)
        for ifs in (":", "", "x", " "):
            with self.subTest(ifs=ifs):
                script = (f"IFS='{ifs}'\nexport GIT_DIR=/nonexistent GIT_INDEX_FILE=/nonexistent/index\n"
                          'source "$1"\necho "${GIT_DIR-unset} ${GIT_INDEX_FILE-unset}"\n')
                done = subprocess.run(["bash", "-c", script, "_", str(LIB)], env=env, capture_output=True, text=True,
                                      timeout=60, stdin=subprocess.DEVNULL, cwd=tmp)
                self.assertEqual((done.stdout, done.returncode), ("unset unset\n", 0), done.stderr)
        self.assertEqual(sorted(os.listdir(env["TMPDIR"])), [], "a fixture folder was left")


class Bash32(unittest.TestCase):
    """The review of hq#9715 F1, ported: macOS's /bin/bash is 3.2, which has no $BASHPID, so a `set -u` caller died
    sourcing the file ("BASHPID: unbound variable"). bash 4+ always sets BASHPID, so no run here can reproduce that;
    this row rejects the bash-4-only names in the file's code. The real check is this whole file under a bash 3.2
    (the `bash:3.2` container image, or a stock Mac): `python3 -I tests/test_git_fixture_cleanup.py`."""

    # `{name}>` (a free fd bash picks) is bash 4.1: the file probes for a closed fd instead (review of cmux#41844 F1).
    BASH4_ONLY = re.compile(r"\bBASHPID\b|\bmapfile\b|\breadarray\b|\bcoproc\b|\b(?:declare|local|typeset) -[a-zA-Z]*[An]"
                            r"|\$\{[^}]*(?:,,|\^\^)[^}]*\}|&>>|\|&|(?<![$\w])\{[A-Za-z_]\w*\}[<>]")

    def test_the_file_uses_no_bash_4_only_name(self):
        hits = []
        for number, line in enumerate(LIB.read_text().splitlines(), 1):
            code = re.sub(r"(^|\s)#.*$", "", line)
            if self.BASH4_ONLY.search(code):
                hits.append(f"{number}: {line.strip()}")
        self.assertEqual(hits, [], "bash 3.2 (macOS /bin/bash) lacks these")

    def test_sourcing_under_set_u_in_the_running_bash(self):
        tmp = Path(tempfile.mkdtemp(prefix="git-fixture-bash32-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)], check=False)
        env = Env.clean(tmp)
        done = subprocess.run(["bash", "-c", 'set -u; source "$1"; echo "ok $BASH_VERSION"', "_", str(LIB)], env=env,
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL, cwd=tmp)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue(done.stdout.startswith("ok "), done.stdout)
        self.assertEqual(sorted(os.listdir(env["TMPDIR"])), [])


if __name__ == "__main__":
    unittest.main()
