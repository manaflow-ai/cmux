#!/usr/bin/env python3
"""The cmux-tui macOS legs built on a Mac run their cargo invocations at once, as the Linux legs do.

.github/workflows/cmux-tui-build-package.yml builds the aarch64-apple-darwin leg of a tree on a
free owned mini when one is idle ("Build cmux-tui (native)"; x86_64-apple-darwin on main in
"Build cmux-tui (macOS cross)"). Those steps ran their six cargo builds one after another, so
each fat-LTO link (one core) ran alone: the mini legs of 2026-11-17/18 took 42.1, 53.7, and
62.5 and 65.0 min (cancelled by the job timeout), against 13-15 min (p50) for the same target
built on Linux, whose step runs the groups at once through scripts/ci/cargo-groups.sh. The NEXT
nightly waits for that tree at "Bundle the cmux-tui client": run 44243166776 waited 37.9 min
there for the 53.7 min mini leg of run 44240874997, and nightlies that waited 45 min on a
cancelled mini leg failed.

This runs each Mac build step's own script with a fake cargo that takes SLEEP seconds per call
and checks that:
- the step takes about one call's time, not the sum of six (the groups run at once);
- every binary and its .dSYM (CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO=packed) ends in
  target/<triple>/release, where "Stage binary" and the dSYM upload read them;
- acpmux is staged from acpmux-standalone, with the shipping features for the target.

lane = "manual" (no new CI tests, Lawrence 2026-10-23).
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
    for script in ("cargo-groups.sh", "acpmux-build-features.sh"):
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
    def run_step(self, name: str, triple: str) -> tuple[float, Path, str, str]:
        script = str(step(name)["run"]).replace("${{ matrix.build_target }}", triple)
        self.assertNotIn("${{", script, "the step reads an expression this test does not fill")
        tmp = Path(tempfile.mkdtemp(prefix="mac-legs-"))
        self.addCleanup(shutil.rmtree, tmp, True)
        root = tmp / "repo"
        make_repo(root)
        bindir = tmp / "bin"
        bindir.mkdir()
        (bindir / "cargo").write_text(FAKE_CARGO)
        (bindir / "cargo").chmod(0o755)
        log = tmp / "cargo.log"
        env = git_fixture_env.fixture_env({
            **os.environ,
            "PATH": f"{bindir}{os.pathsep}{os.environ['PATH']}",
            "RUNNER_OS": "macOS",
            "RUNNER_TEMP": str(tmp),
            "CMUX_TUI_DISTRIBUTION_VERSION": "0.0.0-test",
            "PACKAGE_NPM": "false",
            "FAKE_CARGO_SLEEP": str(SLEEP),
            "FAKE_CARGO_LOG": str(log),
        })
        env.pop("CARGO_TARGET_DIR", None)
        env.pop("CARGO_BUILD_JOBS", None)
        env.pop("GITHUB_ACTIONS", None)
        started = time.monotonic()
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                              cwd=root / "cmux-tui", env=env, capture_output=True, text=True)
        took = time.monotonic() - started
        self.assertEqual(done.returncode, 0, f"{name} failed:\n{done.stdout}\n{done.stderr}")
        return took, root / "cmux-tui" / "target" / triple / "release", log.read_text(), expected_features(root, triple)

    def check(self, name: str, triple: str) -> None:
        took, release, log, features = self.run_step(name, triple)
        self.assertEqual(log.count(" start"), CALLS, log)
        # One after another this is CALLS * SLEEP (12 s); at once about SLEEP plus the setup.
        self.assertLess(took, (CALLS - 2) * SLEEP,
                        f"{name} took {took:.1f} s for {CALLS} cargo calls of {SLEEP} s each: "
                        "they ran one after another, not at once (scripts/ci/cargo-groups.sh)")
        for b in BINARIES:
            self.assertTrue((release / b).is_file(), f"{name}: no {b} in {release}")
            self.assertTrue((release / f"{b}.dSYM" / "Contents" / "Resources" / "DWARF" / b).is_file(),
                            f"{name}: no {b}.dSYM in {release} (the dSYM upload reads target/<triple>/release/*.dSYM)")
        acpmux = (release / "acpmux").read_text()
        self.assertTrue(acpmux.startswith("acpmux-standalone "), acpmux)
        self.assertIn(f"features={features}", acpmux)
        self.assertNotIn("commit=\n", acpmux, "CMUX_TUI_BUILD_COMMIT did not reach cargo")

    def test_native_leg_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (native)", "aarch64-apple-darwin")

    def test_mac_cross_leg_runs_its_cargo_builds_at_once(self) -> None:
        self.check("Build cmux-tui (macOS cross)", "x86_64-apple-darwin")


if __name__ == "__main__":
    unittest.main()
