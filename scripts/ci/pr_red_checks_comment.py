#!/usr/bin/env python3
"""Keep one comment on a pull request into feat-cmux-next that names its red web and size checks.

The web checks and the CmuxNextApp size cap are advisory (not required) on feat-cmux-next, so a
red one does not stop a merge; this comment makes it impossible to miss (chief 2026-10-12, after
#20117 merged with red web checks and left 168 settings strings stale on the base).

Reads every check run of the pull request's head commit, keeps the newest run per name among the
TRACKED names, and keeps exactly one comment (found by MARKER):
  - some tracked check red -> "red: <check>; do not merge until green; see lane-rules", one line
    per red check (created, or edited when the list changed);
  - none red, and the comment says red -> edited to "all web/size checks green";
  - none red and no comment -> nothing (no comment on a clean PR).
Pending checks do not count. Several workflows call it (each after its own checks); every call
recomputes from all check runs, so the comment converges. A new advisory check is one more entry
in TRACKED.

Env: GITHUB_TOKEN, GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA, GITHUB_API_URL (default api.github.com).
"""
import json
import os
import sys
import urllib.error
import urllib.request

MARKER = "<!-- cmux-red-checks -->"
# (kind, value): "prefix" matches the start of a check name, "name" the whole name.
TRACKED = (
    ("prefix", "web / "),                            # ci-web.yml jobs (ci.yml `web` caller)
    ("name", "cmux-next CmuxNextApp size cap"),       # cmux-next-guards.yml app-size job (hq-11)
)
RED = {"failure", "timed_out", "action_required", "startup_failure"}
GREEN_BODY = MARKER + "\nall web/size checks green"


def tracked(name):
    return any(name.startswith(v) if k == "prefix" else name == v for k, v in TRACKED)


def red_checks(check_runs):
    """Names of tracked checks whose newest completed run is red."""
    newest = {}
    for run in check_runs:
        name = run.get("name") or ""
        if not tracked(name):
            continue
        key = (run.get("started_at") or "", run.get("id") or 0)
        if name not in newest or key > newest[name][0]:
            newest[name] = (key, run)
    return sorted(n for n, (_, r) in newest.items() if r.get("status") == "completed" and r.get("conclusion") in RED)


def decide(check_runs, existing_body):
    """(action, body): action is "create", "update" or None."""
    red = red_checks(check_runs)
    if red:
        body = MARKER + "\n" + "\n".join(f"red: {n}; do not merge until green; see lane-rules" for n in red)
    elif existing_body is not None and "red: " in existing_body:
        body = GREEN_BODY
    else:
        return None, None
    if existing_body is None:
        return "create", body
    return ("update", body) if existing_body.strip() != body.strip() else (None, None)


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


def main():
    gh = GitHub(os.environ.get("GITHUB_API_URL", "https://api.github.com"), os.environ["GITHUB_REPOSITORY"],
                os.environ["GITHUB_TOKEN"])
    pr, sha = os.environ["PR_NUMBER"], os.environ["HEAD_SHA"]
    runs = gh.pages(f"/repos/{gh.repo}/commits/{sha}/check-runs?filter=latest", key="check_runs")
    comments = gh.pages(f"/repos/{gh.repo}/issues/{pr}/comments")
    mine = next((c for c in comments if MARKER in (c.get("body") or "")), None)
    action, body = decide(runs, mine["body"] if mine else None)
    if action == "create":
        gh.call("POST", f"/repos/{gh.repo}/issues/{pr}/comments", {"body": body})
    elif action == "update":
        gh.call("PATCH", f"/repos/{gh.repo}/issues/comments/{mine['id']}", {"body": body})
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
