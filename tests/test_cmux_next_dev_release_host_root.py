#!/usr/bin/env python3
"""The DEV Release compile builds from one fixed tree and DerivedData per host, under a host lock.

Xcode's compilation cache keys hold the absolute source and DerivedData paths. #24994 turned the
cache on with a per-runner path (RUNNER_NAME + workspace), and the DEV compile lands on 30+ runner
instances, so a compile only hit the cache when the same instance had built before.
scripts/cmux-next/compile-dev-release.sh builds instead from HOME/.../dev-daily-release/host/src,
cloned from the checkout, into one DerivedData per host, holding flock(2) on the host lock through
a descriptor every child inherits. These run it against stub compilers:

- two runner instances on a host build at the same paths;
- the tree is exactly the checked-out tree (a file an earlier build's checkout had is gone);
- a build that starts while another holds the host root builds per instance at once;
- a wrapper killed with SIGKILL while its compile still runs keeps the root until the compile
  exits, then the next build takes it (no stale lock, no shared tree);
- a failed tree setup builds per instance and releases the lock;
- with the cache off or off a mini nothing touches the host root.
"""
from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK_TOOL = ROOT / "scripts/cmux-next/host_build_lock.py"
REAL = {
    "scripts/cmux-next/compile-dev-release.sh": ROOT / "scripts/cmux-next/compile-dev-release.sh",
    "scripts/cmux-next/host_build_lock.py": LOCK_TOOL,
    "scripts/cmux-next/release-derived-data-path.sh": ROOT / "scripts/cmux-next/release-derived-data-path.sh",
    "scripts/ci/canonical-build-root.sh": ROOT / "scripts/ci/canonical-build-root.sh",
    "scripts/ci/apfs_clone.py": ROOT / "scripts/ci/apfs_clone.py",
}
# A real one on macOS, where /usr/bin/git and /usr/bin/python3 resolve through it; only hashed here.
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR") or (
    subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    if sys.platform == "darwin" else "") or "/Applications/Xcode_26.6.app/Contents/Developer"
# The stub compile: where it ran and what it saw, then the app the script zips. With STUB_HOLD it
# writes its pid to STUB_HOLD and waits for STUB_HOLD.go (a build in progress).
STUB_COMPILE = r'''#!/bin/bash
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
lock="$HOME/Library/Caches/cmux-next-ci/dev-daily-release/host/lock"
locked=false
python3 "$root/scripts/cmux-next/host_build_lock.py" probe "$lock" || locked=true
python3 - "$root" "$1" "$locked" <<'PY' > "$TEST_LOG"
import json, os, subprocess, sys
root, dd, locked = sys.argv[1:]
print(json.dumps({"root": root, "dd": dd, "head": subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
    capture_output=True, text=True).stdout.strip(), "stale": os.path.exists(os.path.join(root, "stale.txt")),
    "locked": locked == "true", "acpmux": os.environ.get("CMUX_NEXT_ACPMUX_BIN", "")}))
PY
if [[ -n "${STUB_HOLD:-}" ]]; then
  echo $$ > "$STUB_HOLD.tmp" && mv "$STUB_HOLD.tmp" "$STUB_HOLD"
  for _ in $(seq 600); do [[ -e "$STUB_HOLD.go" ]] && break; sleep 0.1; done
fi
mkdir -p "$1/Build/Products/Release/cmux NEXT DEV.app"
exit "${STUB_COMPILE_STATUS:-0}"
'''


def write_executable(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


def wait_for(path: Path, seconds: float = 60):
    deadline = time.monotonic() + seconds
    while not path.exists():
        if time.monotonic() > deadline:
            raise AssertionError(f"{path} never appeared")
        time.sleep(0.05)


def probe(lock: Path) -> int:
    return subprocess.run([sys.executable, str(LOCK_TOOL), "probe", str(lock)]).returncode


def wait_free(lock: Path, seconds: float = 30) -> int:
    deadline = time.monotonic() + seconds
    while probe(lock) != 0 and time.monotonic() < deadline:
        time.sleep(0.05)
    return probe(lock)


class HostRootTests(unittest.TestCase):
    def setUp(self):
        if sys.platform != "darwin" and not shutil.which("rsync"):
            self.skipTest("canonical-build-root.sh copies with rsync off macOS")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(os.path.realpath(self.temp.name))
        self.home = self.root / "home"
        self.home.mkdir()
        self.host = self.home / "Library/Caches/cmux-next-ci/dev-daily-release/host"
        self.lock = self.host / "lock"
        self.bin = self.root / "bin"
        write_executable(self.bin / "xcodebuild", '#!/bin/bash\necho "Xcode 26.6"; echo "Build version 17F1"\n')
        write_executable(self.bin / "xcrun", '#!/bin/bash\necho 26A1\n')
        write_executable(self.bin / "ditto", '#!/bin/bash\ntouch "${@: -1}"\n')
        # This interpreter: macOS's /usr/bin/python3 is an xcrun shim (so is git: DEVELOPER_DIR above).
        (self.bin / "python3").symlink_to(sys.executable)
        self.jobs = 0
        self.pids = []
        self.addCleanup(self.kill_leftovers)

    def kill_leftovers(self):
        for pid in self.pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def workspace(self, name: str, *, extra: str = "") -> Path:
        ws = self.root / name / "_work/cmux/cmux"
        for rel, src in REAL.items():
            (ws / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, ws / rel)
        write_executable(ws / "scripts/cmux-next/check-cmux-scheme-compile.sh", STUB_COMPILE)
        write_executable(ws / "scripts/cmux-next/check-app-personalities.sh", "#!/bin/bash\n")
        (ws / "Sources.swift").write_text(f"// {name} {extra}\n")
        git = ["git", "-C", str(ws), "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", "init", "-q", str(ws)], check=True)
        subprocess.run(git + ["add", "-A"], check=True)
        subprocess.run(git + ["commit", "-qm", name], check=True)
        return ws

    def start(self, ws: Path, runner: str = "cmux14-glaeda-2", **overrides):
        self.jobs += 1
        job = self.root / f"job-{self.jobs}"
        job.mkdir()
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home), "RUNNER_TEMP": str(job),
            "RUNNER_NAME": runner, "GITHUB_WORKSPACE": str(ws), "TEST_LOG": str(job / "seen.json"),
            "CMUX_NEXT_RUNNER": "glaeda-side-std-xcode-26.6", "CMUX_NEXT_COMPILATION_CACHE": "1",
            "DEVELOPER_DIR": DEVELOPER_DIR,
        }
        env.update(overrides)
        proc = subprocess.Popen(["/bin/bash", str(ws / "scripts/cmux-next/compile-dev-release.sh"),
                                 str(job / "app.zip")], cwd=ws, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.pids.append(proc.pid)
        return proc, job

    def finish(self, proc, job: Path, status: int = 0) -> dict:
        out, _ = proc.communicate(timeout=120)
        self.assertEqual(proc.returncode, status, out)
        if status:
            return {"out": out}
        self.assertTrue((job / "app.zip").exists(), "no archive")
        seen = json.loads((job / "seen.json").read_text())
        seen["out"] = out
        return seen

    def compile(self, ws: Path, runner: str = "cmux14-glaeda-2", **overrides) -> dict:
        return self.finish(*self.start(ws, runner, **overrides))

    def assert_host(self, seen: dict, ws: Path):
        self.assertEqual(seen["root"], str(self.host / "src"), seen["out"])
        self.assertTrue(seen["dd"].startswith(str(self.host / "Release/xcode-")), seen["dd"])
        self.assertTrue(seen["locked"], "the host build ran without the host lock")
        self.assertEqual(seen["head"], subprocess.run(["git", "-C", str(ws), "rev-parse", "HEAD"],
                                                       capture_output=True, text=True).stdout.strip())

    def assert_instance(self, seen: dict, ws: Path, *, other_holder: bool = False):
        self.assertEqual(seen["root"], str(ws), seen["out"])
        self.assertNotIn("/host/", seen["dd"])
        if not other_holder:
            self.assertFalse(seen["locked"], "a per-instance build kept the host lock")

    def test_two_runner_instances_build_at_one_host_path(self):
        first = self.compile(self.workspace("runner-2"), "cmux14-glaeda-2")
        second = self.compile(self.workspace("runner-5"), "cmux14-glaeda-5")
        self.assert_host(first, self.root / "runner-2/_work/cmux/cmux")
        self.assert_host(second, self.root / "runner-5/_work/cmux/cmux")
        self.assertEqual((first["root"], first["dd"]), (second["root"], second["dd"]),
                         "two runner instances built at different paths: the cache keys cannot match")
        self.assertEqual(probe(self.lock), 0, "the host lock outlived the build")

    def test_the_host_tree_is_exactly_this_checkout(self):
        old = self.workspace("runner-2")
        (old / "stale.txt").write_text("from an earlier checkout\n")
        self.assertTrue(self.compile(old)["stale"])
        new = self.workspace("runner-5", extra="next commit")
        seen = self.compile(new, "cmux14-glaeda-5")
        self.assert_host(seen, new)
        self.assertFalse(seen["stale"], "a file from an earlier build's tree survived into the host tree")
        self.assertIn("next commit", (self.host / "src/Sources.swift").read_text())

    def test_a_build_during_another_builds_per_instance_at_once(self):
        hold = self.root / "hold"
        first, first_job = self.start(self.workspace("runner-2"), STUB_HOLD=str(hold))
        wait_for(hold)
        ws = self.workspace("runner-5")
        started = time.monotonic()
        seen = self.compile(ws, "cmux14-glaeda-5")
        self.assertLess(time.monotonic() - started, 60, "a busy host root made the build wait")
        self.assert_instance(seen, ws, other_holder=True)
        self.assertIn("another build holds the host root", seen["out"])
        self.assertEqual(probe(self.lock), 1, "the fallback build dropped the running build's lock")
        (self.root / "hold.go").touch()
        self.assert_host(self.finish(first, first_job), self.root / "runner-2/_work/cmux/cmux")

    def test_a_killed_wrapper_keeps_the_root_until_its_compile_exits(self):
        hold = self.root / "hold"
        wrapper, _ = self.start(self.workspace("runner-2"), STUB_HOLD=str(hold))
        wait_for(hold)
        compile_pid = int(hold.read_text())
        self.pids.append(compile_pid)
        wrapper.kill()  # SIGKILL: no trap runs
        wrapper.wait(timeout=60)
        wrapper.stdout.close()
        ws = self.workspace("runner-5")
        self.assert_instance(self.compile(ws, "cmux14-glaeda-5"), ws, other_holder=True)
        os.kill(compile_pid, signal.SIGKILL)
        self.assertEqual(wait_free(self.lock), 0, "the lock outlived every process that held it")
        self.assert_host(self.compile(ws, "cmux14-glaeda-5"), ws)

    def test_a_lock_file_left_behind_is_not_held(self):
        self.host.mkdir(parents=True)
        self.lock.write_text(json.dumps({"pid": 1, "runner": "gone"}))
        ws = self.workspace("runner-2")
        self.assert_host(self.compile(ws), ws)

    def test_a_failed_tree_setup_builds_per_instance_and_releases_the_lock(self):
        if os.geteuid() == 0:
            self.skipTest("root removes a read-only directory")
        ws = self.workspace("runner-2")
        locked = self.host / "src/locked"
        locked.mkdir(parents=True)
        (locked / "file").write_text("x")
        locked.chmod(0o500)
        self.addCleanup(locked.chmod, 0o700)
        seen = self.compile(ws)
        self.assert_instance(seen, ws)
        self.assertIn("host tree setup failed", seen["out"])

    def test_cache_off_or_off_a_mini_never_touches_the_host_root(self):
        ws = self.workspace("runner-2")
        for overrides in ({"CMUX_NEXT_COMPILATION_CACHE": "0"}, {"CMUX_NEXT_RUNNER": "blacksmith-6vcpu-macos-26"}):
            with self.subTest(overrides=overrides):
                self.assert_instance(self.compile(ws, **overrides), ws)
                self.assertFalse(self.host.exists())

    def test_the_checkout_acpmux_is_read_from_the_host_tree(self):
        ws = self.workspace("runner-2")
        (ws / "cmux-tui/target/hosted/tree/k").mkdir(parents=True)
        (ws / "cmux-tui/target/hosted/tree/k/acpmux").write_text("bin")
        seen = self.compile(ws, CMUX_NEXT_ACPMUX_BIN=str(ws / "cmux-tui/target/hosted/tree/k/acpmux"))
        self.assertEqual(seen["acpmux"], str(self.host / "src/cmux-tui/target/hosted/tree/k/acpmux"))
        elsewhere = str(self.root / "job-temp/acpmux")
        self.assertEqual(self.compile(ws, CMUX_NEXT_ACPMUX_BIN=elsewhere)["acpmux"], elsewhere)

    def test_a_failed_compile_fails_and_releases_the_lock(self):
        proc, job = self.start(self.workspace("runner-2"), STUB_COMPILE_STATUS="65")
        self.finish(proc, job, status=65)
        self.assertEqual(probe(self.lock), 0)


class LockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.lock = Path(self.temp.name) / "lock"

    def hold(self, extra: str = "exec sleep 120"):
        """A shell that takes the lock the way compile-dev-release.sh does, then runs EXTRA."""
        proc = subprocess.Popen(["/bin/bash", "-c", f'exec 9>>"$0"; "$1" "$2" acquire "$0" --fd 9; echo $?; {extra}',
                                 str(self.lock), sys.executable, str(LOCK_TOOL)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: (proc.kill(), proc.wait(), proc.stdout.close()))
        return proc, int(proc.stdout.readline())

    def test_one_holder_at_a_time_without_waiting(self):
        self.assertEqual(probe(self.lock), 0)
        first, status = self.hold()
        self.assertEqual(status, 0)
        self.assertEqual(probe(self.lock), 1)
        started = time.monotonic()
        _, status = self.hold()
        self.assertEqual(status, 1)
        self.assertLess(time.monotonic() - started, 10)
        first.kill()
        first.wait()
        self.assertEqual(wait_free(self.lock), 0, "the kernel did not drop a killed holder's lock")

    def test_a_child_keeps_the_lock_after_its_shell_is_gone(self):
        proc, status = self.hold(extra="sleep 120 & echo $!; wait")
        self.assertEqual(status, 0)
        child = int(proc.stdout.readline())
        self.addCleanup(lambda: os.kill(child, signal.SIGKILL) if probe(self.lock) else None)
        proc.kill()
        proc.wait()
        self.assertEqual(probe(self.lock), 1, "the lock went with the shell while its child still ran")
        os.kill(child, signal.SIGKILL)
        self.assertEqual(wait_free(self.lock), 0)

    def test_a_descriptor_for_another_file_is_an_error(self):
        self.lock.touch()
        other = Path(self.temp.name) / "other"
        result = subprocess.run(["/bin/bash", "-c", 'exec 9>>"$0"; "$1" "$2" acquire "$3" --fd 9',
                                 str(other), sys.executable, str(LOCK_TOOL), str(self.lock)])
        self.assertEqual(result.returncode, 2)


class WorkflowTests(unittest.TestCase):
    def test_the_dev_step_compiles_through_the_host_root(self):
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text()
        step = text[text.index("id: compile-cmux-next-dev-release\n"):text.index("      - name: Upload DEV daily compile timing")]
        self.assertIn('scripts/cmux-next/compile-dev-release.sh "$archive"', step)
        self.assertNotIn("check-cmux-scheme-compile.sh", step, "the step builds around the host root")
        self.assertIn("CMUX_NEXT_COMPILATION_CACHE: ${{ vars.CMUX_NEXT_DEV_COMPILATION_CACHE || '1' }}", step)


if __name__ == "__main__":
    unittest.main()
