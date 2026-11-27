#!/usr/bin/env python3
"""Three publication checks for the NEXT nightly, run just before anything is uploaded or a feed changes.

  nightly_publish_guard.py webview-verdict --source own|recovered|run --result R --checked-sha S --build-sha B
                                           [--run-id N] [--repo OWNER/REPO] [--wait-seconds N]
      Whether the build's tree passed the webview checks (check-nightly-webviews in nightly.yml: the pieces of
      webviews' `bun run check` that gate feat-cmux-next, scripts/ci/fast_gate_webviews_checks.py, which include
      the type check). An own build needs this run's job green on the exact build commit; a recovered build needs
      the same job green in the run that built it; run reads it as shelf-verdict does. Prints one line; exits 0 (green) or 3 (refuse: publish nothing).

  nightly_publish_guard.py shelf-verdict --source own|recovered|run --result R --checked-sha S --build-sha B
                                         [--run-id N] [--repo OWNER/REPO] [--wait-seconds N]
      Whether the build's App Store shelf works: every Discover listing installs and shows something
      (check-nightly-app-store-shelf in nightly.yml runs scripts/ci/app-store-shelf-check.sh, the App Store shelf
      workflow's tests, on the exact build commit). own and recovered read it as webview-verdict does; run (the
      one-job publisher, which does not wait on the job) reads the job in this run, --run-id, waiting up to
      --wait-seconds for it to finish. Prints one line; exits 0 (green) or 3 (refuse: publish nothing).

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

The shelf check: Leo, 2026-11-16: "if i click install it means it works". The App Store shelf workflow ran only
on pull requests and pushes that touch the shelf's paths, so nothing stopped a nightly from publishing a tree
whose shelf was red (feat-cmux-next's shelf runs failed 2026-11-23 19:39-20:02Z).
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
import time
import urllib.request
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_pages  # noqa: E402

SHA = re.compile(r"^[0-9a-f]{40}$")
# check-nightly-webviews's name: in nightly.yml and in the jobs a recovered build's run lists.
WEBVIEW_JOB = "nightly webview checks"
# check-nightly-app-store-shelf's name, read the same ways.
SHELF_JOB = "nightly App Store shelf"
LIST_PATH = ".github/nightly-known-bad.json"
LIST_REF = "feat-cmux-next"
GIT_SECONDS = 180


# ---------------------------------------------------------------- webview verdict

def job_verdict(job: str, what: str, source: str, result: str, checked_sha: str, build_sha: str,
                run_jobs_fn: Optional[Callable[[], list]] = None, wait_seconds: int = 0,
                sleep: Callable[[float], None] = time.sleep,
                clock: Callable[[], float] = time.monotonic) -> tuple[bool, str]:
    """(ok, line) for the check job named `job`. run_jobs_fn lists the jobs of the run to read (latest attempt):
    the run that built a recovered build, or (source run) this run, polled until the job completes."""
    if source == "own":
        if result != "success":
            return False, f"the {what} ({job}) are {result or 'missing'} for {build_sha}"
        if checked_sha != build_sha:
            return False, f"the {what} ran on {checked_sha or 'nothing'}, not the build commit {build_sha}"
        return True, f"{what} green on {build_sha}"
    if source in ("recovered", "run"):
        whose = "the recovered build's run" if source == "recovered" else "this run"
        deadline = clock() + (wait_seconds if source == "run" else 0)
        while True:
            try:
                jobs = run_jobs_fn() if run_jobs_fn else []
            except Exception as error:  # noqa: BLE001  (an unreadable run refuses, never publishes unchecked)
                return False, f"{whose}'s {what} could not be read ({error})"
            named = [entry for entry in jobs if entry.get("name") == job]
            if any(entry.get("conclusion") == "success" for entry in named):
                return True, f"{what} green in {whose} for {build_sha}"
            pending = named and all(entry.get("status", "completed") != "completed" for entry in named)
            if not pending or clock() >= deadline:
                seen = ",".join(sorted({str(entry.get("conclusion")) for entry in named})) or "missing"
                if pending:
                    seen = "still running"
                return False, f"{whose} has no green {job} job ({seen}) for {build_sha}"
            sleep(30)
    return False, f"unknown build source '{source}'"


def webview_verdict(source: str, result: str, checked_sha: str, build_sha: str,
                    recovered_jobs: Optional[Callable[[], list]] = None, wait_seconds: int = 0,
                    sleep: Callable[[float], None] = time.sleep,
                    clock: Callable[[], float] = time.monotonic) -> tuple[bool, str]:
    """(ok, line). recovered_jobs lists the jobs of the run that built a recovered build (latest attempt), or this
    run's jobs for source run (NIGHTLY_COMPONENT_GATES=block, where publish-nightly no longer needs the check)."""
    if source not in ("own", "recovered", "run"):
        return False, f"unknown build source '{source}'"
    return job_verdict(WEBVIEW_JOB, "webview checks", source, result, checked_sha, build_sha, recovered_jobs,
                       wait_seconds, sleep, clock)


def shelf_verdict(source: str, result: str, checked_sha: str, build_sha: str,
                  run_jobs_fn: Optional[Callable[[], list]] = None, wait_seconds: int = 0,
                  sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic) -> tuple[bool, str]:
    """(ok, line) for the App Store shelf check (check-nightly-app-store-shelf)."""
    return job_verdict(SHELF_JOB, "App Store shelf checks", source, result, checked_sha, build_sha,
                       run_jobs_fn, wait_seconds, sleep, clock)


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
    return [{"name": job.get("name"), "status": job.get("status"), "conclusion": job.get("conclusion")}
            for job in jobs]


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
    web.add_argument("--wait-seconds", type=int, default=0)
    shelf = sub.add_parser("shelf-verdict")
    shelf.add_argument("--source", required=True)
    shelf.add_argument("--result", default="")
    shelf.add_argument("--checked-sha", default="")
    shelf.add_argument("--build-sha", required=True)
    shelf.add_argument("--run-id", default="")
    shelf.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    shelf.add_argument("--wait-seconds", type=int, default=0)
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
                                   lambda: run_jobs(args.repo, args.run_id), args.wait_seconds)
        print(line)
        return 0 if ok else 3
    if args.command == "shelf-verdict":
        ok, line = shelf_verdict(args.source, args.result, args.checked_sha, args.build_sha,
                                 lambda: run_jobs(args.repo, args.run_id), args.wait_seconds)
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
