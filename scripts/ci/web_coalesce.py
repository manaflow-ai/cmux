#!/usr/bin/env python3
"""Coalesce cmux-next-web.yml's feat-cmux-next push runs, and bisect a coalesced run's new webview reds.

    web_coalesce.py wait --last LAST.json --sha SHA [--before SHA] [--hold-minutes 15] [--off] --out OUT.json
        the coalesce job: sleep until HOLD minutes after the last push that ran the web checks, then name this push
        the newest covered one (OUT) and print `base=<the last covered sha>` to $GITHUB_OUTPUT
    web_coalesce.py bisect --base SHA --head SHA --results RESULTS.json... [--history HISTORY.json]
                           --probe PROBE.sh --report REPORT.json
        the web bisect job: for each webview test red at HEAD and not at BASE (the run before it), the first commit
        of BASE..HEAD it fails at, with the fewest probe runs

Why (2026-11-02): cmux-next-web.yml ran on every feat-cmux-next push, 919 runs, each 8 x 16 vCPU react-apps-check
shards plus react-doctor: about $4.1k of Blacksmith a day (cmuxterm-hq build-fleet/data/raw/2026/11/02). Most of
those runs tested a commit a newer push already contained. So the web checks now run at most once every HOLD
minutes, on the newest push that waited; each run routes from the last run's commit (push_base), so it checks
everything since. Three rules from the decision (claude-sr2-coord, 2026-11-03):

1. A run starts at least every HOLD (15) minutes while pushes land, so a base red is at most about 15 minutes of
   landings wide (the decision's bound is 30).
2. When such a run goes red, `bisect` re-runs only the failing test files, only on the commits the run covered, so
   the first red commit and its pull request are still named (test_reds.py bisect_report reads its lines).
3. Pull requests are untouched: react-apps-base-check and everything else ci.yml runs is the same.

How the waiting works: the coalesce job has its own concurrency group with cancel-in-progress false. One coalesce
job runs (waits) at a time; a newer push's coalesce job replaces a pending one, which never started, so that run
ends cancelled with no job run (readers skip such runs: base_red_excuse.coalesced). Nothing that started is ever
cancelled. The last covered push is kept in the Actions cache (one small entry a run, newest restored by prefix);
with none (evicted, the first run) the push runs at once and routes from its own push base, as before.

Bisect, cheaply: a webview test's verdict changes only with its inputs (webviews_test_history.py inputs: the paths
the router runs the suite on), so only commits that change those inputs can be a test's first red, and most
feat-cmux-next commits change none. Tests red at BASE too (the base's own push verdict, from the flake history),
or that flip on the base by themselves (flaky), are not new and are not bisected. The rest are binary searched
over the commits that changed the inputs, each probe running only the files still unresolved there. One such
commit needs no probe. BASE is probed only when the search reaches it with no recorded verdict.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

HOLD_MINUTES = 15.0
SHA = re.compile(r"[0-9a-f]{40}")
# A coalesced run covers about 15 minutes of landings (9 commits at p50, 26 at most on 2026-11-02); past this many
# the range is not bisected (a force push, a long outage): its reds keep the run's range.
MAX_COMMITS = 120
MAX_PROBES = 6  # probe runs a bisect makes at most; a file still unresolved names its narrowest range
SQUASH_PR = re.compile(r"\(#([1-9][0-9]*)\)\s*$")


# -- wait (the coalesce job)

def read_last(path: str | None) -> dict | None:
    """The last covered push ({"sha", "started"}) from PATH, or None when there is none to trust."""
    if not path:
        return None
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if (not isinstance(data, dict) or not isinstance(data.get("sha"), str) or not SHA.fullmatch(data["sha"])
            or not isinstance(data.get("started"), (int, float)) or isinstance(data.get("started"), bool)):
        return None
    return {"sha": data["sha"], "started": float(data["started"])}


def plan_wait(last: dict | None, sha: str, before: str, now: float, hold_s: float) -> tuple[float, str]:
    """(seconds to wait, the push base to route from). With no last covered push, no wait and the push's own base;
    a last covered push at this very commit (a re-run) is no wait either."""
    fallback = before if SHA.fullmatch(before or "") and before != "0" * 40 else ""
    if last is None or last["sha"] == sha:
        return 0.0, fallback
    return max(0.0, last["started"] + hold_s - now), last["sha"]


def wait(args, sleep=time.sleep, clock=time.time) -> int:
    hold_s = 0.0 if args.off else args.hold_minutes * 60
    last = None if args.off else read_last(args.last)
    seconds, base = plan_wait(last, args.sha, args.before or "", clock(), hold_s)
    if seconds > 0:
        print(f"the last web checks started on {last['sha'][:12]}; waiting {seconds:.0f} s, so they run at most once "
              f"every {args.hold_minutes:g} minutes (a newer push's run replaces this wait only while it is pending)")
        sleep(seconds)
    started = clock()
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps({"sha": args.sha, "started": started}) + "\n", encoding="utf-8")
    print(f"web checks run on {args.sha[:12]}, covering every push since {base[:12] or 'its own push base'}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"base={base}\n")
    return 0


# -- bisect (the web bisect job)

def git(*args: str, cwd: str | None = None) -> str:
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout.strip()


def reds_of(results: dict[str, bool]) -> set[str]:
    return {name for name, ok in results.items() if not ok}


def new_reds(head: dict[str, bool], base_run: dict | None, flaky: set[str]) -> tuple[dict[str, set[str]], dict]:
    """({file: its new red names} for the files red at HEAD and not at BASE, {file: why it is not bisected}). A file
    is new when one of its named red tests is not red at BASE (and does not flip there by itself), or, red with no
    test named (a timeout, a file that did not load), when BASE names no red in it at all."""
    base_red = set(base_run["red"]) if base_run else set()
    by_file: dict[str, set[str]] = {}
    for name in reds_of(head):
        by_file.setdefault(name.split(" > ", 1)[0], set()).add(name)
    out: dict[str, set[str]] = {}
    skipped: dict[str, str] = {}
    for file, names in sorted(by_file.items()):
        tests = {n for n in names if n != file} or {file}
        if file in flaky or tests <= flaky:
            skipped[file] = "flaky"
            continue
        base_file = {n for n in base_red if n == file or n.startswith(file + " > ")}
        new = {n for n in tests - flaky if n not in base_red and (n != file or not base_file)}
        if new:
            out[file] = new
        else:
            skipped[file] = "base"
    return out, skipped


def changing(keys: list[str]) -> list[int]:
    """The positions (1..n) whose inputs key differs from the one before; KEYS[0] is BASE's."""
    return [i for i in range(1, len(keys)) if keys[i] != keys[i - 1]]


def search(files: list[str], points: list[int], base_known_green: bool, probe, max_probes: int = MAX_PROBES):
    """{file: (kind, a, b)} over positions into the commit list (0 is BASE). POINTS are the positions whose inputs
    changed, ascending; the last one's verdict is HEAD's, red. kind "first": the first red is at position a, every
    commit before it green back to the run before (b = a - 1, its first-parent parent). kind "base": red at BASE
    already. kind "unresolved": the first red is somewhere in (a, b], not narrowed further (the probes ran out, a
    probe gave no verdict, or BASE has none). PROBE(position, files) -> {file: True red, False green, None unknown}."""
    order = [0] + points  # indexes: 0 is BASE, the last is red
    lo = {f: 0 for f in files}
    hi = {f: len(order) - 1 for f in files}
    state = {f: "open" for f in files}
    known_base = base_known_green
    probes = 0
    while probes < max_probes:
        wide = [f for f in files if state[f] == "open" and hi[f] - lo[f] > 1]
        if wide:
            pick = max(wide, key=lambda f: (hi[f] - lo[f], f))
            mid = (lo[pick] + hi[pick]) // 2
            batch = [f for f in wide if lo[f] < mid < hi[f]]
            got = probe(order[mid], batch)
            probes += 1
            for f in batch:
                if got.get(f) is True:
                    hi[f] = mid
                elif got.get(f) is False:
                    lo[f] = mid
                else:
                    state[f] = "unknown"
            continue
        at_base = [f for f in files if state[f] == "open" and lo[f] == 0 and not known_base]
        if not at_base:
            break
        got = probe(0, at_base)
        probes += 1
        known_base = True
        for f in at_base:
            if got.get(f) is True:
                state[f] = "base"
            elif got.get(f) is None:
                state[f] = "unknown"
    out = {}
    for f in files:
        if state[f] == "base":
            out[f] = ("base", 0, 0)
        elif state[f] == "open" and hi[f] - lo[f] == 1 and (lo[f] > 0 or known_base):
            out[f] = ("first", order[hi[f]], order[hi[f]] - 1)
        else:
            out[f] = ("unresolved", order[lo[f]], order[hi[f]])
    return out


def pr_of(subject: str) -> str:
    match = SQUASH_PR.search(subject or "")
    return f"#{match.group(1)}" if match else "a direct push"


def report_lines(found: dict, commits: list[str], subjects: dict[str, str], names: dict[str, set[str]],
                 skipped: dict[str, str], base: str) -> list[str]:
    """The lines test_reds.py bisect_report reads, one a file. COMMITS[0] is BASE."""
    lines = []
    for file in sorted(found):
        kind, a, b = found[file]
        tests = "; ".join(sorted(names.get(file) or []))[:400]
        if kind == "base":
            lines.append(f"web bisect: red before the range at {base}: {file}")
        elif kind == "unresolved":
            lines.append(f"web bisect: unresolved between {commits[a]} and {commits[b]}: {file}")
        else:
            first, green = commits[a], commits[b]
            lines.append(f"web bisect: first red at {first} ({pr_of(subjects.get(first, ''))}) after {green}: "
                         f"{file}" + (f" ({tests})" if tests else ""))
    for file in sorted(skipped):
        why = "flaky on the base" if skipped[file] == "flaky" else f"red before the range at {base}"
        lines.append(f"web bisect: {why}: {file}")
    return lines


def bisect(args, run=subprocess.run) -> int:
    import webviews_test_history as history  # noqa: PLC0415

    report: dict = {"base": args.base, "head": args.head, "files": {}, "lines": []}
    Path(args.report).parent.mkdir(parents=True, exist_ok=True)

    def finish(note: str | None = None) -> int:
        if note:
            print(f"web bisect: nothing to bisect ({note})")
            report["note"] = note
        Path(args.report).parent.mkdir(parents=True, exist_ok=True)
        Path(args.report).write_text(json.dumps(report, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        for line in report["lines"]:
            print(line)
        return 0

    if not SHA.fullmatch(args.base or "") or not SHA.fullmatch(args.head or ""):
        return finish("no base for this run")
    head = history.results(args.results)
    runs = history.load(args.history) if args.history else []
    base_runs = [r for r in runs if r["sha"] == args.base]
    base_run = max(base_runs, key=lambda r: r.get("attempt", 1)) if base_runs else None
    flaky = set(history.flaky(runs, sorted(reds_of(head)))) if runs else set()
    names, skipped = new_reds(head, base_run, flaky)
    if not names and not skipped:
        return finish("no webview test is red at the head")
    try:
        git("merge-base", "--is-ancestor", args.base, args.head)
    except subprocess.CalledProcessError:
        return finish(f"{args.base[:12]} is not an ancestor of {args.head[:12]}")
    commits = [args.base] + git("rev-list", "--first-parent", "--reverse", f"{args.base}..{args.head}").split()
    if len(commits) - 1 > MAX_COMMITS:
        return finish(f"{len(commits) - 1} commits in the range, more than {MAX_COMMITS}")
    subjects = dict(line.split(" ", 1) for line in git("log", "--no-walk=unsorted", "--format=%H %s", *commits[1:])
                    .splitlines() if " " in line)
    keys = [history.inputs_at(".", sha) for sha in commits]
    points = changing(keys)
    found: dict = {}
    if names and not points:
        # No commit changed a webview input: the same tree as BASE, so a new red is a flake the history has not seen.
        skipped.update({file: "flaky" for file in names})
        names = {}
    elif names:
        def probe(position: int, files: list[str]) -> dict[str, bool | None]:
            sha = commits[position]
            print(f"web bisect: probing {sha[:12]} ({pr_of(subjects.get(sha, ''))}) for {len(files)} file(s)",
                  flush=True)
            out = Path(args.report).parent / f"probe-{sha[:12]}.json"
            listed = Path(args.report).parent / f"probe-{sha[:12]}.files"
            listed.write_text("\n".join(files) + "\n", encoding="utf-8")
            run(["bash", args.probe, sha, str(listed), str(out)], check=False)
            try:
                got = json.loads(out.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                return {f: None for f in files}
            reds = {name.split(" > ", 1)[0] for name, ok in got.items() if not ok}
            ran = {name.split(" > ", 1)[0] for name in got}
            # A file the commit does not have yet cannot fail there: green.
            return {f: (True if f in reds else False if f in ran or not exists(sha, f) else None) for f in files}

        # BASE's verdict is known for a file only when the run before ran it.
        known = base_run is not None and all(file in base_run["files"] for file in names)
        found = search(sorted(names), points, known, probe, args.max_probes)
    report["files"] = {f: list(v) for f, v in found.items()}
    report["skipped"] = skipped
    report["lines"] = report_lines(found, commits, subjects, names, skipped, args.base)
    return finish()


def exists(sha: str, file: str) -> bool:
    try:
        git("cat-file", "-e", f"{sha}:webviews/{file}")
        return True
    except subprocess.CalledProcessError:
        return False


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    w = sub.add_parser("wait")
    w.add_argument("--last")
    w.add_argument("--sha", required=True)
    w.add_argument("--before", default="")
    w.add_argument("--hold-minutes", type=float, default=HOLD_MINUTES)
    w.add_argument("--off", action="store_true", help="no coalescing: run at once, from the push's own base")
    w.add_argument("--out", required=True)
    b = sub.add_parser("bisect")
    b.add_argument("--base", default="")
    b.add_argument("--head", required=True)
    b.add_argument("--results", nargs="*", default=[])
    b.add_argument("--history")
    b.add_argument("--probe", required=True)
    b.add_argument("--report", required=True)
    b.add_argument("--max-probes", type=int, default=MAX_PROBES)
    args = parser.parse_args(argv)
    return wait(args) if args.command == "wait" else bisect(args)


if __name__ == "__main__":
    sys.exit(main())
