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


if __name__ == "__main__":
    unittest.main()
