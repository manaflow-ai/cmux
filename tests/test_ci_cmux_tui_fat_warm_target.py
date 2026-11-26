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
- both build steps call the warm script's restore before the build, with the disk the mount
  uses, and never record: "Record the warm target" prunes and records after "Stage binary" (the
  prune run on the build step's exit removed target/<triple> before staging, 2026-11-18);
- the warm bound is not below one leg's measured use and fits the sticky disk;
- the macOS-on-Linux leg passes a toolchain stamp, and the script empties a disk whose stamp
  differs (link inputs Cargo does not track: clang, lld, zig, the SDK label, the stubs);
- the shipped builds print cargo --timings (compile vs link per unit).

lane = "manual" (no new CI tests, Lawrence 2026-10-23, lifted 2026-11-18). Run: python3 tests/test_ci_cmux_tui_fat_warm_target.py
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
# The pool darwin leg runs on the trees cmux-next dispatches, not only pushes (which skip it).
NEXT_TREE = "(github.event_name == 'push' || github.event_name == 'workflow_dispatch') && github.ref == 'refs/heads/feat-cmux-next'"


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
        restore = re.search(r"machine-channel-warm-target\.sh restore\b", run)
        self.assertTrue(restore, f"{build['name']}: restores the warm target")
        self.assertLess(restore.start(), run.index(before), f"{build['name']}: restore before the build")
        # The disk path sits in the run, or in an env value the restore reads (WARM_DISK: a pool
        # runner's own directory, else the sticky disk's mount point).
        self.assertIn(disk, run + str(build.get("env", {})), f"{build['name']}: uses the fat disk {disk}")
        # record prunes top-level entries of an over-bound disk: run on the build step's exit it
        # removed target/<triple> before "Stage binary" read it (runs 44240874997, 44243309941).
        self.assertNotRegex(run, r"\brecord\b", f"{build['name']}: never records (prunes) itself")
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

    def test_record_prunes_only_after_stage_binary(self) -> None:
        names = [s.get("name") for s in steps()]
        record = step("Record the warm target")
        run = str(record["run"])
        self.assertIn("machine-channel-warm-target.sh record", run)
        self.assertGreater(names.index("Record the warm target"), names.index("Stage binary"),
                           "the prune runs after every binary is staged")
        others = [s for s in steps() if s.get("name") != "Record the warm target"]
        for s in others:
            self.assertNotRegex(str(s.get("run", "")), r"machine-channel-warm-target\.sh\"? record|warm record\b",
                                f"{s.get('name')}: only 'Record the warm target' records")
        cond = str(record.get("if", ""))
        self.assertIn("always()", cond, "a failed build or stage still records")
        self.assertIn("runner.os == 'Linux'", cond)
        # The disks and toolchain stamp the build steps restored with.
        for target in SHIPPED:
            self.assertIn(str(fat_mount_for(target)["with"]["path"]), run)
        self.assertIn("/home/runner/machine-channel-warm", run)
        built = step("Build the macOS binaries on Linux (no Apple SDK)")
        self.assertEqual(str(record["env"]["DARWIN_TOOLCHAIN"]), str(built["env"]["MACHINE_CHANNEL_WARM_TOOLCHAIN"]))
        self.assertIn('MACHINE_CHANNEL_WARM_TOOLCHAIN="$DARWIN_TOOLCHAIN"', run)

    def test_bound_is_above_measured_use_and_fits_the_disk(self) -> None:
        # The largest leg held 44469088256 bytes after its build (thin aarch64, run 44240874997,
        # 2026-11-18); the 40 GiB bound below that pruned the leg's own triple. The sticky disk
        # is 590 GB (scripts/blacksmith-testbox-target-prune.sh); record caps the bound at 80%
        # of the real disk (df) as well.
        measured = 44469088256
        text = WARM.read_text(encoding="utf-8")
        m = re.search(r'max_bytes="\$\{MACHINE_CHANNEL_WARM_MAX_BYTES:-\$\(\((\d+) \* 1024 \* 1024 \* 1024\)\)\}"', text)
        self.assertTrue(m, "the default bound is N GiB")
        bound = int(m.group(1)) * 1024**3
        self.assertGreaterEqual(bound, 2 * measured, "at least twice the largest leg's measured use")
        self.assertLessEqual(bound, 590 * 10**9 * 8 // 10, "within 80% of the sticky disk")
        self.assertRegex(text, r"df -B1 --output=size")
        self.assertIn('"$target" "$bound"', text, "the prune gets the disk-capped bound")

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

    def test_record_over_the_bound_keeps_the_triple_the_job_built(self) -> None:
        # The steps after the build read target/<triple>/release, so record's prune must not
        # remove it, also when it is the oldest entry of a disk that is over the bound.
        self.warm("restore", None)
        target = self.repo / "cmux-tui" / "target"
        built = target / "aarch64-apple-darwin" / "release" / "cmux-tui"
        host = target / "release" / "build" / "host.bin"
        for path in (built, host):
            path.parent.mkdir(parents=True)
            path.write_bytes(b"\0" * 300_000)
        os.utime(target / "aarch64-apple-darwin", (1, 1))
        self.env["MACHINE_CHANNEL_WARM_MAX_BYTES"] = "450000"
        out = self.warm("record", None)
        self.assertIn("warm target: prune bound 450000 bytes", out)
        self.assertTrue(built.exists(), out)
        self.assertFalse(host.exists(), out)

    def test_record_bounds_the_disk_when_the_triple_alone_is_over(self) -> None:
        # record runs after "Stage binary", so once the other entries are gone it may remove
        # the triple too: the disk stays bounded, and this job no longer reads it.
        self.warm("restore", None)
        built = self.repo / "cmux-tui" / "target" / "aarch64-apple-darwin" / "release" / "cmux-tui"
        built.parent.mkdir(parents=True)
        built.write_bytes(b"\0" * 300_000)
        self.env["MACHINE_CHANNEL_WARM_MAX_BYTES"] = "100000"
        out = self.warm("record", None)
        self.assertFalse((self.disk / "target" / "aarch64-apple-darwin").exists(), out)
        self.assertTrue((self.disk / "target" / ".machine-channel-warm-source").exists(), out)

    def recorded_disk(self) -> tuple[Path, Path]:
        """A disk as a build left it: the triple's dir (the oldest entry) and a newer one."""
        target = self.disk / "target"
        triple = target / "aarch64-apple-darwin" / "release" / "cmux-tui"
        host = target / "release" / "build" / "host.bin"
        for path in (triple, host):
            path.parent.mkdir(parents=True)
            path.write_bytes(b"\0" * 300_000)
        os.utime(target / "aarch64-apple-darwin", (1, 1))
        return triple, host

    def test_restore_never_prunes_even_over_the_bound(self) -> None:
        # Only record (after "Stage binary") prunes. A prune before the build removed warm
        # output the build would have used; record bounds the disk after staging instead.
        triple, host = self.recorded_disk()
        self.env["MACHINE_CHANNEL_WARM_MAX_BYTES"] = "450000"
        out = self.warm("restore", None)
        self.assertNotIn("prune:", out)
        self.assertTrue(triple.exists(), out)
        self.assertTrue(host.exists(), out)

    def test_restore_below_the_bound_removes_nothing(self) -> None:
        triple, host = self.recorded_disk()
        self.env["MACHINE_CHANNEL_WARM_MAX_BYTES"] = "10000000"
        out = self.warm("restore", None)
        self.assertTrue(triple.exists(), out)
        self.assertTrue(host.exists(), out)


class PoolRunnerWarmTarget(ToolchainStamp):
    """On a cmux-runner-pool-* runner (no sticky disk, HOME kept) the darwin leg's warm target is
    the runner slot's own directory: bounded, seeded from R2, removed when the host is short of disk."""

    STAMP = "clang 19 / zig 0.17 / sdk 26.5"

    def setUp(self) -> None:
        super().setUp()
        (self.tmp / "bin" / "mountpoint").write_text("#!/bin/sh\nexit 1\n")
        self.env["HOME"] = str(self.tmp / "home")
        self.env["RUNNER_NAME"] = "cmux-runner-pool-e1c-0137-3"
        self.disk = Path(self.pool_dir())

    def pool_dir(self, **env: str) -> str:
        out = subprocess.run(
            ["bash", str(self.repo / "scripts/ci/machine-channel-warm-target.sh"), "pool-dir", "aarch64-apple-darwin"],
            env={**self.env, **env}, capture_output=True, text=True, check=True,
        )
        return out.stdout.strip()

    def test_pool_dir_is_the_runner_slots_own_under_home(self) -> None:
        self.assertEqual(
            str(self.disk),
            f"{self.tmp}/home/.cache/cmux-next-ci/cmux-tui-fat-warm/cmux-runner-pool-e1c-0137-3/aarch64-apple-darwin",
        )
        self.assertNotEqual(self.pool_dir(RUNNER_NAME="cmux-runner-pool-e1c-0137-2"), str(self.disk))
        self.assertEqual(self.pool_dir(RUNNER_NAME="blacksmith-16vcpu-ubuntu-2404"), "")

    def test_a_recorded_pool_tree_is_a_hit_and_probes_as_one(self) -> None:
        self.assertEqual(self.warm("probe", self.STAMP).strip(), "miss")
        obj = self.build_once(self.STAMP)
        self.assertEqual(self.warm("probe", self.STAMP).strip(), "hit")
        self.assertEqual(self.warm("probe", "clang 20").strip(), "miss")
        out = self.warm("restore", self.STAMP)
        self.assertIn("warm target: hit", out)
        self.assertTrue(obj.exists())
        self.assertEqual(os.readlink(self.repo / "cmux-tui" / "target"), str(self.disk / "target"))

    def test_a_path_outside_the_slot_is_never_used_without_a_mount(self) -> None:
        self.disk = self.tmp / "elsewhere"
        out = self.warm("restore", self.STAMP)
        self.assertIn("no sticky disk mounted", out)
        self.assertFalse((self.repo / "cmux-tui" / "target").exists())

    def test_the_first_job_seeds_the_tree_from_the_r2_restore(self) -> None:
        restored = self.repo / "cmux-tui" / "target" / "release" / "deps" / "libdep.rlib"
        restored.parent.mkdir(parents=True)
        restored.write_text("from r2\n")
        self.env["MACHINE_CHANNEL_WARM_SEED_EXACT"] = "true"
        out = self.warm("restore", self.STAMP)
        self.assertIn("seeded", out)
        self.assertTrue((self.repo / "cmux-tui" / "target").is_symlink())
        self.assertTrue((self.disk / "target" / "release" / "deps" / "libdep.rlib").exists())

    def test_a_prefix_r2_restore_seeds_nothing_another_toolchain_built(self) -> None:
        restored = self.repo / "cmux-tui" / "target" / "release" / "deps" / "libdep.rlib"
        restored.parent.mkdir(parents=True)
        restored.write_text("maybe another toolchain\n")
        out = self.warm("restore", self.STAMP)
        self.assertIn("toolchain changed", out)
        self.assertFalse((self.disk / "target" / "release" / "deps" / "libdep.rlib").exists())

    def test_a_host_short_of_disk_removes_the_tree_and_builds_cold(self) -> None:
        obj = self.build_once(self.STAMP)
        self.env["MACHINE_CHANNEL_WARM_POOL_MIN_FREE_BYTES"] = str(1 << 62)
        out = self.warm("restore", self.STAMP)
        self.assertIn("pool host has", out)
        self.assertFalse(obj.exists())
        self.assertFalse((self.repo / "cmux-tui" / "target").exists())

    def test_record_keeps_the_tree_for_later_readers_and_release_drops_it(self) -> None:
        # Job 140189679068: record removed the tree on a host short of disk, so the workspace
        # delta's pack and the R2 dependency save after it found a dangling cmux-tui/target.
        self.warm("restore", self.STAMP)
        link = self.repo / "cmux-tui" / "target"
        obj = link / "release" / "obj.o"
        obj.parent.mkdir(parents=True)
        obj.write_text("built\n")
        self.env["MACHINE_CHANNEL_WARM_POOL_MIN_FREE_BYTES"] = str(1 << 62)
        out = self.warm("record", self.STAMP)
        self.assertIn("warm target: recorded", out)
        self.assertNotIn("removed", out)
        self.assertTrue(obj.exists(), "a step after record still reads the tree through the link")
        out = self.warm("release", self.STAMP)
        self.assertIn("pool tree removed at the end of the job", out)
        self.assertFalse((self.disk / "target" / "release" / "obj.o").exists())
        self.assertFalse(link.is_symlink() or link.exists())

    def test_release_keeps_the_tree_on_a_host_with_room(self) -> None:
        obj = self.build_once(self.STAMP)
        out = self.warm("release", self.STAMP)
        self.assertNotIn("removed", out)
        self.assertTrue(obj.exists())

    def test_release_never_touches_a_sticky_disk(self) -> None:
        self.disk = self.tmp / "elsewhere"
        (self.disk / "target").mkdir(parents=True)
        self.env["MACHINE_CHANNEL_WARM_POOL_MIN_FREE_BYTES"] = str(1 << 62)
        self.warm("release", self.STAMP)
        self.assertTrue((self.disk / "target").exists())

    def test_release_runs_after_every_reader_of_the_target(self) -> None:
        names = [s.get("name") for s in steps()]
        release = step("Release the pool warm target")
        self.assertEqual(names[-1], "Release the pool warm target", "nothing after it may read cmux-tui/target")
        for reader in ("Record the warm target", "Pack the workspace delta", "Save the workspace delta to R2",
                       "Strip the workspace's own output before the R2 save", "Save the cargo build to R2"):
            self.assertLess(names.index(reader), names.index("Release the pool warm target"), reader)
        self.assertIn("always()", str(release["if"]))
        self.assertIn("steps.pool-warm-darwin.outputs.disk", str(release["env"]["POOL_DISK"]))
        self.assertIn('release "$POOL_DISK"', str(release["run"]))

    def test_record_bounds_a_pool_tree_tighter(self) -> None:
        self.env["MACHINE_CHANNEL_WARM_POOL_MAX_BYTES"] = "450000"
        self.build_once(self.STAMP)
        self.env.pop("MACHINE_CHANNEL_WARM_POOL_MAX_BYTES")
        self.warm("restore", self.STAMP)
        self.env["MACHINE_CHANNEL_WARM_POOL_MAX_BYTES"] = "450000"
        out = self.warm("record", self.STAMP)
        self.assertIn("warm target: prune bound 450000 bytes", out)

    def test_workflow_routes_the_pool_darwin_leg_to_its_own_tree(self) -> None:
        locate = step("Locate the pool warm target (feat-cmux-next, fat, aarch64 macOS on Linux)")
        cond = str(locate["if"])
        for part in ("startsWith(runner.name, 'cmux-runner-pool-')", "matrix.target == 'aarch64-apple-darwin'", NEXT_TREE, "inputs.lto != 'thin'"):
            self.assertIn(part, cond)
        self.assertIn("pool-dir", str(locate["run"]))
        self.assertIn("probe", str(locate["run"]))
        stamp = str(step("Build the macOS binaries on Linux (no Apple SDK)")["env"]["MACHINE_CHANNEL_WARM_TOOLCHAIN"])
        self.assertEqual(str(locate["env"]["MACHINE_CHANNEL_WARM_TOOLCHAIN"]), stamp)
        self.assertIn("steps.pool-warm-darwin.outputs.hit != 'true'", str(step("Key the cargo build in R2")["if"]))
        build = step("Build the macOS binaries on Linux (no Apple SDK)")
        self.assertIn("steps.pool-warm-darwin.outputs.disk", str(build["env"]["WARM_DISK"]))
        self.assertIn("steps.r2-cargo-target.outputs.cache-hit == 'true'", str(build["env"]["MACHINE_CHANNEL_WARM_SEED_EXACT"]))
        self.assertIn('restore "$WARM_DISK"', str(build["run"]))
        record = step("Record the warm target")
        self.assertIn("steps.pool-warm-darwin.outputs.disk", str(record["env"]["POOL_DISK"]))
        self.assertIn("${POOL_DISK:-", str(record["run"]))


if __name__ == "__main__":
    unittest.main()
