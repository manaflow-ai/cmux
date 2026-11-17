#!/usr/bin/env python3
"""Every nightly job that compiles gives its tools the macOS SDK of the Xcode it selected.

A tool that runs cc or c++ with no SDK (a cargo build script under rustc 1.88.0, npm's
node-gyp for create-dmg / fs-xattr) takes the SDK xcrun names by default. On a macOS 27 Mac
with Command Line Tools 27 and DEVELOPER_DIR=Xcode_26.6 that default is
/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk, and the Xcode 26.6 linker cannot
read it: "tapi error: ... unknown architecture arm64e.x1-macos". It failed the nightly two
times on 2026-11-10: run 42775849251 (build-nightly-app, the OptChat Chief cargo build) and
run 42804411758 (build-sign-notarize-nightly, "Install build deps").

The repo fix is one step per job, "Select the SDK of the selected Xcode", which writes
SDKROOT=<that Xcode's macOS SDK> to GITHUB_ENV before any step that compiles.

This test runs with no Mac and no nightly run. It builds the fault's host out of fakes (an
xcrun whose default SDK is the Command Line Tools' MacOSX27.0.sdk, a c++ that links only
against the SDK of its own Xcode), then walks each job's steps in order, RUNS the workflow's
own SDK step script where the job has it, and links a one-line file with the environment the
next step gets. Without the step the link takes the Command Line Tools SDK and fails.

Run it yourself after changing a "Select Xcode" step or a compiling job in nightly.yml:
python3 tests/test_nightly_job_sdkroot.py (about 1 s, no Mac).
"""
from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
JOBS = yaml.safe_load(WORKFLOW.read_text())["jobs"]
SELECTOR = "scripts/select-ci-xcode.sh"
SDK_STEP = "Select the SDK of the selected Xcode"
# Compiles with Zig only and selects no Xcode (tests/test_ci_macos_xcode_selection.py EXEMPT):
# its SDK step names the SDK of the host's default Xcode, before the step that installs Zig.
ZIG_ONLY = {"build-nightly-ghostty-cli-helper": "Install Zig"}

FAKE_XCRUN = r"""#!/usr/bin/env bash
# xcrun of the fault's host. `--sdk macosx` names the SDK of the Xcode in DEVELOPER_DIR (the
# host's default Xcode when unset). With no --sdk, SDKROOT wins, and without SDKROOT the
# default is the Command Line Tools SDK. Measured on Xcode 26.6's xcrun, 2026-11-10.
sdk="" want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sdk) sdk="$2"; shift ;;
    --show-sdk-path) want=path ;;
    -n|--no-cache) ;;
    *) echo "fake xcrun: unexpected argument $1" >&2; exit 64 ;;
  esac
  shift
done
[ "$want" = path ] || exit 64
if [ "$sdk" = macosx ]; then
  [ "${FAKE_XCRUN_BROKEN:-}" = 1 ] && exit 1
  echo "${DEVELOPER_DIR:-$FAKE_DEFAULT_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
elif [ -n "${SDKROOT:-}" ]; then
  echo "$SDKROOT"
else
  echo "$FAKE_CLT_SDK"
fi
"""

FAKE_CXX = r"""#!/usr/bin/env bash
# c++ of the Xcode in DEVELOPER_DIR: it links against SDKROOT, else xcrun's default SDK, and
# its linker reads only the SDK of its own Xcode.
sysroot="${SDKROOT:-$(xcrun --show-sdk-path)}"
own="${DEVELOPER_DIR:-$FAKE_DEFAULT_DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
if [ "$sysroot" != "$own" ]; then
  echo "ld: tapi error: malformed file $sysroot/usr/lib/libc++.1.tbd: unknown architecture arm64e.x1-macos" >&2
  exit 1
fi
"""


def steps_of(job: str) -> list[dict]:
    return JOBS[job].get("steps") or []


def runs_selector(step: dict) -> bool:
    return SELECTOR in str(step.get("run", ""))


def compiling_jobs() -> list[str]:
    """Jobs that select an Xcode, and the Zig-only helper job."""
    return [name for name, job in JOBS.items()
            if name in ZIG_ONLY or any(runs_selector(s) for s in job.get("steps") or [])]


class Host:
    """A macOS 27 Mac with Xcode 26.6 selected and Command Line Tools 27 installed, made of fakes."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.bin = root / "bin"
        self.bin.mkdir()
        for name, text in (("xcrun", FAKE_XCRUN), ("c++", FAKE_CXX)):
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o755)
        self.developer = root / "Applications/Xcode_26.6.app/Contents/Developer"
        self.xcode_sdk = self.developer / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
        self.clt_sdk = root / "Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk"
        self.xcode_sdk.mkdir(parents=True)
        self.clt_sdk.mkdir(parents=True)

    def environment(self, **extra: str) -> dict[str, str]:
        return {"PATH": f"{self.bin}:{os.environ['PATH']}", "HOME": str(self.root),
                "FAKE_CLT_SDK": str(self.clt_sdk), "FAKE_DEFAULT_DEVELOPER_DIR": str(self.developer), **extra}

    def run_step(self, script: str, env: dict[str, str]) -> subprocess.CompletedProcess:
        """Run a step's script as the runner does for `shell: bash`; apply what it wrote to GITHUB_ENV."""
        github_env = self.root / "github-env"
        github_env.write_text("")
        result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                                env={**env, "GITHUB_ENV": str(github_env)}, capture_output=True, text=True)
        for line in github_env.read_text().splitlines():
            key, _, value = line.partition("=")
            env[key] = value
        return result

    def link(self, env: dict[str, str]) -> subprocess.CompletedProcess:
        return subprocess.run(["c++", "one.cpp", "-o", "one"], env=env, capture_output=True, text=True)

    def environment_after_setup(self, job: str) -> dict[str, str]:
        """The environment of the first step after the job's toolchain setup.

        "Select Xcode" exports DEVELOPER_DIR (the fake Xcode 26.6); the Zig-only job selects
        none and keeps the host default. The walk stops at the first step after that which is
        not the SDK step: every later step of the job can compile.
        """
        env = self.environment()
        steps = steps_of(job)
        if job in ZIG_ONLY:
            start = 0
            end = next(i for i, s in enumerate(steps) if s.get("name") == ZIG_ONLY[job])
        else:
            start = next(i for i, s in enumerate(steps) if runs_selector(s))
            env["DEVELOPER_DIR"] = str(self.developer)
            end = start + 2
        for step in steps[start:end]:
            if step.get("name") == SDK_STEP:
                result = self.run_step(step["run"], env)
                assert result.returncode == 0, f"{job}: the SDK step failed: {result.stdout}{result.stderr}"
        return env


class NightlyJobSdkroot(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.host = Host(Path(self._tmp.name))

    def test_the_fake_host_has_the_fault(self) -> None:
        # The red this test stands on: with Xcode 26.6 selected and no SDKROOT, a link takes the
        # Command Line Tools' MacOSX27.0.sdk and fails; with the Xcode's own SDK it passes.
        env = self.host.environment(DEVELOPER_DIR=str(self.host.developer))
        failed = self.host.link(env)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("unknown architecture arm64e.x1-macos", failed.stderr)
        self.assertIn(str(self.host.clt_sdk), failed.stderr)
        self.assertEqual(self.host.link({**env, "SDKROOT": str(self.host.xcode_sdk)}).returncode, 0)

    def test_the_compiling_jobs_are_the_known_ones(self) -> None:
        # A new job that selects an Xcode joins the walk by itself; this keeps the set from shrinking unseen.
        self.assertEqual(sorted(compiling_jobs()), sorted([
            "refresh-compilation-cache", "refresh-test-compilation-cache", "build-nightly-ghostty-cli-helper",
            "build-nightly-app", "build-sign-notarize-nightly", "verify-signed-nightly",
            "verify-final-dmg-nightly", "recover-nightly-next-notarization", "verify-recovered-nightly-next",
            "visual-gate-nightly", "build-nightly-deltas", "generate-nightly-deltas",
        ]))

    def test_a_link_in_each_compiling_job_takes_the_selected_xcodes_sdk(self) -> None:
        for job in compiling_jobs():
            with self.subTest(job=job):
                env = self.host.environment_after_setup(job)
                linked = self.host.link(env)
                self.assertEqual(
                    linked.returncode, 0,
                    f"{job}: a cc/c++ with no SDK links against xcrun's default SDK, not the selected Xcode's "
                    f"(SDKROOT={env.get('SDKROOT', 'unset')}): {linked.stderr.strip()} "
                    f"Add the '{SDK_STEP}' step right after the job's Xcode selection.")
                self.assertEqual(env.get("SDKROOT"), str(self.host.xcode_sdk))

    def test_the_sdk_step_runs_whenever_the_setup_before_it_runs(self) -> None:
        # A resumed run skips the job's build steps: the SDK step carries the same `if:` as the
        # Xcode selection (the Zig-only job: as its Zig install), so it never runs alone.
        for job in compiling_jobs():
            with self.subTest(job=job):
                steps = steps_of(job)
                sdk_steps = [s for s in steps if s.get("name") == SDK_STEP]
                self.assertEqual(len(sdk_steps), 1, f"{job} sets SDKROOT one time per job")
                partner = (next(s for s in steps if s.get("name") == ZIG_ONLY[job]) if job in ZIG_ONLY
                           else next(s for s in steps if runs_selector(s)))
                self.assertEqual(sdk_steps[0].get("if"), partner.get("if"))

    def test_every_copy_of_the_sdk_step_is_the_same_script(self) -> None:
        scripts = {s["run"] for job in JOBS for s in steps_of(job) if s.get("name") == SDK_STEP}
        self.assertEqual(len(scripts), 1, "one script: edit the anchored step, then its conditional twin")

    def sdk_script(self) -> str:
        scripts = [s["run"] for job in JOBS for s in steps_of(job) if s.get("name") == SDK_STEP]
        self.assertTrue(scripts, f"nightly.yml has no '{SDK_STEP}' step")
        return scripts[0]

    def test_an_sdkroot_from_the_runner_is_replaced(self) -> None:
        # A runner service or an xcrun shim may already export SDKROOT (the wrong SDK on 2026-10-07,
        # scripts/ci/package-test-lane.sh): the step names the selected Xcode's SDK all the same.
        env = self.host.environment(DEVELOPER_DIR=str(self.host.developer), SDKROOT=str(self.host.clt_sdk))
        result = self.host.run_step(self.sdk_script(), env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(env["SDKROOT"], str(self.host.xcode_sdk))
        self.assertEqual(self.host.link(env).returncode, 0)

    def test_no_sdk_stops_the_job_with_one_error(self) -> None:
        for extra in ({"FAKE_XCRUN_BROKEN": "1"}, {"DEVELOPER_DIR": str(self.host.root / "Applications/Gone.app")}):
            with self.subTest(extra=extra):
                env = self.host.environment(**extra)
                result = self.host.run_step(self.sdk_script(), env)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SDKROOT", env)
                self.assertEqual(result.stdout.count("::error"), 1, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
