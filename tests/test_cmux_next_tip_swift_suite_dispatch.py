#!/usr/bin/env python3
"""cmux-next-tip-swift-suite-dispatch.yml asks for one Swift suite run per feat-cmux-next tip.

A feat-cmux-next push skips the CmuxNext Swift suite, so a base red there stayed invisible for a
day (2026-10-21). The dispatcher runs every four hours and dispatches cmux-next.yml's
tip_swift_suite mode, unless the tip already has a run going or one that finished with a verdict.

Runs the workflow's github-script under node with a stubbed GitHub API.
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
TIP = "f" * 40

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


text = WORKFLOW.read_text()
schedule = re.findall(r'^    - cron: "([^"]+)"$', text, re.MULTILINE)
check(schedule == ["41 */4 * * *"], f"the dispatcher must run every four hours off the hour, got {schedule}")
check("ref: `refs/heads/${source}`" in text, "the dispatch must name the branch fully qualified")


def script_body():
    match = re.search(r"^        with:\n          script: \|\n((?:^            .*\n|^\s*\n)+)", text, re.MULTILINE)
    if not match:
        sys.exit("FAIL: could not find the dispatcher's github-script")
    return "\n".join(line[12:] for line in match.group(1).splitlines())


HARNESS = r"""
const fixture = JSON.parse(require('fs').readFileSync(process.argv[2], 'utf8'));
const calls = [];
const github = { rest: {
  git: { getRef: async () => ({ data: { object: { sha: fixture.tip } } }) },
  actions: {
    listWorkflowRuns: async (args) => {
      calls.push(['list', args.workflow_id, args.event, args.branch]);
      return { data: { workflow_runs: fixture.runs } };
    },
    createWorkflowDispatch: async (args) => { calls.push(['dispatch', args.workflow_id, args.ref, args.inputs]); },
  },
} };
const core = { notice: () => {}, warning: () => {}, info: () => {} };
const context = { repo: { owner: 'o', repo: 'r' }, payload: { repository: { default_branch: 'main' } } };
(async () => {
  await (async () => { SCRIPT })();
  console.log(JSON.stringify(calls));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def tip_run(sha, status, conclusion=None):
    return {"head_sha": sha, "status": status, "conclusion": conclusion, "name": "cmux-next",
            "display_title": f"cmux-next tip Swift suite · {sha}"}


def run(runs):
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "fixture.json").write_text(json.dumps({"tip": TIP, "runs": list(runs)}))
        (Path(tmp) / "run.js").write_text(HARNESS.replace("SCRIPT", script_body()))
        result = subprocess.run(["node", str(Path(tmp) / "run.js"), str(Path(tmp) / "fixture.json")],
                                capture_output=True, text=True)
    if result.returncode != 0:
        failures.append(f"the script failed:\n{result.stderr}")
        return []
    return json.loads(result.stdout.strip().splitlines()[-1])


def dispatched(calls):
    return [c for c in calls if c[0] == "dispatch"]


if not shutil.which("node"):
    sys.exit("FAIL: node is required")

# A new tip: one tip_swift_suite run on feat-cmux-next.
calls = run([tip_run("a" * 40, "completed", "failure")])
check(dispatched(calls) == [["dispatch", "cmux-next.yml", "refs/heads/feat-cmux-next", {"tip_swift_suite": "true"}]],
      f"a moved tip must get one Swift suite run, got {dispatched(calls)}")
check(["list", "cmux-next.yml", "workflow_dispatch", "feat-cmux-next"] in calls,
      "the dedupe must read cmux-next.yml's dispatches on feat-cmux-next")

# The tip already has a verdict, red or green, or a run going: nothing.
for status, conclusion in (("completed", "failure"), ("completed", "success"), ("in_progress", None), ("queued", None)):
    calls = run([tip_run(TIP, status, conclusion)])
    check(dispatched(calls) == [], f"a tip with a {status}/{conclusion} run must not get another, got {dispatched(calls)}")

# A cancelled run on the tip gave no verdict: ask again.
calls = run([tip_run(TIP, "completed", "cancelled")])
check(len(dispatched(calls)) == 1, f"a cancelled run must be retried, got {dispatched(calls)}")

# Another kind of dispatch on the tip (the DEV daily) does not count.
dev = {"head_sha": TIP, "status": "completed", "conclusion": "success", "name": "cmux-next",
       "display_title": f"cmux NEXT DEV daily · {TIP}"}
calls = run([dev])
check(len(dispatched(calls)) == 1, f"a DEV daily run must not stand in for the Swift suite, got {dispatched(calls)}")

if failures:
    print("FAIL: cmux NEXT tip Swift suite dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT tip Swift suite dispatcher asks once per tip")
