#!/usr/bin/env python3
"""Tell the landings behind a new red on feat-cmux-next's kit tests, the minutes after it turns red.

Why (2026-11-25): feat-cmux-next's `cmux-next-ios kit tests` push runs went 0 green in 60. GitHub
keeps one pending run per concurrency group and replaces it when a newer push joins, so 56 were
cancelled before they started; that part is by design (each finished run covers every landing
before it). The 4 that ran were red: AgentCLIHybridProofTests from 00:11Z, then
LoadingWordsWaitTests (#54975 and #54994 landed four minutes apart, each green on its own base) and
WorkspacesCacheStoreTests. Nobody was told. Each later kit PR went red on tests it never touched,
gh-merge-green excused them as the base's (test_reds.py), and they stayed red. main has
ci-compile-attribution.yml for its compile; feat-cmux-next's kit had nothing.

So, on a red push run: the tests failing here that did not fail in the previous finished push run
(the new reds), and every landing between that run's head and this one that changed the kit's
inputs, get one comment each, naming the new reds and the run. A landing that touched the file a
red was recorded in is listed first as the likely one. Nothing gates or blocks; a run with no new
red says so and writes nothing.

    python3 scripts/ci/ios_kit_base_red.py --repo OWNER/REPO --run RUN_ID [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Callable

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_reds  # noqa: E402

WORKFLOW = "cmux-next-ios-kit.yml"
JOB = "CmuxMobileKit tests (macOS swift test, iOS simulator)"
BRANCH = "feat-cmux-next"
MARKER = "<!-- ios-kit-base-red:{run} -->"
# The kit's inputs: the app tree and the local packages it links (the workflow's push paths).
KIT_PATHS = ("cmux-next-ios/", "Packages/Shared/", "Packages/iOS/")
LANDING = re.compile(r"\(#(\d+)\)\s*$")
SITE = re.compile(r'✘ (?:Test|Suite) ("[^"\n]*"|.+?\)) recorded an issue.*? at ([A-Za-z0-9_+.-]+\.swift):\d+')

Get = Callable[[str], str]


@dataclass
class Landing:
    number: int
    sha: str
    subject: str
    files: list[str] = field(default_factory=list)


def gh_get(path: str) -> str:
    return subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout


def kit_job_log(get: Get, repo: str, run: int) -> str | None:
    jobs = json.loads(get(f"repos/{repo}/actions/runs/{run}/jobs?per_page=50")).get("jobs", [])
    job = next((j for j in jobs if j.get("name") == JOB), None)
    if not job or job.get("conclusion") not in ("success", "failure"):
        return None
    return get(f"repos/{repo}/actions/jobs/{job['id']}/logs")


def failures(log: str | None) -> tuple[set[str], dict[str, set[str]]]:
    """The failing tests a kit log names, and for each the .swift files its issues were recorded in."""
    if not log:
        return set(), {}
    lines = test_reds.lines_of(log)
    sites: dict[str, set[str]] = {}
    for text in lines:
        if match := SITE.search(text):
            sites.setdefault(match.group(1), set()).add(match.group(2))
    return test_reds.failed_names(lines), sites


def previous_run(get: Get, repo: str, run: dict) -> dict | None:
    """The newest finished (success or failure) push run of the workflow on the branch before RUN (listed from
    RUN's creation back, so a red found hours later still reads the run before it)."""
    data = json.loads(get(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&event=push"
                          f"&status=completed&per_page=60&created=%3C{run['created_at']}"))
    older = [r for r in data.get("workflow_runs", [])
             if r["id"] != run["id"] and r.get("conclusion") in ("success", "failure")
             and r["created_at"] < run["created_at"]]
    return max(older, key=lambda r: r["created_at"], default=None)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def landings(base: str, head: str, run_git: Callable[..., str] = git) -> list[Landing]:
    """The squash landings base..head on the first-parent line that changed the kit's inputs."""
    out: list[Landing] = []
    for line in run_git("log", "--first-parent", "--format=%H%x09%s", f"{base}..{head}").splitlines():
        sha, _, subject = line.partition("\t")
        match = LANDING.search(subject)
        if not match:
            continue
        files = [f for f in run_git("diff-tree", "--no-commit-id", "--name-only", "-r", sha).splitlines() if f]
        if any(f.startswith(KIT_PATHS) for f in files):
            out.append(Landing(int(match.group(1)), sha, subject, files))
    return out


def likely(landing: Landing, sites: set[str]) -> bool:
    return any(os.path.basename(f) in sites for f in landing.files)


def comment(run_url: str, run_id: int, new: list[str], base: str, head: str, landing: Landing,
            others: list[Landing], sites: set[str]) -> str:
    why = ("it changed " + ", ".join(sorted(os.path.basename(f) for f in landing.files
                                            if os.path.basename(f) in sites))
           if likely(landing, sites) else "it changed the kit's inputs in that range")
    tests = "\n".join(f"- `{name}`" for name in new[:20]) + (f"\n- and {len(new) - 20} more" if len(new) > 20 else "")
    peers = ", ".join(f"#{o.number}" for o in others if o.number != landing.number) or "none"
    return (f"{MARKER.format(run=run_id)}\n"
            f"feat-cmux-next's kit tests went red after this landed ({run_url}), on tests that passed or did not "
            f"run at the previous finished base run ({base[:10]}..{head[:10]}). This landing is named because {why}.\n\n"
            f"New reds:\n{tests}\n\n"
            f"Other landings in the range that changed the kit: {peers}. Fix forward on feat-cmux-next if it is "
            f"yours; every later kit PR shows these reds until then. (scripts/ci/ios_kit_base_red.py)")


def main(argv: list[str] | None = None, get: Get = gh_get, run_git: Callable[..., str] = git,
         post: Callable[[int, str], None] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)
    run = json.loads(get(f"repos/{args.repo}/actions/runs/{args.run}"))
    now, where = failures(kit_job_log(get, args.repo, args.run))
    if not now:
        print("no failing test named in this run's kit job; nothing to tell")
        return 0
    prev = previous_run(get, args.repo, run)
    if prev is None:
        print("no earlier finished base run to compare; nothing to tell")
        return 0
    before = failures(kit_job_log(get, args.repo, prev["id"]))[0] if prev["conclusion"] == "failure" else set()
    new = sorted(now - before)
    # Only the new reds' files point at a landing: an old red's file says nothing about this range.
    sites = {site for name in new for site in where.get(name, ())}
    if not new:
        print(f"red, but every failing test already failed at {prev['head_sha'][:10]} (run {prev['id']}); nothing new")
        return 0
    found = landings(prev["head_sha"], run["head_sha"], run_git)
    found.sort(key=lambda l: not likely(l, sites))
    print(f"new reds since {prev['head_sha'][:10]}: {', '.join(new)}")
    for landing in found:
        body = comment(run["html_url"], args.run, new, prev["head_sha"], run["head_sha"], landing, found, sites)
        tag = "likely" if likely(landing, sites) else "in range"
        print(f"#{landing.number} ({tag}): {landing.subject}")
        if args.dry_run:
            continue
        existing = get(f"repos/{args.repo}/issues/{landing.number}/comments?per_page=100")
        if any(MARKER.format(run=args.run) in (c.get("body") or "") for c in json.loads(existing or "[]")):
            continue
        (post or gh_comment(args.repo))(landing.number, body)
    return 0


def gh_comment(repo: str) -> Callable[[int, str], None]:
    def send(number: int, body: str) -> None:
        subprocess.run(["gh", "api", f"repos/{repo}/issues/{number}/comments", "-f", f"body={body}"],
                       check=True, capture_output=True, text=True)
    return send


if __name__ == "__main__":
    sys.exit(main())
