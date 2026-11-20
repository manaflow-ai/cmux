#!/usr/bin/env python3
"""Coalesce cmux-next-web.yml's feat-cmux-next push runs, and bisect a coalesced run's new webview reds.

    web_coalesce.py wait --last LAST.json --sha SHA [--before SHA] [--hold-minutes 30] [--ref REF] [--off]
                         --out OUT.json
        the coalesce job: sleep until HOLD minutes after the last push that ran the web checks, then name this push
        the newest covered one (OUT) and print `base=<the last covered sha>` and `run=true` to $GITHUB_OUTPUT, or,
        when it slept and REF has moved past SHA, yield to the newer push (`run=false`, nothing recorded)
    web_coalesce.py bisect --base SHA --head SHA --results RESULTS.json... [--history HISTORY.json]
                           --probe PROBE.sh --report REPORT.json
        the web bisect job: for each webview test red at HEAD and not at BASE (the run before it), the first commit
        of BASE..HEAD it fails at, with the fewest probe runs

Why (2026-11-02): cmux-next-web.yml ran on every feat-cmux-next push, 919 runs, each 8 x 16 vCPU react-apps-check
shards plus react-doctor: about $4.1k of Blacksmith a day (cmuxterm-hq build-fleet/data/raw/2026/11/02). Most of
those runs tested a commit a newer push already contained. So the web checks now run at most once every HOLD
minutes, on the newest push that waited; each run routes from the last run's commit (push_base), so it checks
everything since. Three rules from the decision (claude-sr2-coord, 2026-11-03):

1. A run starts at least every HOLD (30) minutes while pushes land, so a base red is at most about 30 minutes of
   landings wide, the decision's bound. HOLD was 15 until 2026-11-04: at about 44 landings an hour nearly every
   15-minute window held a webview input change, so a run went every window (about 96 a day, about $448); 30
   halves that (ask-23acd2a449).
2. When such a run goes red, `bisect` re-runs only the failing test files, only on the commits the run covered, so
   the first red commit and its pull request are still named (test_reds.py bisect_report reads its lines).
3. Pull requests are untouched: react-apps-base-check and everything else ci.yml runs is the same.

How the waiting works: the coalesce job has its own concurrency group with cancel-in-progress false. One coalesce
job runs (waits) at a time; a newer push's coalesce job replaces a pending one, which never started, so that run
ends cancelled with no job run (readers skip such runs: base_red_excuse.coalesced). Nothing that started is ever
cancelled. When a job that slept wakes and the branch has moved past its push, it yields (#33872): it records
nothing and outputs run=false, so its run ends with its checks skipped, and the newest push's coalesce job, pending
behind it, starts past the deadline and runs at once from the last covered commit. A job that did not sleep never
yields, so a window always ends in a run however fast pushes land. A yielded run is no verdict either (readers: a run
whose every job bar `coalesce` was cancelled or skipped). The last covered push is kept in the Actions cache (one
small entry a run, newest restored by prefix); with none (evicted, the first run) the push runs at once and runs
every web check (push base EVERYTHING): a push replaced before it may have changed web/ outside its own push range
(#33892).

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

HOLD_MINUTES = 30.0
EVERYTHING = "all"  # the push base that runs every web check (web_subareas.EVERY_SUBAREA)
SHA = re.compile(r"[0-9a-f]{40}")
# A coalesced run covers about 30 minutes of landings (about 22 commits at 44 an hour, about 40 at the busiest hour
# of 2026-11-03); past this many
# the range is not bisected (a force push, a long outage): its reds keep the run's range.
MAX_COMMITS = 120
MAX_PROBES = 6  # probe runs a bisect makes at most; a file still unresolved names its narrowest range
SQUASH_PR = re.compile(r"\(#([1-9][0-9]*)\)\s*$")


# -- wait (the coalesce job)

COVERED_KEPT = 200  # covered pushes the marker remembers with their base, for a re-run: about two days of runs


def read_last(path: str | None) -> dict | None:
    """The last covered push ({"sha", "started", "covered": {sha: the base its run routed from}}) from PATH, or None
    when there is none to trust. An older marker with no "covered" map reads as an empty one."""
    if not path:
        return None
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if (not isinstance(data, dict) or not isinstance(data.get("sha"), str) or not SHA.fullmatch(data["sha"])
            or not isinstance(data.get("started"), (int, float)) or isinstance(data.get("started"), bool)):
        return None
    covered = data.get("covered") if isinstance(data.get("covered"), dict) else {}
    covered = {sha: base for sha, base in covered.items() if isinstance(sha, str) and SHA.fullmatch(sha)
               and isinstance(base, str) and (base in ("", EVERYTHING) or SHA.fullmatch(base))}
    return {"sha": data["sha"], "started": float(data["started"]), "covered": covered}


def plan_wait(last: dict | None, sha: str, before: str, now: float, hold_s: float,
              attempt: int = 1, off: bool = False) -> tuple[float, str]:
    """(seconds to wait, the push base to route from; EVERYTHING runs every web check). A re-run never waits and
    routes from the base its first attempt used (the marker's "covered" map), so it checks the same commits again.
    When the range this push covers is unknown, it runs at once and runs every web check (#33892): with no marker
    (the first run, an eviction, an unreadable one) a push replaced before this one may have changed web/ outside
    this push's own range, and a re-run the marker no longer remembers covered a range nobody kept. The off switch
    coalesces nothing, so every push runs on its own push base, as before coalescing."""
    own = before if SHA.fullmatch(before or "") and before != "0" * 40 else ""
    if off:
        return 0.0, own
    covered = (last or {}).get("covered") or {}
    if sha in covered:
        return 0.0, covered[sha]
    if last is None or attempt > 1:
        return 0.0, EVERYTHING
    if last["sha"] == sha:
        return 0.0, own  # an older marker's covered push with no "covered" map: its first attempt's own range
    return max(0.0, last["started"] + hold_s - now), last["sha"]


def branch_tip(ref: str) -> str | None:
    """REF's sha on the remote (a public read, no credentials), or None when it cannot be read."""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        return None
    try:
        out = subprocess.run(["git", "ls-remote", f"{server}/{repo}.git", ref], capture_output=True, text=True,
                             timeout=60, check=True).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return None
    return out[0] if out and SHA.fullmatch(out[0]) else None


def emit(base: str, run: bool) -> None:
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"base={base}\nrun={'true' if run else 'false'}\n")


def wait(args, sleep=time.sleep, clock=time.time, tip=branch_tip) -> int:
    hold_s = 0.0 if args.off else args.hold_minutes * 60
    last = None if args.off else read_last(args.last)
    attempt = int(getattr(args, "attempt", 1) or 1)
    rerun = attempt > 1 or (last is not None and (args.sha in last["covered"] or last["sha"] == args.sha))
    seconds, base = plan_wait(last, args.sha, args.before or "", clock(), hold_s, attempt, off=args.off)
    if seconds > 0:
        print(f"the last web checks started on {last['sha'][:12]}; waiting {seconds:.0f} s, so they run at most once "
              f"every {args.hold_minutes:g} minutes (a newer push's run replaces this wait while it is pending, and "
              "this run yields to a push that landed while it slept)")
        sleep(seconds)
        ref = getattr(args, "ref", None)
        newest = tip(ref) if ref else None
        if newest and newest != args.sha:
            # A newer push's coalesce job waits behind this one: it starts past the deadline and runs at once, from the
            # same last covered commit, so this push's commits are checked there. Nothing is recorded here.
            print(f"{ref} moved to {newest[:12]} while this push waited: its run checks this push's commits too, so "
                  "this run yields (no web checks here)")
            Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            Path(args.out).write_text(json.dumps(last) + "\n", encoding="utf-8")
            emit("", False)
            return 0
    started = clock()
    if rerun and last is not None:
        record = dict(last)  # a re-run is no newer covered push: the marker stays as it was
    else:
        covered = dict((last or {}).get("covered") or {})
        covered.pop(args.sha, None)
        covered[args.sha] = base
        covered = dict(list(covered.items())[-COVERED_KEPT:])
        record = {"sha": args.sha, "started": started, "covered": covered}
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(record) + "\n", encoding="utf-8")
    covers = ("every web check (the range it covers is unknown)" if base == EVERYTHING
              else f"covering every push since {base[:12] or 'its own push base'}")
    print(f"web checks run on {args.sha[:12]}, {covers}"
          + (" (a re-run: the range its first attempt checked)" if rerun and base != EVERYTHING else ""))
    emit(base, True)
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


def routes_webview_tests(paths: list[str], matcher) -> bool:
    """True when a commit changing PATHS routes the webview suite: the router's own lists (web_subareas
    classify_paths' react_apps) plus the paths web-bundle-key.py derives, with MATCHER computed once per bisect."""
    import web_subareas  # noqa: PLC0415
    for path in paths:
        if path in web_subareas.ALL_SUBAREA_INPUTS or path in web_subareas.REACT_EXACT \
                or path.startswith(web_subareas.REACT_PREFIXES) or (matcher is not None and matcher(path)):
            return True
    return False


def routed_points(commits: list[str]) -> list[int]:
    """The positions (1..n) of COMMITS whose change from the commit before routes the webview suite, with this
    checkout's router (the head's). COMMITS[0] is BASE. Only those commits can change a webview test's verdict."""
    import web_subareas  # noqa: PLC0415
    matcher = web_subareas.web_bundle_input_matcher(str(Path.cwd().resolve()))
    points = []
    for i in range(1, len(commits)):
        changed = git("diff", "--no-renames", "--name-only", commits[i - 1], commits[i], "--").splitlines()
        if routes_webview_tests(changed, matcher):
            points.append(i)
    return points


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

    requested_base = args.base
    base, base_source = choose_bisect_base(requested_base, getattr(args, "last_known_green", ""), args.head)
    report: dict = {"base": base, "head": args.head, "files": {}, "lines": [], "base_source": base_source}
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

    if not SHA.fullmatch(base or "") or not SHA.fullmatch(args.head or ""):
        return finish("no base for this run")
    head = history.results(args.results)
    runs = history.load(args.history) if args.history else []
    base_runs = [r for r in runs if r["sha"] == base]
    base_run = max(base_runs, key=lambda r: r.get("attempt", 1)) if base_runs else None
    flaky = set(history.flaky(runs, sorted(reds_of(head)))) if runs else set()
    names, skipped = new_reds(head, base_run, flaky)
    if not names and not skipped:
        return finish("no webview test is red at the head")
    try:
        git("merge-base", "--is-ancestor", base, args.head)
    except subprocess.CalledProcessError:
        return finish(f"{base[:12]} is not an ancestor of {args.head[:12]}")
    commits = [base] + git("rev-list", "--first-parent", "--reverse", f"{base}..{args.head}").split()
    if len(commits) - 1 > MAX_COMMITS:
        return finish(f"{len(commits) - 1} commits in the range, more than {MAX_COMMITS}")
    subjects = dict(line.split(" ", 1) for line in git("log", "--no-walk=unsorted", "--format=%H %s", *commits[1:])
                    .splitlines() if " " in line)
    points = routed_points(commits)
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
            try:
                ran = json.loads(Path(f"{out}.states").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                ran = {}
            ran = ran if isinstance(ran, dict) else {}
            return {f: probe_verdict(f, names[f], got, ran.get(f), lambda f=f: exists(sha, f)) for f in files}

        # BASE's verdict is known for a file only when the run before ran it.
        # A file red whole at BASE (a timeout, a load error) gave no verdict for the tests in it.
        known = base_run is not None and all(file in base_run["files"] and file not in base_run["red"] for file in names)
        found = search(sorted(names), points, known, probe, args.max_probes)
    report["files"] = {f: list(v) for f, v in found.items()}
    report["skipped"] = skipped
    report["lines"] = report_lines(found, commits, subjects, names, skipped, base)
    if base_source == "last-known-green":
        line = f"web bisect: lower bound last-known-green at {base} (coalesced base {requested_base})"
        report["lines"].insert(0, line)
    return finish()


def probe_verdict(file: str, wanted: set[str], got: dict, state, present) -> bool | None:
    """FILE's verdict at a probed commit: True red, False green, None unknown. GOT is the probe's results in the
    shards' shape (webviews_test_results.py: `FILE: true` for a passing file, each named failure as `FILE > TEST:
    false`, `FILE: false` for one red with no test named), STATE its run state (`{"result", "completed"}`) or None,
    PRESENT() whether the commit has the file. WANTED are the file's new red names.

    Red only when one of the new red tests is red here: a test already red at BASE, red in the same file, says
    nothing about where the new one broke. A file-level red (no test named) counts any red in the file. A file that
    ran to its end (passed, or failed naming only other tests) is green for the new tests: the results name no
    passing test, so this is where a test red at BASE beside them still gives a verdict. A file that timed out or
    died before its end is no verdict, and a file the commit does not have yet cannot fail there: green."""
    mine = {name: ok for name, ok in got.items() if name == file or name.startswith(file + " > ")}
    state = state if isinstance(state, dict) else {}
    completed = state.get("completed") is True or got.get(file) is True
    if file in wanted:
        if mine:
            return not all(mine.values())
        return None if present() else False
    if any(mine.get(name) is False for name in wanted):
        return True
    if mine and completed and got.get(file) is not False:
        return False  # the file ran to its end and none of the new red tests failed
    # A file red with no test named (it did not load, an error outside a test) gives no verdict for the tests in it,
    # even when bun printed its closing tally.
    if mine or state:
        return None  # it failed (a timeout, a crash, a load error) before the new tests gave a verdict
    return None if present() else False


def exists(sha: str, file: str) -> bool:
    try:
        git("cat-file", "-e", f"{sha}:webviews/{file}")
        return True
    except subprocess.CalledProcessError:
        return False


def choose_bisect_base(base: str, last_known_green: str, head: str) -> tuple[str, str]:
    """Use the published last-known-green as the lower bound when it covers HEAD.

    The coalesce marker normally gives a short range, but a red may have
    appeared in an earlier run.  A reconciler-published green ref lets this
    job identify the merged PR that introduced the red.  Invalid, unrelated,
    or stale refs are ignored and the marker's range remains the safe fallback.
    The bounded check belongs here, before the history is loaded: otherwise a
    stale ref can replace a usable coalesced range and make the bisector return
    no result merely because the old range exceeds ``MAX_COMMITS``.
    """
    if not SHA.fullmatch(last_known_green or "") or not SHA.fullmatch(head or ""):
        return base, "coalesced"
    try:
        git("merge-base", "--is-ancestor", last_known_green, head)
        distance = git("rev-list", "--first-parent", "--count", f"{last_known_green}..{head}")
        if not distance.isdigit() or int(distance) > MAX_COMMITS:
            return base, "coalesced"
    except (subprocess.CalledProcessError, OSError, subprocess.SubprocessError):
        return base, "coalesced"
    return last_known_green, "last-known-green"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    w = sub.add_parser("wait")
    w.add_argument("--last")
    w.add_argument("--sha", required=True)
    w.add_argument("--before", default="")
    w.add_argument("--hold-minutes", type=float, default=HOLD_MINUTES)
    w.add_argument("--attempt", type=int, default=1, help="the run's attempt: a re-run never waits")
    w.add_argument("--ref", help="the pushed ref: a job that slept yields when it moved past --sha")
    w.add_argument("--off", action="store_true", help="no coalescing: run at once, from the push's own base")
    w.add_argument("--out", required=True)
    b = sub.add_parser("bisect")
    b.add_argument("--base", default="")
    b.add_argument("--last-known-green", default="", help="optional last-known-green SHA; used when it is an ancestor of HEAD")
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
