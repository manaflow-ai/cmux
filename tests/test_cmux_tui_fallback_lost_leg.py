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


def leg(target: str, conclusion: str, failed_step: str | None = None) -> dict:
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": "failure"})
    elif conclusion == "cancelled":
        steps.append({"name": "Build cmux-tui (Linux cross)", "conclusion": "cancelled"})
    return {"name": f"build / build {target}", "conclusion": conclusion, "steps": steps}


@unittest.skipIf(shutil.which("jq") is None, "jq runs the step's --jq filters (GitHub's runners have it)")
class FallbackIgnoresALostLinuxLeg(unittest.TestCase):
    def run_plan(self, built, jobs=None, build_result="failure") -> tuple[dict, str, str]:
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
                routes[f"repos/{REPO}/actions/runs/100/attempts/1/jobs"] = {"total_count": len(jobs), "jobs": jobs}
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
                "REPOSITORY": REPO,
                "RUN_ID": "100",
                "RUN_ATTEMPT": "1",
                "BUILD_RESULT": build_result,
                "FIRST_ON_MAC": "false",
                "BRANCH_PUSH": "",
            }
            for name in step["env"]:
                self.assertIn(name, env, f"the test sets the plan step's env {name}")
            result = subprocess.run(["bash", "-c", step["run"]], env=env, capture_output=True, text=True, timeout=60)
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

    def test_the_machine_channel_leg_of_the_same_target_is_not_read(self) -> None:
        # build-linux (the Cloud machine channel) builds the same targets under another caller job.
        values, out, _ = self.run_plan(["aarch64-unknown-linux-musl"], [
            {"name": "build-linux / build x86_64-unknown-linux-musl", "conclusion": "cancelled", "steps": []},
            leg("x86_64-unknown-linux-musl", "failure", "Build cmux-tui (Linux cross)"),
        ])
        self.assertEqual(values.get("target_set"), "", out)

    def test_every_linux_target_built_never_reads_the_jobs(self) -> None:
        values, out, log = self.run_plan(list(LINUX))
        self.assertEqual(values.get("target_set"), "macos-arm64", out)
        self.assertNotIn("/jobs", log)
        values, out, log = self.run_plan(list(LINUX) + ["aarch64-apple-darwin"])
        self.assertEqual(values.get("target_set"), "", out)
        self.assertEqual(values.get("recovered"), "true")
        self.assertNotIn("/jobs", log)

    def test_the_plan_reads_this_attempts_jobs(self) -> None:
        step = plan_step()
        self.assertEqual(step["env"].get("RUN_ATTEMPT"), "${{ github.run_attempt }}")
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        self.assertEqual(document["jobs"]["darwin-fallback-plan"]["permissions"].get("actions"), "read")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
