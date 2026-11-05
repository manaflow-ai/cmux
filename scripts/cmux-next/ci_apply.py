#!/usr/bin/env python3
"""Check a cmux NEXT pull request against a prebuilt base build: skip the compile, run the tests.

Leo, 2026-11-05: "If a hot swapped build works (copied versions of a certain version) Then you can
skip compile skip build you only need the tests".

    ci_apply.py plan [--repo DIR] [--labels a,b] [--event pull_request] [--json] BASE HEAD
    ci_apply.py commands [--repo DIR] BASE HEAD
    ci_apply.py replay --prs PRS.jsonl --checks CHECKS.jsonl [--repo DIR] [--json] [--misses]

This is a tool, not a CI job: it adds no check, gate or required status, and CI runs as before.

`plan` sorts the change (live_apply.py's classifier, read from `git diff BASE HEAD`) into a lane:

  no-app      nothing in the app changes: no app build is needed at all
  web         webviews/ only (with no-app files): the base app plus the PR's web bundles
  daemon      cmux-tui Rust the app does not link: the base app plus an incremental daemon build
  swift-body  CmuxNextApp Swift changed only inside function bodies: the base live code build
              plus scripts/live-code/patch.py
  full        anything else: the normal full build and tests

A PR can take several appliers (web and daemon). Any of these sends it to `full`, with the reason:
a live_apply `rebuild` file (a stored property, a changed signature, a new type or enum case, a
resource, manifest or plist, Swift outside the patched modules), Rust the app links through FFI
(scripts/ci/cmux_next_route.py SWIFT_JOB_INPUTS and app_ffi_inputs), an input of every CI tier
(FULL_INPUTS), iOS, the `full-ci`, `dev-build`, release or nightly labels, or any event other than a
pull request. Signed, nightly and release builds are never patched builds: they always build clean.

`commands` prints the fleet steps for the lane, every one an existing command:

  base app    cmux-ci build cmux --ref BASE --any-tag     (answered by source tree, cmuxterm-hq#7238)
  daemons     the base tree's cmux-tui from R2 (cmux-tui-artifacts.yml, tree key), then
              scripts/ci/cargo_affected.py --base BASE -- cargo build/test on a warm tree
  web         scripts/cmux-next/build-web-bundles.sh at HEAD, then the router's web tests
  swift-body  scripts/live-code/build.sh at BASE (kept by tree), patch.py --tree HEAD FILES
  tests       the tests scripts/ci/cmux_next_route.py picks for the change, minus its compile tiers

`replay` reads CI history saved from GitHub (PRS: one merged PR per line with its last heads;
CHECKS: one head commit per line with every check run, both from GraphQL) and, for every head,
compares what full CI concluded with what the lane would have concluded: the lane drops the app
build jobs (APP_BUILD_JOBS) and keeps every other check. A miss is a head that full CI failed only
through a job the lane drops. It prints the share of PRs each lane takes, the minutes the dropped
jobs used, and the agreement.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import live_apply  # noqa: E402

LANES = ("no-app", "web", "daemon", "swift-body", "full")
# Labels that ask for the full build on purpose (docs/ci/cmux-next-tiers.md, pr-ci-coverage.md).
FULL_LABELS = {"full-ci", "dev-build", "release", "nightly", "media-tour"}
# The checks whose work a prebuilt base replaces: compiling or building the app. Matched against
# "workflow / job" names. Everything else (tests, lints, guards) runs in the lane as in full CI.
APP_BUILD_JOBS = re.compile(
    r"^cmux-next / ("
    r"cmux-next app compile \(build fleet\)"
    r"|cmux-next Swift canary( \(build fleet\))?"
    r"|cmux-next Release compile.*"
    r"|cmux app scheme compile \(Debug\)"
    r"|cmux NEXT DEV Release compile.*"
    r")$"
    r"|^CI / Dogfood build"
)
# The daemon build a Rust lane replaces with an incremental build on a warm tree.
DAEMON_BUILD_JOBS = re.compile(r"^cmux-tui artifacts / ")
# Jobs that compile the app's test targets. The lane keeps them for Swift: a unit test needs its
# own target built, and no prebuilt build holds a PR's test bundle.
TEST_COMPILE_JOBS = re.compile(r"^cmux-next / cmux-next (swift test|fast tier)|^fleet test-compile / ")

# Measured costs of the lane's own steps, in minutes, added back to its time.
# base app: an answered `cmux-ci build cmux --any-tag` download (cmuxterm-hq#7238, median ready
# time of an answered build). daemon: the incremental cargo build of a one-crate edit on a warm
# tree (cmux#36465, save-to-swapped p50 42 s), rounded up. swift-body: patch.py's compile and link
# of the changed files (research/2026-11-04-try-pr-live-apply.md).
LANE_COST_MIN = {"base": 1.0, "daemon": 1.5, "web": 0.0, "swift-body": 1.0}


def _router():
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import cmux_next_route  # noqa: E402
    return cmux_next_route


def app_linked_rust(paths: list[str]) -> list[str]:
    """The changed Rust paths the app links (FFI crates and their inputs): those need the app rebuilt."""
    route = _router()
    inputs = [p for p in route.SWIFT_JOB_INPUTS if p.startswith("cmux-tui/")]
    try:
        inputs += list(route.app_ffi_inputs(ROOT)) + list(route.scheme_phase_rust_inputs(ROOT))
    except Exception:  # noqa: BLE001 - a router that cannot read the tree: treat every Rust path as linked
        return [p for p in paths if p.startswith("cmux-tui/")]
    return [p for p in paths if any(p == i or p.startswith(i.rstrip("/") + "/") for i in inputs)]


def full_inputs(paths: list[str]) -> list[str]:
    route = _router()
    return [p for p in paths if p in route.FULL_INPUTS or p in route.VENDORED_PINS]


def plan_from(result: dict, labels: set[str] = frozenset(), event: str = "pull_request") -> dict:
    """The lane for a live_apply.classify() result."""
    files = result["files"]
    every = sorted({p for paths in files.values() for p in paths})
    reasons: dict[str, list[str]] = {}
    if event != "pull_request":
        reasons[f"{event} builds are clean full builds"] = []
    hit = sorted(set(labels) & FULL_LABELS)
    if hit:
        reasons[f"label {', '.join(hit)}"] = []
    for why, paths in result["reasons"].items():
        reasons.setdefault(why, []).extend(paths)
    if "ios-only" in files:
        reasons["iOS (not covered by this lane)"] = files["ios-only"]
    if "rebuild" in files and not result["reasons"]:
        reasons["rebuild"] = files["rebuild"]
    linked = app_linked_rust(files.get("daemon", []))
    if linked:
        reasons["Rust the app links (FFI)"] = linked
    pinned = full_inputs(every)
    if pinned:
        reasons["an input of every CI tier"] = pinned
    appliers = [lane for lane, kind in (("web", "web-live"), ("daemon", "daemon"), ("swift-body", "swift-live"))
                if kind in files]
    if reasons:
        lane = "full"
    elif not appliers:
        lane = "no-app"
    else:
        lane = appliers[-1] if len(appliers) == 1 else "+".join(appliers)
    return {"lane": lane, "appliers": [] if lane == "full" else appliers,
            "fallback": {k: sorted(set(v)) for k, v in reasons.items()}, "files": files}


RUST_CLASS = HERE / "rust-change-class" / "target" / "release" / "rust-change-class"


def rust_bucket(repo: str, base: str, head: str) -> dict | None:
    """rust-change-class's verdict (no-compile, test-only, body-only, full), when its binary is built
    (CI_APPLY_RUST_CLASS, or scripts/cmux-next/rust-change-class/check.sh on a build host)."""
    binary = Path(os.environ.get("CI_APPLY_RUST_CLASS", RUST_CLASS))
    if not binary.is_file():
        return None
    run = subprocess.run([str(binary), "--repo", repo, base, head], capture_output=True, text=True)
    return json.loads(run.stdout) if run.returncode == 0 and run.stdout.strip() else None


def plan(repo: str, base: str, head: str, labels: set[str] = frozenset(), event: str = "pull_request") -> dict:
    out = plan_from(live_apply.classify_range(repo, base, head), labels, event)
    out.update(base=base, head=head)
    if "daemon" in out["appliers"]:
        out["rust"] = rust_bucket(repo, base, head)
    return out


def commands(p: dict) -> list[str]:
    """The fleet steps for a plan; each one is an existing command."""
    base, head = p.get("base", "BASE"), p.get("head", "HEAD")
    if p["lane"] == "full":
        return [f"# full CI: {'; '.join(p['fallback'])}"]
    if p["lane"] == "no-app":
        return ["# no app build: CI's router already runs only the tests these files reach"]
    steps = [f"cmux-ci build cmux --ref {base} --any-tag    # the base app, answered by tree"]
    if "web" in p["appliers"]:
        steps.append(f"cmux-ci test --ref {head} -- bash scripts/cmux-next/build-web-bundles.sh")
    if "daemon" in p["appliers"]:
        bucket = (p.get("rust") or {}).get("bucket")
        if bucket == "no-compile":
            steps.append(f"# Rust: no-compile (rust-change-class): the base tree's daemons as they are, no cargo build")
        else:
            why = {"test-only": "test code only: the base daemons ship, the tests build",
                   "body-only": "function bodies only: incremental cargo check + build on the warm base tree",
                   }.get(bucket, "incremental cargo build on the warm base tree")
            steps.append(f"cmux-ci test --ref {head} --setup rust -- python3 scripts/ci/cargo_affected.py "
                         f"--base {base} -- cargo test --locked    # {why}")
    if "swift-body" in p["appliers"]:
        swift = sorted(p["files"].get("swift-live", []))
        steps.append(f"cmux-ci run --class light --ref {base} --script scripts/live-code/build.sh  # kept by tree")
        steps.append(f"scripts/live-code/patch.py --log LOG --module CmuxNextApp --live DIR --tree <{head} worktree> "
                     + " ".join(swift))
    if (ROOT / "scripts" / "ci" / "affected_tests.py").is_file():  # cmux#36531
        steps.append(f"cmux-ci test --affected --ref {head}    # the affected tests, sharded over the fleet")
    else:
        steps.append(f"python3 scripts/ci/cmux_next_route.py --event pull_request --changed-files <git diff "
                     f"--name-only {base} {head}>   # the tests to run, minus the native/scheme/canary tiers")
    return steps


# --- replay ---------------------------------------------------------------------------------------

def _t(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None


def head_jobs(check_obj: dict) -> list[dict]:
    """Every completed check run of a head, from pull request runs and the branch's push runs."""
    jobs = []
    for suite in check_obj["checkSuites"]["nodes"]:
        run = suite.get("workflowRun")
        if not run:
            continue
        workflow = run["workflow"]["name"]
        if run["event"] not in ("pull_request", "push"):
            continue
        if run["event"] == "push" and not DAEMON_BUILD_JOBS.match(workflow + " / "):
            continue
        for r in suite["checkRuns"]["nodes"]:
            start, end = _t(r.get("startedAt")), _t(r.get("completedAt"))
            jobs.append({"name": f"{workflow} / {r['name']}", "conclusion": r.get("conclusion"),
                         "minutes": (end - start) / 60 if start and end and end >= start else 0.0,
                         "start": start, "end": end})
    return jobs


def dropped(job_name: str, lane: str, appliers) -> bool:
    if lane in ("full", "no-app"):
        return False
    if APP_BUILD_JOBS.match(job_name):
        return True
    return "daemon" in appliers and bool(DAEMON_BUILD_JOBS.match(job_name))


def verdict(jobs) -> str:
    concl = {j["conclusion"] for j in jobs}
    return "red" if concl & {"FAILURE", "TIMED_OUT", "STARTUP_FAILURE"} else "green"


def merge_diff_plan(repo: str, pr: dict) -> dict:
    merge = (pr.get("mergeCommit") or {}).get("oid")
    if not merge:
        return {"lane": "unknown", "appliers": [], "fallback": {"no merge commit": []}, "files": {}}
    labels = {n["name"] for n in pr.get("labels", {}).get("nodes", [])}
    try:
        return plan(repo, f"{merge}^1", merge, labels)
    except subprocess.CalledProcessError as error:
        return {"lane": "unknown", "appliers": [], "fallback": {f"git: {error}": []}, "files": {}}


def replay(repo: str, prs_path: str, checks_path: str) -> dict:
    checks = {}
    for line in Path(checks_path).read_text(encoding="utf-8").splitlines():
        obj = json.loads(line)
        checks[obj["oid"]] = obj
    lanes, rows = Counter(), []
    for line in Path(prs_path).read_text(encoding="utf-8").splitlines():
        pr = json.loads(line)
        p = merge_diff_plan(repo, pr)
        lane_key = "full" if p["lane"] == "full" else ("no-app" if p["lane"] == "no-app" else p["lane"])
        lanes[lane_key] += 1
        for node in pr["commits"]["nodes"]:
            oid = node["commit"]["oid"]
            if oid not in checks:
                continue
            jobs = [j for j in head_jobs(checks[oid]) if j["conclusion"] not in (None, "SKIPPED", "NEUTRAL", "CANCELLED")]
            if not jobs:
                continue
            kept = [j for j in jobs if not dropped(j["name"], p["lane"], p["appliers"])]
            gone = [j for j in jobs if j not in kept]
            full_v, lane_v = verdict(jobs), verdict(kept)
            ends_all = [j["end"] for j in jobs if j["end"]]
            starts = [j["start"] for j in jobs if j["start"]]
            ends_kept = [j["end"] for j in kept if j["end"]]
            rows.append({
                "pr": pr["number"], "head": oid, "lane": p["lane"], "appliers": p["appliers"],
                "fallback": list(p["fallback"]), "full": full_v, "fast": lane_v,
                "dropped_min": sum(j["minutes"] for j in gone),
                "dropped_failed": [j["name"] for j in gone if verdict([j]) == "red"],
                "kept_failed": [j["name"] for j in kept if verdict([j]) == "red"],
                "wall_full": (max(ends_all) - min(starts)) / 60 if ends_all and starts else 0.0,
                "wall_kept": (max(ends_kept) - min(starts)) / 60 if ends_kept and starts else 0.0,
                "test_compile_min": sum(j["minutes"] for j in kept if TEST_COMPILE_JOBS.match(j["name"])),
            })
    return {"lanes": dict(lanes), "prs": sum(lanes.values()), "heads": rows}


def summarize(rep: dict) -> str:
    rows = rep["heads"]
    by_lane = defaultdict(list)
    for r in rows:
        by_lane[r["lane"]].append(r)
    fast = [r for r in rows if r["lane"] not in ("full", "no-app", "unknown")]
    misses = [r for r in fast if r["full"] == "red" and r["fast"] == "green"]
    extra = [r for r in fast if r["full"] == "green" and r["fast"] == "red"]
    lines = [f"PRs: {rep['prs']}   heads with CI: {len(rows)}", "", "| lane | PRs | share |", "|---|---|---|"]
    for lane, n in sorted(rep["lanes"].items(), key=lambda kv: -kv[1]):
        lines.append(f"| {lane} | {n} | {100 * n / max(rep['prs'], 1):.0f}% |")
    lines += ["", "| lane | heads | app build min dropped per head (mean) | full wall min (median) | kept wall min (median) | full red | lane red | misses |",
              "|---|---|---|---|---|---|---|---|"]

    def med(xs):
        xs = sorted(xs)
        return xs[len(xs) // 2] if xs else 0.0
    for lane, rs in sorted(by_lane.items()):
        if lane in ("full", "no-app", "unknown"):
            continue
        cost = LANE_COST_MIN["base"] + sum(LANE_COST_MIN.get(a, 0) for a in (rs[0]["appliers"] or []))
        lines.append(
            f"| {lane} | {len(rs)} | {sum(r['dropped_min'] for r in rs) / len(rs):.1f} (lane cost {cost:.1f}) | "
            f"{med([r['wall_full'] for r in rs]):.1f} | {med([r['wall_kept'] for r in rs]):.1f} | "
            f"{sum(r['full'] == 'red' for r in rs)} | {sum(r['fast'] == 'red' for r in rs)} | "
            f"{sum(r['full'] == 'red' and r['fast'] == 'green' for r in rs)} |")
    agree = sum(r["full"] == r["fast"] for r in fast)
    lines += ["", f"lane heads: {len(fast)}; verdict agreement with full CI: {agree}/{len(fast)}; "
              f"misses (full red, lane green): {len(misses)}; lane red where full green: {len(extra)}"]
    for r in misses:
        lines.append(f"  miss: #{r['pr']} {r['head'][:12]} {r['lane']}: {', '.join(r['dropped_failed'])}")
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "commands"):
        sp = sub.add_parser(name)
        sp.add_argument("--repo", default=os.getcwd())
        sp.add_argument("--labels", default="")
        sp.add_argument("--event", default="pull_request")
        sp.add_argument("--json", action="store_true")
        sp.add_argument("base")
        sp.add_argument("head")
    rp = sub.add_parser("replay")
    rp.add_argument("--repo", default=os.getcwd())
    rp.add_argument("--prs", required=True)
    rp.add_argument("--checks", required=True)
    rp.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.cmd == "replay":
        rep = replay(args.repo, args.prs, args.checks)
        print(json.dumps(rep, indent=1) if args.json else summarize(rep))
        return 0
    labels = {x for x in args.labels.split(",") if x}
    p = plan(args.repo, args.base, args.head, labels, args.event)
    if args.cmd == "commands":
        print("\n".join(commands(p)))
    elif args.json:
        print(json.dumps(p, indent=2))
    else:
        rust = (p.get("rust") or {}).get("bucket")
        print(p["lane"] + (f" (Rust: {rust})" if rust else ""))
        for why, paths in p["fallback"].items():
            print(f"  {why}: {', '.join(paths[:5])}{' …' if len(paths) > 5 else ''}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
