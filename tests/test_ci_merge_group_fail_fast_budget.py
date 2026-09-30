#!/usr/bin/env python3
"""The merge-group watcher's GITHUB_TOKEN spend, measured by running it.

Every workflow in the repository shares one GITHUB_TOKEN budget per hour. On
2026-09-30 a per-run polling watcher (ci-fail-fast.yml) read the run and its
jobs every 20 seconds and exhausted that budget, which failed the CLA checks
and every `gh api` step in CI. merge-group-fail-fast.yml polls the same way for
each queued group, so this test runs its real step script against a fake `gh`
and a fake `sleep` and counts the requests one watched run costs.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "merge-group-fail-fast.yml"

# The fake gh answers from a scripted timeline: the run's jobs as of poll N.
FAKE_GH = r'''#!/usr/bin/env python3
import json, os, sys
state_dir = os.environ["FAKE_STATE"]
log = os.path.join(state_dir, "calls")
with open(log, "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\n")
args = [arg for arg in sys.argv[1:]]
path = next(arg for arg in args[1:] if not arg.startswith("-") and "/" in arg)
jq = args[args.index("--jq") + 1] if "--jq" in args else None
timeline = json.load(open(os.path.join(state_dir, "timeline.json")))
polls_file = os.path.join(state_dir, "job_polls")
if "-X" in args:
    print("{}")
    sys.exit(0)
if "/runs?" in path:
    print("1\thttps://example.invalid/run/1")
    sys.exit(0)
if "/jobs" in path:
    count = int(open(polls_file).read()) if os.path.exists(polls_file) else 0
    open(polls_file, "w").write(str(count + 1))
    jobs = timeline["jobs"][min(count, len(timeline["jobs"]) - 1)]
    # Both the old and new scripts shape rows with jq; emulate the two filters they use.
    if "@tsv" in (jq or ""):
        for job in jobs:
            print("\t".join([job["name"], job["status"], job.get("conclusion") or ""]))
    else:
        print(sum(1 for job in jobs if job.get("conclusion") not in (None, "success", "skipped")))
    sys.exit(0)
count = int(open(polls_file).read()) if os.path.exists(polls_file) else 0
print(timeline["run_status"][min(count, len(timeline["run_status"]) - 1)])
'''


def step_script(text: str) -> tuple[str, dict[str, str]]:
    job = yaml.safe_load(text)["jobs"]["watch"]
    step = job["steps"][0]
    env = {key: str(value) for key, value in (step.get("env") or {}).items() if "${{" not in str(value)}
    return step["run"], env


def run_watcher(script: str, env_extra: dict[str, str], timeline: dict) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        fake_sleep = bin_dir / "sleep"
        fake_sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_sleep.chmod(fake_sleep.stat().st_mode | stat.S_IEXEC)
        (tmp_path / "timeline.json").write_text(json.dumps(timeline), encoding="utf-8")
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_STATE": tmp,
            "SOURCE_WORKFLOW_PATHS": ".github/workflows/merge-group-policy-checks.yml",
            "SOURCE_PATH": ".github/workflows/merge-group-policy-checks.yml",
            "SOURCE_EVENT": "merge_group",
            "HEAD_SHA": "a" * 40,
            "CI_RUNS": "repos/o/r/actions/workflows/ci.yml/runs",
            "REPOSITORY": "o/r",
            **env_extra,
        }
        result = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        return (tmp_path / "calls").read_text(encoding="utf-8").splitlines()


def running(n: int) -> list[dict]:
    return [{"name": f"shard {i}", "status": "in_progress", "conclusion": None} for i in range(n)]


def timeline_success(polls: int) -> dict:
    """A 45-job run that stays green for `polls` jobs reads, then ci-status completes."""
    jobs = [running(45) for _ in range(polls)]
    jobs.append([{"name": f"shard {i}", "status": "completed", "conclusion": "success"} for i in range(44)]
                + [{"name": "ci-status", "status": "completed", "conclusion": "success"}])
    run_status = ["in_progress"] * polls + ["completed"] * 5
    return {"jobs": jobs, "run_status": run_status}


def timeline_failure(polls: int) -> dict:
    jobs = [running(45) for _ in range(polls)]
    jobs.append(running(44) + [{"name": "macos / macOS compile admission", "status": "completed",
                                "conclusion": "failure"}])
    return {"jobs": jobs, "run_status": ["in_progress"] * (polls + 5)}


def reads(calls: list[str]) -> list[str]:
    return [call for call in calls if "-X" not in call.split()]


def test_success_run_costs_one_request_per_poll() -> None:
    script, env = step_script(WORKFLOW.read_text(encoding="utf-8"))
    interval = int(env.get("POLL_SECONDS", "20"))
    # A 60-minute merge group.
    polls = 3600 // interval
    calls = run_watcher(script, env, timeline_success(polls))
    per_minute = len(reads(calls)) / 60
    assert per_minute <= 2.5, (len(calls), per_minute)
    assert not [call for call in calls if "-X" in call.split()], calls


def test_failure_cancels_once() -> None:
    script, env = step_script(WORKFLOW.read_text(encoding="utf-8"))
    calls = run_watcher(script, env, timeline_failure(5))
    cancels = [call for call in calls if "-X POST" in call]
    assert len(cancels) == 1 and cancels[0].endswith("/actions/runs/1/cancel"), calls


def main() -> int:
    tests = [value for name, value in globals().items() if name.startswith("test_") and callable(value)]
    for test in tests:
        test()
        print(f"PASS {test.__name__}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
