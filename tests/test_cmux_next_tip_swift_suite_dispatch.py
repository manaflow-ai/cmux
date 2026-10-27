#!/usr/bin/env python3
"""cmux-next-tip-swift-suite-dispatch.yml batches the Swift suite on the feat-cmux-next tip.

A feat-cmux-next push skips the CmuxNext Swift suite, so a base red there stayed invisible for a
day (2026-10-21). Every 30 minutes the dispatcher may ask cmux-next.yml for one tip_swift_suite run:
never while one is in flight or started in the last 25 minutes, never again on a tip with a
swift-test verdict, a retry (three runs per tip at most) when a run gave none, and on a new tip only
when the diff since the last green (else the newest red) reaches swift-test (the router step), or
there is no usable base. Every verdict is read from the swift-test job.

Runs scripts/ci/tip_swift_suite_plan.js under node with a stubbed GitHub API.
"""
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-tip-swift-suite-dispatch.yml"
PLAN = ROOT / "scripts/ci/tip_swift_suite_plan.js"
TIP = "f" * 40
NOW = 1_800_000_000_000  # ms
MIN = 60_000

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


text = WORKFLOW.read_text()
schedule = re.findall(r'^    - cron: "([^"]+)"$', text, re.MULTILINE)
check(schedule == ["11,41 * * * *"], f"the dispatcher must tick every 30 minutes off the hour, got {schedule}")
check("cancel-in-progress: false" in text, "a tick must never cancel another")
check("timeout-minutes: 10" in text, "a tick is one short job")
check("statuses:" not in text, "the dispatcher takes no statuses grant")
check("--event pull_request" in text and "tip/scripts/ci/cmux_next_route.py" in text,
      "the change filter must be cmux-next's own router on the tip, not a second path list")
check("steps.plan.outputs.action == 'dispatch' || steps.route.outputs.swift == 'true'" in text,
      "the dispatch must follow the plan or the router's swift verdict")

HARNESS = r"""
const fixture = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const { plan, dispatch } = require(process.argv[3]);
const calls = [];
const github = { rest: {
  git: { getRef: async () => ({ data: { object: { sha: fixture.tip } } }) },
  repos: { compareCommitsWithBasehead: async (args) => {
    calls.push(['compare', args.basehead]);
    return { data: { status: fixture.compare || 'ahead' } };
  } },
  actions: {
    listWorkflowRuns: async (args) => {
      calls.push(['list', args.workflow_id, args.event, args.branch]);
      return { data: { workflow_runs: fixture.runs } };
    },
    listJobsForWorkflowRun: async (args) => {
      calls.push(['jobs', args.run_id]);
      return { data: { jobs: fixture.jobs[String(args.run_id)] || [] } };
    },
    createWorkflowDispatch: async (args) => { calls.push(['dispatch', args.workflow_id, args.ref, args.inputs]); },
  },
} };
const context = { repo: { owner: 'o', repo: 'r' } };
(async () => {
  const p = await plan({ github, context, now: fixture.now });
  if (p.action === 'dispatch') await dispatch({ github, context });
  console.log(JSON.stringify({ plan: p, calls }));
})().catch((e) => { console.error(e); process.exit(1); });
"""

_ids = iter(range(1000, 100000))


def tip_run(sha, status="completed", conclusion="failure", age_min=60, title=None):
    return {"id": next(_ids), "head_sha": sha, "status": status, "conclusion": conclusion, "name": "cmux-next",
            "display_title": title or f"cmux-next tip Swift suite · {sha}",
            "created_at_ms": NOW - age_min * MIN}


def swift_job(conclusion, failed_step=None):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": "failure"})
    return [{"name": "cmux-next checks (god files)", "status": "completed", "conclusion": "cancelled", "steps": []},
            {"name": "cmux-next swift test", "status": "completed", "conclusion": conclusion, "steps": steps}]


def run(runs, jobs=None, compare="ahead"):
    from datetime import datetime, timezone
    for r in runs:
        r["created_at"] = datetime.fromtimestamp(r.pop("created_at_ms") / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
    jobs = dict(jobs or {})
    for r in runs:  # a successful run's swift test passed unless the case says otherwise
        if r["conclusion"] == "success":
            jobs.setdefault(r["id"], swift_job("success"))
    fixture = {"tip": TIP, "now": NOW, "runs": runs, "compare": compare,
               "jobs": {str(k): v for k, v in jobs.items()}}
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "fixture.json").write_text(json.dumps(fixture))
        (Path(tmp) / "run.js").write_text(HARNESS)
        result = subprocess.run(["node", str(Path(tmp) / "run.js"), str(Path(tmp) / "fixture.json"), str(PLAN)],
                                capture_output=True, text=True)
    if result.returncode != 0:
        failures.append(f"the plan failed:\n{result.stderr}")
        return {"action": "error"}, []
    out = json.loads(result.stdout.strip().splitlines()[-1])
    return out["plan"], out["calls"]


def dispatched(calls):
    return [c for c in calls if c[0] == "dispatch"]


if not shutil.which("node"):
    sys.exit("FAIL: node is required")

GREEN = "a" * 40

# No tip suite run at all: dispatch, fully qualified, tip_swift_suite only.
p, calls = run([])
check(dispatched(calls) == [["dispatch", "cmux-next.yml", "refs/heads/feat-cmux-next", {"tip_swift_suite": "true"}]],
      f"with no green run the tip must get one Swift suite run, got {dispatched(calls)}")
check(["list", "cmux-next.yml", "workflow_dispatch", "feat-cmux-next"] in calls,
      "the plan must read cmux-next.yml's dispatches on feat-cmux-next")

# Cadence: a run in flight (any sha) or one created in the last 25 minutes skips the tick.
for status in ("in_progress", "queued", "waiting"):
    p, calls = run([tip_run(GREEN, status, None, age_min=90)])
    check(p["action"] == "skip" and not dispatched(calls), f"a {status} run must skip the tick, got {p}")
p, calls = run([tip_run(GREEN, conclusion="success", age_min=20)])
check(p["action"] == "skip", f"a run created 20 minutes ago must skip the tick, got {p}")
p, calls = run([tip_run(GREEN, conclusion="success", age_min=26)])
check(p["action"] == "route", f"a run created 26 minutes ago must not hold back a 30-minute tick, got {p}")

# Change filter: a new tip with a green ancestor goes to the router with that green.
p, calls = run([tip_run(GREEN, conclusion="success")])
check(p == {"action": "route", "reason": p.get("reason"), "tip": TIP, "base": GREEN},
      f"a new tip with a green ancestor must be routed from that green, got {p}")
check(["compare", f"{GREEN}...{TIP}"] in calls, "the ancestry check is one compare from the green to the tip")
check(not dispatched(calls), "the plan must not dispatch before the router says swift test is reached")
# A green that is not an ancestor (force push): dispatch.
p, calls = run([tip_run(GREEN, conclusion="success")], compare="diverged")
check(p["action"] == "dispatch", f"a green that is not an ancestor must dispatch, got {p}")
# The last green is the newest run whose swift-test passed, even when the run itself was red.
red, green_job = tip_run("b" * 40, age_min=40), tip_run("c" * 40, age_min=50)
p, calls = run([red, green_job, tip_run(GREEN, conclusion="success", age_min=70)],
               jobs={red["id"]: swift_job("failure", "Run package tests (changed suites first, then selected targets)"),
                     green_job["id"]: swift_job("success")})
check(p["base"] == "c" * 40, f"the green must come from the swift-test job, not the run, got {p}")
# A successful run whose swift test was skipped tested nothing: not a verdict, not a green.
r = tip_run(TIP, conclusion="success")
p, calls = run([r], jobs={r["id"]: swift_job("skipped")})
check(p["action"] == "dispatch", f"a run whose swift test was skipped must be retried, got {p}")
r = tip_run(GREEN, conclusion="success")
p, calls = run([r], jobs={r["id"]: swift_job("skipped")})
check(p["action"] == "dispatch", f"a run whose swift test was skipped is no green, got {p}")
# No green: route from the newest red, so a red base is not re-run on a change swift test never sees.
reds = [tip_run(c * 40, age_min=40 + 30 * i) for i, c in enumerate("bcd")]
p, calls = run(reds, jobs={x["id"]: swift_job("failure", "Run package tests (changed suites first, then selected targets)") for x in reds})
check(p["action"] == "route" and p["base"] == "b" * 40, f"with no green the newest red is the base, got {p}")
# A no-verdict streak longer than the read budget, with a red inside it: route from that red, never
# a blind dispatch because the budget ran out.
streak = [tip_run(f"{i:x}".rjust(40, "1"), age_min=40 + 30 * i) for i in range(14)]
jobs = {x["id"]: swift_job("failure", "Set up runner") for x in streak}
jobs[streak[2]["id"]] = swift_job("failure", "Build package and tests")
p, calls = run(streak, jobs=jobs)
check(p["action"] == "route" and p["base"] == streak[2]["head_sha"], f"a red within the budget is the base, got {p}")
check(len([c for c in calls if c[0] == "jobs"]) <= 10, "a tick reads at most ten job lists")
# A DEV daily on the tip is not a tip suite run.
p, calls = run([tip_run(TIP, conclusion="success", title=f"cmux NEXT DEV daily · {TIP}")])
check(p["action"] == "dispatch", f"a DEV daily run must not stand in for the Swift suite, got {p}")

# Verdicts on the tip: pass or a test-step red is final.
p, calls = run([tip_run(TIP, conclusion="success")])
check(p["action"] == "skip", f"a green tip must not run again, got {p}")
r = tip_run(TIP)
p, calls = run([r], jobs={r["id"]: swift_job("failure", "Run package tests (changed suites first, then selected targets)")})
check(p["action"] == "skip", f"a tip whose tests failed has a verdict, got {p}")
r = tip_run(TIP)
p, calls = run([r], jobs={r["id"]: swift_job("failure", "Build package and tests")})
check(p["action"] == "skip", f"a tip whose test build failed has a verdict, got {p}")

# No verdict: retried on the next tick, three runs per tip at most.
r = tip_run(TIP)  # run 40451896807: swift test failed in "Set up runner" on a mini after a minute
p, calls = run([r], jobs={r["id"]: swift_job("failure", "Set up runner")})
check(p["action"] == "dispatch" and len(dispatched(calls)) == 1, f"a setup failure must be retried, got {p}")
r = tip_run(TIP, conclusion="cancelled")
p, calls = run([r], jobs={r["id"]: swift_job("cancelled")})
check(p["action"] == "dispatch", f"a cancelled run must be retried, got {p}")
r = tip_run(TIP)
p, calls = run([r], jobs={r["id"]: [{"name": "cmux-next path routing", "status": "completed", "conclusion": "failure", "steps": []}]})
check(p["action"] == "dispatch", f"a run whose swift test never ran must be retried, got {p}")
r1, r2 = tip_run(TIP, age_min=40), tip_run(TIP, age_min=80)
p, calls = run([r1, r2], jobs={r1["id"]: swift_job("failure", "Checkout"), r2["id"]: swift_job("failure", "Set up runner")})
check(p["action"] == "dispatch", f"a second no-verdict run must be retried once more, got {p}")
runs = [tip_run(TIP, age_min=40 * (i + 1)) for i in range(3)]
p, calls = run(runs, jobs={x["id"]: swift_job("failure", "Set up runner") for x in runs})
check(p["action"] == "skip" and not dispatched(calls), f"a tip with three no-verdict runs must not loop, got {p}")


if failures:
    print("FAIL: cmux NEXT tip Swift suite dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT tip Swift suite dispatcher batches the tip suite")
