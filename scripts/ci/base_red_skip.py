#!/usr/bin/env python3
"""A pull request run skips a Mac job that is red on the base for a reason the pull request does not touch.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period." Over 11-22 21Z..11-23 21Z
`cmux-next generated files` was green on 0 of 538 runs (14.6k Mac-min), `cmux-next fast tier` on 188 of 1,562
(27k): each pull request run spent about 27 min to report the base's red again (cmuxterm-hq
docs/ci/ci-cut-ledger.md, "required checks: no run on PR heads while the check is red on base"). The red also
hid a new one: cmux#48267 merged a compile red into generated files unseen because the job was always red.

For each job J in JOBS that the router would run:
  1. the newest completed cmux-next.yml run on the base branch within WINDOW_HOURS that has a verdict for J
     (success or failure; skipped and cancelled are no verdict) is read. Green: J runs.
  2. J red there: J's log is read for the Swift files its errors name (`File.swift:12:3: error:`, a failed
     test's `File.swift:12`). None named: J runs (nothing to compare).
  3. J is skipped, with its reason in the step summary and a notice, only when no changed path of the pull
     request (changed-files, vs the base tip) or of the base since the red run (compare API) is
       - a file the red names, or in the same Swift target folder (`.../Sources/T/`, `.../Tests/T/`) as one,
       - a Package.swift / Package.resolved / project.pbxproj,
       - the job's own definition (cmux-next.yml, scripts/ci, scripts/cmux-next, .github/actions).
     A fix of the red (it touches the named file) therefore runs the job, and so does a pull request that
     edits the area that is red.
Everything else fails open: the full-ci label, an API or log error, a truncated compare (300 files), a red
older than the window, `vars.CMUX_NEXT_BASE_RED_SKIP == '0'` (BASE_RED_SKIP=0). Residual risk, owned: a pull
request that changes an API used by a red file in ANOTHER target is not run here; the next base run of the
job reads it (it is red already, so base-red notes name it).

    base_red_skip.py --changed-files FILE --base-sha SHA [--labels a,b] [--github-output FILE]

Prints `base_red_jobs= generated-files fast-tier ` (space-padded, for `contains()`) to --github-output,
and `fast_tier=false` (last output wins) for the fast tier.
Test: scripts/ci/tests/test_base_red_skip.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

WORKFLOW = "cmux-next.yml"
# workflow job key -> job name on a run
JOBS = {
    "fast-tier": "cmux-next fast tier",
    "generated-files": "cmux-next generated files",
}
WINDOW_HOURS = 6
RUNS_PAGE = 40
MAX_JOB_READS = 6
LOG_MAX_BYTES = 120 * 1024 * 1024
COMPARE_FILE_CAP = 300
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
# A Swift source path followed by :line on a line that reports an error or a test issue.
SWIFT_PATH = re.compile(r"((?:[\w.+@~-]+/)*[\w.+@~-]+\.swift):\d+")
REPORTS = re.compile(r"\berror:|\bissue\b|✘|\bfailed\b", re.IGNORECASE)
TARGET_DIR = re.compile(r"^(.*?/(?:Sources|Tests)/[^/]+)/")
ALWAYS = ("Package.swift", "Package.resolved", "project.pbxproj")
PLUMBING = (".github/workflows/cmux-next.yml", ".github/actions/", "scripts/ci/", "scripts/cmux-next/")


class Unknown(Exception):
    """Nothing can be said: the job runs."""


class DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    # The job-logs endpoint answers 302 to a signed blob URL; the blob store refuses a forwarded token.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        old, moved = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if new is not None and (moved.scheme, moved.netloc) != (old.scheme, old.netloc):
            new.remove_header("Authorization")
        return new


def api(path: str, *, raw: bool = False, limit: int = 8 * 1024 * 1024):
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not token or not repo:
        raise Unknown("no token or repository")
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    request = urllib.request.Request(f"{base}/repos/{repo}/{path}", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.build_opener(DropAuthOnRedirect).open(request, timeout=30) as response:
            body = response.read(limit + 1)
    except OSError as error:
        raise Unknown(f"GET {path.split('?', 1)[0]}: {error}") from error
    if len(body) > limit:
        raise Unknown(f"GET {path.split('?', 1)[0]}: over {limit} bytes")
    return body.decode("utf-8", "replace") if raw else json.loads(body)


def swift_paths(log: str) -> set[str]:
    """The Swift files a job's log names in error or failed-test lines."""
    found = set()
    for line in ANSI.sub("", log).splitlines():
        if ".swift:" not in line or not REPORTS.search(line):
            continue
        for match in SWIFT_PATH.finditer(STAMP.sub("", line)):
            found.add(match.group(1))
    return found


def touches(changed: list[str], named: set[str]) -> str | None:
    """The first changed path that reaches what the red names, or None."""
    targets = set()
    for path in named:
        match = TARGET_DIR.match(path)
        targets.add(match.group(1) if match else os.path.dirname(path))
    targets.discard("")
    for path in changed:
        base = os.path.basename(path)
        if base in ALWAYS or any(path == p or path.startswith(p) for p in PLUMBING):
            return path
        for full in named:
            if full == path or full.endswith("/" + path):
                return path
        for target in targets:
            # A runner path ends with the repository path: some suffix of the target (3+ folders) is a
            # prefix of the changed path.
            parts = target.split("/")
            if any(path.startswith("/".join(parts[i:]) + "/") for i in range(len(parts) - 2)):
                return path
    return None


def parse_time(text: str) -> datetime:
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def base_verdicts(branch: str, wanted: dict[str, str], now: datetime) -> dict[str, dict]:
    """Per workflow job key: the newest base run's verdict {conclusion, sha, run_url, job_id, name}."""
    runs = api(f"actions/workflows/{WORKFLOW}/runs?" + urllib.parse.urlencode(
        {"branch": branch, "status": "completed", "per_page": RUNS_PAGE}))["workflow_runs"]
    runs = [r for r in runs if now - parse_time(r["created_at"]) <= timedelta(hours=WINDOW_HOURS)]
    runs.sort(key=lambda r: r["created_at"], reverse=True)
    found: dict[str, dict] = {}
    reads = 0
    for run in runs:
        if len(found) == len(wanted):
            break
        # A run that ended green or cancelled can carry no red; a red job makes its run "failure".
        if run.get("conclusion") not in ("failure", "success"):
            continue
        if run["conclusion"] == "success" and not any(k not in found for k in wanted):
            continue
        reads += 1
        if reads > MAX_JOB_READS:
            break
        jobs = api(f"actions/runs/{run['id']}/jobs?filter=latest&per_page=100")["jobs"]
        for key, name in wanted.items():
            if key in found:
                continue
            for job in jobs:
                if job.get("name") == name and job.get("conclusion") in ("success", "failure"):
                    found[key] = {"conclusion": job["conclusion"], "sha": run["head_sha"],
                                  "run_url": run["html_url"], "job_id": job["id"], "name": name}
    return found


def decide(changed: list[str], base_sha: str, branch: str, labels: str, now: datetime | None = None):
    """(skipped job keys, report lines)."""
    now = now or datetime.now(timezone.utc)
    lines: list[str] = []
    if "full-ci" in [l.strip() for l in labels.split(",")]:
        return [], ["full-ci label: no base-red skip."]
    if os.environ.get("BASE_RED_SKIP") == "0":
        return [], ["BASE_RED_SKIP=0: no base-red skip."]
    try:
        verdicts = base_verdicts(branch, JOBS, now)
    except Unknown as error:
        return [], [f"base verdicts unreadable ({error}): every job runs."]
    skipped: list[str] = []
    for key, name in JOBS.items():
        verdict = verdicts.get(key)
        if verdict is None:
            lines.append(f"{name}: no base verdict in {WINDOW_HOURS} h: runs.")
            continue
        if verdict["conclusion"] != "failure":
            lines.append(f"{name}: green on base ({verdict['sha'][:12]}): runs.")
            continue
        try:
            named = swift_paths(api(f"actions/jobs/{verdict['job_id']}/logs", raw=True, limit=LOG_MAX_BYTES))
            if not named:
                lines.append(f"{name}: red on base but its log names no Swift file: runs.")
                continue
            moved: list[str] = []
            if verdict["sha"] != base_sha:
                files = api(f"compare/{verdict['sha']}...{base_sha}")["files"]
                if len(files) >= COMPARE_FILE_CAP:
                    raise Unknown("the base moved over 300 files since the red")
                moved = [f["filename"] for f in files]
        except Unknown as error:
            lines.append(f"{name}: red on base, evidence unreadable ({error}): runs.")
            continue
        hit = touches(changed, named) or touches(moved, named)
        if hit:
            lines.append(f"{name}: red on base ({verdict['sha'][:12]}) but {hit} reaches what the red names: runs.")
            continue
        skipped.append(key)
        sample = ", ".join(sorted(named)[:3])
        lines.append(f"{name}: SKIPPED, inherits the base verdict: red on {verdict['sha'][:12]} "
                     f"({verdict['run_url']}) at {len(named)} Swift file(s) ({sample}); this pull request "
                     f"changes none of them or their target folders. Add the full-ci label to run it anyway.")
    return skipped, lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--changed-files", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--branch", default="feat-cmux-next")
    parser.add_argument("--labels", default="")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    try:
        changed = [l.strip() for l in open(args.changed_files, encoding="utf-8") if l.strip()]
    except OSError:
        changed = []
    try:
        skipped, lines = decide(changed, args.base_sha, args.branch, args.labels)
    except Exception as error:  # noqa: BLE001 - any failure fails open
        skipped, lines = [], [f"base-red skip failed open: {error}"]
    for key in skipped:
        print(f"::notice title={JOBS[key]} skipped (base red)::inherits the base verdict")
    print("### Base verdicts for PR jobs")
    for line in lines:
        print(f"- {line}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"base_red_jobs= {' '.join(skipped)} \n" if skipped else "base_red_jobs=\n")
            # The last value of an output wins: the fast tier's own route flag goes false, which skips
            # fast-tier, its fleet job, its re-run placement and its runner grant with no workflow edit.
            if "fast-tier" in skipped:
                out.write("fast_tier=false\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
