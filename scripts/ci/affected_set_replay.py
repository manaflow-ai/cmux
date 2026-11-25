#!/usr/bin/env python3
"""Replays the last merged PRs and asks which of their checks the diff could not have made fail.

    affected_set_replay.py fetch [--limit 20] [--base origin/feat-cmux-next] [--cache FILE]
    affected_set_replay.py report [--cache FILE] [--json OUT]

fetch: takes the last LIMIT first-parent squash merges on BASE whose PR is not a bot's, and reads, per PR, one
`gh pr view --json statusCheckRollup` (every check's start and end, one call) and one
`gh api actions/runs?head_sha=` (which workflow each run id is), then the diff from local git (MERGE^..MERGE, the
squash against the base it landed on). Everything goes to CACHE, so report makes no GitHub call; a fetch that
GitHub refuses part way is resumed by running it again (PRs already in CACHE are kept).

report: for each PR, the verdict wall (first check start to last check end of the checks that ran and counted),
then the wall and machine minutes of the checks its diff could have affected against those it could not. A check
could not have failed when the diff touches none of its inputs. Totals: the share of wall and of machine minutes,
and the critical-path wall if only the affected checks had run (first start to last end of those).

Assumptions (the input map is INPUTS below, one regex list per check; an unknown check is affected by everything):
- Counted: completed checks that ran (not skipped, not neutral, not cancelled, not advisory or report-only) and
  started before the merge. A
  cancelled check is a superseded run of an older head, and a check after the merge is the post-merge bookkeeping.
- A check's wall is its completed minus its started. Machine minutes are the same, one machine per check; queue
  time is not in it, and a hosted job that fans out inside itself is one check here.
- "Could have failed" is by input: the files the check builds or tests, its workflow and its scripts, from the
  path_route rules in .github/workflows/cmux-next.yml (scripts/ci/cmux_next_route.py), the jobs' working paths and
  scripts/ci/affected-jobs.json. Any change to .github/workflows/, .github/actions/ or scripts/ci/ is an input of
  every check (CI_PLUMBING), the conservative reading.
- Checks that look at the PR itself, not its files (labels, body, merge freeze, risk tier, the size budget's
  comment) and the routers and placement jobs that decide the rest are always affected: the verdict needs them
  whatever the diff, so they are never counted as skippable (a lower bound on the share that could be skipped).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REPO = "manaflow-ai/cmux"
CACHE = Path("/tmp/affected_set_replay.json")

CI_PLUMBING = (r"^\.github/(workflows|actions)/", r"^scripts/ci/")

SWIFT_APP = (r"^Packages/macOS/", r"^Sources/", r"^cmux\.xcodeproj/", r"^Resources/", r"^CLI/", r"^cmux-next-app/",
             r"^ghostty", r"^GhosttyKit")
RUST_TUI = (r"^cmux-tui/",)
IOS = (r"^Packages/iOS/", r"^ios/", r"^cmux-next-ios/", r"^Packages/Shared/", r"^Packages/macOS/CmuxNext/")
WEB = (r"^web/", r"^webviews/", r"^apps/", r"^package\.json$", r"^bun\.lock")
BACKEND_MIGRATIONS = (r"^(web|backend)/.*migrations?/", r"^drizzle/")
EVERYTHING = (r"^.",)

# check name (regex, re.search, case-insensitive, first match wins) -> inputs (regexes on repo paths).
# None means the verdict depends on the PR itself, not its files: always affected.
INPUTS: list[tuple[str, tuple[str, ...] | None]] = [
    (r"size budget|size cap|defaults guard|freeze|risk|language boundaries|intent|^close$|pr-red-checks|^batch$"
     r"|autofix|repairs|CI timing|ci-status|fallback|pr-checks|local test receipt|pr-capture-check|design spec"
     r"|fast check route|^changes$|resolve head and base|plan the look|path routing|^pr router$|action export areas"
     r"|^check$|web-subarea-scope|placement", None),
    (r"react-apps|Agent pane on real acpmux|chat-open|web bundles", WEB + (r"^Packages/macOS/CmuxNext/",)),
    (r"app compile|fast tier|terminal crates|journey", RUST_TUI + SWIFT_APP),
    (r"api-workerd|^backend", (r"^backend/", r"^workers/", r"^services/", r"^web/")),
    (r"^fast gates$|^post cmux-next/fast-gates", EVERYTHING),
    (r"^tooling-tests$", (r"^scripts/", r"^tests/", r"^\.github/")),
    (r"^generated drift$", (r"^cmux-next/", r"^Packages/macOS/CmuxNext/", r"^cmux-tui/", r"^scripts/")),
    (r"^pr pipeline / linux$|^linux-preflight$", EVERYTHING),
    (r"^pr pipeline / web|^Web validation$|^web$|^browser$", WEB),
    (r"^ios-|^mobile-core", IOS),
    (r"^package-conventions-lint$", (r"Package\.swift$", r"^Packages/")),
    (r"^Swift packages on Linux$", (r"^Packages/",)),
    (r"^(rustfmt|clippy|acpmux|carrier simulation|inventory|api-compat|crate-graph)", RUST_TUI),
    (r"^React Doctor", (r"\.(tsx|jsx)$", r"^web/", r"^webviews/", r"^apps/")),
    (r"^macos$|^macOS|^cmux-next .*(Swift|Mac)|^action exports|^GhosttyKit|^exports from", SWIFT_APP),
    (r"^remote-daemon$", (r"^daemon/", r"^cmux-tui/")),
    (r"^backend migrations|^apply-(staging|production)", BACKEND_MIGRATIONS),
    (r"^classic", (r"^Sources/", r"^CLI/", r"^cmux\.xcodeproj/")),
    (r"^screen share drop gate$", (r"screen.?shar",)),
    (r"^Dogfood build", SWIFT_APP),
]


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def gh(*args: str) -> str:
    """gh's stdout; a refusal (the broker's exit 75 under rate pressure) is tried 3 times, then raised with its text."""
    for attempt in range(3):
        r = subprocess.run(["gh", *args], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout
    raise RuntimeError(f"gh {' '.join(args[:3])} exit {r.returncode}: {r.stderr.strip()[:300]}")


def ts(s: str) -> float:
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").timestamp() / 60


def dur(c: dict) -> float:
    return max(0.0, ts(c["end"]) - ts(c["start"]))


def fetch(base: str, limit: int, cache: Path) -> None:
    out = json.loads(cache.read_text()) if cache.exists() else []
    done = {p["number"] for p in out}
    for line in git("log", base, "--first-parent", "--format=%H %s", "-200").splitlines():
        m = re.search(r"\(#(\d+)\)$", line)
        if not m:
            continue
        sha, number = line.split()[0], int(m.group(1))
        if number in done:
            continue
        pr = json.loads(gh("pr", "view", str(number), "--repo", REPO, "--json",
                           "number,author,headRefOid,mergedAt,baseRefName,statusCheckRollup"))
        if pr["author"].get("is_bot") or pr["author"]["login"].endswith("[bot]") or pr["baseRefName"] != "feat-cmux-next":
            continue
        runs = json.loads(gh("api", f"repos/{REPO}/actions/runs?head_sha={pr['headRefOid']}&per_page=100"))
        paths = {str(r["id"]): r["path"].rsplit("/", 1)[-1] for r in runs["workflow_runs"]}
        checks = []
        for c in pr["statusCheckRollup"]:
            if c.get("__typename") != "CheckRun" or not c.get("startedAt"):
                continue
            m2 = re.search(r"/runs/(\d+)", c.get("detailsUrl") or "")
            checks.append({"name": c["name"], "conclusion": c["conclusion"], "start": c["startedAt"],
                           "end": c["completedAt"], "workflow": paths.get(m2.group(1), "?") if m2 else "?"})
        files = git("diff", "--name-only", f"{sha}^", sha).splitlines()
        out.append({"number": number, "merge": sha, "merged_at": pr["mergedAt"], "files": files, "checks": checks})
        cache.write_text(json.dumps(out, indent=1))
        if len(out) == limit:
            break
    cache.write_text(json.dumps(out, indent=1))
    print(f"{len(out)} PRs -> {cache}")


def could_fail(name: str, files: list[str]) -> bool:
    """True when the diff touches an input of the check, or the check depends on the PR and not its files."""
    ins: tuple[str, ...] | None = EVERYTHING
    for pattern, found in INPUTS:
        if re.search(pattern, name, re.I):
            ins = found
            break
    if ins is None:
        return True
    pats = tuple(ins) + CI_PLUMBING
    return any(re.search(p, f) for f in files for p in pats)


def counted(c: dict, merged_at: str) -> bool:
    if re.search(r"advisory|report only", c["name"], re.I):  # they gate nothing
        return False
    return c["conclusion"] in ("SUCCESS", "FAILURE", "TIMED_OUT") and bool(c["end"]) and c["start"] < merged_at


def span(xs: list[dict]) -> float:
    return (max(ts(c["end"]) for c in xs) - min(ts(c["start"]) for c in xs)) if xs else 0.0


def replay(prs: list[dict]) -> dict:
    rows = []
    costly: dict[str, float] = {}
    for pr in prs:
        cs = [c for c in pr["checks"] if counted(c, pr["merged_at"])]
        if not cs:
            continue
        aff = [c for c in cs if could_fail(c["name"], pr["files"])]
        no = [c for c in cs if not could_fail(c["name"], pr["files"])]
        for c in no:
            costly[c["name"]] = costly.get(c["name"], 0) + dur(c)
        rows.append({"pr": pr["number"], "files": len(pr["files"]), "n": len(cs), "n_no": len(no),
                     "verdict_wall": span(cs), "machine": sum(map(dur, cs)),
                     "aff_wall": span(aff), "aff_machine": sum(map(dur, aff)), "no_machine": sum(map(dur, no))})
    return {"rows": rows, "costly": sorted(costly.items(), key=lambda kv: -kv[1])}


def p50(xs: list[float]) -> float:
    xs = sorted(xs)
    return xs[len(xs) // 2] if xs else 0.0


def report(cache: Path, json_out: str | None) -> None:
    res = replay(json.loads(cache.read_text()))
    rows = res["rows"]
    print(f"{'PR':>6} {'files':>5} {'checks':>7} {'verdict wall':>12} {'machine':>8} {'aff wall':>8} {'aff mach':>8} {'unaffectable mach':>17}")
    for r in rows:
        print(f"{r['pr']:>6} {r['files']:>5} {r['n']:>4}/{r['n_no']:<2} {r['verdict_wall']:>12.1f} {r['machine']:>8.1f} "
              f"{r['aff_wall']:>8.1f} {r['aff_machine']:>8.1f} {r['no_machine']:>17.1f}")
    tm = sum(r["machine"] for r in rows)
    tn = sum(r["no_machine"] for r in rows)
    tw = sum(r["verdict_wall"] for r in rows)
    ta = sum(r["aff_wall"] for r in rows)
    print(f"\nmachine minutes on checks that could not have failed: {tn:.0f} of {tm:.0f} ({100 * tn / max(tm, 1):.0f}%)")
    print(f"verdict wall if only affected checks ran: {ta:.0f} of {tw:.0f} min summed ({100 * (tw - ta) / max(tw, 1):.0f}% less)")
    print(f"verdict wall p50 {p50([r['verdict_wall'] for r in rows]):.1f} min; "
          f"affected-only critical path p50 {p50([r['aff_wall'] for r in rows]):.1f} min")
    print("\ncostliest checks that could not have failed (machine minutes over the window):")
    for name, m in res["costly"][:8]:
        print(f"  {m:7.1f}  {name[:90]}")
    if json_out:
        Path(json_out).write_text(json.dumps(res, indent=1))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--limit", type=int, default=20)
    f.add_argument("--base", default="origin/feat-cmux-next")
    f.add_argument("--cache", type=Path, default=CACHE)
    r = sub.add_parser("report")
    r.add_argument("--cache", type=Path, default=CACHE)
    r.add_argument("--json")
    a = ap.parse_args()
    if a.cmd == "fetch":
        fetch(a.base, a.limit, a.cache)
    else:
        report(a.cache, a.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
