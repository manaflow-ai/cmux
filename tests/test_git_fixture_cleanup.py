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
    runs at exit is compared too. Run on the CI runner's bash and in the `bash:3.2` image (macOS /bin/bash)."""

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
    ]
    # Set before the script (and before sourcing, under the wrapper).
    BEFORE = {"ignored before sourcing": "trap '' EXIT\n",
              "ignored and reset before sourcing": "trap '' EXIT\ntrap - EXIT\n"}
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
                    body = "".join(f'{line}\necho "rc=$?"\n' for line in lines) + "echo ==\ntrap -p\nexit 3\n"
                    before = errexit + self.BEFORE.get(name, "")
                    plain = self.run_side(before + body, tmpdir)
                    wrapped = self.run_side(before + 'source "$1"\n' + body, tmpdir)
                    self.assertEqual(wrapped, plain, f"script:\n{before}{body}")
                    self.assertEqual(sorted(os.listdir(tmpdir)), [], "a fixture folder was left")


class Bash32(unittest.TestCase):
    """The review of hq#9715 F1, ported: macOS's /bin/bash is 3.2, which has no $BASHPID, so a `set -u` caller died
    sourcing the file ("BASHPID: unbound variable"). bash 4+ always sets BASHPID, so no run here can reproduce that;
    this row rejects the bash-4-only names in the file's code. The real check is this whole file under a bash 3.2
    (the `bash:3.2` container image, or a stock Mac): `python3 -I tests/test_git_fixture_cleanup.py`."""

    BASH4_ONLY = re.compile(r"\bBASHPID\b|\bmapfile\b|\breadarray\b|\bcoproc\b|\b(?:declare|local|typeset) -[a-zA-Z]*[An]"
                            r"|\$\{[^}]*(?:,,|\^\^)[^}]*\}|&>>|\|&")

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
