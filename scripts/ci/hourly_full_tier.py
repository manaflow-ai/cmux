#!/usr/bin/env python3
"""The hourly full tier: feat-cmux-next's own head runs the full tier once an hour, instead of every landing head.

cmuxterm-hq goals/ci-runner-min-per-day-50k.md, cut 2. Leo, 2026-11-26: "de facto, im asking for 99% fewer minutes
of ci time, period." With head_tier.py's hourly full tier rule a `ready-to-land` head runs only its affected (cheap)
tier and lands on it; the workflows whose full tier that skips are listed in .github/hourly-full-tier.json and run
here on the branch instead.

    hourly_full_tier.py run [--repo R] [--branch B] [--dry-run]
        cmux-next-hourly-full-tier.yml's one step. First the verdict: for each listed workflow, the newest finished
        workflow_dispatch run on the branch; a red one (not success, skipped or neutral) names the pull requests merged
        since that workflow's newest green run before it (the first-parent log between the two heads), in one issue
        per red head (deduplicated by title). The base-breaker's owner reverts or fixes forward; nothing is reverted
        here. Then the dispatch: each listed workflow whose newest dispatch run is not at the tip, and whose own
        pull_request paths the commits since that run touched, is dispatched on the branch with no inputs. A tip
        that has not moved dispatches nothing.

cmux-next-post-merge-dispatch.yml (main's 30-minute schedule) starts this workflow through post_merge_batch.py tick
(hourly_kick there): at most once every HOURLY_MINUTES, only when the tip moved since the last one. The repository
variable CI_LAND_FULL_PER_PR=1 puts the full tier back on every landing head and skips this workflow's job.
Stdlib only; gh for the API.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / ".github" / "hourly-full-tier.json"
WORKFLOW = "cmux-next-hourly-full-tier.yml"
BRANCH = "feat-cmux-next"
GREEN = frozenset({"success", "skipped", "neutral"})
PR_RE = re.compile(r"\(#(\d+)\)\s*$")
COMPARE_FILES_CAP = 300  # the compare API lists at most this many files: at the cap every workflow is reached
RED_TITLE = "Hourly full tier red at {branch} {sha}"


def gh_api(path: str, *, method: str = "GET", fields: dict | None = None, token: str | None = None,
           run=subprocess.run) -> object:
    argv = ["gh", "api", "-X", method, path]
    data = None
    if fields is not None:
        argv += ["--input", "-"]
        data = json.dumps(fields)
    env = {**os.environ, "GH_TOKEN": token} if token else None
    out = run(argv, input=data, capture_output=True, text=True, env=env)
    if out.returncode:
        raise RuntimeError(f"gh api {method} {path}: {(out.stderr or out.stdout).strip()[-400:]}")
    return json.loads(out.stdout) if out.stdout.strip() else None


def load_manifest(path: Path = MANIFEST) -> dict[str, list[str]]:
    """workflow file -> its paths filter ([] reaches every change)."""
    data = json.loads(path.read_text())
    return {name: list((spec or {}).get("paths") or []) for name, spec in data["workflows"].items()}


def _glob(pattern: str) -> re.Pattern:
    out, i = "", 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out, i = out + "(?:.*/)?", i + 3
        elif pattern.startswith("**", i):
            out, i = out + ".*", i + 2
        elif pattern[i] == "*":
            out, i = out + "[^/]*", i + 1
        elif pattern[i] == "?":
            out, i = out + "[^/]", i + 1
        else:
            out, i = out + re.escape(pattern[i]), i + 1
    return re.compile(out + r"\Z")


def reached(files: list[str] | None, paths: list[str]) -> bool:
    """Whether a pull_request `paths` filter (GitHub's rule: the last pattern a file matches wins, `!` excludes)
    lets any of FILES through. None (unknown files) and an empty filter reach every workflow."""
    if files is None or not paths:
        return True
    compiled = [(p.startswith("!"), _glob(p[1:] if p.startswith("!") else p)) for p in paths]
    for name in files:
        keep = False
        for negated, rx in compiled:
            if rx.match(name):
                keep = not negated
        if keep:
            return True
    return False


def dispatch_runs(repo: str, workflow: str, branch: str, api=gh_api) -> list[dict]:
    """WORKFLOW's workflow_dispatch runs on BRANCH, newest first (one page)."""
    data = api(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={branch}&event=workflow_dispatch&per_page=30")
    runs = list((data or {}).get("workflow_runs") or [])
    runs.sort(key=lambda r: (r.get("created_at") or "", r.get("id") or 0), reverse=True)
    return runs


def verdict(runs: list[dict]) -> tuple[dict, dict | None] | None:
    """(the newest finished run, the newest green finished run before it) when the newest finished run is red; None
    when it is green or nothing has finished. RUNS newest first."""
    done = [r for r in runs if r.get("status") == "completed" and r.get("conclusion") != "cancelled"]
    if not done or done[0].get("conclusion") in GREEN:
        return None
    red = done[0]
    green = next((r for r in done[1:] if r.get("conclusion") in GREEN and r.get("head_sha") != red.get("head_sha")),
                 None)
    return red, green


def first_parent_chain(commits: list[dict], good: str, bad: str) -> list[dict]:
    """The first-parent commits in (good, bad], newest first, from a compare listing (each commit with `sha` and
    `parents`). Stops at GOOD, at a commit the listing lacks, or after the listing's length."""
    by_sha = {c.get("sha"): c for c in commits}
    chain: list[dict] = []
    sha = bad
    while sha and sha != good and sha in by_sha and len(chain) <= len(commits):
        commit = by_sha[sha]
        chain.append(commit)
        parents = commit.get("parents") or []
        sha = parents[0].get("sha") if parents else ""
    return chain


def merged_prs(chain: list[dict]) -> list[tuple[str, str, str]]:
    """(pr number or "", short sha, subject) per first-parent commit."""
    out = []
    for commit in chain:
        subject = (str((commit.get("commit") or {}).get("message") or "").splitlines() or [""])[0]
        match = PR_RE.search(subject)
        out.append((match.group(1) if match else "", str(commit.get("sha") or "")[:10], subject))
    return out


def red_body(branch: str, reds: list[tuple[str, dict, dict | None]], prs: list[tuple[str, str, str]] | None,
             good: str) -> str:
    lines = [f"The hourly full tier ({WORKFLOW}) is red on `{branch}` at {reds[0][1].get('head_sha')}.", ""]
    for workflow, red, green in reds:
        since = f"last green at {str(green.get('head_sha'))[:10]}" if green else "no earlier green hourly run"
        lines.append(f"- {workflow}: [{red.get('conclusion')}]({red.get('html_url')}) ({since})")
    lines.append("")
    if prs is None:
        lines.append("No earlier green hourly run of these workflows to compare with: the first green one starts the log.")
    else:
        lines.append(f"Merged since {good[:10]} (first-parent):")
        for number, sha, subject in prs:
            lines.append(f"- #{number} {subject}" if number else f"- {sha} {subject}")
    lines += ["", "The base-breaker's owner reverts or fixes forward (nothing here reverts). The repository variable "
              "`CI_LAND_FULL_PER_PR=1` puts the full tier back on every landing head (scripts/ci/head_tier.py)."]
    return "\n".join(lines)


def report_reds(repo: str, branch: str, found: list[tuple[str, dict, dict | None]], dry_run: bool, api=gh_api,
                issue_token: str | None = None) -> list[str]:
    """One issue per red head sha, naming the PRs since the oldest last-green head of its red workflows."""
    titles = []
    by_sha: dict[str, list[tuple[str, dict, dict | None]]] = {}
    for item in found:
        by_sha.setdefault(str(item[1].get("head_sha") or ""), []).append(item)
    for sha, reds in by_sha.items():
        title = RED_TITLE.format(branch=branch, sha=sha[:10])
        greens = [g for _, _, g in reds if g]
        # The oldest of the red workflows' last greens covers every one's window; one with none gives no window.
        good = (str(min(greens, key=lambda g: g.get("created_at") or "").get("head_sha") or "")
                if greens and len(greens) == len(reds) else "")
        prs = None
        if good:
            compare = api(f"repos/{repo}/compare/{good}...{sha}?per_page=250") or {}
            prs = merged_prs(first_parent_chain(list(compare.get("commits") or []), good, sha))
        body = red_body(branch, reds, prs, good)
        q = f'repo:{repo} is:issue in:title "{title}"'
        existing = api("search/issues?q=" + _quote(q)) or {}
        if any(item.get("title") == title for item in existing.get("items") or []):
            print(f"{title}: already reported")
            continue
        print(f"{title}\n{body}")
        titles.append(title)
        if not dry_run:
            api(f"repos/{repo}/issues", method="POST", fields={"title": title, "body": body}, token=issue_token)
    return titles


def _quote(text: str) -> str:
    from urllib.parse import quote  # noqa: PLC0415

    return quote(text, safe="")


def due(tip: str, runs: list[dict], files_since, paths: list[str]) -> tuple[bool, str]:
    """Whether to dispatch a workflow at TIP: not when its newest dispatch run is at TIP or one is in flight, nor
    when the commits since its newest dispatch run touch none of its PATHS."""
    if not runs:
        return True, "no hourly run yet"
    newest = runs[0]
    if newest.get("head_sha") == tip:
        return False, "already ran at the tip"
    if any(r.get("status") != "completed" for r in runs[:5]):
        return False, "a run is still going"
    if not reached(files_since(str(newest.get("head_sha") or "")), paths):
        return False, f"nothing since {str(newest.get('head_sha'))[:10]} touches its paths"
    return True, f"the tip moved since {str(newest.get('head_sha'))[:10]}"


def changed_since(repo: str, base: str, tip: str, api=gh_api) -> list[str] | None:
    if not base:
        return None
    try:
        data = api(f"repos/{repo}/compare/{base}...{tip}") or {}
    except RuntimeError:
        return None
    files = [str(f.get("filename") or "") for f in data.get("files") or []]
    return None if len(files) >= COMPARE_FILES_CAP else files


def run(args: argparse.Namespace, api=gh_api) -> int:
    manifest = load_manifest(Path(args.manifest))
    tip = api(f"repos/{args.repo}/commits/{args.branch}")["sha"]
    runs = {wf: dispatch_runs(args.repo, wf, args.branch, api) for wf in manifest}
    found = []
    for wf, wf_runs in runs.items():
        judged = verdict(wf_runs)
        if judged:
            found.append((wf, judged[0], judged[1]))
    if found:
        try:
            report_reds(args.repo, args.branch, found, args.dry_run, api, os.environ.get("ISSUE_TOKEN") or None)
        except RuntimeError as err:
            # The red stays the newest verdict, so the next hour reports it; the dispatches below still go.
            print(f"::warning::hourly full tier red not reported this hour: {err}")
    cache: dict[str, list[str] | None] = {}

    def files_since(base: str) -> list[str] | None:
        if base not in cache:
            cache[base] = changed_since(args.repo, base, tip, api)
        return cache[base]

    for wf, paths in manifest.items():
        go, why = due(tip, runs[wf], files_since, paths)
        print(f"{wf}: {'dispatch' if go else 'skip'}: {why}")
        if go and not args.dry_run:
            api(f"repos/{args.repo}/actions/workflows/{wf}/dispatches", method="POST", fields={"ref": args.branch})
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    p.add_argument("--branch", default=BRANCH)
    p.add_argument("--manifest", default=str(MANIFEST))
    p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        return run(args)
    except RuntimeError as err:
        # An unread answer (a spent rate limit, a 5xx) skips this hour; the next kick asks again.
        print(f"::warning::hourly full tier skipped: {err}")
        return 0


if __name__ == "__main__":
    sys.exit(main())
