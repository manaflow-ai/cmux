#!/usr/bin/env python3
"""Two publication checks for the NEXT nightly, run just before anything is uploaded or a feed changes.

  nightly_publish_guard.py webview-verdict --source own|recovered --result R --checked-sha S --build-sha B
                                           [--run-id N] [--repo OWNER/REPO]
      Whether the build's tree passed the webview checks (check-nightly-webviews in nightly.yml: the pieces of
      webviews' `bun run check` that gate feat-cmux-next, scripts/ci/fast_gate_webviews_checks.py, which include
      the type check). An own build needs this run's job green on the exact build commit; a recovered build needs
      the same job green in the run that built it. Prints one line; exits 0 (green) or 3 (refuse: publish nothing).

  nightly_publish_guard.py known-bad --repo OWNER/REPO [--sha SHA] [--build N] [--github-output PATH]
                                     [--list-file PATH | --list-ref REF]
      Whether the build's commit holds a listed bad commit without its fix. The list
      (.github/nightly-known-bad.json, {"pairs": [{"bad": SHA, "fix": SHA, "note": ...}]}) is read live from
      feat-cmux-next when the job runs, not when the run was dispatched, so a pair landed while a run builds
      still holds that run's publication. Writes skip=true|false and reason= to --github-output and a line to
      the step summary. Always exits 0: an unreadable list, commit or ancestry publishes with a warning, so a
      GitHub blip never stalls the feed.

2026-11-02: #32056 (fca2e5f4) landed a temporal-dead-zone read in SessionInfo.tsx (TS2448, which `bun run check`
reports), every agent pane showed "could not be drawn", and the NEXT nightly published 50298238a before the fix
#32160 (c8b7f59e) landed; two runs already building that tree could not be stopped.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_pages  # noqa: E402

SHA = re.compile(r"^[0-9a-f]{40}$")
# check-nightly-webviews's name: in nightly.yml and in the jobs a recovered build's run lists.
WEBVIEW_JOB = "nightly webview checks"
LIST_PATH = ".github/nightly-known-bad.json"
LIST_REF = "feat-cmux-next"
GIT_SECONDS = 180


# ---------------------------------------------------------------- webview verdict

def webview_verdict(source: str, result: str, checked_sha: str, build_sha: str,
                    recovered_jobs: Optional[Callable[[], list]] = None) -> tuple[bool, str]:
    """(ok, line). recovered_jobs lists the jobs of the run that built a recovered build (latest attempt)."""
    if source == "own":
        if result != "success":
            return False, f"the webview checks ({WEBVIEW_JOB}) are {result or 'missing'} for {build_sha}"
        if checked_sha != build_sha:
            return False, f"the webview checks ran on {checked_sha or 'nothing'}, not the build commit {build_sha}"
        return True, f"webview checks green on {build_sha}"
    if source == "recovered":
        try:
            jobs = recovered_jobs() if recovered_jobs else []
        except Exception as error:  # noqa: BLE001  (an unreadable run refuses, never publishes unchecked)
            return False, f"the recovered build's webview checks could not be read ({error})"
        named = [job for job in jobs if job.get("name") == WEBVIEW_JOB]
        if not any(job.get("conclusion") == "success" for job in named):
            seen = ",".join(sorted({str(job.get("conclusion")) for job in named})) or "missing"
            return False, f"the recovered build's run has no green {WEBVIEW_JOB} job ({seen}) for {build_sha}"
        return True, f"webview checks green in the recovered build's run for {build_sha}"
    return False, f"unknown build source '{source}'"


def run_jobs(repo: str, run_id: str) -> list:
    if not re.fullmatch(r"[0-9]+", run_id or ""):
        raise ValueError(f"no run id ('{run_id}')")
    # One bounded page per call (scripts/ci/gh_pages.py): the gh quota wrapper refuses gh api's paginating flag.
    def fetch(url: str) -> dict:
        out = subprocess.run(["gh", "api", url], capture_output=True, text=True, timeout=120)
        if out.returncode != 0:
            raise RuntimeError(out.stderr.strip().replace("\n", " ") or f"gh exited {out.returncode}")
        return {"jobs": json.loads(out.stdout)["jobs"]}
    try:
        jobs = gh_pages.items(fetch, f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    except gh_pages.PageCapError as error:
        raise RuntimeError(str(error)) from None
    return [{"name": job.get("name"), "conclusion": job.get("conclusion")} for job in jobs]


# ---------------------------------------------------------------- known-bad list

def parse_pairs(text: str) -> list[dict]:
    """The list's pairs. Raises ValueError on anything malformed (the caller publishes with a warning)."""
    data = json.loads(text)
    pairs = data.get("pairs") if isinstance(data, dict) else None
    if not isinstance(pairs, list):
        raise ValueError("no 'pairs' list")
    out = []
    for pair in pairs:
        bad, fix = (pair or {}).get("bad", ""), (pair or {}).get("fix", "")
        if not SHA.match(bad) or not SHA.match(fix):
            raise ValueError(f"pair {pair!r} needs full 40-character 'bad' and 'fix' SHAs")
        out.append({"bad": bad, "fix": fix, "note": str(pair.get("note", ""))})
    return out


def decide(pairs: list[dict], contains: Callable[[str], Optional[bool]], sha: str) -> tuple[bool, str, list[str]]:
    """(skip, reason, warnings). contains(commit) says whether commit is in sha's history (None: unknown)."""
    warnings = []
    for pair in pairs:
        has_bad = contains(pair["bad"])
        if has_bad is None:
            warnings.append(f"could not tell whether {sha} contains {pair['bad']}; not held for it")
            continue
        if not has_bad:
            continue
        has_fix = contains(pair["fix"])
        if has_fix is None:
            warnings.append(f"{sha} contains {pair['bad']}, and whether it has the fix {pair['fix']} is unknown; not held for it")
            continue
        if not has_fix:
            note = f" ({pair['note']})" if pair["note"] else ""
            return True, f"{sha} contains known-bad {pair['bad'][:12]} without its fix {pair['fix'][:12]}{note}", warnings
    return False, f"{sha} holds no listed bad commit without its fix", warnings


def read_list(repo: str, ref: str, path: str) -> str:
    out = subprocess.run(["gh", "api", "-H", "Accept: application/vnd.github.raw",
                          f"repos/{repo}/contents/{path}?ref={ref}"], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().replace("\n", " ") or f"gh exited {out.returncode}")
    return out.stdout


def build_commit(repo: str, build: str) -> str:
    """A build's commit: the head of its signed release notes, else the head of the nightly-next run that made it
    (build = run id + two-digit attempt), as nightly-next-legacy-requirement.sh resolves it."""
    base = os.environ.get("NOTES_BASE", "")
    if base:
        try:
            with urllib.request.urlopen(f"{base}/{build}.json", timeout=30) as response:  # noqa: S310  (our feed)
                notes = json.loads(response.read())
            if str(notes.get("build")) == build and SHA.match(str(notes.get("head", ""))):
                return notes["head"]
        except Exception:  # noqa: BLE001  (falls back to the run)
            pass
    out = subprocess.run(["gh", "api", f"repos/{repo}/actions/runs/{build[:-2]}", "--jq",
                          '"\\(.head_sha) \\(.head_branch) \\(.path)"'], capture_output=True, text=True, timeout=60)
    parts = out.stdout.split() if out.returncode == 0 else []
    if len(parts) == 3 and SHA.match(parts[0]) and parts[1] == "nightly-next" and parts[2] == ".github/workflows/nightly.yml":
        return parts[0]
    raise RuntimeError(f"build {build}'s commit is unreadable")


class Ancestry:
    """Whether a commit is in sha's history, from the commit graph alone (a treeless fetch, no API call), else
    GitHub's compare API. None when neither can tell."""

    def __init__(self, repo: str, sha: str, commits: list[str]):
        self.repo, self.sha, self.dir = repo, sha, None
        url = os.environ.get("NIGHTLY_KNOWN_BAD_GIT_URL", f"https://github.com/{repo}.git")
        if not url:
            return
        holder = tempfile.mkdtemp(prefix="nightly-known-bad-")
        try:
            subprocess.run(["git", "init", "-q", "--bare", holder], check=True, capture_output=True, timeout=30)
            subprocess.run(["git", "-C", holder, "-c", "protocol.version=2", "fetch", "-q", "--no-tags", "--filter=tree:0",
                            url, sha, *sorted(set(commits))], check=True, capture_output=True, timeout=GIT_SECONDS)
            self.dir = holder
        except (subprocess.SubprocessError, OSError):
            shutil.rmtree(holder, ignore_errors=True)

    def __call__(self, commit: str) -> Optional[bool]:
        if commit == self.sha:
            return True
        if self.dir:
            rc = subprocess.run(["git", "-C", self.dir, "merge-base", "--is-ancestor", commit, self.sha],
                                capture_output=True, timeout=60).returncode
            if rc in (0, 1):
                return rc == 0
        out = subprocess.run(["gh", "api", f"repos/{self.repo}/compare/{commit}...{self.sha}", "--jq", ".status"],
                             capture_output=True, text=True, timeout=120)
        status = out.stdout.strip() if out.returncode == 0 else ""
        return {"ahead": True, "identical": True, "behind": False, "diverged": False}.get(status)

    def close(self) -> None:
        if self.dir:
            shutil.rmtree(self.dir, ignore_errors=True)


def known_bad(args: argparse.Namespace) -> tuple[bool, str, list[str]]:
    try:
        text = open(args.list_file, encoding="utf-8").read() if args.list_file else read_list(args.repo, args.list_ref, LIST_PATH)
        pairs = parse_pairs(text)
    except Exception as error:  # noqa: BLE001
        return False, "the known-bad list is unreadable; published unchecked", [f"known-bad list unreadable: {error}"]
    if not pairs:
        return False, "the known-bad list is empty", []
    sha = args.sha
    if not SHA.match(sha or ""):
        try:
            sha = build_commit(args.repo, args.build or "")
        except Exception as error:  # noqa: BLE001
            return False, "the build's commit is unreadable; published unchecked", [str(error)]
    ancestry = Ancestry(args.repo, sha, [c for pair in pairs for c in (pair["bad"], pair["fix"])])
    try:
        return decide(pairs, ancestry, sha)
    finally:
        ancestry.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    web = sub.add_parser("webview-verdict")
    web.add_argument("--source", required=True)
    web.add_argument("--result", default="")
    web.add_argument("--checked-sha", default="")
    web.add_argument("--build-sha", required=True)
    web.add_argument("--run-id", default="")
    web.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    bad = sub.add_parser("known-bad")
    bad.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    bad.add_argument("--sha", default="")
    bad.add_argument("--build", default="")
    bad.add_argument("--list-file", default=os.environ.get("NIGHTLY_KNOWN_BAD_LIST_FILE", ""))
    bad.add_argument("--list-ref", default=LIST_REF)
    bad.add_argument("--github-output", default="")
    args = parser.parse_args(argv)

    if args.command == "webview-verdict":
        ok, line = webview_verdict(args.source, args.result, args.checked_sha, args.build_sha,
                                   lambda: run_jobs(args.repo, args.run_id))
        print(line)
        return 0 if ok else 3

    skip, reason, warnings = known_bad(args)
    for warning in warnings:
        print(f"::warning title=Nightly known-bad check::{warning}")
    print(f"known-bad: {'skip' if skip else 'publish'}: {reason}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"skip={'true' if skip else 'false'}\nreason={reason}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and (skip or warnings):
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"- {'held, not published' if skip else 'known-bad check'}: {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
