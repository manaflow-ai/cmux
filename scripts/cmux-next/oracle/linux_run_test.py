#!/usr/bin/env python3
"""Hermetic tests for linux_run.sh: cleanup and isolation of tree builds and diff runs.

Run: python3 -I scripts/cmux-next/oracle/linux_run_test.py (Linux, stdlib unittest; needs git,
flock and setsid). Fake `cargo`, `rustc` and `zig` on PATH stand in for the toolchain (fake cargo
sleeps, then writes target/<profile>/cmux-tui and fails if its tree was removed under it), a
throwaway repo with a ghostty-next gitlink stands in for cmux, and a fake oracle.py beside a copy
of the script stands in for the oracle run.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = Path(os.environ.get("LINUX_RUN_SH") or HERE / "linux_run.sh")

FAKE_CARGO = r'''#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
if args[:1] == ["-V"]:
    print("cargo 0.0.0-fake")
    sys.exit(0)
state = os.environ["FAKE_STATE"]
with open(os.path.join(state, "cargo.pids"), "a") as handle:
    handle.write(f"{os.getpid()}\n")
if os.environ.get("CMUX_GHOSTTY_SRC"):
    sys.exit("CMUX_GHOSTTY_SRC is set")
if not os.path.isfile("../ghostty-next/build.zig"):
    sys.exit("ghostty-next is not checked out")
profile = args[args.index("--profile") + 1]
time.sleep(float(os.environ.get("FAKE_CARGO_SLEEP", "0")))
if not os.path.isfile("Cargo.toml"):
    sys.exit("the tree was removed under the build")
if os.environ.get("FAKE_CARGO_FAIL"):
    sys.exit(101)
out = os.path.join(os.environ["CARGO_TARGET_DIR"], {"dev": "debug", "release": "release"}.get(profile, profile))
os.makedirs(out, exist_ok=True)
binary = os.path.join(out, "cmux-tui")
with open(binary, "w") as handle:
    handle.write("#!/bin/sh\necho fake cmux-tui\n")
os.chmod(binary, 0o755)
'''

FAKE_ORACLE = r'''#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
value = lambda name: args[args.index(name) + 1]
state = os.environ["FAKE_STATE"]
driver = subprocess.Popen(["sleep", "300"])
with open(os.path.join(state, "oracle.pids"), "w") as handle:
    handle.write(f"{os.getpid()} {driver.pid}\n")
deadline = time.monotonic() + float(os.environ.get("FAKE_ORACLE_SLEEP", "0"))
while time.monotonic() < deadline and not os.path.exists(os.path.join(state, "oracle.go")):
    time.sleep(0.05)
seen = all(os.access(value(flag), os.X_OK) for flag in ("--base-binary", "--head-binary"))
with open(os.path.join(state, "oracle.seen"), "w") as handle:
    handle.write("binaries present\n" if seen else "binaries missing\n")
driver.kill()
driver.wait()
code = int(os.environ.get("FAKE_ORACLE_EXIT", "0"))
if code == 0:
    with open(os.path.join(value("--out"), "comparison.json"), "w") as handle:
        json.dump({"divergences": 0, "base": value("--base")}, handle)
sys.exit(code if seen else 9)
'''


def write_exe(path: Path, text: str) -> None:
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def alive(pid: int) -> bool:
    try:
        with open(f"/proc/{pid}/stat") as handle:
            return handle.read().split(") ", 1)[1][0] != "Z"
    except (FileNotFoundError, IndexError):
        return False


@unittest.skipUnless(sys.platform.startswith("linux") and shutil.which("flock") and shutil.which("setsid"),
                     "linux_run.sh runs on Linux with flock and setsid")
class LinuxRunTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="linux-run-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.root = self.tmp / "wt"
        self.state = self.tmp / "state"
        self.state.mkdir()
        tools = self.tmp / "tools"
        tools.mkdir()
        write_exe(tools / "cargo", FAKE_CARGO)
        write_exe(tools / "rustc", "#!/bin/sh\necho rustc 0.0.0-fake\n")
        write_exe(tools / "zig", "#!/bin/sh\necho 0.0.0-fake\n")
        scripts = self.tmp / "scripts"
        scripts.mkdir()
        shutil.copy(SCRIPT, scripts / "linux_run.sh")
        write_exe(scripts / "oracle.py", FAKE_ORACLE)
        self.script = scripts / "linux_run.sh"
        home = self.tmp / "home"
        home.mkdir()
        self.env = {
            "PATH": f"{tools}:{os.environ['PATH']}",
            "HOME": str(home),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            "ORACLE_WT_ROOT": str(self.root),
            "FAKE_STATE": str(self.state),
            "LC_ALL": "C",
        }
        self.ghostty = self.tmp / "ghostty-origin"
        self.ghostty.mkdir()
        self.git(self.ghostty, "init", "-q", "-b", "main")
        (self.ghostty / "build.zig").write_text("// fake\n")
        self.git(self.ghostty, "add", "-A")
        self.git(self.ghostty, "commit", "-q", "-m", "ghostty")
        self.repo = self.tmp / "cmux"
        self.repo.mkdir()
        self.git(self.repo, "init", "-q", "-b", "main")
        crate = self.repo / "cmux-tui" / "crates" / "cmux-tui" / "src"
        crate.mkdir(parents=True)
        (crate / "main.rs").write_text("fn main() {}\n")
        (self.repo / "cmux-tui" / "Cargo.toml").write_text("[workspace]\n\n[profile.oracle]\ninherits = \"release\"\n")
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "add", "-q", str(self.ghostty), "ghostty-next")
        self.git(self.repo, "add", "-A")
        self.git(self.repo, "commit", "-q", "-m", "base")
        self.base = self.git(self.repo, "rev-parse", "HEAD").strip()
        (crate / "main.rs").write_text("fn main() { println!(); }\n")
        self.git(self.repo, "commit", "-q", "-am", "head")
        self.head = self.git(self.repo, "rev-parse", "HEAD").strip()
        self.env["ORACLE_REPO"] = str(self.repo)

    def tearDown(self) -> None:
        for pid in self.recorded_pids():
            if alive(pid):
                os.kill(pid, signal.SIGKILL)

    def git(self, cwd: Path, *args: str) -> str:
        return subprocess.run(["git", *args], cwd=cwd, env=self.env, check=True, stdout=subprocess.PIPE, text=True).stdout

    def start(self, *args: str, **env: str) -> subprocess.Popen:
        # Its own session, like a job under timeout(1) or a runner: a group TERM reaches only it.
        return subprocess.Popen([str(self.script), *args], env={**self.env, **env}, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, start_new_session=True)

    def run_script(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        proc = self.start(*args, **env)
        out, err = proc.communicate(timeout=60)
        return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)

    def recorded_pids(self) -> list[int]:
        pids = []
        for name in ("cargo.pids", "oracle.pids"):
            path = self.state / name
            if path.exists():
                pids += [int(x) for x in path.read_text().split()]
        return pids

    def src_entries(self) -> list[str]:
        src = self.root / "src"
        return sorted(os.listdir(src)) if src.is_dir() else []

    def wait_for(self, predicate, what: str, timeout: float = 20) -> None:
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                self.fail(f"timed out waiting for {what}")
            time.sleep(0.05)

    def cargo_started(self, count: int = 1) -> bool:
        path = self.state / "cargo.pids"
        return path.exists() and len(path.read_text().split()) >= count

    def assert_no_leftovers(self) -> None:
        self.assertEqual(self.src_entries(), [])
        self.assertEqual([pid for pid in self.recorded_pids() if alive(pid)], [])

    def test_build_removes_tree_and_second_build_is_a_cache_hit(self) -> None:
        first = self.run_script("build", self.base)
        self.assertEqual(first.returncode, 0, first.stderr)
        binary = first.stdout.strip().splitlines()[-1]
        self.assertTrue(os.access(binary, os.X_OK))
        receipt = json.loads((Path(binary).parent.parent / "build.json").read_text())
        self.assertEqual(receipt["sha"], self.base)
        self.assertEqual(receipt["ghosttyNext"]["gitlink"], receipt["gitlinks"]["ghostty-next"])
        self.assertEqual(receipt["ghosttyNext"]["checkedOut"], receipt["gitlinks"]["ghostty-next"])
        self.assertEqual(self.src_entries(), [])
        second = self.run_script("build", self.base)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("cache hit", second.stderr)
        self.assertEqual(second.stdout.strip().splitlines()[-1], binary)
        self.assert_no_leftovers()

    def test_failed_build_removes_tree(self) -> None:
        result = self.run_script("build", self.base, FAKE_CARGO_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_no_leftovers()

    def test_term_to_the_script_during_cargo_removes_tree_and_cargo(self) -> None:
        proc = self.start("build", self.base, FAKE_CARGO_SLEEP="30")
        self.wait_for(self.cargo_started, "cargo")
        os.kill(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=20)
        self.assertEqual(proc.returncode, 143)
        self.assert_no_leftovers()

    def test_group_term_during_cargo_removes_tree_and_cargo(self) -> None:
        proc = self.start("build", self.base, FAKE_CARGO_SLEEP="30")
        self.wait_for(self.cargo_started, "cargo")
        os.killpg(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=20)
        self.assertEqual(proc.returncode, 143)
        self.assert_no_leftovers()

    def test_term_to_a_job_waiting_for_the_key_leaves_the_other_build_its_tree(self) -> None:
        building = self.start("build", self.base, FAKE_CARGO_SLEEP="3")
        self.wait_for(self.cargo_started, "the first build's cargo")
        waiting = self.start("build", self.base)
        time.sleep(0.5)
        os.killpg(waiting.pid, signal.SIGTERM)
        waiting.communicate(timeout=20)
        self.assertEqual(waiting.returncode, 143)
        self.assertEqual(len(self.src_entries()), 1, "the waiting job removed the running build's tree")
        out, err = building.communicate(timeout=30)
        self.assertEqual(building.returncode, 0, err)
        self.assert_no_leftovers()

    def test_term_to_the_script_while_it_waits_for_the_key_is_prompt(self) -> None:
        building = self.start("build", self.base, FAKE_CARGO_SLEEP="5")
        self.wait_for(self.cargo_started, "the first build's cargo")
        waiting = self.start("build", self.base)
        time.sleep(0.5)
        started = time.monotonic()
        os.kill(waiting.pid, signal.SIGTERM)
        waiting.communicate(timeout=20)
        self.assertEqual(waiting.returncode, 143)
        self.assertLess(time.monotonic() - started, 3, "the TERM waited for the other build")
        building.communicate(timeout=30)
        self.assertEqual(building.returncode, 0)
        self.assert_no_leftovers()

    def test_diff_writes_both_receipts_and_cleans_up(self) -> None:
        out = self.tmp / "run"
        result = self.run_script("diff", self.base, self.head, "--out", str(out))
        self.assertEqual(result.returncode, 0, result.stderr)
        run = json.loads((out / "linux-run.json").read_text())
        self.assertEqual(run["base"]["sha"], self.base)
        self.assertEqual(run["head"]["sha"], self.head)
        self.assertFalse(run["sameBuild"])
        self.assertEqual(run["comparison"], {"divergences": 0, "base": self.base})
        self.assertEqual((self.state / "oracle.seen").read_text(), "binaries present\n")
        self.assert_no_leftovers()

    def test_diff_with_a_reused_out_never_reports_the_old_comparison(self) -> None:
        out = self.tmp / "run"
        self.assertEqual(self.run_script("diff", self.base, self.base, "--out", str(out)).returncode, 0)
        result = self.run_script("diff", self.base, self.head, "--out", str(out), FAKE_ORACLE_EXIT="2")
        self.assertEqual(result.returncode, 2, result.stderr)
        run = json.loads((out / "linux-run.json").read_text())
        self.assertEqual(run["oracle"]["exit"], 2)
        self.assertIsNone(run["comparison"])

    def test_clean_during_a_diff_keeps_the_binaries_it_runs(self) -> None:
        out = self.tmp / "run"
        proc = self.start("diff", self.base, self.head, "--out", str(out), FAKE_ORACLE_SLEEP="30")
        self.wait_for((self.state / "oracle.pids").exists, "oracle.py")
        for args in (("clean", "--targets"), ("diff", self.base, self.base, "--clean", "--out", str(self.tmp / "other"))):
            result = self.run_script(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("kept", result.stderr)
        (self.state / "oracle.go").touch()
        _, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual((self.state / "oracle.seen").read_text(), "binaries present\n")

    def test_term_to_the_script_during_the_oracle_run_stops_oracle_and_its_drivers(self) -> None:
        proc = self.start("diff", self.base, self.head, "--out", str(self.tmp / "run"), FAKE_ORACLE_SLEEP="300")
        self.wait_for((self.state / "oracle.pids").exists, "oracle.py")
        started = time.monotonic()
        os.kill(proc.pid, signal.SIGTERM)
        proc.communicate(timeout=20)
        self.assertEqual(proc.returncode, 143)
        self.assertLess(time.monotonic() - started, 5, "the TERM waited for oracle.py")
        self.assert_no_leftovers()

    def test_reference_is_a_self_contained_mirror(self) -> None:
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "update", "--init", "-q")
        first = self.run_script("build", self.base)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn(f"from {self.repo}/.git/modules/ghostty-next", first.stderr)
        mirror = self.root / "ref" / "ghostty-next.git"
        self.assertFalse((mirror / "objects" / "info" / "alternates").exists())
        # The stores the mirror filled from go away; a new tree of the same gitlink still builds.
        shutil.rmtree(self.repo / ".git" / "modules")
        shutil.rmtree(self.ghostty)
        again = self.run_script("build", self.base, "--features", "other")
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assert_no_leftovers()

    def test_stale_source_trees_are_pruned(self) -> None:
        stale = self.root / "src" / "dead-job"
        stale.mkdir(parents=True)
        old = time.time() - 7 * 3600
        os.utime(stale, (old, old))
        result = self.run_script("build", self.base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(stale.exists())

    def test_timings_under_a_comma_locale(self) -> None:
        locales = subprocess.run(["locale", "-a"], stdout=subprocess.PIPE, text=True, check=False).stdout.split()
        comma = next((name for name in locales if name.lower().replace("-", "") in ("de_de.utf8", "fr_fr.utf8")), None)
        if comma is None:
            self.skipTest("no comma-decimal locale installed")
        result = self.run_script("build", self.base, FAKE_CARGO_SLEEP="1.2", LC_ALL=comma)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((Path(result.stdout.strip().splitlines()[-1]).parent.parent / "build.json").read_text())
        self.assertGreaterEqual(receipt["buildMs"], 1200)


if __name__ == "__main__":
    unittest.main()
