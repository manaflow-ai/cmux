#!/usr/bin/env python3
"""cmux-next-dev-daily-dispatch.yml hands the publisher the newest finished
cmux NEXT DEV daily run that produced an app.

It used to hand over the newest finished run, failed or not. On 2026-10-14
source run 38584136265 failed (no app) after the older run 38565180800 built
one, so the publisher skipped the failed run ("no successful app-producing
job"). The run with the app was never handed over, and cmux-NEXT-DEV.zip
stayed at 01:59Z.

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
WORKFLOW = ROOT / ".github/workflows/cmux-next-dev-daily-dispatch.yml"
PUBLISH_WORKFLOW = ROOT / ".github/workflows/cmux-next-dev-daily.yml"
TIP = "f" * 40

failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


source_workflow = (ROOT / ".github/workflows/cmux-next.yml").read_text()
check("request-cmux-next-dev-publish:" in source_workflow,
      "the successful DEV source must hand off to the publisher directly")
check("gh workflow run cmux-next-dev-daily.yml" in source_workflow,
      "the source handoff must dispatch the publisher workflow")
check("name: cmux-next-dev-handoff-${{ inputs.dev_daily_sha }}" in source_workflow,
      "the source handoff must retain an exact-SHA receipt artifact")
check('"queue_ms"' in source_workflow and '"runner_labels"' in source_workflow,
      "the handoff receipt must include queue and runner evidence")
handoff_job = re.search(r"^  request-cmux-next-dev-publish:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)",
                        source_workflow, re.MULTILINE | re.DOTALL)
handoff_body = handoff_job.group(1) if handoff_job else ""
# The shared GITHUB_TOKEN budget was spent when every DEV compile finished on
# 2026-10-26, so the handoff failed and the dispatcher published 12-46 minutes
# later. The App token has its own budget; GITHUB_TOKEN waits through a limit.
check("private-key: ${{ secrets.GLAEDA_ROUTE_APP_KEY }}" in handoff_body
      and "permission-actions: write" in handoff_body,
      "the handoff must dispatch with the manaflow-glaeda-route App token, not only the shared GITHUB_TOKEN")
app_step = re.search(r"- name: Dispatch the exact source run to the publisher\n(.*?)\n        run:", handoff_body, re.DOTALL)
check(bool(app_step) and "GH_TOKEN: ${{ steps.handoff-token.outputs.token }}" in app_step.group(1)
      and "continue-on-error: true" in app_step.group(1),
      "the handoff must try the App token first, and its failure must fall through to GITHUB_TOKEN")
fallback = re.search(r"- name: Dispatch with GITHUB_TOKEN, waiting through a rate limit\n(.*?)(?=\n      - name: |\Z)",
                     handoff_body, re.DOTALL)
fallback_text = fallback.group(1) if fallback else ""
check("if: steps.app-dispatch.outcome != 'success'" in fallback_text
      and "rate limit exceeded" in fallback_text and 'sleep "$wait"' in fallback_text,
      "the GITHUB_TOKEN fallback must wait through a rate limit instead of failing")
check("handoff-token" not in fallback_text,
      "the GITHUB_TOKEN fallback step must not hold the App token")
receipt_step = re.search(r"- name: Record source queue and handoff receipt\n(.*?)\n        run:", handoff_body, re.DOTALL)
check(bool(receipt_step) and "continue-on-error: true" in receipt_step.group(1),
      "a refused receipt read must not stop the dispatch")
handoff = re.search(r"^  request-cmux-next-dev-publish:\n    needs: cmux-scheme-compile\n    if: (.*)$",
                    source_workflow, re.MULTILINE)
handoff_if = handoff.group(1) if handoff else ""
check(handoff_if.startswith("${{ !cancelled() && "),
      "the handoff must not inherit success() over the skipped jobs upstream of the DEV compile "
      "(it was skipped on every run until 2026-10-24)")
check("needs.cmux-scheme-compile.result == 'success'" in handoff_if,
      "the handoff must still require the DEV Release compile to succeed")
check("(inputs.same_tree_sha == '' || inputs.same_tree_sha == github.sha)" in handoff_if,
      "a same-tree DEV run whose head moved must not be handed over (the publisher rejects it)")
text = WORKFLOW.read_text()
schedule = re.findall(r'^    - cron: "([^"]+)"$', text, re.MULTILINE)
check(schedule == ["2-59/5 * * * *"],
      f"the dev dispatcher must run every five minutes, got {schedule}")
check("run.head_sha === sha" in text and "activeOrSucceeded" in text,
      "the exact-SHA dedupe guard must remain in the dispatcher")
check("run.conclusion === 'success'" in text and "run.status" in text,
      "a skipped or failed publisher run must not suppress a retry")
publish_text = PUBLISH_WORKFLOW.read_text()
verify = re.search(r"^  verify:\n(.*?)(?=^  publish:\n)", publish_text, re.MULTILINE | re.DOTALL)
verify_text = verify.group(1) if verify else ""
check("needs: [sign, runner]" in verify_text,
      "DEV verify must wait for the owned-Mac placement job")
check("needs.runner.outputs.label" in verify_text and "blacksmith-6vcpu-macos-26" in verify_text,
      "DEV verify must prefer the picked owned Mac and retain a Blacksmith fallback")
check("workflow_run:" not in publish_text,
      "the publisher must be dispatch-only; unrelated cmux-next completions are not DEV artifacts")
check("SOURCE_RUN_ID: ${{ inputs.source_run_id }}" in publish_text,
      "the publisher must resolve the exact dispatched source run")
check("finishedRuns.slice(0, 10)" not in text,
      "the dispatcher must not hide an older app behind ten failed source runs")
check("has no current Release app artifact; retry the handoff" in publish_text,
      "a missing source artifact must fail publication so the dispatcher retries")


def script_body():
    text = WORKFLOW.read_text()
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
    listWorkflowRuns: async ({ workflow_id }) => ({ data: { workflow_runs:
      workflow_id === 'cmux-next.yml' ? fixture.sourceRuns : fixture.publishRuns } }),
    listJobsForWorkflowRun: async ({ run_id }) => {
      calls.push(['jobs', run_id]);
      return { data: { jobs: fixture.jobs[String(run_id)] || [] } };
    },
    createWorkflowDispatch: async (args) => { calls.push(['dispatch', args.workflow_id, args.inputs]); },
  },
} };
const core = { notice: () => {}, warning: () => {}, info: () => {} };
const context = { repo: { owner: 'o', repo: 'r' }, payload: { repository: { default_branch: 'main' } } };
(async () => {
  await (async () => { SCRIPT })();
  console.log(JSON.stringify(calls));
})().catch((e) => { console.error(e); process.exit(1); });
"""


def dev_run(run_id, sha, conclusion):
    return {"id": run_id, "head_sha": sha, "status": "completed", "conclusion": conclusion,
            "name": "cmux-next", "display_title": f"cmux NEXT DEV daily · {sha}"}


def app_job(conclusion):
    return [{"name": "cmux NEXT DEV Release compile", "conclusion": conclusion},
            {"name": "cmux-next path routing", "conclusion": "success"}]


def run(source_runs, jobs, publish_runs=()):
    fixture = {"tip": TIP, "sourceRuns": list(source_runs), "publishRuns": list(publish_runs),
               "jobs": {str(k): v for k, v in jobs.items()}}
    with tempfile.TemporaryDirectory() as tmp:
        (Path(tmp) / "fixture.json").write_text(json.dumps(fixture))
        (Path(tmp) / "run.js").write_text(HARNESS.replace("SCRIPT", script_body()))
        result = subprocess.run(["node", str(Path(tmp) / "run.js"), str(Path(tmp) / "fixture.json")],
                                capture_output=True, text=True)
    if result.returncode != 0:
        failures.append(f"the script failed:\n{result.stderr}")
        return []
    return json.loads(result.stdout.strip().splitlines()[-1])


def published(calls):
    return [c[2]["source_run_id"] for c in calls if c[0] == "dispatch" and c[1] == "cmux-next-dev-daily.yml"]


if not shutil.which("node"):
    sys.exit("FAIL: node is required")

# The 2026-10-14 case: the newest finished run failed before its app compile;
# the older one built the app. The older one is published.
calls = run([dev_run(2, "b" * 40, "failure"), dev_run(1, "a" * 40, "success")],
            {2: app_job("skipped"), 1: app_job("success")})
check(published(calls) == ["1"], f"the newest run with an app must be published, got {published(calls)}")

# A run whose app compile passed but whose other checks are red still ships.
calls = run([dev_run(3, "c" * 40, "failure")], {3: app_job("success")})
check(published(calls) == ["3"], f"an unrelated red must not hold back a built app, got {published(calls)}")

# Once the newest app is handed over, an older one is never published after it.
calls = run([dev_run(5, "e" * 40, "success"), dev_run(4, "d" * 40, "success")],
            {5: app_job("success"), 4: app_job("success")},
            [{"name": "x", "display_title": "cmux NEXT DEV daily · publish 5", "status": "completed", "conclusion": "success"}])
check(published(calls) == [], f"a handled newest app must stop the search, got {published(calls)}")

# A skipped publisher workflow_run is not a handoff receipt. Retry publication
# rather than treating the skipped run as already handled.
calls = run([dev_run(8, "8" * 40, "success")], {8: app_job("success")},
            [{"name": "x", "display_title": "cmux NEXT DEV daily · publish 8",
              "status": "completed", "conclusion": "skipped"}])
check(published(calls) == ["8"], f"a skipped publisher must be retried, got {published(calls)}")

# No finished run has an app: nothing is published.
calls = run([dev_run(7, "7" * 40, "failure"), dev_run(6, "6" * 40, "failure")],
            {7: app_job("failure"), 6: app_job("skipped")})
check(published(calls) == [], f"runs without an app must not be published, got {published(calls)}")

if failures:
    print("FAIL: cmux NEXT DEV daily dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV daily dispatcher hands over the newest run with an app")
