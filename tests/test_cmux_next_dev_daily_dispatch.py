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
import datetime
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


text = WORKFLOW.read_text()
schedule = re.findall(r'^    - cron: "([^"]+)"$', text, re.MULTILINE)
check(schedule == ["2-59/5 * * * *"],
      f"the dev dispatcher must run every five minutes, got {schedule}")
# The dispatcher failed on its first read whenever the shared GITHUB_TOKEN
# budget was spent (2026-10-26 15:47Z, 16:03Z): reads and the publisher dispatch
# take the manaflow-glaeda-route App's budget, the DEV build dispatch stays on
# GITHUB_TOKEN (cmux-next.yml routes re-runs on its triggering actor).
check("private-key: ${{ secrets.GLAEDA_ROUTE_APP_KEY }}" in text and "APP_TOKEN: ${{ steps.app-token.outputs.token }}" in text,
      "the dispatcher must read with the manaflow-glaeda-route App token when it can mint one")
check("github.rest.git.getRef" not in text and "github.rest.actions.list" not in text,
      "every dispatcher read must go through the App token client")
check(re.search(r"await github\.rest\.actions\.createWorkflowDispatch\(\{\s*owner,\s*repo,\s*workflow_id: workflow,", text) is not None,
      "the DEV build dispatch must stay on GITHUB_TOKEN")
check(re.search(r"await api\.rest\.actions\.createWorkflowDispatch\(\{\s*owner,\s*repo,\s*workflow_id: 'cmux-next-dev-daily.yml'", text) is not None,
      "the publisher dispatch must use the App token client")
check("run.head_sha === sha" in text and "activeOrSucceeded" in text,
      "the exact-SHA dedupe guard must remain in the dispatcher")
check("run.conclusion === 'success'" in text and "run.status" in text,
      "a skipped or failed publisher run must not suppress a retry")
publish_text = PUBLISH_WORKFLOW.read_text()
# The shared GITHUB_TOKEN budget was spent when the publishers started on
# 2026-10-26 ("Resolve the source run" failed with the installation rate limit).
sign_job = re.search(r"^  sign:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n)", publish_text, re.MULTILINE | re.DOTALL)
sign_text = sign_job.group(1) if sign_job else ""
check("id: read-token" in sign_text and "private-key: ${{ secrets.GLAEDA_ROUTE_APP_KEY }}" in sign_text
      and "permission-actions: read" in sign_text and "permission-actions: write" not in sign_text,
      "the signer must read the source run with the read-only manaflow-glaeda-route token")
check("GH_TOKEN: ${{ github.token }}" not in sign_text,
      "every signer source-run read must try the App token before GITHUB_TOKEN")
check("- name: Wait for the API budget before publishing" in publish_text,
      "the release writes must wait for the shared budget instead of failing on it")
for call in ("ghw release upload", "ghw release edit", 'ghw api "repos/$GH_REPO/compare/'):
    check(call in publish_text, f"the release write path must retry through a rate limit: {call}")
check(re.search(r"^\s+gh release (upload|edit) ", publish_text, re.MULTILINE) is None,
      "a release upload or edit must not call gh without the rate-limit retry")
check("ghw release create" not in publish_text,
      "release create makes several requests and must not be replayed")

# ghw itself: a refused attempt's stdout must never reach a capture, and a
# failure that is not the rate limit returns at once.
ghw_src = re.search(r"^          waited_file=.*?^          }$", publish_text, re.MULTILINE | re.DOTALL)
check(bool(ghw_src), "the publish step must define ghw")
if ghw_src and shutil.which("bash"):
    body = "\n".join(line[10:] for line in ghw_src.group(0).splitlines())
    with tempfile.TemporaryDirectory() as tmp:
        stub = Path(tmp) / "gh"
        stub.write_text(
            "#!/bin/bash\n"
            "if [ \"$1\" = api ] && [ \"$2\" = rate_limit ]; then echo $(( $(date +%s) + 1 )); exit 0; fi\n"
            "n=$(cat \"$STUB_DIR/count\" 2>/dev/null || echo 0); echo $((n+1)) > \"$STUB_DIR/count\"\n"
            "if [ \"$n\" -lt 1 ]; then echo '{\"message\":\"API rate limit exceeded\"}'; "
            "echo 'gh: API rate limit exceeded for installation (HTTP 403)' >&2; exit 1; fi\n"
            "if [ \"$1\" = fail ]; then echo other >&2; exit 4; fi\n"
            "echo ahead\n")
        stub.chmod(0o755)
        (Path(tmp) / "fn.sh").write_text(body + "\n")
        script = ('set -euo pipefail; source "$STUB_DIR/fn.sh"; '
                  'status="$(ghw api compare 2>/dev/null)"; printf "%s|" "$status"; '
                  'rm -f "$STUB_DIR/count"; echo 1 > "$STUB_DIR/count"; ghw fail x 2>/dev/null || echo "rc=$?"')
        env = {"PATH": f"{tmp}:/usr/bin:/bin", "STUB_DIR": tmp, "RUNNER_TEMP": tmp}
        result = subprocess.run(["bash", "-c", script], capture_output=True, text=True, env=env, timeout=120)
        check(result.stdout.strip() == "ahead|rc=4",
              f"ghw must print only the successful attempt's stdout and pass other failures through: {result.stdout!r} {result.stderr!r}")
check("workflow_run:" not in publish_text,
      "the publisher must be dispatch-only; unrelated cmux-next completions are not DEV artifacts")
check("SOURCE_RUN_ID: ${{ inputs.source_run_id }}" in publish_text,
      "the publisher must resolve the exact dispatched source run")
check(re.search(r"select\(\.conclusion == \"success\"\) \| \.name' \|\| true", publish_text) is None,
      "a failed source-job read must fail the publisher run, not succeed with nothing published")
check("finishedRuns.slice(0, 10)" not in text,
      "the dispatcher must not hide an older app behind ten failed source runs")
# verify is the admission gate since the signer moved to Linux (Apple's codesign runs only
# there): a red verify fails the run on purpose, so the dispatcher hands the source run over
# again instead of counting a build that never published as handled.
verify_job = "\n".join(line for line in publish_text[publish_text.index("\n  verify:\n"):publish_text.index("\n  publish:\n")]
                       .splitlines() if not line.lstrip().startswith("#"))
check("continue-on-error" not in verify_job and "|| true" not in verify_job.split("id: check")[1].split("- name:")[0],
      "verify must not be continue-on-error, and its checks must not be masked")
check("    needs: [sign, runner]\n" in verify_job, "verify runs after sign and its placement job")
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

# A DEV build started under five minutes ago is still running: a push kick
# for a newer tip waits for the next push or tick instead of starting another.
def built(calls):
    return [c[2]["dev_daily_sha"] for c in calls if c[0] == "dispatch" and c[1] == "cmux-next.yml"]


def active_run(run_id, sha, age_s, status="in_progress", title=None, name="cmux-next"):
    created = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age_s)
    return {"id": run_id, "head_sha": sha, "status": status, "conclusion": None,
            "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "name": name, "display_title": title or f"cmux NEXT DEV daily · {sha}"}


for status in ("queued", "requested", "waiting", "pending", "in_progress"):
    calls = run([active_run(20, "2" * 40, 60, status=status)], {})
    check(built(calls) == [], f"a {status} DEV build under five minutes old must space the next one, got {built(calls)}")
calls = run([active_run(20, "2" * 40, 60, title="cmux-next", name=f"cmux NEXT DEV daily · {'2' * 40}")], {})
check(built(calls) == [], f"a DEV build named by run.name must space the next one, got {built(calls)}")
for title in ("cmux NEXT DEV daily · publish 123", "cmux NEXT DEV daily · abc", f"cmux NEXT DEV daily · {'2' * 40} extra"):
    calls = run([active_run(20, "2" * 40, 60, title=title)], {})
    check(built(calls) == [TIP], f"{title!r} is not a dispatched DEV build and must not space the tip, got {built(calls)}")
calls = run([active_run(21, "2" * 40, 6 * 60)], {})
check(built(calls) == [TIP], f"a DEV build over five minutes old must not hold the tip, got {built(calls)}")
finished = dev_run(22, "2" * 40, "failure")
finished["created_at"] = active_run(22, "2" * 40, 60)["created_at"]
calls = run([finished], {22: app_job("failure")})
check(built(calls) == [TIP], f"a finished DEV build must not space the next one, got {built(calls)}")
check(run([], {}) and built(run([], {})) == [TIP], "with no DEV build running the tip is built")

# No finished run has an app: nothing is published.
calls = run([dev_run(7, "7" * 40, "failure"), dev_run(6, "6" * 40, "failure")],
            {7: app_job("failure"), 6: app_job("skipped")})
check(published(calls) == [], f"runs without an app must not be published, got {published(calls)}")

if failures:
    print("FAIL: cmux NEXT DEV daily dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV daily dispatcher hands over the newest run with an app")
