#!/usr/bin/env python3
"""Refuse a classic cmux.com deploy from main that nobody approved, before Vercel ships it.

Every push to main that changes a web build input redeploys classic cmux.com and its API: the Vercel Git
integration builds it (web/vercel.json `deploymentEnabled {main: true}`), and docs-channels.yml deploys the docs
projects from the same web/. scripts/ci/classic-auto-deploy.json lists those deploys; its `deploy_guard` section
names what this check reads.

For each commit a push lands on main, this check reads the commit's changed paths and the pull request it came
from. A commit that changes a deployed classic path passes only when that pull request carries the
`classic-migration` label (Leo's approval, the same one classic-frozen-guard accepts) or was opened by a teammate
listed in `deploy_guard.teammates` (classic is their product: Leo, 2026-11-04, "Lawrence/the team should be allowed
to merge wherever"). Anything else is refused: our lanes' pull requests without the label, outside contributors,
bots and direct pushes. Unreadable answers refuse too.

`check` exits 1 on a refusal; .github/workflows/classic-deploy-guard.yml then runs `cancel`, which cancels the
Vercel production deployment of that commit while it is still queued or building, and docs-channels.yml does not
deploy. The pull request checks (classic-api-guard, classic-frozen-guard) judge a change before merge; this one
judges the commit that is about to ship.

The range is everything since the last deploy this guard passed (this workflow's last green push run), not only
the push: a refused commit stays on main after its deployment is cancelled, so the next push would ship it too.
It stays refused until its pull request gets the label: a later revert does not clear it, because a path's
name alone cannot show its content is gone (a rename carries it on under another name). Before the first green
run the baseline is `deploy_guard.seed_baseline` (the commit this guard landed in), so refusals can never move
it forward. A push that does not contain the baseline (a history rewrite) is refused, since its commits cannot
all be listed.

Leo, 2026-11-04: "apparently the api if we change it it'll auto deploy so we wanna make extra sure we dont change
it for clasisc".
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, Iterable

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = ROOT / "scripts" / "ci" / "classic-auto-deploy.json"
ZERO_SHA = "0" * 40
WORKFLOW = "classic-deploy-guard.yml"
COMPARE_PAGE = 100
MAX_COMPARE_PAGES = 100  # 10,000 commits since the last passed deploy; past that, the range is unreadable
GITHUB_API = "https://api.github.com"
VERCEL_API = "https://api.vercel.com"
# Vercel states in which a deployment has not gone live yet and can still be cancelled.
CANCELLABLE = frozenset({"QUEUED", "INITIALIZING", "BUILDING"})
FINISHED = frozenset({"READY", "ERROR", "CANCELED"})

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classic_api_guard import glob_regex  # noqa: E402  (one glob dialect for every classic guard)


class Unreadable(RuntimeError):
    """An answer the check needs could not be read; the deploy is refused."""


class NotForward(RuntimeError):
    """The push is not a fast-forward from the baseline; the deploy is refused."""


def load_config(path: Path) -> dict:
    config = json.loads(path.read_text())
    guard = config.get("deploy_guard")
    if not isinstance(guard, dict) or not guard.get("deploys") or not guard.get("label"):
        raise ValueError(f"{path} has no deploy_guard section with deploys and a label")
    if not re.fullmatch(r"[0-9a-f]{40}", str(guard.get("seed_baseline") or "")):
        raise ValueError(f"{path} deploy_guard.seed_baseline must be a full commit sha")
    known = {d["id"] for d in config["deploys"]}
    missing = [d for d in guard["deploys"] if d not in known]
    if missing:
        raise ValueError(f"deploy_guard names deploys {missing} that {path} does not list")
    return config


def deployed_paths(config: dict, paths: Iterable[str]) -> list[str]:
    """The paths whose change redeploys classic from main (deploy_guard.deploys, less deploy_guard.exclude)."""
    guard = config["deploy_guard"]
    include = [glob_regex(p) for d in config["deploys"] if d["id"] in guard["deploys"] for p in d["paths"]]
    exclude = [glob_regex(p) for p in guard.get("exclude", [])]
    return [p for p in paths if any(r.match(p) for r in include) and not any(r.match(p) for r in exclude)]


def approval(config: dict, pr: dict) -> str | None:
    """Why PR may redeploy classic, or None."""
    guard = config["deploy_guard"]
    labels = {str(label.get("name")) for label in pr.get("labels") or []}
    if guard["label"] in labels:
        return f"#{pr.get('number')} carries Leo's `{guard['label']}` label"
    user = pr.get("user") or {}
    for mate in guard.get("teammates", []):
        if user.get("login") == mate["login"] and user.get("id") == mate["id"] and user.get("type") != "Bot":
            return f"#{pr.get('number')} is teammate {mate['login']}'s classic work"
    return None


def merged_pr(pulls: list[dict], sha: str, branch: str) -> dict | None:
    """The pull request that landed SHA on BRANCH (merge, squash or merge-queue commit), or None."""
    for pr in pulls:
        if (pr.get("merged_at") and (pr.get("base") or {}).get("ref") == branch
                and pr.get("merge_commit_sha") == sha):
            return pr
    landed = [pr for pr in pulls if pr.get("merged_at") and (pr.get("base") or {}).get("ref") == branch]
    # A rebase merge lands the PR's own commits, whose merge_commit_sha is the last of them.
    return landed[0] if len(landed) == 1 else None


def judge(config: dict, commits: list[str], files_of: Callable[[str], list[str]],
          pulls_of: Callable[[str], list[dict]], branch: str = "main") -> tuple[list[str], list[str]]:
    """(refusals, notices) for COMMITS landing on BRANCH. Any exception from a reader is a refusal.

    Every commit is judged by its own changed paths, a rename's old and new name both: never by whether a path
    still differs at the tip, which a rename or a revert-and-re-add would hide."""
    refusals: list[str] = []
    notices: list[str] = []
    for sha in commits:
        try:
            hits = deployed_paths(config, files_of(sha))
        except Exception as exc:  # noqa: BLE001  (an unread file list cannot show classic is untouched)
            refusals.append(f"{sha[:12]}: its changed files could not be read ({exc})")
            continue
        if not hits:
            notices.append(f"{sha[:12]}: no deployed classic path changed")
            continue
        shown = ", ".join(hits[:8]) + (f" and {len(hits) - 8} more" if len(hits) > 8 else "")
        try:
            pr = merged_pr(pulls_of(sha), sha, branch)
        except Exception as exc:  # noqa: BLE001
            refusals.append(f"{sha[:12]} changes {shown}; its pull request could not be read ({exc})")
            continue
        if pr is None:
            refusals.append(f"{sha[:12]} changes {shown} with no pull request merged into {branch} behind it "
                            "(a direct push)")
            continue
        why = approval(config, pr)
        if why:
            notices.append(f"{sha[:12]} changes {shown}: approved, {why}")
        else:
            refusals.append(f"{sha[:12]} (#{pr.get('number')} by {(pr.get('user') or {}).get('login')}) changes "
                            f"{shown} without Leo's `{config['deploy_guard']['label']}` label")
    return refusals, notices


# --- GitHub and Vercel readers -------------------------------------------------------------------------------------

def _request(url: str, token: str | None, method: str = "GET", accept: str = "application/vnd.github+json",
             timeout: float = 30) -> object:
    headers = {"Accept": accept, "User-Agent": "classic-deploy-guard"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, method=method, headers=headers, data=b"" if method == "PATCH" else None)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"null")
    except (urllib.error.URLError, TimeoutError, ValueError) as exc:
        raise Unreadable(f"{method} {url.split('?')[0]}: {exc}") from exc


class GitHub:
    def __init__(self, repo: str, token: str | None, request: Callable[..., object] | None = None):
        self.repo, self.token, self.request = repo, token, request

    def get(self, path: str) -> object:
        return (self.request or _request)(f"{GITHUB_API}/repos/{self.repo}/{path}", self.token)

    def baseline(self, workflow: str, branch: str) -> str | None:
        """The commit of WORKFLOW's last green push run on BRANCH: the last deploy the guard let through. Every
        commit after it ships with the next deploy, refused ones included until they are approved."""
        runs = self.get(f"actions/workflows/{workflow}/runs?branch={branch}&event=push&status=success&per_page=1")
        if not isinstance(runs, dict):
            raise Unreadable(f"{workflow}'s runs returned no object")
        listed = runs.get("workflow_runs") or []
        return listed[0].get("head_sha") if listed else None

    def commits(self, before: str, after: str) -> list[str]:
        """The commits from BEFORE to AFTER, oldest first, all of them (compare pages past its 250-commit answer).

        AFTER must contain BEFORE. A force push that rewrote BEFORE away is not a range this can judge, so it
        raises NotForward: what ships is AFTER's whole tree, and the commits that built it are not all listed."""
        if not before or before == ZERO_SHA:
            raise NotForward(f"no baseline to judge {after[:12]} from")
        commits: list[str] = []
        total = 0
        for page in range(1, MAX_COMPARE_PAGES + 1):
            compare = self.get(f"compare/{before}...{after}?per_page={COMPARE_PAGE}&page={page}")
            if not isinstance(compare, dict):
                raise Unreadable("compare returned no object")
            if compare.get("status") not in ("ahead", "identical"):
                raise NotForward(f"{after[:12]} does not contain {before[:12]} (compare: {compare.get('status')}); "
                                 "a history rewrite on main cannot be validated commit by commit")
            total = int(compare.get("total_commits") or 0)
            batch = [c["sha"] for c in compare.get("commits") or []]
            commits.extend(sha for sha in batch if sha not in commits)
            if len(commits) >= total or not batch:
                break
        if len(commits) < total:
            raise Unreadable(f"the range lands {total} commits; compare listed {len(commits)}")
        return commits

    def files(self, sha: str) -> list[str]:
        paths: list[str] = []
        for page in range(1, 31):  # GitHub lists at most 3,000 files of a commit, 100 a page
            commit = self.get(f"commits/{sha}?per_page=100&page={page}")
            if not isinstance(commit, dict):
                raise Unreadable(f"commit {sha[:12]} returned no object")
            batch = commit.get("files") or []
            for f in batch:
                paths.append(f["filename"])
                if f.get("previous_filename"):
                    paths.append(f["previous_filename"])
            if len(batch) < 100:
                return paths
        raise Unreadable(f"commit {sha[:12]} changes more files than GitHub lists")

    def pulls(self, sha: str) -> list[dict]:
        pulls = self.get(f"commits/{sha}/pulls?per_page=100")
        if not isinstance(pulls, list):
            raise Unreadable(f"commit {sha[:12]}'s pull requests returned no list")
        return pulls


def cancel_deploy(config: dict, sha: str, token: str, team: str, wait_s: float, step_s: float = 15,
                  request: Callable[..., object] | None = None, sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic) -> tuple[int, list[str]]:
    """Cancel the Vercel production deployment of SHA before it goes live. (exit code, lines).

    The Git integration may not have created the deployment yet when this runs, so the list is re-read every
    STEP_S seconds for up to WAIT_S. No deployment by then: Vercel's ignore step skipped the build (nothing to
    cancel) or it has not started; the refusal stays red either way. A deployment already READY went live before
    the guard could stop it: an error, and the commit needs a rollback by a person."""
    request = request or _request
    project = config["deploy_guard"]["vercel_project"]
    query = urllib.parse.urlencode({"projectId": project, "teamId": team, "target": "production", "limit": 50})
    deadline = clock() + wait_s
    out: list[str] = []
    while True:
        listed = request(f"{VERCEL_API}/v6/deployments?{query}", token, accept="application/json")
        deployments = [d for d in (listed or {}).get("deployments", [])
                       if (d.get("meta") or {}).get("githubCommitSha") == sha]
        live = [d for d in deployments if (d.get("state") or d.get("readyState")) == "READY"]
        pending = [d for d in deployments if (d.get("state") or d.get("readyState")) in CANCELLABLE]
        for d in pending:
            request(f"{VERCEL_API}/v12/deployments/{d['uid']}/cancel?teamId={urllib.parse.quote(team)}", token,
                    method="PATCH", accept="application/json")
            out.append(f"::notice::Cancelled Vercel production deployment {d.get('url') or d['uid']} of {sha[:12]}")
        if live:
            out.append(f"::error::{sha[:12]} went live on Vercel ({live[0].get('url')}) before the guard could "
                       "cancel it; roll it back by hand (Vercel Instant Rollback)")
            return 1, out
        if pending:
            return 0, out
        if deployments and all((d.get("state") or d.get("readyState")) in FINISHED for d in deployments):
            out.append(f"::notice::Vercel's deployment of {sha[:12]} already stopped "
                       f"({', '.join(sorted({d.get('state') or d.get('readyState') for d in deployments}))})")
            return 0, out
        if clock() >= deadline:
            out.append(f"::notice::No Vercel production deployment of {sha[:12]} appeared within {int(wait_s)} s "
                       "(the ignore step skipped it, or it has not started)")
            return 0, out
        sleep(step_s)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="judge the commits a push lands on main")
    check.add_argument("--repo", required=True)
    check.add_argument("--before", default="")
    check.add_argument("--after", required=True)
    check.add_argument("--branch", default="main")
    check.add_argument("--baseline", choices=("auto", "before"), default="auto",
                       help="auto: judge every commit since this workflow's last green push run (else the seed "
                            "baseline); before: a dry run of --after alone")
    cancel = sub.add_parser("cancel", help="cancel the Vercel production deployment of --sha")
    cancel.add_argument("--sha", required=True)
    cancel.add_argument("--wait", type=float, default=300)
    args = parser.parse_args(argv)
    config = load_config(args.config)

    if args.command == "check":
        github = GitHub(args.repo, os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN"))
        base = args.before
        try:
            if args.baseline == "auto":
                approved = github.baseline(WORKFLOW, args.branch)
                base = approved or config["deploy_guard"]["seed_baseline"]
                print(f"::notice::Judging every commit since {base[:12]}, "
                      + ("the last deploy this guard passed" if approved else "the seed baseline (no green run yet)"))
                commits = github.commits(base, args.after)
            else:
                commits = [args.after]  # a dry run of one commit
        except NotForward as exc:
            print(f"::error::Refused classic deploy: {exc}")
            return 1
        except Exception as exc:  # noqa: BLE001
            print(f"::error::Refused: the commits of {base[:12]}..{args.after[:12]} could not be read ({exc})")
            return 1
        refusals, notices = judge(config, commits, github.files, github.pulls, args.branch)
        for line in notices:
            print(f"::notice::{line}")
        for line in refusals:
            print(f"::error::Refused classic deploy: {line}")
        if refusals:
            print(f"::error::A deploy of classic cmux.com from {args.branch} needs Leo's "
                  f"`{config['deploy_guard']['label']}` label on the pull request (or a teammate's own classic "
                  "pull request); scripts/ci/classic-auto-deploy.json lists what deploys.")
            return 1
        return 0

    token, team = os.environ.get("VERCEL_TOKEN"), os.environ.get("VERCEL_ORG_ID")
    if not token or not team:
        print("::error::VERCEL_TOKEN and VERCEL_ORG_ID are needed to cancel the deployment; it was not cancelled")
        return 1
    try:
        code, lines = cancel_deploy(config, args.sha, token, team, args.wait)
    except Exception as exc:  # noqa: BLE001
        print(f"::error::The Vercel deployment of {args.sha[:12]} could not be cancelled ({exc})")
        return 1
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
