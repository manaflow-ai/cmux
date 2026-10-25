#!/usr/bin/env python3
"""The DEV Release compile builds from one fixed tree and DerivedData per host, under a host lock.

Xcode's compilation cache keys hold the absolute source and DerivedData paths. #24994 turned the
cache on with a per-runner path (RUNNER_NAME + workspace), and the DEV compile lands on 30+ runner
instances, so every compile after it was cold (median compile job 10.8 min over 12 DEV publishes).
scripts/cmux-next/compile-dev-release.sh builds instead from HOME/.../dev-daily-release/host/src,
cloned from the checkout, into one DerivedData per host. These run it against stub compilers:

- two runner instances on a host build at the same paths;
- the tree is exactly the checked-out commit (a file an earlier build's checkout had is gone);
- a lock another live process holds builds per instance at once, and leaves that lock alone;
- a stale lock (dead holder, or a reused pid) is taken;
- a failed tree setup builds per instance and releases the lock;
- with the cache off or off a mini nothing touches the host root.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REAL = {
    "scripts/cmux-next/compile-dev-release.sh": ROOT / "scripts/cmux-next/compile-dev-release.sh",
    "scripts/cmux-next/host_build_lock.py": ROOT / "scripts/cmux-next/host_build_lock.py",
    "scripts/cmux-next/release-derived-data-path.sh": ROOT / "scripts/cmux-next/release-derived-data-path.sh",
    "scripts/ci/canonical-build-root.sh": ROOT / "scripts/ci/canonical-build-root.sh",
    "scripts/ci/apfs_clone.py": ROOT / "scripts/ci/apfs_clone.py",
}
# A real one on macOS, where /usr/bin/git and /usr/bin/python3 resolve through it; only hashed here.
DEVELOPER_DIR = os.environ.get("DEVELOPER_DIR") or (
    subprocess.run(["xcode-select", "-p"], capture_output=True, text=True).stdout.strip()
    if sys.platform == "darwin" else "") or "/Applications/Xcode_26.6.app/Contents/Developer"
# The stub compile: where it ran, what it saw, and the app the script zips.
STUB_COMPILE = r'''#!/bin/bash
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd -P)"
lock="$HOME/Library/Caches/cmux-next-ci/dev-daily-release/host/lock"
python3 - "$root" "$1" "$lock" <<'PY' >> "$TEST_LOG"
import json, os, subprocess, sys
root, dd, lock = sys.argv[1:]
print(json.dumps({"root": root, "dd": dd, "head": subprocess.run(["git", "-C", root, "rev-parse", "HEAD"],
    capture_output=True, text=True).stdout.strip(), "stale": os.path.exists(os.path.join(root, "stale.txt")),
    "locked": os.path.exists(lock), "acpmux": os.environ.get("CMUX_NEXT_ACPMUX_BIN", "")}))
PY
mkdir -p "$1/Build/Products/Release/cmux NEXT DEV.app"
exit "${STUB_COMPILE_STATUS:-0}"
'''


def write_executable(path: Path, content: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


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
        # This interpreter: macOS's /usr/bin/python3 is an xcrun shim (so is git: DEVELOPER_DIR below).
        (self.bin / "python3").symlink_to(sys.executable)
        self.log = self.root / "log"
        self.jobs = 0
        self.sleepers = []
        self.addCleanup(self.stop_sleepers)

    def stop_sleepers(self):
        for proc in self.sleepers:
            proc.kill()
            proc.wait()

    def sleeper(self) -> int:
        proc = subprocess.Popen(["sleep", "120"])
        self.sleepers.append(proc)
        return proc.pid

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

    def compile(self, ws: Path, runner: str = "cmux14-glaeda-2", **overrides) -> dict:
        self.jobs += 1
        runner_temp = self.root / f"job-{self.jobs}"
        runner_temp.mkdir()
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home), "RUNNER_TEMP": str(runner_temp),
            "RUNNER_NAME": runner, "GITHUB_WORKSPACE": str(ws), "TEST_LOG": str(self.log),
            "CMUX_NEXT_RUNNER": "glaeda-side-std-xcode-26.6", "CMUX_NEXT_COMPILATION_CACHE": "1",
            "DEVELOPER_DIR": DEVELOPER_DIR,
        }
        env.update(overrides)
        self.log.unlink(missing_ok=True)
        archive = runner_temp / "app.zip"
        result = subprocess.run(["/bin/bash", str(ws / "scripts/cmux-next/compile-dev-release.sh"), str(archive)],
                                cwd=ws, env=env, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(archive.exists(), "no archive")
        seen = json.loads(self.log.read_text())
        seen["out"] = result.stdout + result.stderr
        return seen

    def assert_host(self, seen: dict, ws: Path):
        self.assertEqual(seen["root"], str(self.host / "src"), seen["out"])
        self.assertTrue(seen["dd"].startswith(str(self.host / "Release/xcode-")), seen["dd"])
        self.assertTrue(seen["locked"], "the host build ran without the host lock")
        self.assertEqual(seen["head"], subprocess.run(["git", "-C", str(ws), "rev-parse", "HEAD"],
                                                       capture_output=True, text=True).stdout.strip())

    def assert_instance(self, seen: dict, ws: Path):
        self.assertEqual(seen["root"], str(ws), seen["out"])
        self.assertNotIn("/host/", seen["dd"])

    def test_two_runner_instances_build_at_one_host_path(self):
        first = self.compile(self.workspace("runner-2"), "cmux14-glaeda-2")
        second = self.compile(self.workspace("runner-5"), "cmux14-glaeda-5")
        self.assert_host(first, self.root / "runner-2/_work/cmux/cmux")
        self.assert_host(second, self.root / "runner-5/_work/cmux/cmux")
        self.assertEqual((first["root"], first["dd"]), (second["root"], second["dd"]),
                         "two runner instances built at different paths: the cache keys cannot match")
        self.assertFalse(self.lock.exists(), "the host lock outlived the build")

    def test_the_host_tree_is_exactly_this_checkout(self):
        old = self.workspace("runner-2")
        (old / "stale.txt").write_text("from an earlier checkout\n")
        self.assertTrue(self.compile(old)["stale"])
        new = self.workspace("runner-5", extra="next commit")
        seen = self.compile(new, "cmux14-glaeda-5")
        self.assert_host(seen, new)
        self.assertFalse(seen["stale"], "a file from an earlier build's tree survived into the host tree")
        self.assertIn("next commit", (self.host / "src/Sources.swift").read_text())

    def test_a_held_lock_builds_per_instance_at_once(self):
        ws = self.workspace("runner-2")
        self.host.mkdir(parents=True)
        holder = self.sleeper()
        lock = [sys.executable, str(REAL["scripts/cmux-next/host_build_lock.py"]), "acquire", str(self.lock)]
        self.assertEqual(subprocess.run(lock + ["--pid", str(holder)]).returncode, 0)
        started = time.monotonic()
        seen = self.compile(ws)
        self.assertLess(time.monotonic() - started, 60, "a busy host lock made the build wait")
        self.assert_instance(seen, ws)
        self.assertIn("another build holds the host root", seen["out"])
        self.assertEqual(json.loads(self.lock.read_text())["pid"], holder, "the fallback build dropped another job's lock")

    def test_a_stale_lock_is_taken(self):
        ws = self.workspace("runner-2")
        self.host.mkdir(parents=True)
        dead = subprocess.Popen(["true"])
        dead.wait()
        for holder in ({"pid": dead.pid, "started": "Sat Oct 25 00:00:00 2026"},
                       # pid reuse: a live pid whose start time is not the holder's
                       {"pid": os.getpid(), "started": "Thu Jan  1 00:00:00 1970"},
                       {}):
            with self.subTest(holder=holder):
                self.lock.write_text(json.dumps(holder) if holder else "not json")
                self.assert_host(self.compile(ws), ws)
                self.assertFalse(self.lock.exists())

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
        self.assertFalse(self.lock.exists(), "a failed setup kept the host lock")

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
        ws = self.workspace("runner-2")
        env = {"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home), "RUNNER_TEMP": str(self.root),
               "RUNNER_NAME": "r", "GITHUB_WORKSPACE": str(ws), "TEST_LOG": str(self.log),
               "CMUX_NEXT_RUNNER": "glaeda-x", "CMUX_NEXT_COMPILATION_CACHE": "1", "DEVELOPER_DIR": DEVELOPER_DIR,
               "STUB_COMPILE_STATUS": "65"}
        result = subprocess.run(["/bin/bash", str(ws / "scripts/cmux-next/compile-dev-release.sh"),
                                 str(self.root / "a.zip")], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertFalse(self.lock.exists())


class LockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.lock = str(Path(self.temp.name) / "lock")
        self.procs = [subprocess.Popen(["sleep", "120"]) for _ in range(2)]
        self.addCleanup(lambda: [(p.kill(), p.wait()) for p in self.procs])

    def lock_cli(self, command: str, pid: int) -> int:
        return subprocess.run([sys.executable, str(REAL["scripts/cmux-next/host_build_lock.py"]), command,
                               self.lock, "--pid", str(pid)], capture_output=True).returncode

    def test_one_live_holder_at_a_time(self):
        a, b = (p.pid for p in self.procs)
        self.assertEqual(self.lock_cli("acquire", a), 0)
        self.assertEqual(self.lock_cli("acquire", a), 0, "the holder's own acquire is not busy")
        self.assertEqual(self.lock_cli("acquire", b), 1)
        self.lock_cli("release", b)
        self.assertEqual(self.lock_cli("acquire", b), 1, "a non-holder released the lock")
        self.lock_cli("release", a)
        self.assertEqual(self.lock_cli("acquire", b), 0)

    def test_a_killed_holder_is_stale(self):
        a, b = self.procs
        self.assertEqual(self.lock_cli("acquire", a.pid), 0)
        a.kill()
        a.wait()
        self.assertEqual(self.lock_cli("acquire", b.pid), 0)

    def test_no_process_is_an_error(self):
        dead = subprocess.Popen(["true"])
        dead.wait()
        self.assertEqual(self.lock_cli("acquire", dead.pid), 2)


class WorkflowTests(unittest.TestCase):
    def test_the_dev_step_compiles_through_the_host_root(self):
        text = (ROOT / ".github/workflows/cmux-next.yml").read_text()
        step = text[text.index("id: compile-cmux-next-dev-release\n"):text.index("      - name: Upload DEV daily compile timing")]
        self.assertIn('scripts/cmux-next/compile-dev-release.sh "$archive"', step)
        self.assertNotIn("check-cmux-scheme-compile.sh", step, "the step builds around the host root")
        self.assertIn("CMUX_NEXT_COMPILATION_CACHE: ${{ vars.CMUX_NEXT_DEV_COMPILATION_CACHE || '1' }}", step)


if __name__ == "__main__":
    unittest.main()
