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
check("steps.plan.outputs.action == 'dispatch' || steps.route.outputs.reached == 'true'" in text,
      "the dispatch must follow the plan or the router's verdict for the suite's tier")
check(re.search(r"matrix:\n\s+suite: \[swift, daemon\]", text) is not None,
      "the Swift and daemon suites each get a matrix leg")
check('sed -n "s/^${SUITE}=//p"' in text, "the router verdict read is the suite's own tier (swift= or daemon=)")
check(text.count("SUITE: ${{ matrix.suite }}") == 3, "the plan, router and dispatch steps all take the leg's suite")
# The router on feat-cmux-next emits both tier lines the legs read (a pull_request event routes per path).
route_text = subprocess.run(["git", "-C", str(ROOT), "show", "origin/feat-cmux-next:scripts/ci/cmux_next_route.py"],
                            capture_output=True, text=True).stdout
if route_text:
    for key in ("swift", "daemon"):
        check(f'"{key}": flag(result.{key})' in route_text,
              f"feat-cmux-next's router must print {key}= for the {key} leg to read")

HARNESS = r"""
const fixture = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const { plan, dispatch } = require(process.argv[3]);
const calls = [];
const github = { rest: {
  git: { getRef: async () => ({ data: { object: { sha: fixture.tip } } }) },
  repos: { compareCommitsWithBasehead: async (args) => {
    calls.push(['compare', args.basehead]);
    const base = args.basehead.split('...')[0];
    const by = (fixture.ahead_by_from || {})[base] ?? fixture.ahead_by ?? 1;
    return { data: { status: fixture.compare || 'ahead', ahead_by: by } };
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
    createWorkflowDispatch: async (args) => {
      calls.push(['dispatch', args.workflow_id, args.ref, args.inputs]);
      if (fixture.refuse) { const e = new Error(fixture.refuse); e.status = 422; throw e; }
    },
  },
} };
const context = { repo: { owner: 'o', repo: 'r' } };
const core = { warning: (m) => calls.push(['warning', m]) };
(async () => {
  const p = await plan({ github, context, now: fixture.now, suite: fixture.suite });
  let sent = null;
  let thrown = null;
  if (p.action === 'dispatch') {
    try { sent = await dispatch({ github, context, suite: fixture.suite, core }); } catch (e) { thrown = e.message; }
  }
  console.log(JSON.stringify({ plan: p, calls, sent, thrown }));
})().catch((e) => { console.error(e); process.exit(1); });
"""

_ids = iter(range(1000, 100000))


def tip_run(sha, status="completed", conclusion="failure", age_min=60, title=None, head_sha=None):
    return {"id": next(_ids), "head_sha": head_sha or sha, "status": status, "conclusion": conclusion,
            "name": "cmux-next", "display_title": title or f"cmux-next tip Swift suite · {sha}",
            "created_at_ms": NOW - age_min * MIN}


def daemon_run(sha, conclusion="failure", age_min=60, head_sha=None, status="completed"):
    return tip_run(sha, status, conclusion, age_min, title=f"cmux-next tip daemon suite · {sha}", head_sha=head_sha)


def daemon_job(conclusion, failed_step=None):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": "failure"})
    return [{"name": "cmux-next path routing", "status": "completed", "conclusion": "success", "steps": []},
            {"name": "cmux-next daemon tests", "status": "completed", "conclusion": conclusion, "steps": steps}]


def swift_job(conclusion, failed_step=None):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    if failed_step:
        steps.append({"name": failed_step, "conclusion": "failure"})
    return [{"name": "cmux-next checks (god files)", "status": "completed", "conclusion": "cancelled", "steps": []},
            {"name": "cmux-next swift test", "status": "completed", "conclusion": conclusion, "steps": steps}]


def run(runs, jobs=None, compare="ahead", suite=None, ahead_by=1, refuse=False, ahead_by_from=None):
    from datetime import datetime, timezone
    for r in runs:
        r["created_at"] = datetime.fromtimestamp(r.pop("created_at_ms") / 1000, timezone.utc).isoformat().replace("+00:00", "Z")
    jobs = dict(jobs or {})
    for r in runs:  # a successful run's suite job passed unless the case says otherwise
        if r["conclusion"] == "success":
            jobs.setdefault(r["id"], daemon_job("success") if suite == "daemon" else swift_job("success"))
    fixture = {"tip": TIP, "now": NOW, "runs": runs, "compare": compare, "suite": suite, "ahead_by": ahead_by,
               "ahead_by_from": ahead_by_from or {},
               "refuse": refuse, "jobs": {str(k): v for k, v in jobs.items()}}
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "fixture.json").write_text(json.dumps(fixture))
        (Path(tmp) / "run.js").write_text(HARNESS)
        result = subprocess.run(["node", str(Path(tmp) / "run.js"), str(Path(tmp) / "fixture.json"), str(PLAN)],
                                capture_output=True, text=True)
    if result.returncode != 0:
        failures.append(f"the plan failed:\n{result.stderr}")
        return {"action": "error"}, []
    out = json.loads(result.stdout.strip().splitlines()[-1])
    return out["plan"], out["calls"] + [["sent", out["sent"]], ["thrown", out["thrown"]]]


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
check(p == {"action": "route", "reason": p.get("reason"), "tip": TIP, "base": GREEN, "suite": "swift"},
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


# The daemon suite (2026-10-30, #27692: a feat-cmux-next push never runs daemon-test, so the base had no
# daemon-test verdict to compare a pull request's daemon red with).
p, calls = run([], suite="daemon")
check(dispatched(calls) == [["dispatch", "cmux-next.yml", "refs/heads/feat-cmux-next", {"tip_daemon_suite": "true"}]],
      f"with no daemon verdict the tip must get one daemon suite run, got {dispatched(calls)}")
# Its runs are its own: a Swift suite run on the tip is no daemon verdict, and the reverse.
p, calls = run([tip_run(TIP, conclusion="success")], suite="daemon")
check(p["action"] == "dispatch", f"a Swift suite run must not stand in for the daemon suite, got {p}")
p, calls = run([daemon_run(TIP, conclusion="success")])
check(p["action"] == "dispatch", f"a daemon suite run must not stand in for the Swift suite, got {p}")
# A same-tree run tests the recorded commit after the tip moved: the name, not head_sha, says which.
p, calls = run([daemon_run(TIP, conclusion="success", head_sha="9" * 40)], suite="daemon")
check(p["action"] == "skip", f"a same-tree daemon run of the tip is the tip's verdict, got {p}")
p, calls = run([daemon_run(GREEN, conclusion="success", head_sha=TIP)], suite="daemon")
check(p["action"] == "route" and p["base"] == GREEN, f"the daemon green is the commit its name tests, got {p}")
# The verdict comes from the daemon job; a skipped one is none (retried once past the deferred grace).
r = daemon_run(TIP, conclusion="success", age_min=100)
p, calls = run([r], jobs={r["id"]: daemon_job("skipped")}, suite="daemon")
check(p["action"] == "dispatch", f"a run whose daemon tests were skipped must be retried, got {p}")
r = daemon_run(TIP)
p, calls = run([r], jobs={r["id"]: daemon_job("failure", "Run the live-daemon suites")}, suite="daemon")
check(p["action"] == "skip", f"a tip whose live-daemon suites failed has a verdict, got {p}")
# Fresh base log: 20 landings past the last verdict dispatch whatever the router says; fewer route.
p, calls = run([daemon_run(GREEN, conclusion="success")], suite="daemon", ahead_by=20)
check(p["action"] == "dispatch", f"20 landings past the last daemon verdict must dispatch, got {p}")
p, calls = run([daemon_run(GREEN, conclusion="success")], suite="daemon", ahead_by=19)
check(p["action"] == "route", f"19 landings past the last daemon verdict go to the router, got {p}")
# The floor counts from the newest verdict, red included: a green 21 landings back and a red periodic
# run 1 landing back route on the router; the routing base stays the green.
RED = "b" * 40
red_run, green_run = daemon_run(RED, age_min=40), daemon_run(GREEN, conclusion="success", age_min=90)
p, calls = run([red_run, green_run], jobs={red_run["id"]: daemon_job("failure", "Run the live-daemon suites")},
               suite="daemon", ahead_by_from={GREEN: 21, RED: 1})
check(p["action"] == "route" and p["base"] == GREEN,
      f"a red verdict 1 landing back must hold the floor and route from the green, got {p}")
check(["compare", f"{RED}...{TIP}"] in calls, "the floor reads the distance from the newest verdict")
red_run, green_run = daemon_run(RED, age_min=40), daemon_run(GREEN, conclusion="success", age_min=90)
p, calls = run([red_run, green_run], jobs={red_run["id"]: daemon_job("failure", "Run the live-daemon suites")},
               suite="daemon", ahead_by_from={GREEN: 41, RED: 20})
check(p["action"] == "dispatch", f"20 landings past the newest (red) verdict must dispatch, got {p}")
p, calls = run([tip_run(GREEN, conclusion="success")], ahead_by=500)
check(p["action"] == "route", f"the Swift suite keeps routing on its tier alone, got {p}")
# Cadence per suite: a daemon run in flight holds only the daemon leg.
p, calls = run([daemon_run(GREEN, status="in_progress", conclusion=None, age_min=5)], suite="daemon")
check(p["action"] == "skip", f"a daemon run in flight must skip the daemon tick, got {p}")
p, calls = run([daemon_run(GREEN, status="in_progress", conclusion=None, age_min=5)])
check(p["action"] == "dispatch", f"a daemon run in flight must not hold the Swift tick, got {p}")
# Before feat-cmux-next's cmux-next.yml takes the input: a warning, not a red tick.
UNKNOWN = 'Unexpected inputs provided: ["tip_daemon_suite"]'
p, calls = run([], suite="daemon", refuse=UNKNOWN)
check(["sent", False] in calls and ["thrown", None] in calls and any(c[0] == "warning" for c in calls),
      f"a daemon dispatch refused for the unknown input must warn and report nothing sent, got {calls}")
# Any other 422 is a real failure, for the daemon leg and the Swift leg alike.
for suite, message in (("daemon", "No ref found for: refs/heads/feat-cmux-next"),
                       ("daemon", 'Unexpected inputs provided: ["something_else"]'),
                       (None, 'Unexpected inputs provided: ["tip_swift_suite"]')):
    p, calls = run([], suite=suite, refuse=message)
    check(["thrown", message] in calls and not any(c[0] == "warning" for c in calls),
          f"a {suite or 'swift'} dispatch refused with {message!r} must fail the tick, got {calls}")

# A daemon run whose tree was still publishing (daemon-test skipped) is pending until its same-tree
# run starts: never dispatched again meanwhile, so one sha gets one same-tree run.
r = daemon_run(TIP, conclusion="success", age_min=30)
p, calls = run([r], jobs={r["id"]: daemon_job("skipped")}, suite="daemon")
check(p["action"] == "skip" and not dispatched(calls), f"a deferred daemon run must not be re-dispatched, got {p}")
# Its same-tree run (named for the same sha, head_sha the moved tip) in flight holds the leg too.
r = daemon_run(TIP, conclusion="success", age_min=30)
p, calls = run([daemon_run(TIP, status="in_progress", conclusion=None, age_min=2, head_sha="9" * 40), r],
               jobs={r["id"]: daemon_job("skipped")}, suite="daemon")
check(p["action"] == "skip" and not dispatched(calls), f"a deferred run's same-tree run in flight must skip, got {p}")
# ...and its verdict, once in, is the tip's.
st = daemon_run(TIP, conclusion="failure", age_min=26, head_sha="9" * 40)
r2 = daemon_run(TIP, conclusion="success", age_min=80)
p, calls = run([st, r2], jobs={st["id"]: daemon_job("failure", "Run the live-daemon suites"),
                               r2["id"]: daemon_job("skipped")}, suite="daemon")
check(p["action"] == "skip" and "verdict" in p["reason"], f"the same-tree run's verdict must stand, got {p}")
# A deferred run past the grace whose same-tree run never came is a lost run: retried.
r = daemon_run(TIP, conclusion="success", age_min=100)
p, calls = run([r], jobs={r["id"]: daemon_job("skipped")}, suite="daemon")
check(p["action"] == "dispatch", f"a deferred run past the grace must be retried, got {p}")
# The Swift suite has no deferred state: a skipped swift test is retried at once (as before).
r = tip_run(TIP, conclusion="success", age_min=30)
p, calls = run([r], jobs={r["id"]: swift_job("skipped")})
check(p["action"] == "dispatch", f"a skipped Swift suite job is retried, got {p}")

if failures:
    print("FAIL: cmux NEXT tip Swift suite dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT tip Swift suite dispatcher batches the tip suite")
