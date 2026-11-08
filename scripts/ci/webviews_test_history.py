#!/usr/bin/env python3
"""The webview tests' recent verdicts on feat-cmux-next pushes, and which tests flip on them.

    webviews_test_history.py inputs [--root DIR]
        print the key of HEAD's webview test inputs: the files and folders web_subareas.py routes the
        webview suite on (its REACT_PREFIXES, REACT_EXACT and ALL_SUBAREA_INPUTS), as git has them
    webviews_test_history.py record HISTORY OUT --sha SHA --time EPOCH --inputs KEY RESULTS.json...
        append one push run (its shards' webviews_test_results.py maps) to HISTORY (missing or
        unreadable: an empty one) and write the newest KEEP runs to OUT
    webviews_test_history.py flaky HISTORY [--names NAMES.json]
        print, one a line, the tests and files that passed and failed on the same inputs (two base
        pushes with the same inputs key gave them different verdicts), or that went red, green and red
        again on any inputs, or failed there once while their file's reds came back. With NAMES (a
        {name: passed} map, a head's results), only names among its reds.
    webviews_test_history.py fetch OUT --repo OWNER/REPO --branch BRANCH
        write to OUT the newest history a push on BRANCH uploaded (the ARTIFACT artifact), or an empty
        one when there is none or it cannot be read; GITHUB_TOKEN reads it (actions: read)

Why: a pull request fails only on the webview tests its base replay (react-apps-base-check)
passes, and that replay runs each red file once, alone, on the merge parent. A test that fails
now and then on the base passed there by chance and was charged to the change:
agent-pane-suggested-tasks' sent image (base runs 41075124126 red and 41075808917 green on the same
tree) was a new red on 9 of 40 sampled red pull request runs (2026-10-30). guards_new_reds.py
--flaky keeps such a test a warning.

A flake is a test whose verdict changes while its inputs do not. Most feat-cmux-next pushes change
no webview input (Swift, Rust, docs), so the same inputs run again and again. A verdict that only
follows the code (a break, then its revert: green, red, green) changes its inputs each time, so it
is never called a flake. A red that comes back after a green is one whatever the inputs: a break and
its fix make one red stretch, and a busy day changes the inputs on nearly every push, so a flake may
never run twice on the same ones. So is a red of a test that failed on the base itself while its
file's reds came back after a green: one flake may fail a different test of its file each run. The inputs are the paths the router (web_subareas.py) runs the webview
suite for; a test that reads a file outside them is a router gap, which also skips it on pull requests.
Each run stores only what it needs: its inputs key, the files that ran and the names that were red.
A test is green on a run whose file ran and named neither it nor the file as red; a file red
without naming tests (a timeout, a crash) says nothing about that file's tests on that run.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile

KEEP = 120  # push runs kept: several hours of feat-cmux-next pushes, a few MB
# The history itself, uploaded by every push's webviews-test-history job and read by the next push and by each pull
# request's replay. An artifact, not an Actions cache: on 2026-11-08 no push restored the cache the one before it saved
# (runs 42487089305, 42489479972, 42494348690: "Cache not found", "1 push runs"), because the saves went to the Linux
# pool's own cache store, which the next push's restore never read. The history held one run, so nothing ever flipped
# and send-stream-motion was charged to pull requests that touch no agent-session code (#37286, #36911, #38250).
ARTIFACT = "webviews-test-history"
ARTIFACT_FILE = "history.json"
LIST_PAGE = 30  # artifacts listed, newest first: pushes' uploads are a few an hour, kept 3 days
FETCH_TIMEOUT_S = 30
MAX_BYTES = 16 * 1024 * 1024  # KEEP runs are a few MB at most


def load(path: str | Path) -> list[dict]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, list):
        return []
    return [r for r in runs if isinstance(r, dict) and isinstance(r.get("sha"), str)
            and isinstance(r.get("time"), (int, float)) and isinstance(r.get("files"), list)
            and isinstance(r.get("red"), list) and isinstance(r.get("inputs"), str) and r["inputs"]]


def inputs(root: str | Path = ".") -> str:
    """HEAD's webview test inputs key: the git ids of every path web_subareas.py routes the suite on."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import web_subareas  # noqa: PLC0415
    paths = sorted({p.rstrip("/") for p in (*web_subareas.REACT_PREFIXES, *web_subareas.REACT_EXACT,
                                            *web_subareas.ALL_SUBAREA_INPUTS)})
    listed = subprocess.run(["git", "-C", str(root), "ls-tree", "HEAD", "--", *paths],
                            check=True, capture_output=True, text=True).stdout
    return hashlib.sha256(listed.encode()).hexdigest()[:20]


def results(paths: list[str]) -> dict[str, bool]:
    merged: dict[str, bool] = {}
    for path in paths:
        try:
            found = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(found, dict):
            for name, ok in found.items():
                merged[str(name)] = merged.get(str(name), True) and bool(ok)
    return merged


def record(history: list[dict], sha: str, time: float, found: dict[str, bool], key: str,
           attempt: int = 1, keep: int = KEEP) -> list[dict]:
    """The history with this run in it (one per sha and attempt: a re-run of the same push is more evidence), oldest
    first."""
    if not found:
        return history[-keep:]
    run = {
        "sha": sha,
        "attempt": attempt,
        "time": time,
        "inputs": key,
        "files": sorted({name.split(" > ", 1)[0] for name in found}),
        "red": sorted(name for name, ok in found.items() if not ok),
    }
    runs = [r for r in history if (r["sha"], r.get("attempt", 1)) != (sha, attempt)] + [run]
    runs.sort(key=lambda r: (r["time"], r["sha"], r.get("attempt", 1)))
    return runs[-keep:]


def verdicts(runs: list[dict], name: str) -> list[tuple[str, bool]]:
    """NAME's (inputs key, verdict) on each run that says one, oldest first."""
    file = name.split(" > ", 1)[0]
    out = []
    for run in runs:
        if file not in run["files"]:
            continue
        red = set(run["red"])
        if name in red:
            out.append((run["inputs"], False))
        elif name != file and file in red:
            continue  # the file failed without reaching or naming its tests
        else:
            out.append((run["inputs"], True))
    return out


def flips(found: list[tuple[str, bool]]) -> bool:
    """Whether some inputs gave both verdicts, or the verdicts went red, green and red again."""
    seen: dict[str, set[bool]] = {}
    for key, ok in found:
        seen.setdefault(key, set()).add(ok)
    return any(len(both) == 2 for both in seen.values()) or returns(found)


def returns(found: list[tuple[str, bool]]) -> bool:
    """Whether a red came back after a green, whatever the inputs: two separate red stretches, oldest first.

    A break and its fix make one red stretch (green, red, green), however the inputs change. A test that fails now and
    then makes several, and on a day when most pushes change a webview input no two of its runs share an inputs key."""
    stretches, last = 0, True
    for _, ok in found:
        if not ok and last:
            stretches += 1
        last = ok
    return stretches >= 2


def file_verdicts(runs: list[dict], file: str) -> list[tuple[str, bool]]:
    """FILE's (inputs key, verdict) on each run that named its tests, oldest first: red when it named any of them red."""
    out = []
    for run in runs:
        if file not in run["files"] or file in run["red"]:
            continue  # not run, or failed without naming its tests
        out.append((run["inputs"], not any(name.startswith(f"{file} > ") for name in run["red"])))
    return out


def flaky_name(runs: list[dict], name: str) -> bool:
    """Whether NAME flips on the base (flips), or failed there itself while its file's reds came back after a green.

    The second: one flake can fail a different test of its file on each run. send-stream-motion's send, steer and tools
    share one assertion; on 2026-11-08 each failed now and then on feat-cmux-next, each replay's base run failed a
    sibling and passed the one its head failed, and send (red on one base push) was charged to pull requests that touch
    no agent-session code (#37286, #36911, #38250). A test that never failed on the base stays the change's."""
    found = verdicts(runs, name)
    if flips(found):
        return True
    file = name.split(" > ", 1)[0]
    return name != file and any(not ok for _, ok in found) and returns(file_verdicts(runs, file))


def flaky(runs: list[dict], names: list[str] | None = None) -> list[str]:
    if names is None:
        names = sorted({name for run in runs for name in run["red"]})
    return sorted(name for name in names if flaky_name(runs, name))


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):  # the download's storage URL is fetched without the token
        return None


def _get(url: str, token: str | None) -> tuple[int, dict, bytes]:
    """One GET: (status, headers, body). A redirect is returned, not followed."""
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "cmux-webviews-test-history"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(urllib.request.Request(url, headers=headers), timeout=FETCH_TIMEOUT_S) as reply:
            return reply.status, dict(reply.headers), reply.read(MAX_BYTES + 1)
    except urllib.error.HTTPError as error:
        return error.code, dict(error.headers or {}), b""


def newest(listing: object, branch: str) -> dict | None:
    """The newest unexpired ARTIFACT that a run of this repository on BRANCH uploaded. A fork's run is never one: its
    branch may share the name, and a history it wrote would excuse reds."""
    best = None
    items = listing.get("artifacts") if isinstance(listing, dict) else None
    for item in items if isinstance(items, list) else []:
        if not isinstance(item, dict):
            continue
        run = item.get("workflow_run") if isinstance(item.get("workflow_run"), dict) else {}
        if (item.get("name") != ARTIFACT or item.get("expired") or run.get("head_branch") != branch
                or not run.get("repository_id") or run.get("head_repository_id") != run.get("repository_id")):
            continue
        if best is None or str(item.get("created_at") or "") > str(best.get("created_at") or ""):
            best = item
    return best


def fetch(repo: str, branch: str, token: str | None, get=_get) -> tuple[list[dict], str, bool]:
    """(the newest history a push on BRANCH uploaded, what was read, whether it was read): two requests, the list and
    the download. Any failure is an empty history that says why and was not read; a missing history only means no
    flakes, and counts as read."""
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    query = urllib.parse.urlencode({"name": ARTIFACT, "per_page": LIST_PAGE})
    try:
        status, _, body = get(f"{api}/repos/{repo}/actions/artifacts?{query}", token)
        if status != 200:
            return [], f"listing the {ARTIFACT} artifacts answered {status}", False
        found = newest(json.loads(body), branch)
        if found is None:
            return [], f"no {ARTIFACT} artifact from a push on {branch}", True
        status, headers, body = get(str(found.get("archive_download_url") or ""), token)
        if status in (301, 302, 303, 307, 308):
            location = headers.get("Location") or headers.get("location") or ""
            status, _, body = get(location, None) if location.startswith("https://") else (status, {}, b"")
        if status != 200:
            return [], f"downloading {ARTIFACT} {found.get('id')} answered {status}", False
        if len(body) > MAX_BYTES:
            return [], f"{ARTIFACT} {found.get('id')} is over {MAX_BYTES} bytes", False
        with zipfile.ZipFile(io.BytesIO(body)) as archive:
            info = archive.getinfo(ARTIFACT_FILE)
            if info.file_size > MAX_BYTES:
                return [], f"{ARTIFACT} {found.get('id')}'s {ARTIFACT_FILE} is over {MAX_BYTES} bytes", False
            data = json.loads(archive.read(info))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        return [], f"reading the {ARTIFACT} artifact failed: {error}", False
    runs = data.get("runs") if isinstance(data, dict) else None
    if not isinstance(runs, list):
        return [], f"{ARTIFACT} {found.get('id')} holds no runs", False
    run = found.get("workflow_run") or {}
    return runs, f"{ARTIFACT} {found.get('id')} from run {run.get('id')} ({str(run.get('head_sha') or '')[:12]})", True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    keyed = sub.add_parser("inputs")
    keyed.add_argument("--root", default=".")
    rec = sub.add_parser("record")
    rec.add_argument("history")
    rec.add_argument("out")
    rec.add_argument("--sha", required=True)
    rec.add_argument("--time", type=float, required=True)
    rec.add_argument("--inputs", required=True)
    rec.add_argument("--attempt", type=int, default=1)
    rec.add_argument("results", nargs="+")
    fl = sub.add_parser("flaky")
    fl.add_argument("history")
    fl.add_argument("--names")
    fe = sub.add_parser("fetch")
    fe.add_argument("out")
    fe.add_argument("--repo", required=True)
    fe.add_argument("--branch", required=True)
    fe.add_argument("--need-read", action="store_true",
                    help="exit 1 when the history could not be read (a missing one is fine): a push then saves none")
    args = parser.parse_args(argv)
    if args.command == "fetch":
        found, said, read = fetch(args.repo, args.branch, os.environ.get("GITHUB_TOKEN"))
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps({"runs": found}, separators=(",", ":")) + "\n", encoding="utf-8")
        print(f"webview test history: {len(found)} push runs ({said})")
        return 1 if args.need_read and not read else 0
    if args.command == "inputs":
        print(inputs(args.root))
        return 0
    if args.command == "record":
        runs = record(load(args.history), args.sha, args.time, results(args.results), args.inputs, args.attempt)
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(json.dumps({"runs": runs}, separators=(",", ":")) + "\n", encoding="utf-8")
        print(f"webview test history: {len(runs)} push runs")
        return 0
    names = None
    if args.names:
        names = sorted(name for name, ok in results([args.names]).items() if not ok)
    for name in flaky(load(args.history), names):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
