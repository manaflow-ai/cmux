#!/usr/bin/env python3
"""A Linux leg the runner lost does not turn off the macOS fallback; a Linux build failure still does.

darwin-fallback-plan builds the macOS targets on a Mac when the Linux cross-link of them fails. It
refused whenever a Linux musl target had no artifacts ("the $linux build failed too"). In run
44942698705 the x86_64-unknown-linux-musl leg was cancelled 60 s in ("The runner has received a
shutdown signal": the runner was preempted), so the macOS fallback was refused for the whole run though
no Linux build had failed.

This runs the plan step itself with a fake `gh` (the GitHub API answers come from fixtures and the
step's own --jq filters run through jq). A missing Linux target whose leg ended cancelled, or failed
with no failed step (a lost runner), plans the fallback; one whose leg failed in a step, or that the
jobs read cannot place, still refuses.
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"
REPO = "manaflow-ai/cmux"
LINUX = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
KINDS = ("cmux-tui", "cmux-relay", "chatmux-relay")

# gh api PATH [--paginate] [--jq EXPR]: answers from FAKE_GH_ROUTES (path without query -> JSON body,
# or null for a failed call) and applies --jq with jq, as gh does.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(args) + "\n")
if not args or args[0] != "api":
    sys.exit(2)
jq = None
path = None
rest = args[1:]
i = 0
while i < len(rest):
    if rest[i] == "--jq":
        jq = rest[i + 1]; i += 2; continue
    if rest[i].startswith("-"):
        i += 1; continue
    path = rest[i]; i += 1
routes = json.load(open(os.environ["FAKE_GH_ROUTES"]))
body = routes.get(path.split("?")[0])
if body is None:
    print("gh: Not Found (HTTP 404)", file=sys.stderr)
    sys.exit(1)
text = json.dumps(body)
if jq is None:
    print(text)
    sys.exit(0)
done = subprocess.run(["jq", "-r", jq], input=text, text=True, capture_output=True)
sys.stdout.write(done.stdout)
sys.stderr.write(done.stderr)
sys.exit(done.returncode)
'''


def plan_step() -> dict:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    steps = [s for s in document["jobs"]["darwin-fallback-plan"]["steps"] if s.get("id") == "plan"]
    assert len(steps) == 1, "darwin-fallback-plan has one step with id plan"
    return steps[0]


def artifacts(targets) -> dict:
    return {"artifacts": [{"name": f"{kind}-{target}"} for target in targets for kind in KINDS]}


DARWIN_BUILD_STEP = "Build the macOS binaries on Linux (no Apple SDK)"
# The macOS cross leg's steps in order (job 138283422102), trimmed.
DARWIN_STEPS = ("Set up job", "Checkout caller or requested ref",
                "Fetch the ghostty-next Zig packages (cached, deadlined, retried)",
                "Install the macOS cross toolchain", DARWIN_BUILD_STEP, "Stage binary")


def leg(target: str, conclusion: str | None, failed_step: str | None = None, job_id: int = 1) -> dict:
    steps = [{"name": "Set up job", "conclusion": "success", "number": 1}]
    if target.endswith("-apple-darwin"):
        steps = []
        for number, name in enumerate(DARWIN_STEPS, 1):
            ran = failed_step is None or DARWIN_STEPS.index(name) < DARWIN_STEPS.index(failed_step)
            state = "failure" if name == failed_step else ("success" if ran else "skipped")
            steps.append({"name": name, "conclusion": state, "number": number})
    elif failed_step:
        steps.append({"name": failed_step, "conclusion": "failure", "number": 2})
    elif conclusion == "cancelled":
        steps.append({"name": "Build cmux-tui (Linux cross)", "conclusion": "cancelled", "number": 2})
    # The Linux targets build in build-linux, their own call (#51895); the macOS ones in build.
    caller = "build" if target.endswith("-apple-darwin") else "build-linux"
    return {"id": job_id, "name": f"{caller} / build {target}", "conclusion": conclusion, "steps": steps}


@unittest.skipIf(shutil.which("jq") is None, "jq runs the step's --jq filters (GitHub's runners have it)")
class FallbackIgnoresALostLinuxLeg(unittest.TestCase):
    def run_plan(self, built, jobs=None, build_result="failure", logs=None, attempt="1", base_stubs=None) -> tuple[dict, str, str]:
        step = plan_step()
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            bin_dir = temp_path / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            gh.write_text(FAKE_GH, encoding="utf-8")
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            routes = {f"repos/{REPO}/actions/runs/100/artifacts": artifacts(built)}
            if jobs is not None:
                routes[f"repos/{REPO}/actions/runs/100/attempts/{attempt}/jobs"] = {"total_count": len(jobs), "jobs": jobs}
            for job_id, text in (logs or {}).items():
                routes[f"repos/{REPO}/actions/jobs/{job_id}/logs"] = text
            if base_stubs is not None:
                routes[f"repos/{REPO}/commits/feat-cmux-next"] = {"sha": "b" * 40}
                routes[f"repos/{REPO}/contents/scripts/ci"] = [{"name": "macos-stubs", "sha": base_stubs}]
            (temp_path / "routes.json").write_text(json.dumps(routes), encoding="utf-8")
            output = temp_path / "output"
            output.touch()
            log = temp_path / "gh.log"
            log.touch()
            # Only what the workflow sets: the step's env block, with its expressions filled in.
            env = {
                "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                "HOME": temp,
                "GITHUB_OUTPUT": str(output),
                "GITHUB_REF": "refs/heads/feat-cmux-next",
                "GITHUB_SHA": "a" * 40,
                "FAKE_GH_ROUTES": str(temp_path / "routes.json"),
                "FAKE_GH_LOG": str(log),
                "GH_TOKEN": "x",
                "GH_TOKEN_SPARES": "",
                "GH_BUDGET_WAIT_MAX_SECONDS": "0",
                "REPOSITORY": REPO,
                "RUN_ID": "100",
                "RUN_ATTEMPT": attempt,
                "BUILD_RESULT": build_result,
                "BRANCH_PUSH": "",
            }
            for name in step["env"]:
                self.assertIn(name, env, f"the test sets the plan step's env {name}")
            result = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True, timeout=60, cwd=ROOT)
            self.assertEqual(result.returncode, 0, result.stderr)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)
            return values, result.stdout, log.read_text()

    def test_a_cancelled_linux_leg_still_plans_the_macos_fallback(self) -> None:
        # Run 44942698705: x86_64 musl cancelled 60 s in, aarch64 musl built, the macOS link failed.
        values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], [
            leg("aarch64-unknown-linux-musl", "success"),
            leg("x86_64-unknown-linux-musl", "cancelled"),
            leg("aarch64-apple-darwin", "failure", "Build the macOS binaries on Linux (no Apple SDK)"),
        ])
        self.assertEqual(values.get("target_set"), "macos-arm64", out)
        self.assertEqual(values.get("recovered"), "false")
        self.assertIn("x86_64-unknown-linux-musl leg ended cancelled", out)
        self.assertNotIn("::error", out)

    def test_a_linux_leg_that_lost_its_runner_still_plans_the_macos_fallback(self) -> None:
        # A runner that stops answering ends the job `failure` with no step failed.
        values, out, _ = self.run_plan(["x86_64-unknown-linux-musl"], [
            leg("x86_64-unknown-linux-musl", "success"),
            leg("aarch64-unknown-linux-musl", "failure"),
        ])
        self.assertEqual(values.get("target_set"), "macos-arm64", out)

    def test_a_failed_linux_build_still_refuses(self) -> None:
        values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], [
            leg("aarch64-unknown-linux-musl", "success"),
            leg("x86_64-unknown-linux-musl", "failure", "Build cmux-tui (Linux cross)"),
        ])
        self.assertEqual(values.get("target_set"), "", out)
        self.assertEqual(values.get("recovered"), "false")
        self.assertIn("the x86_64-unknown-linux-musl build failed too", out)

    def test_one_lost_leg_does_not_excuse_another_that_failed(self) -> None:
        values, out, _ = self.run_plan([], [
            leg("x86_64-unknown-linux-musl", "cancelled"),
            leg("aarch64-unknown-linux-musl", "failure", "Build cmux-tui (Linux cross)"),
        ])
        self.assertEqual(values.get("target_set"), "", out)
        self.assertIn("the aarch64-unknown-linux-musl build failed too", out)

    def test_an_unreadable_or_unplaced_leg_refuses_as_before(self) -> None:
        for why, jobs in (("the jobs read failed", None),
                          ("no leg has that name", [leg("aarch64-unknown-linux-musl", "success")]),
                          ("the leg was skipped", [leg("x86_64-unknown-linux-musl", "skipped")])):
            values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], jobs)
            self.assertEqual(values.get("target_set"), "", f"{why}: {out}")
            self.assertIn("the x86_64-unknown-linux-musl build failed too", out, why)

    def test_a_linux_leg_still_building_does_not_hold_the_fallback(self) -> None:
        # FALLBACK_STARTS_WHEN_BUILD_FAILS: the plan no longer waits on build-linux (run 46095639867:
        # the macOS leg failed at 02:18Z, the plan started at 02:26Z). A leg with no conclusion yet
        # is still building, not failed.
        values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], [
            leg("x86_64-unknown-linux-musl", None),
            leg("aarch64-unknown-linux-musl", "success"),
        ])
        self.assertEqual(values.get("target_set"), "macos-arm64", out)
        self.assertIn("the x86_64-unknown-linux-musl leg is still building", out)

    def test_a_same_named_leg_of_another_caller_is_not_read(self) -> None:
        # Only build-linux's leg of a Linux target counts (#51895), not a leg of that name in build.
        values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], [
            {"name": "build / build x86_64-unknown-linux-musl", "conclusion": "cancelled", "steps": []},
            leg("x86_64-unknown-linux-musl", "failure", "Build cmux-tui (Linux cross)"),
        ])
        self.assertEqual(values.get("target_set"), "", out)

    def test_every_linux_target_built_never_reads_the_jobs(self) -> None:
        values, out, log = self.run_plan(list(LINUX))
        self.assertEqual(values.get("target_set"), "macos-arm64", out)
        # Only the macOS legs' read (FALLBACK_RETRIES_LOST_LEGS_ON_LINUX), never the Linux legs'.
        self.assertEqual(log.count("/jobs"), 1, log)
        self.assertNotIn("build-linux", log)
        values, out, log = self.run_plan(list(LINUX) + ["aarch64-apple-darwin"])
        self.assertEqual(values.get("target_set"), "", out)
        self.assertEqual(values.get("recovered"), "true")
        self.assertNotIn("/jobs", log)

    # FALLBACK_RETRIES_LOST_LEGS_ON_LINUX: a macOS leg that never reached its link rebuilds on Linux.
    def darwin_plan(self, failed_step, **kwargs) -> tuple[dict, str]:
        values, out, _ = self.run_plan(list(LINUX), [
            leg("x86_64-unknown-linux-musl", "success"),
            leg("aarch64-unknown-linux-musl", "success"),
            leg("aarch64-apple-darwin", kwargs.pop("conclusion", "failure"), failed_step, job_id=7),
        ], **kwargs)
        self.assertEqual(values.get("target_set"), "macos-arm64", out)
        return values, out

    def test_a_macos_leg_that_failed_before_its_link_rebuilds_on_linux(self) -> None:
        for step in ("Checkout caller or requested ref",
                     "Fetch the ghostty-next Zig packages (cached, deadlined, retried)"):
            values, out = self.darwin_plan(step)
            self.assertEqual(values.get("builder"), "linux", f"{step}: {out}")
            self.assertNotIn("cross_failed", values, "no red linux-cross status for a lost leg")

    def test_a_macos_leg_that_lost_its_runner_rebuilds_on_linux(self) -> None:
        values, out = self.darwin_plan(None)
        self.assertEqual(values.get("builder"), "linux", out)
        values, out = self.darwin_plan(DARWIN_BUILD_STEP, logs={7: "...\n##[error]The runner has received a shutdown signal. This can"})
        self.assertEqual(values.get("builder"), "linux", out)

    def test_a_failed_link_on_older_stubs_relinks_on_linux_with_the_bases(self) -> None:
        # 2026-11-24: heads from before #53037 failed on kSecGuestAttributePid and went to a Mac.
        values, out = self.darwin_plan(DARWIN_BUILD_STEP, base_stubs="c" * 40,
                                       logs={7: "ld64.lld: error: undefined symbol: kSecGuestAttributePid"})
        self.assertEqual(values.get("builder"), "linux", out)
        self.assertEqual(values.get("stubs_ref"), "b" * 40)
        self.assertNotIn("cross_failed", values)

    def test_a_plain_compile_error_has_no_fallback(self) -> None:
        values, out, _ = self.run_plan(list(LINUX), [
            leg("aarch64-apple-darwin", "failure", DARWIN_BUILD_STEP, job_id=7),
        ], logs={7: "error[E0432]: unresolved import\nerror: could not compile `cmux-tui`"})
        self.assertEqual(values.get("target_set"), "", out)
        self.assertIn("::error title=no macOS fallback", out)

    def test_a_failed_link_still_rebuilds_on_a_mac(self) -> None:
        head_tree = subprocess.run(["git", "rev-parse", "HEAD:scripts/ci/macos-stubs"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        # Same stubs as the base's (or an unreadable base): a Mac is the fallback.
        for logs, base in (({7: "ld64.lld: error: undefined symbol: kSecGuestAttributePid"}, head_tree), (None, None)):
            values, out = self.darwin_plan(DARWIN_BUILD_STEP, logs=logs, base_stubs=base)
            self.assertEqual(values.get("builder"), "mac", out)
            self.assertEqual(values.get("cross_failed"), "true")
        values, out = self.darwin_plan("Stage binary")
        self.assertEqual(values.get("builder"), "mac", out)

    def test_a_timeout_a_later_attempt_or_an_unread_leg_rebuilds_on_a_mac(self) -> None:
        values, out = self.darwin_plan(None, conclusion="cancelled", build_result="cancelled")
        self.assertEqual(values.get("builder"), "mac", out)
        values, out = self.darwin_plan("Checkout caller or requested ref", attempt="2")
        self.assertEqual(values.get("builder"), "mac", out)
        values, out, _ = self.run_plan(list(LINUX))
        self.assertEqual(values.get("builder"), "mac", out)

    def test_one_macos_leg_at_its_link_keeps_both_on_a_mac(self) -> None:
        values, out, _ = self.run_plan(list(LINUX), [
            leg("aarch64-apple-darwin", "failure", "Checkout caller or requested ref", job_id=7),
            leg("x86_64-apple-darwin", "failure", DARWIN_BUILD_STEP, job_id=8),
        ])
        self.assertEqual(values.get("builder"), "mac", out)

    def test_the_fallback_build_takes_the_plans_builder(self) -> None:
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        call = document["jobs"]["build-darwin-fallback"]["with"]
        self.assertEqual(call["darwin_builder"], "${{ needs.darwin-fallback-plan.outputs.builder }}")
        self.assertEqual(call["linux_runner"], "cmux-linux")
        self.assertEqual(call["macos_stubs_ref"], "${{ needs.darwin-fallback-plan.outputs.stubs_ref }}")
        self.assertEqual(document["jobs"]["darwin-fallback-plan"]["outputs"]["builder"],
                         "${{ steps.plan.outputs.builder || 'mac' }}")

    def test_the_plan_reads_this_attempts_jobs(self) -> None:
        step = plan_step()
        self.assertEqual(step["env"].get("RUN_ATTEMPT"), "${{ github.run_attempt }}")
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(document["jobs"]["darwin-fallback-plan"]["permissions"].get("actions"), "read")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
