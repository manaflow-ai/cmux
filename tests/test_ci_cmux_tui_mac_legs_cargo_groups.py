#!/usr/bin/env python3
"""The cmux-tui macOS legs built on a Mac run their cargo invocations at once when the Mac has the memory.

.github/workflows/cmux-tui-build-package.yml builds the aarch64-apple-darwin leg of a tree on a
free owned mini when one is idle ("Build cmux-tui (native)"; x86_64-apple-darwin on main in
"Build cmux-tui (macOS cross)"). Those steps ran their six cargo builds one after another, so
each fat-LTO link (one core) ran alone: the mini legs of 2026-11-17/18 took 42.1, 53.7, and
62.5 and 65.0 min (cancelled by the job timeout), against 13-15 min (p50) for the same target
built on Linux, whose step runs the groups at once through scripts/ci/cargo-groups.sh. The NEXT
nightly waits for that tree at "Bundle the cmux-tui client": run 44243166776 waited 37.9 min
there for the 53.7 min mini leg of run 44240874997, and nightlies that waited 45 min on a
cancelled mini leg failed.

At once needs memory: on a 16 GB mini the six builds at once ran out of it (11 GB of swap,
critical pressure at 14 min, review of cmux#46073), where one after another took 33.8 min with a
largest process of 10.9 GB. So scripts/ci/cmux-tui-mac-cargo-builds.sh reads hw.memsize at run
time and runs them at once only at 40 GiB or more (the 48 GB minis), else one after another as
before.

At once also needs cores: a 48 GB mini admitted with 3 (CMUX_CI_CPU_BUDGET=3, CARGO_BUILD_JOBS=3)
ran the six groups at once in 2h01m (run 44947539922), cmux-tui-core and acpmux compiling in both
heavy groups' target directories over 3 time-sliced cores. So the script runs them at once only with
a CPU budget of 8 or more (CMUX_CI_CPU_BUDGET, else hw.ncpu), else one after another in one target
directory, where the heavy builds share what they build alike.

This runs each Mac build step's own script with a fake cargo that takes SLEEP seconds per call
and a fake sysctl that reports FAKE_MEMSIZE and FAKE_NCPU, and checks that:
- with 48 GiB and 8 or more cores the step takes about one call's time, not the sum of six (the groups run at once);
- with 16 GiB, under 8 cores (CMUX_CI_CPU_BUDGET first, else hw.ncpu), or when sysctl cannot
  say, no two cargo calls overlap (one after another) and all build in one target directory;
- every binary and its .dSYM (CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=packed) ends in
  target/<triple>/release, where "Stage binary" and the dSYM upload read them;
- acpmux is staged from acpmux-standalone, with the shipping features for the target.

lane = "manual" (no new CI tests, Lawrence 2026-10-23, lifted 2026-11-18).
Run: python3 tests/test_ci_cmux_tui_mac_legs_cargo_groups.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
ROOT = TESTS.parent
sys.path.insert(0, str(TESTS))
import git_fixture_env  # noqa: E402
import workflow_jobs  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-build-package.yml"
SLEEP = 2.0
CALLS = 6  # cmux-tui, cmux-holder, cmux-app-host, cmux-relay, chatmux-relay, acpmux-standalone
BINARIES = ("cmux-tui", "cmux-tui-hook", "cmux-tui-host", "cmux-holder", "cmux-app-host",
            "cmux-relay", "chatmux-relay", "acpmux-standalone")

FAKE_SYSCTL = r"""#!/usr/bin/env bash
# Fake sysctl: `sysctl -n hw.memsize` prints FAKE_MEMSIZE and `sysctl -n hw.ncpu` FAKE_NCPU; an
# empty value fails as on Linux.
case "$*" in
  "-n hw.memsize") v=${FAKE_MEMSIZE:-} ;;
  "-n hw.ncpu") v=${FAKE_NCPU:-} ;;
  *) v="" ;;
esac
[[ -n "$v" ]] || { echo "sysctl: unknown oid '$*'" >&2; exit 1; }
echo "$v"
"""
GIB = 1024 ** 3

FAKE_CARGO = r"""#!/usr/bin/env bash
# Fake cargo: `cargo build -p PKG [--bin B]... --release --locked --target T [--features=F]`.
set -euo pipefail
[[ "$1" == build ]] || { echo "fake cargo: unexpected $*" >&2; exit 2; }
shift
pkg="" target="" bins=() features=""
while (($#)); do
  case "$1" in
    -p) pkg=$2; shift ;;
    --bin) bins+=("$2"); shift ;;
    --target) target=$2; shift ;;
    --features=*) features=${1#--features=} ;;
    --release|--locked|--timings) ;;
    *) echo "fake cargo: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$target" ]] || { echo "fake cargo: no --target" >&2; exit 2; }
((${#bins[@]})) || bins=("$pkg")
out="${CARGO_TARGET_DIR:-$PWD/target}/$target/release"
mkdir -p "$out"
echo "$pkg $(date +%s.%N) start" >> "$FAKE_CARGO_LOG"
sleep "$FAKE_CARGO_SLEEP"
for b in "${bins[@]}"; do
  printf '%s features=%s commit=%s\n' "$b" "$features" "${CMUX_TUI_BUILD_COMMIT:-}" > "$out/$b"
  chmod +x "$out/$b"
  if [[ "${CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO:-}" == packed ]]; then
    mkdir -p "$out/$b.dSYM/Contents/Resources/DWARF"
    echo "$b" > "$out/$b.dSYM/Contents/Resources/DWARF/$b"
  fi
done
echo "$pkg $(date +%s.%N) end" >> "$FAKE_CARGO_LOG"
"""


def step(name: str) -> dict:
    found = [s for s in workflow_jobs.jobs(WORKFLOW)["build"]["steps"] if s.get("name") == name]
    assert len(found) == 1, f"one step named {name!r}, found {len(found)}"
    return found[0]


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env=git_fixture_env.fixture_env(os.environ.copy()))


def make_repo(root: Path) -> None:
    for d in (root, root / "ghostty-next"):
        d.mkdir(parents=True, exist_ok=True)
        git(d, "init", "-q")
        (d / "README").write_text("x\n")
        git(d, "add", "README")
        git(d, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x")
    (root / "scripts" / "ci").mkdir(parents=True)
    for script in ("cargo-groups.sh", "acpmux-build-features.sh", "cmux-tui-mac-cargo-builds.sh"):
        if not (ROOT / "scripts" / "ci" / script).exists():
            continue  # the base before the memory gate has no such script
        shutil.copy2(ROOT / "scripts" / "ci" / script, root / "scripts" / "ci" / script)
    for crate in ("acpmux", "acpmux-standalone"):
        manifest = root / "cmux-tui" / "crates" / crate / "Cargo.toml"
        manifest.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "cmux-tui" / "crates" / crate / "Cargo.toml", manifest)


def expected_features(root: Path, triple: str) -> str:
    out = subprocess.run(
        ["bash", str(root / "scripts" / "ci" / "acpmux-build-features.sh"),
         "crates/acpmux/Cargo.toml", triple, "acpmux"],
        cwd=root / "cmux-tui", check=True, capture_output=True, text=True).stdout.strip()
    return out.removeprefix("--features=")


class MacLegsRunCargoAtOnce(unittest.TestCase):
    def run_step(self, name: str, triple: str, memsize: int | None = 48 * GIB,
                 sleep: float = SLEEP, ncpu: int | None = 12,
                 budget: str | None = None, preread: bool = False) -> tuple[float, Path, str, str]:
        script = str(step(name)["run"]).replace("${{ matrix.build_target }}", triple)
        self.assertNotIn("${{", script, "the step reads an expression this test does not fill")
        tmp = Path(tempfile.mkdtemp(prefix="mac-legs-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        root = tmp / "repo"
        make_repo(root)
        if preread:
            manifest = root / "cmux-tui/crates/cmux-launch-preread/Cargo.toml"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('[package]\nname = "cmux-launch-preread"\n')
        bindir = tmp / "bin"
        bindir.mkdir()
        (bindir / "cargo").write_text(FAKE_CARGO)
        (bindir / "cargo").chmod(0o755)
        (bindir / "sysctl").write_text(FAKE_SYSCTL)
        (bindir / "sysctl").chmod(0o755)
        log = tmp / "cargo.log"
        env = git_fixture_env.fixture_env({
            **os.environ,
            "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_OS": "macOS",
            "RUNNER_TEMP": str(tmp),
            "CMUX_TUI_DISTRIBUTION_VERSION": "0.0.0-test",
            "PACKAGE_NPM": "false",
            "FAKE_CARGO_SLEEP": str(sleep),
            "FAKE_MEMSIZE": "" if memsize is None else str(memsize),
            "FAKE_NCPU": "" if ncpu is None else str(ncpu),
            "FAKE_CARGO_LOG": str(log),
        })
        env.pop("CARGO_TARGET_DIR", None)
        env.pop("CARGO_BUILD_JOBS", None)
        env.pop("GITHUB_ACTIONS", None)
        env.pop("CMUX_CI_CPU_BUDGET", None)
        if budget is not None:
            env["CMUX_CI_CPU_BUDGET"] = budget
        started = time.monotonic()
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                              cwd=root / "cmux-tui", env=env, capture_output=True, text=True)
        took = time.monotonic() - started
        self.assertEqual(done.returncode, 0, f"{name} failed:\n{done.stdout}\n{done.stderr}")
        return took, root / "cmux-tui" / "target" / triple / "release", log.read_text(), expected_features(root, triple)

    def check(self, name: str, triple: str, memsize: int | None = 48 * GIB, ncpu: int | None = 12,
              budget: str | None = None) -> None:
        valid_budget = budget is not None and budget.isdigit() and int(budget) > 0
        cpus = int(budget) if valid_budget else (ncpu or 0)
        concurrent = memsize is not None and memsize >= 40 * GIB and cpus >= 8
        took, release, log, features = self.run_step(name, triple, memsize, SLEEP if concurrent else 0.2,
                                                     ncpu, budget)
        self.assertEqual(log.count(" start"), CALLS, log)
        if concurrent:
            # One after another this is CALLS * SLEEP (12 s); at once about SLEEP plus the setup.
            self.assertLess(took, (CALLS - 2) * SLEEP,
                            f"{name} took {took:.1f} s for {CALLS} cargo calls of {SLEEP} s each with "
                            f"{memsize / GIB:.0f} GiB: they ran one after another, not at once (scripts/ci/cargo-groups.sh)")
        else:
            events = [(float(t), kind) for _, t, kind in (line.split() for line in log.splitlines())]
            events.sort()
            running = peak = 0
            for _, kind in events:
                running += 1 if kind == "start" else -1
                peak = max(peak, running)
            mem = "no hw.memsize" if memsize is None else f"hw.memsize {memsize}"
            mem += f", {cpus} cores"
            self.assertEqual(peak, 1, f"{name} ran {peak} cargo builds at once with {mem}: a 16 GB mini "
                             "runs out of memory that way, and 3 cores took 2h01m (run 44947539922) "
                             "(scripts/ci/cmux-tui-mac-cargo-builds.sh)\n" + log)
            groups = release.parent.parent / "groups"
            self.assertFalse(groups.exists(), f"{name} built in per-group target dirs ({groups}) one after "
                             "another: the heavy builds then compile cmux-tui-core and acpmux twice")
        for b in BINARIES:
            self.assertTrue((release / b).is_file(), f"{name}: no {b} in {release}")
            self.assertTrue((release / f"{b}.dSYM" / "Contents" / "Resources" / "DWARF" / b).is_file(),
                            f"{name}: no {b}.dSYM in {release} (the dSYM upload reads target/<triple>/release/*.dSYM)")
        acpmux = (release / "acpmux").read_text()
        self.assertTrue(acpmux.startswith("acpmux-standalone "), acpmux)
        self.assertIn(f"features={features}", acpmux)
        self.assertNotIn("commit=\n", acpmux, "CMUX_TUI_BUILD_COMMIT did not reach cargo")

    def test_preread_is_its_own_group_on_native_and_cross_macos_legs(self) -> None:
        for name, triple in (("Build cmux-tui (native)", "aarch64-apple-darwin"),
                             ("Build cmux-tui (macOS cross)", "x86_64-apple-darwin")):
            for mem in (16 * GIB, 48 * GIB):
                with self.subTest(name=name, mem=mem):
                    _, release, log, _ = self.run_step(name, triple, mem, sleep=0, preread=True)
                    self.assertEqual(log.count(" start"), CALLS + 1)
                    self.assertIn("cmux-launch-preread ", log)
                    self.assertTrue((release / "cmux-launch-preread").is_file())

    def test_preread_staging_clears_stale_files_and_requires_present_crate_output(self) -> None:
        script = str(step("Stage binary")["run"])
        script = script[script.index('rm -f "dist/cmux-tui-launch-preread-'):
                        script.index("# The bundled agent screen detector")]
        for triple in ("aarch64-apple-darwin", "x86_64-apple-darwin", "x86_64-unknown-linux-musl"):
            for crate, binary in ((False, False), (False, True), (True, False), (True, True)):
                with self.subTest(triple=triple, crate=crate, binary=binary), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    output = root / f"dist/cmux-tui-launch-preread-{triple}"
                    output.parent.mkdir()
                    output.write_text("stale")
                    if crate:
                        manifest = root / "cmux-tui/crates/cmux-launch-preread/Cargo.toml"
                        manifest.parent.mkdir(parents=True)
                        manifest.touch()
                    if binary:
                        built = root / f"cmux-tui/target/{triple}/release/cmux-launch-preread"
                        built.parent.mkdir(parents=True)
                        built.write_text("new")
                    done = subprocess.run(["bash", "-euc", script.replace("${{ matrix.target }}", triple)],
                                          cwd=root, env={**os.environ, "STAGE_TARGET": triple},
                                          capture_output=True, text=True)
                    wanted = crate and triple.endswith("-apple-darwin")
                    self.assertEqual(done.returncode == 0, not wanted or binary, done.stderr)
                    self.assertEqual(output.exists(), wanted and binary)
                    if output.exists():
                        self.assertEqual(output.read_text(), "new")

    def test_native_leg_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin")

    def test_mac_cross_leg_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (macOS cross)", "x86_64-apple-darwin")

    def test_native_leg_on_16_gib_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 16 * GIB)

    def test_mac_cross_leg_on_16_gib_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (macOS cross)", "x86_64-apple-darwin", 16 * GIB)

    def test_native_leg_at_40_gib_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 40 * GIB)

    def test_native_leg_just_under_40_gib_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 40 * GIB - 1)

    def test_native_leg_without_hw_memsize_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", None)

    def test_native_leg_with_a_cpu_budget_of_3_runs_its_cargo_builds_one_after_another(self) -> None:
        # Run 44947539922: 48 GiB, CMUX_CI_CPU_BUDGET=3, at once took 2h01m.
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, budget="3")

    def test_mac_cross_leg_with_a_cpu_budget_of_3_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (macOS cross)", "x86_64-apple-darwin", 48 * GIB, budget="3")

    def test_native_leg_with_a_cpu_budget_of_8_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, ncpu=4, budget="8")

    def test_native_leg_with_a_cpu_budget_of_7_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, ncpu=14, budget="7")

    def test_native_leg_without_a_budget_on_4_cores_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, ncpu=4)

    def test_native_leg_with_a_bad_budget_falls_back_to_hw_ncpu(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, ncpu=12, budget="0")

    def test_native_leg_without_hw_ncpu_runs_its_cargo_builds_one_after_another(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin", 48 * GIB, ncpu=None)


if __name__ == "__main__":
    unittest.main()
