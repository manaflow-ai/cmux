#!/usr/bin/env python3
"""The shipped fat-LTO cmux-tui legs start from the last feat-cmux-next build's target dir.

.github/workflows/cmux-tui-build-package.yml builds the shipped binaries (lto=fat:
x86_64-unknown-linux-musl, aarch64-unknown-linux-musl, and aarch64-apple-darwin cross-built
on Linux) and the Cloud machine channel's binaries (lto=thin). The thin legs mount a sticky
disk with the previous build's target dir and run scripts/ci/machine-channel-warm-target.sh
restore/record around their build; the fat legs restored a dependency-only rust-cache entry and
recompiled every workspace crate, 916-1008 s per build step (runs 43630816742, 43630990255).

This pins the fat legs' wiring:
- each shipped target mounts its own sticky disk on feat-cmux-next pushes, keyed apart from
  every thin disk (fat and thin objects never mix) and from the other targets;
- no sticky disk step admits both LTO modes;
- the rust-cache restore is skipped when the disk is mounted (restore refuses an existing target);
- both build steps call the warm script's restore before the build and record on exit, with the
  disk the mount uses;
- the macOS-on-Linux leg passes a toolchain stamp, and the script empties a disk whose stamp
  differs (link inputs Cargo does not track: clang, lld, zig, the SDK label, the stubs);
- the shipped builds print cargo --timings (compile vs link per unit).

lane = "manual" (no new CI tests, Lawrence 2026-10-23). Run: python3 tests/test_ci_cmux_tui_fat_warm_target.py
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

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))
import git_fixture_env  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
WARM = ROOT / "scripts" / "ci" / "machine-channel-warm-target.sh"
MACOS_CROSS = ROOT / "scripts" / "ci" / "macos-cross.sh"
STICKY = "useblacksmith/stickydisk@"
SHIPPED = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl", "aarch64-apple-darwin")
NEXT_PUSH = "github.event_name == 'push' && github.ref == 'refs/heads/feat-cmux-next'"


def steps() -> list[dict]:
    return workflow_jobs.jobs(WORKFLOW)["build"]["steps"]


def step(name: str) -> dict:
    found = [s for s in steps() if s.get("name") == name]
    assert len(found) == 1, f"one step named {name!r}, found {len(found)}"
    return found[0]


def sticky_steps() -> list[dict]:
    return [s for s in steps() if str(s.get("uses", "")).startswith(STICKY)]


def is_fat(cond: str) -> bool:
    return "inputs.lto != 'thin'" in cond


def is_thin(cond: str) -> bool:
    return "inputs.lto == 'thin'" in cond


def fat_mount_for(target: str) -> dict:
    """The fat sticky disk step a feat-cmux-next push of TARGET mounts, with its key resolved."""
    found = []
    for s in sticky_steps():
        cond = str(s.get("if", ""))
        if not is_fat(cond):
            continue
        guard = re.search(r"matrix\.target == '([^']+)'", cond)
        if guard and guard.group(1) != target:
            continue
        if target.endswith("-apple-darwin") and "!matrix.darwin_on_linux" in cond:
            continue
        if target.endswith("-linux-musl") and re.search(r"(?<!!)matrix\.darwin_on_linux\b", cond):
            continue
        found.append(s)
    assert len(found) == 1, f"{target}: one fat sticky disk step, found {len(found)}"
    s = dict(found[0])
    s["key"] = str(s["with"]["key"]).replace("${{ matrix.target }}", target)
    return s


class FatWarmWiring(unittest.TestCase):
    def test_every_shipped_target_mounts_its_own_fat_disk_on_next_pushes(self) -> None:
        keys = {}
        for target in SHIPPED:
            mount = fat_mount_for(target)
            cond = str(mount["if"])
            self.assertIn(NEXT_PUSH, cond, f"{target}: only feat-cmux-next pushes write the disk")
            self.assertIn("startsWith(runner.name, 'blacksmith')", cond)
            self.assertIn("runner.os == 'Linux'", cond)
            self.assertTrue(mount.get("continue-on-error"), f"{target}: a failed mount is a cold build")
            self.assertEqual(mount["with"].get("commit"), "on-change")
            self.assertNotIn("${{", mount["key"], f"{target}: key resolves to a fixed name")
            keys[target] = mount["key"]
        self.assertEqual(len(set(keys.values())), len(SHIPPED), f"one disk per target: {keys}")

    def test_fat_and_thin_never_share_a_disk(self) -> None:
        thin_keys = set()
        for s in sticky_steps():
            cond = str(s.get("if", ""))
            self.assertNotEqual(is_fat(cond), is_thin(cond), f"{s['name']}: gated on exactly one LTO mode")
            if is_thin(cond):
                thin_keys.add(str(s["with"]["key"]))
        fat_keys = {fat_mount_for(t)["key"] for t in SHIPPED}
        self.assertTrue(thin_keys, "the thin disks are still there")
        self.assertFalse(fat_keys & thin_keys, f"shared keys: {fat_keys & thin_keys}")
        for fat in fat_keys:
            for thin in thin_keys:
                self.assertFalse(fat.startswith(thin) or thin.startswith(fat), (fat, thin))

    def test_rust_cache_steps_yield_to_a_mounted_disk(self) -> None:
        order = [s.get("name") for s in steps()]
        caches = {
            "Restore the Linux cargo cache": [t for t in SHIPPED if t.endswith("-linux-musl")],
            "Restore the macOS-on-Linux cargo cache": [t for t in SHIPPED if t.endswith("-apple-darwin")],
        }
        for name, targets in caches.items():
            cond = str(step(name).get("if", ""))
            for t in targets:
                mount = fat_mount_for(t)
                self.assertTrue(mount.get("id"), f"{t}: the fat mount step has an id")
                self.assertIn(f"steps.{mount['id']}.outcome != 'success'", cond, name)
                self.assertLess(order.index(mount["name"]), order.index(name), f"{t} mounts before {name}")

    def _assert_wraps(self, build: dict, target: str, before: str) -> str:
        run = str(build["run"])
        disk = str(fat_mount_for(target)["with"]["path"])
        self.assertIn("machine-channel-warm-target.sh", run)
        restore = re.search(r"warm restore\b", run)
        record = re.search(r"trap '[^']*warm record\b", run)
        self.assertTrue(restore and record, f"{build['name']}: restore, then record on EXIT")
        self.assertLess(restore.start(), run.index(before), f"{build['name']}: restore before the build")
        self.assertLess(record.start(), run.index(before), f"{build['name']}: the trap is set before the build")
        self.assertIn(disk, run, f"{build['name']}: uses the fat disk {disk}")
        return run

    def test_linux_build_wraps_fat_builds_too(self) -> None:
        build = step("Build cmux-tui (Linux cross)")
        run = self._assert_wraps(build, "x86_64-unknown-linux-musl", "../scripts/ci/cargo-groups.sh \"")
        # The warm calls must not sit inside a thin-only branch.
        head = run[: run.index("../scripts/ci/cargo-groups.sh \"")]
        thin_blocks = re.findall(r'if \[\[ "\$LTO" == thin \]\]; then(.*?)\n\s*fi\n', head, re.S)
        for block in thin_blocks:
            self.assertNotIn("warm restore", block, "restore runs for fat legs too")
        self.assertRegex(head, r'profile\+=" --timings"')
        timings = head.index('profile+=" --timings"')
        for block in thin_blocks:
            self.assertNotIn('profile+=" --timings"', block, "timings for the fat legs too")
        self.assertGreater(timings, 0)

    def test_darwin_build_wraps_macos_cross_all_with_a_toolchain_stamp(self) -> None:
        build = step("Build the macOS binaries on Linux (no Apple SDK)")
        run = self._assert_wraps(build, "aarch64-apple-darwin", "./scripts/ci/macos-cross.sh all ")
        self.assertIn("MACHINE_CHANNEL_WARM_TOOLCHAIN", run + str(build.get("env", {})))
        stamp = str(build.get("env", {}).get("MACHINE_CHANNEL_WARM_TOOLCHAIN", ""))
        self.assertIn("steps.darwin-cross.outputs.key", stamp)
        self.assertIn("scripts/ci/macos-stubs/**", stamp)
        self.assertIn("scripts/ci/macos-cross.sh", stamp)

    def test_macos_cross_all_prints_cargo_timings(self) -> None:
        text = MACOS_CROSS.read_text(encoding="utf-8")
        body = text[text.index("cmd_all() {") :]
        body = body[: body.index("\n}\n")]
        self.assertRegex(body, r'local build="cargo build --release --locked --timings --target \$t"')


class ToolchainStamp(unittest.TestCase):
    """scripts/ci/machine-channel-warm-target.sh empties a disk built by another toolchain."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        for rel in (
            "scripts/ci/machine-channel-warm-target.sh",
            "scripts/ci/timeout.sh",
            "scripts/blacksmith-testbox-source-mtimes.py",
            "scripts/blacksmith-testbox-target-prune.sh",
        ):
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel, self.repo / rel)
        (self.repo / "cmux-tui").mkdir()
        (self.repo / "cmux-tui" / "lib.rs").write_text("fn main() {}\n")
        git = ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t"]
        git_fixture_env.init_repo(self.repo)
        subprocess.run([*git, "add", "-A"], env=git_fixture_env.write_env(), check=True)
        subprocess.run([*git, "commit", "-qm", "fixture"], env=git_fixture_env.write_env(), check=True)
        self.disk = self.tmp / "disk"
        self.disk.mkdir()
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "mountpoint"
        fake.write_text("#!/bin/sh\nexit 0\n")
        fake.chmod(0o755)
        self.env = git_fixture_env.fixture_env({
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "CARGO_HOME": str(self.tmp / "cargo"),
            "RUNNER_TEMP": str(self.tmp),
        })

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def warm(self, command: str, stamp: str | None) -> str:
        env = dict(self.env)
        env.pop("MACHINE_CHANNEL_WARM_TOOLCHAIN", None)
        if stamp is not None:
            env["MACHINE_CHANNEL_WARM_TOOLCHAIN"] = stamp
        out = subprocess.run(
            ["bash", str(self.repo / "scripts/ci/machine-channel-warm-target.sh"), command, str(self.disk), "aarch64-apple-darwin"],
            env=env, capture_output=True, text=True,
        )
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        return out.stdout

    def build_once(self, stamp: str | None) -> Path:
        self.warm("restore", stamp)
        obj = self.repo / "cmux-tui" / "target" / "release" / "obj.o"
        obj.parent.mkdir(parents=True, exist_ok=True)
        obj.write_text("built\n")
        self.warm("record", stamp)
        (self.repo / "cmux-tui" / "target").unlink()  # the next job checks out fresh
        return self.disk / "target" / "release" / "obj.o"

    def test_same_stamp_is_a_hit(self) -> None:
        obj = self.build_once("clang 19 / zig 0.17 / sdk 26.5")
        out = self.warm("restore", "clang 19 / zig 0.17 / sdk 26.5")
        self.assertIn("warm target: hit", out)
        self.assertTrue(obj.exists())

    def test_changed_stamp_empties_the_disk(self) -> None:
        obj = self.build_once("clang 19 / zig 0.17 / sdk 26.5")
        out = self.warm("restore", "clang 20 / zig 0.17 / sdk 26.5")
        self.assertIn("warm target: miss (toolchain changed", out)
        self.assertNotIn("warm target: hit", out)
        self.assertFalse(obj.exists())

    def test_a_disk_recorded_without_a_stamp_is_emptied_when_one_is_asked(self) -> None:
        obj = self.build_once(None)
        out = self.warm("restore", "clang 19")
        self.assertIn("toolchain changed", out)
        self.assertFalse(obj.exists())

    def test_no_stamp_keeps_the_thin_behavior(self) -> None:
        obj = self.build_once(None)
        out = self.warm("restore", None)
        self.assertIn("warm target: hit", out)
        self.assertTrue(obj.exists())


if __name__ == "__main__":
    unittest.main()
