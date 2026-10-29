#!/usr/bin/env python3
"""Keep one comment on a pull request into feat-cmux-next that names its red web and size checks.

The web checks and the CmuxNextApp size cap are advisory (not required) on feat-cmux-next, so a
red one does not stop a merge; this comment makes it impossible to miss (chief 2026-10-12, after
#20117 merged with red web checks and left 168 settings strings stale on the base).

Reads every check run of the pull request's head commit, keeps the newest run per name among the
TRACKED names, and writes the `checks` line of the pull request's status comment
(scripts/ci/pr_status.py):
  - some tracked check red -> "red: <check>; do not merge until green; see lane-rules", one line
    per red check;
  - none red, and the line says red -> "web and size checks: green";
  - none red and no red line -> nothing (no comment on a clean PR).
Pending checks do not count. Several workflows call it (each after its own checks); every call
recomputes from all check runs, so the line converges.

With BASE_SHA (the pull request's base commit), each red check is compared with the base commit's
run of the same check (Leo 2026-10-19, after #20633 merged a new lint red behind a known base red):
its failure signature is its failed step names plus its failure annotations (minus "Process
completed with exit code N"). Anything in the pull request's signature that the base's lacks is
NEW and blocks; the same signature is a base red and does not; a base with no finished run of the
check cannot excuse it. A new advisory check is one more entry
in TRACKED. The comment this used to keep on its own (LEGACY_MARKER) is deleted on the first write.

OWN_CHECKS_GREEN=true (the caller's tracked jobs all passed or were skipped) reads only the status
comment and stops when its line names no red: then this call has nothing to change.

A call for a commit that is no longer the pull request's head writes nothing: a red at a superseded
commit is not the pull request's red, and a late call for an old head (queued behind a newer one in
the per-PR group) must not overwrite the line the current head's call wrote. The head is read just
before the write, so only a call that has something to change pays for that read.

Env: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA, GITHUB_API_URL (default api.github.com),
BASE_SHA, OWN_CHECKS_GREEN.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_status  # noqa: E402

LEGACY_MARKER = "<!-- cmux-red-checks -->"
# (kind, value): "prefix" matches the start of a check name, "name" the whole name.
TRACKED = (
    ("prefix", "web / "),                            # ci-web.yml jobs (ci.yml `web` caller)
    ("name", "cmux-next CmuxNextApp size cap"),       # cmux-next-guards.yml app-size job (hq-11)
    ("name", "cmux-next crash ratchet"),              # cmux-next-guards.yml crash-ratchet job
    ("name", "cmux-next page strings generate"),      # cmux-next-guards.yml page-strings job
    ("name", "cmux-next checks (god files, concurrency, crash safety, l10n)"),  # cmux-next.yml checks job
)
RED = {"failure", "timed_out", "action_required", "startup_failure"}
GREEN_LINE = "web and size checks: green"
BLOCK = "do not merge until green; see lane-rules"
EXIT_CODE = re.compile(r"^Process completed with exit code \d+\.?$")


def tracked(name):
    return any(name.startswith(v) if k == "prefix" else name == v for k, v in TRACKED)


def newest_runs(check_runs):
    """The newest run of each tracked check, by name."""
    newest = {}
    for run in check_runs:
        name = run.get("name") or ""
        if not tracked(name):
            continue
        key = (run.get("started_at") or "", run.get("id") or 0)
        if name not in newest or key > newest[name][0]:
            newest[name] = (key, run)
    return {n: r for n, (_, r) in newest.items()}


def is_red(run):
    return run is not None and run.get("status") == "completed" and run.get("conclusion") in RED


def red_checks(check_runs):
    """Names of tracked checks whose newest completed run is red."""
    return sorted(n for n, r in newest_runs(check_runs).items() if is_red(r))


def signature(steps, annotations):
    """What failed in one check run: its failed step names and its failure annotations."""
    sig = [f"step `{s.get('name')}`" for s in steps if s.get("conclusion") in RED]
    for a in annotations:
        message = " ".join((a.get("message") or "").split())
        if a.get("annotation_level") == "failure" and message and not EXIT_CODE.match(message):
            sig.append(f"`{message[:160]}`")
    return list(dict.fromkeys(sig))


def compare(name, pr_sig, base_run, base_sig, base_sha):
    """The line for one red check, given the base commit's run of it (None: no finished run)."""
    short = base_sha[:10]
    if base_run is None or base_run.get("status") != "completed" or base_run.get("conclusion") not in RED | {"success"}:
        # Missing, running, cancelled or skipped: no verdict on the base to excuse anything with.
        return f"red: {name}; no finished base run on {short} to compare; {BLOCK}"
    if not is_red(base_run):
        return f"red: {name}; NEW: green on the base {short}; {BLOCK}"
    new = [item for item in pr_sig if item not in base_sig]
    if not new:
        return f"red: {name}; base red: the same failure on the base {short}; does not block"
    what = new[0] + (f" (+{len(new) - 1} more)" if len(new) > 1 else "")
    verb = "passes" if new[0].startswith("step ") else "is not red"
    return f"red: {name}; NEW: {what} {verb} on the base {short}; {BLOCK}"


def decide(check_runs, existing_line, lines=None):
    """The checks line to write, or None to leave it as it is. `lines` maps a red check to its
    base-compared line (BASE_SHA); without it every red check blocks."""
    red = red_checks(check_runs)
    if red:
        line = "\n".join((lines or {}).get(n) or f"red: {n}; {BLOCK}" for n in red)
    elif existing_line is not None and "red: " in existing_line:
        line = GREEN_LINE
    else:
        return None
    return None if existing_line is not None and existing_line.strip() == line else line


class GitHub:
    def __init__(self, api, repo, token):
        self.api, self.repo, self.token = api.rstrip("/"), repo, token

    def call(self, method, path, payload=None):
        req = urllib.request.Request(self.api + path, method=method,
                                     data=None if payload is None else json.dumps(payload).encode(),
                                     headers={"Authorization": f"Bearer {self.token}",
                                              "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"null")

    def pages(self, path, key=None):
        out, page = [], 1
        while page <= 10:
            sep = "&" if "?" in path else "?"
            data = self.call("GET", f"{path}{sep}per_page=100&page={page}")
            items = data[key] if key else data
            out += items
            if len(items) < 100:
                break
            page += 1
        return out


def run_signature(gh, run):
    steps = gh.call("GET", f"/repos/{gh.repo}/actions/jobs/{run['id']}").get("steps") or []
    annotations = gh.call("GET", f"/repos/{gh.repo}/check-runs/{run['id']}/annotations?per_page=100") or []
    return signature(steps, annotations)


def base_lines(gh, runs, base_sha):
    """Each red check's line compared with the base commit's run of it; {} without a base."""
    red = red_checks(runs)
    if not base_sha or not red:
        return {}
    try:
        base = newest_runs(gh.pages(f"/repos/{gh.repo}/commits/{base_sha}/check-runs?filter=latest", key="check_runs"))
    except (urllib.error.URLError, TimeoutError) as err:
        print(f"pr-red-checks: base {base_sha[:10]} unreadable ({err}); every red blocks", file=sys.stderr)
        return {}
    mine = newest_runs(runs)
    lines = {}
    for name in red:
        base_run = base.get(name)
        try:
            pr_sig = run_signature(gh, mine[name])
            base_sig = run_signature(gh, base_run) if is_red(base_run) else []
        except (urllib.error.URLError, TimeoutError) as err:
            print(f"pr-red-checks: {name}: no signature ({err}); it blocks", file=sys.stderr)
            continue
        lines[name] = compare(name, pr_sig, base_run, base_sig, base_sha)
    return lines


def main():
    gh = GitHub(os.environ.get("GITHUB_API_URL", "https://api.github.com"), os.environ["GITHUB_REPOSITORY"],
                os.environ["GITHUB_TOKEN"])
    pr, sha = os.environ["PR_NUMBER"], os.environ["HEAD_SHA"]
    current = pr_status.section(gh.repo, int(pr), "checks", api=gh.call)
    if os.environ.get("OWN_CHECKS_GREEN") == "true" and (current is None or "red: " not in current):
        # The caller's own tracked checks passed and the line names no red: reading the head's
        # check runs could only find another workflow's red, which that workflow's own call (after
        # its checks) writes. Nothing for this call to change; skip the check-runs pages.
        print(f"pr-red-checks: #{pr} {sha[:12]}: own checks green, no red line; action=none")
        return 0
    runs = gh.pages(f"/repos/{gh.repo}/commits/{sha}/check-runs?filter=latest", key="check_runs")
    lines = base_lines(gh, runs, os.environ.get("BASE_SHA", "").strip())
    line = decide(runs, current, lines)
    action = None
    if line is not None:
        head = ((gh.call("GET", f"/repos/{gh.repo}/pulls/{pr}") or {}).get("head") or {}).get("sha")
        if head != sha:
            print(f"pr-red-checks: #{pr} {sha[:12]}: superseded by head {str(head)[:12]}; action=none")
            return 0
        action = pr_status.upsert(gh.repo, int(pr), "checks", line, legacy=LEGACY_MARKER, api=gh.call)
    print(f"pr-red-checks: #{pr} {sha[:12]}: red={red_checks(runs)} action={action or 'none'}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except urllib.error.HTTPError as err:
        # A fork pull request gets a read-only token: the comment cannot be written. Say so; never
        # fail the calling workflow over an advisory comment.
        print(f"pr-red-checks: WARNING, GitHub refused ({err.code} {err.reason}); no comment written", file=sys.stderr)
        sys.exit(0)
