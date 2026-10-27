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
# A feat-cmux-next push run hands over its landing compile's app (cmux-next.yml
# dev-landing-publish); its only producer is that job, and a DEV dispatch run must
# still be finished and named for the SHA it built.
check('.event == "push"' in sign_text and '.head_branch == "feat-cmux-next"' in sign_text
      and '.path == ".github/workflows/cmux-next.yml"' in sign_text,
      "the publisher must accept a feat-cmux-next push run of cmux-next.yml")
check('(.event == "workflow_dispatch" and .status == "completed"' in sign_text,
      "a DEV dispatch source run must still be finished")
check("SOURCE_LANDING_PRODUCER_JOB: cmux NEXT DEV Release compile (landing)" in publish_text
      and '[[ "$SOURCE_EVENT" != push ]] || producers="$SOURCE_LANDING_PRODUCER_JOB"' in sign_text
      and 'done <<< "$producers"' in sign_text,
      "a push run's only app producer is its landing compile")
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
  git: {
    getRef: async () => ({ data: { object: { sha: fixture.tip } } }),
    getCommit: async () => ({ data: { committer: { date: fixture.tipDate } } }),
  },
  actions: {
    listWorkflowRuns: async ({ workflow_id, event }) => ({ data: { workflow_runs:
      workflow_id !== 'cmux-next.yml' ? fixture.publishRuns
        : event === 'push' ? fixture.pushRuns
        : fixture.sourceRuns } }),
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


def run(source_runs, jobs, publish_runs=(), push_runs=(), tip_age_s=3600):
    tip_date = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=tip_age_s)
    fixture = {"tip": TIP, "tipDate": tip_date.strftime("%Y-%m-%dT%H:%M:%SZ"), "sourceRuns": list(source_runs), "publishRuns": list(publish_runs), "pushRuns": list(push_runs),
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



# The publisher's own source checks, run as bash against a stub gh: "Resolve the
# source run" (which runs it accepts) and the source gate (which producer counts).
def sign_step(name):
    steps = re.split(r"^      - ", sign_text, flags=re.MULTILINE)
    step = next((s for s in steps if s.startswith(f"name: {name}\n")), "")
    body = re.search(r"^        run: \|\n((?:^          .*\n|^\s*\n)+)", step, re.MULTILINE)
    return "\n".join(line[10:] for line in body.group(1).splitlines()) if body else ""


STUB_GH = r"""#!/bin/bash
# gh api PATH [--jq FILTER]: answer from $STUB_DIR, keyed by the path's kind.
[ "$1" = api ] || exit 2
case "$2" in
  */jobs\?*) file="$STUB_DIR/jobs.json" ;;
  */git/ref/heads/*) file="$STUB_DIR/ref.json" ;;
  */compare/*) file="$STUB_DIR/compare.json" ;;
  */actions/runs/*) file="$STUB_DIR/run.json" ;;
  *) exit 3 ;;
esac
[ -f "$file" ] || { echo "gh: HTTP 502" >&2; exit 1; }
if [ "$3" = --jq ]; then exec jq -r "$4" "$file"; fi
cat "$file"
"""


def publisher_checks(run, jobs):
    """(exit code, eligible output, GITHUB_ENV text) of resolve + gate for one source run."""
    resolve, gate = sign_step("Resolve the source run"), sign_step("Require a successful app-producing job")
    if not resolve or not gate:
        failures.append("could not find the publisher's resolve and gate steps")
        return None
    sha = run["head_sha"]
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "gh").write_text(STUB_GH)
        (tmp / "gh").chmod(0o755)
        (tmp / "run.json").write_text(json.dumps(run))
        if jobs is not None:
            (tmp / "jobs.json").write_text(json.dumps({"jobs": jobs}))
        (tmp / "ref.json").write_text(json.dumps({"object": {"sha": sha}}))
        (tmp / "compare.json").write_text(json.dumps({"status": "identical"}))
        (tmp / "resolve.sh").write_text(resolve + "\n")
        (tmp / "gate.sh").write_text(gate + "\n")
        env = {"PATH": f"{tmp}:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "STUB_DIR": str(tmp),
               "GH_REPO": "o/r", "SOURCE_RUN_ID": "77", "GITHUB_ENV": str(tmp / "env"),
               "GITHUB_OUTPUT": str(tmp / "out"),
               "SOURCE_APP_PRODUCER_JOBS": "cmux NEXT DEV Release compile\ncmux app scheme compile (Debug)",
               "SOURCE_LANDING_PRODUCER_JOB": "cmux NEXT DEV Release compile (landing)"}
        first = subprocess.run(["bash", str(tmp / "resolve.sh")], capture_output=True, text=True, env=env, timeout=60)
        if first.returncode != 0:
            return first.returncode, None, ""
        for line in (tmp / "env").read_text().splitlines():
            key, _, value = line.partition("=")
            env[key] = value
        second = subprocess.run(["bash", str(tmp / "gate.sh")], capture_output=True, text=True, env=env, timeout=60)
        out = (tmp / "out").read_text() if (tmp / "out").exists() else ""
        eligible = re.search(r"^eligible=(\w+)$", out, re.MULTILINE)
        return second.returncode, eligible.group(1) if eligible else None, (tmp / "env").read_text()


if shutil.which("bash") and shutil.which("jq"):
    S = "a" * 40

    def source(event, status="completed", title=None, branch="feat-cmux-next", path=".github/workflows/cmux-next.yml"):
        return {"event": event, "status": status, "head_branch": branch, "path": path, "head_sha": S,
                "head_repository": {"full_name": "o/r"}, "name": "cmux-next",
                "display_title": title or f"cmux-next · {S}"}

    landing_ok = [{"name": "cmux NEXT DEV Release compile (landing)", "conclusion": "success"}]
    dev_ok = [{"name": "cmux NEXT DEV Release compile", "conclusion": "success"}]
    dev_title = f"cmux NEXT DEV daily · {S}"
    cases = (
        ("an in-progress push run with a landing compile", source("push", "in_progress"), landing_ok, (0, "true")),
        ("a finished DEV dispatch run", source("workflow_dispatch", title=dev_title), dev_ok, (0, "true")),
        ("a DEV dispatch run still running", source("workflow_dispatch", "in_progress", title=dev_title), dev_ok, ("fail", None)),
        ("a dispatch run not named for its SHA", source("workflow_dispatch"), dev_ok, ("fail", None)),
        ("a pull request run", source("pull_request"), landing_ok, ("fail", None)),
        ("a push run of another branch", source("push", branch="main"), landing_ok, ("fail", None)),
        ("a push run of another workflow", source("push", path=".github/workflows/ci.yml"), landing_ok, ("fail", None)),
        ("a push run whose only app job is the DEV-run producer", source("push", "in_progress"), dev_ok, ("fail", None)),
        ("a push run whose jobs came back empty", source("push", "in_progress"), [], ("fail", None)),
        ("a push run whose jobs read failed", source("push", "in_progress"), None, ("fail", None)),
        ("a red DEV run without its app", source("workflow_dispatch", title=dev_title),
         [{"name": "cmux NEXT DEV Release compile", "conclusion": "failure"}], (0, "false")),
    )
    for label, run_json, jobs, (want_rc, want_eligible) in cases:
        result = publisher_checks(run_json, jobs)
        if result is None:
            break
        rc, eligible, env_text = result
        ok = (rc != 0 if want_rc == "fail" else rc == 0) and eligible == want_eligible
        check(ok, f"publisher source checks, {label}: expected rc {want_rc} eligible {want_eligible}, got rc {rc} eligible {eligible}")
        if ok and want_eligible == "true":
            check(f"SOURCE_SHA={S}" in env_text, f"publisher source checks, {label}: SOURCE_SHA not set: {env_text!r}")
else:
    failures.append("bash and jq are required for the publisher source checks")

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

# No spacing: a DEV build of an older landing, however young, never holds the
# tip back (dispatch lag p50 10.2 min, p90 34.6 min on 2026-10-26 with it).
def built(calls):
    return [c[2]["dev_daily_sha"] for c in calls if c[0] == "dispatch" and c[1] == "cmux-next.yml"]


def active_run(run_id, sha, age_s, status="in_progress", title=None, name="cmux-next"):
    created = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age_s)
    return {"id": run_id, "head_sha": sha, "status": status, "conclusion": None,
            "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "name": name, "display_title": title or f"cmux NEXT DEV daily · {sha}"}


# A tip with no landing path (no push run with a landing placement: the landing
# compile off) keeps the five-minute spacing: its push run's cmux-scheme-compile
# builds the app, and a DEV build per merge would compile it twice.
for status in ("queued", "requested", "waiting", "pending", "in_progress"):
    calls = run([active_run(20, "2" * 40, 60, status=status)], {})
    check(built(calls) == [], f"with no landing path a {status} DEV build under five minutes old spaces the tip, got {built(calls)}")
calls = run([active_run(21, "2" * 40, 6 * 60)], {})
check(built(calls) == [TIP], f"a DEV build over five minutes old must not hold the tip, got {built(calls)}")
for title in ("cmux NEXT DEV daily · publish 123", "cmux NEXT DEV daily · abc"):
    calls = run([active_run(20, "2" * 40, 60, title=title)], {})
    check(built(calls) == [TIP], f"{title!r} is not a dispatched DEV build and must not space the tip, got {built(calls)}")
calls = run([active_run(23, TIP, 60)], {})
check(built(calls) == [], f"a running DEV build of the tip itself covers it, got {built(calls)}")
check(run([], {}) and built(run([], {})) == [TIP], "with no DEV build running the tip is built")


# The tip's push run compiles its own DEV app (cmux-next.yml dev-landing-compile).
def push_run(run_id, status="in_progress", sha=TIP, age_s=60):
    created = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age_s)
    return {"id": run_id, "head_sha": sha, "status": status, "conclusion": None if status != "completed" else "success",
            "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "name": "cmux-next", "display_title": f"cmux-next · {sha}"}


def landing_jobs(place=("completed", "success"), compile_=None):
    jobs = [{"name": "cmux NEXT DEV landing placement", "status": place[0], "conclusion": place[1]}]
    if compile_:
        jobs.append({"name": "cmux NEXT DEV Release compile (landing)", "status": compile_[0], "conclusion": compile_[1]})
    return jobs


for label, jobs in (("placing", landing_jobs(place=("in_progress", None))),
                    ("placed, compile not yet created", landing_jobs()),
                    ("compiling", landing_jobs(compile_=("in_progress", None))),
                    ("compile queued", landing_jobs(compile_=("queued", None)))):
    calls = run([], {30: jobs}, push_runs=[push_run(30)])
    check(built(calls) == [] and published(calls) == [],
          f"a landing compile that is {label} covers the tip: no DEV build, got {calls}")
calls = run([], {31: landing_jobs(compile_=("completed", "success"))}, push_runs=[push_run(31)])
check(built(calls) == [] and published(calls) == ["31"],
      f"a finished landing compile is handed to the publisher instead of a DEV build, got {calls}")
calls = run([], {32: landing_jobs(compile_=("completed", "success"))}, push_runs=[push_run(32)],
            publish_runs=[{"name": "x", "display_title": "cmux NEXT DEV daily · publish 32", "status": "in_progress"}])
check(built(calls) == [] and published(calls) == [],
      f"a landing app already handed over is not handed over again, got {calls}")
for label, jobs, status in (("failed", landing_jobs(compile_=("completed", "failure")), "completed"),
                            ("skipped (no tree)", landing_jobs(compile_=("completed", "skipped")), "completed"),
                            ("off", [{"name": "cmux NEXT DEV landing placement", "status": "completed", "conclusion": "skipped"}], "in_progress"),
                            ("placement failed", landing_jobs(place=("completed", "failure")), "completed")):
    calls = run([], {33: jobs}, push_runs=[push_run(33, status=status)])
    check(built(calls) == [TIP], f"a landing compile that is {label} leaves the tip to a DEV build, got {calls}")
    # A tried landing path is never spaced: an older landing's young DEV build does not hold it.
    calls = run([active_run(20, "2" * 40, 60)], {33: jobs}, push_runs=[push_run(33, status=status)])
    expected = [] if label == "off" else [TIP]
    check(built(calls) == expected, f"a landing compile that is {label} with a young DEV build running: expected {expected}, got {calls}")
calls = run([], {34: landing_jobs(compile_=("in_progress", None))}, push_runs=[push_run(34, sha="3" * 40)])
check(built(calls) == [TIP], f"another commit's landing compile does not cover the tip, got {calls}")
# A push run that has not listed its placement yet: young, it is about to place;
# old (a push run without a landing compile, before cmux#25744), it covers nothing.
calls = run([], {35: []}, push_runs=[push_run(35, age_s=30)])
check(built(calls) == [], f"a push run seconds old that has not listed its placement covers the tip, got {calls}")
calls = run([], {36: [{"name": "cmux-next path routing", "status": "completed", "conclusion": "success"}]},
            push_runs=[push_run(36, age_s=10 * 60)])
check(built(calls) == [TIP], f"a push run with no landing compile leaves the tip to a DEV build, got {calls}")
# GitHub has not listed the push run of a tip that landed seconds ago: its landing
# compile takes it. An older tip with no push run (a path-filtered push) is built.
calls = run([], {}, tip_age_s=20)
check(built(calls) == [], f"a tip seconds old with no push run listed yet waits for its landing compile, got {calls}")
calls = run([], {}, tip_age_s=10 * 60)
check(built(calls) == [TIP], f"a tip minutes old with no push run gets a DEV build, got {calls}")
# The tip's own DEV run built its app but a later job failed: its app is published,
# and the tip is not compiled again on every tick.
calls = run([dev_run(37, TIP, "failure")], {37: app_job("success")})
check(published(calls) == ["37"] and built(calls) == [],
      f"a tip whose DEV run built its app is covered even when another job failed, got {calls}")
check(re.search(r"select\(\.conclusion == \"success\"\) \| \.name' \|\| true", publish_text) is None,
      "a failed source-job read must fail the publisher run, not succeed with nothing published")

# No finished run has an app: nothing is published.
calls = run([dev_run(7, "7" * 40, "failure"), dev_run(6, "6" * 40, "failure")],
            {7: app_job("failure"), 6: app_job("skipped")})
check(published(calls) == [], f"runs without an app must not be published, got {published(calls)}")

if failures:
    print("FAIL: cmux NEXT DEV daily dispatcher\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: cmux NEXT DEV daily dispatcher hands over the newest run with an app")
