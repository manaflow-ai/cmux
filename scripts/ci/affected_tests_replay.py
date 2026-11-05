#!/usr/bin/env python3
"""Replay scripts/ci/affected_tests.py on merged PRs: would it have run every test that failed on them?

    affected_tests_replay.py collect --since 2026-11-04T00:00:00Z --until ... --out failures.json
    affected_tests_replay.py check failures.json --metadata cargo-metadata.json [--json OUT]

collect reads, through `gh api` (glaeda-gh's when it is on PATH), the pull requests merged into
feat-cmux-next in the window, every failed pull_request run of the test workflows on them, the
failed jobs of those runs and each failed job's log, and keeps the tests the log names as red:

  python  a failed step's `python3 tests/test_x.py` (or scripts/**/test_*.py) command
  web     `FAIL test/x.test.ts` (run-webviews-tests.sh's per-file verdict)
  swift   `✘ Test ... at File.swift:N` and `✘ Suite S failed`: the test file, so the target
  rust    nextest's `FAIL [ t] crate::binary test` and `cargo test` panics under `Running ... (crate)`

It needs GitHub quota (one read per failed run and per failed test job), so it is a by-hand
check, not a CI step. check needs only git and python: for each failure it fetches the head the
run tested, plans the PR's change (`git diff merge-base...head`) exactly as `cmux-ci test
--affected` would, and says whether the failing test is in the plan. The cmux-tui crate graph
comes from saved `cargo metadata --no-deps --format-version 1` output (--metadata), so no cargo
runs here. A failure the plan misses exits 1; each is listed with the PR, head and test, and
whether the same test failed on other PRs in the window too (a base red, which no selection of
the PR's own change can be expected to run).
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import affected_tests  # noqa: E402
import cargo_affected  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPO = "manaflow-ai/cmux"
BASE_BRANCH = "feat-cmux-next"
# The workflows whose jobs run tests on a pull request.
TEST_WORKFLOWS = ("cmux-next-guards.yml", "cmux-next-fast-gates.yml", "cmux-next.yml", "rust-workspaces.yml",
                  "ci.yml", "cmux-tui-sdks.yml", "cmux-tui.yml", "cmux-tui-spec.yml", "app-platform.yml")
# Failed jobs that only aggregate other jobs or run static checks (no test of their own): their logs
# are not read.
NO_TESTS = ("Web status", "cmux-next checks (god files", "Rust notices", "web lint", "Fail on any red")
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
PY_TEST = re.compile(r"((?:[\w.-]+/)*test_[\w-]+\.py)\b")  # an absolute runner path is resolved in check
WEB_FAIL = re.compile(r"^FAIL ((?:test|src)/\S+\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs))\b")
SWIFT_ISSUE = re.compile(r"^✘ Test .* at ([\w+-]+\.swift):\d+")
SWIFT_SUITE = re.compile(r"^✘ Suite (\w+) failed")
NEXTEST_FAIL = re.compile(r"^\s*(?:FAIL|TIMEOUT|SIGSEGV|SIGABRT) \[[^\]]*\] (?:\(\d+/\d+\) )?([\w-]+)(?:::\S+)? (\S+)")
CARGO_RUNNING = re.compile(r"^\s*Running .*\(target/.*/deps/([\w]+?)-[0-9a-f]{16}\)")
CARGO_FAILED = re.compile(r"^test (\S+) \.\.\. FAILED")


def gh(*args: str) -> str:
    tool = ["glaeda-gh", "gh"] if shutil.which("glaeda-gh") else ["gh"]
    env = {**os.environ, "GLAEDA_GH_SWEEP_OK": "1"}  # a replay reads every failed run's jobs on purpose
    return subprocess.run([*tool, *args], check=True, capture_output=True, text=True, env=env).stdout


def clean(line: str) -> str:
    return ANSI.sub("", STAMP.sub("", line.rstrip("\n")))


def steps(log: str) -> list[tuple[str, list[str], bool]]:
    """The log as (group header, lines, failed) per `##[group]` step."""
    out, header, lines = [], "", []
    for raw in log.splitlines():
        line = clean(raw)
        if line.startswith("##[group]"):
            if header or lines:
                out.append((header, lines, any("##[error]" in x for x in lines)))
            header, lines = line[len("##[group]"):], []
        else:
            lines.append(line)
    out.append((header, lines, any("##[error]" in x for x in lines)))
    return out


def failures_in_log(log: str) -> list[dict]:
    found: dict[tuple[str, str], dict] = {}

    def add(kind, test, detail=""):
        found.setdefault((kind, test), {"kind": kind, "test": test, "detail": detail})

    crate = ""
    for header, lines, failed in steps(log):
        for line in lines:
            m = WEB_FAIL.match(line)
            if m:
                add("web", m.group(1))
            m = SWIFT_ISSUE.match(line)
            if m:
                add("swift-file", m.group(1))
            m = SWIFT_SUITE.match(line)
            if m:
                add("swift-suite", m.group(1))
            m = NEXTEST_FAIL.match(line)
            if m:
                add("rust", m.group(1), m.group(2))
            m = CARGO_RUNNING.match(line)
            if m:
                crate = m.group(1)
            m = CARGO_FAILED.match(line)
            if m and crate:
                add("rust", crate.replace("_", "-"), m.group(1))
        if failed:
            # A red Python test shows as a traceback through its own file (unittest's FAIL and ERROR
            # print one), or as `FAILED (` from a step that runs exactly one test file. Guard output
            # that only names a test path (the registry check) is not a red test.
            framed = {m for line in lines if line.lstrip().startswith('File "') for m in PY_TEST.findall(line)}
            ran = set(PY_TEST.findall(header)) | {m for line in lines[:40] if "python3" in line for m in PY_TEST.findall(line)}
            if not framed and len(ran) == 1 and any(line.startswith(("FAILED (", "FAIL:", "ERROR:")) for line in lines):
                framed = ran
            for name in sorted(framed):
                add("python", name, header[:120])
    return list(found.values())


def collect(since: str, until: str, out: Path, max_runs: int) -> int:
    prs = []
    for page in range(1, 6):
        batch = json.loads(gh("api", f"repos/{REPO}/pulls?state=closed&base={BASE_BRANCH}&sort=updated&direction=desc&per_page=100&page={page}"))
        prs += [p for p in batch if p.get("merged_at") and since <= p["merged_at"] <= until]
        if len(batch) < 100 or (batch and batch[-1]["updated_at"] < since):
            break
    by_branch = {p["head"]["ref"]: p["number"] for p in prs}
    numbers = set(by_branch.values())
    print(f"collect: {len(prs)} PRs merged {since}..{until}", file=sys.stderr)
    failures, runs_read = [], 0
    for workflow in TEST_WORKFLOWS:
        for page in range(1, 11):
            data = json.loads(gh("api", f"repos/{REPO}/actions/workflows/{workflow}/runs?status=failure&event=pull_request"
                                        f"&created={since}..{until}&per_page=100&page={page}"))
            for run in data.get("workflow_runs", []):
                pr = by_branch.get(run["head_branch"]) or next(iter({p["number"] for p in run.get("pull_requests") or []} & numbers), None)
                if not pr or runs_read >= max_runs:
                    continue
                runs_read += 1
                jobs = json.loads(gh("api", f"repos/{REPO}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100"))["jobs"]
                for job in jobs:
                    if job["conclusion"] != "failure" or any(x in job["name"] for x in NO_TESTS):
                        continue
                    try:
                        log = gh("api", "--allow-escape-sequences", f"repos/{REPO}/actions/jobs/{job['id']}/logs")
                    except subprocess.CalledProcessError:
                        continue
                    for f in failures_in_log(log):
                        failures.append({**f, "pr": pr, "head": run["head_sha"], "workflow": workflow,
                                         "job": job["name"], "job_id": job["id"], "run_id": run["id"]})
            if len(data.get("workflow_runs", [])) < 100:
                break
    out.write_text(json.dumps({"since": since, "until": until, "prs": sorted(numbers), "failures": failures}, indent=1))
    print(f"collect: {len(failures)} failed tests from {runs_read} failed runs -> {out}", file=sys.stderr)
    return 0


def git(*args: str, check=True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=check)


def ensure_commit(sha: str, pr: int) -> bool:
    if git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0:
        return True
    git("fetch", "--quiet", "--no-tags", "origin", sha, check=False)
    if git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0:
        return True
    git("fetch", "--quiet", "--no-tags", "origin", f"refs/pull/{pr}/head", check=False)
    return git("cat-file", "-e", f"{sha}^{{commit}}", check=False).returncode == 0


def tree_files(head: str) -> list[str]:
    return git("ls-tree", "-r", "--name-only", head).stdout.splitlines()


def swift_target_of(files: list[str], name: str, kind: str) -> set[tuple[str, str]]:
    """(package, test target) for a test file name, or for a suite declared in a test file of that name."""
    out = set()
    for path in files:
        parts = path.split("/")
        if "Tests" not in parts or not path.endswith(".swift"):
            continue
        i = parts.index("Tests")
        if i + 1 >= len(parts):
            continue
        hit = parts[-1] == name if kind == "swift-file" else parts[-1].startswith(name.removesuffix("Tests"))
        if hit:
            out.add(("/".join(parts[:i]), parts[i + 1]))
    return out


def replay_worktree() -> Path:
    """One detached worktree under .build, moved from head to head (its own, never the caller's checkout)."""
    wt = ROOT / ".build" / "affected-replay"
    if not (wt / ".git").exists():
        git("worktree", "add", "--detach", "--quiet", str(wt), "HEAD")
    return wt


def selected(plan: dict) -> dict:
    sel = {"all": plan["all"], "python": set(), "web": set(), "swift": set(), "rust": False}
    for unit in plan["units"]:
        argv = unit["argv"]
        if unit["kind"] == "python":
            sel["python"] |= {argv[i + 1] for i, a in enumerate(argv) if a == "--path"}
            if "--path" not in argv:
                sel["python"].add("*")
        elif unit["kind"] == "web":
            for a in argv:
                if a.startswith("CMUX_WEB_TEST_FILES="):
                    sel["web"] |= set(a.split("=", 1)[1].splitlines())
        elif unit["kind"] == "swift":
            args = [a.removeprefix("--arg=") for a in argv if a.startswith("--arg=")]
            sel["swift"] |= {(args[1], t) for t in args[2].split(",")}
        elif unit["kind"] == "rust":
            sel["rust"] = True
    return sel


def check(path: Path, metadata: Path, out: Path | None) -> int:
    data = json.loads(path.read_text())
    meta = json.loads(metadata.read_text())
    lanes = affected_tests.python_lane_tests(ROOT)
    plans: dict[str, dict] = {}
    seen_on = collections.defaultdict(set)
    for f in data["failures"]:
        seen_on[(f["kind"], f["test"])].add(f["pr"])
    rows = []
    for f in data["failures"]:
        head, pr = f["head"], f["pr"]
        row = {**f, "verdict": "", "why": ""}
        rows.append(row)
        if not ensure_commit(head, pr):
            row.update(verdict="unknown", why="head not fetchable")
            continue
        if head not in plans:
            base = git("merge-base", head, f"origin/{BASE_BRANCH}", check=False).stdout.strip()
            files = sorted({x for x in git("diff", "--name-only", "--no-renames", f"{base}...{head}").stdout.splitlines() if x})
            # The plan reads the tree's maps (tests, imports, registries) at the head: from a worktree of it.
            wt = replay_worktree()
            subprocess.run(["git", "-C", str(wt), "checkout", "--quiet", "--force", "--detach", head], check=True)
            plan = affected_tests.plan(wt, base, head, files, 4, False)
            crates = cargo_affected.plan(wt, meta, files)
            plans[head] = {"plan": plan, "sel": selected(plan), "crates": crates, "files": files,
                           "tree": None}
        p = plans[head]
        sel, plan = p["sel"], p["plan"]
        kind, test = f["kind"], f["test"]
        if sel["all"]:
            hit, why = True, "every suite (" + "; ".join(plan["reasons"][:2]) + ")"
        elif kind == "python":
            if p["tree"] is None:
                p["tree"] = tree_files(head)
            # A traceback names the runner's absolute path: take the tracked file it ends with.
            test = max((t for t in p["tree"] if test == t or test.endswith("/" + t)), key=len, default=test)
            row["test"] = test
            lane = lanes.get(test, "")
            hit = test in sel["python"] or "*" in sel["python"] or any(n["what"] == test for n in plan["not_run"])
            why = f"lane {lane or 'unregistered'}" + (" (listed as not run)" if any(n["what"] == test for n in plan["not_run"]) else "")
        elif kind == "web":
            hit, why = test in sel["web"], f"{len(sel['web'])} web files selected"
        elif kind in ("swift-file", "swift-suite"):
            if p["tree"] is None:
                p["tree"] = tree_files(head)
            targets = swift_target_of(p["tree"], test, kind)
            hit = bool(targets) and bool(targets & sel["swift"])
            why = f"targets {sorted(t for _, t in targets)[:3]} vs {len(sel['swift'])} selected"
        elif kind == "rust":
            c = p["crates"]
            hit = sel["rust"] and (c.workspace or test in c.crates)
            why = "workspace" if c.workspace else f"{len(c.crates)} crates selected"
        else:
            hit, why = False, "unknown kind"
        row.update(verdict="selected" if hit else "MISSED", why=why, also_failed_on=len(seen_on[(kind, test)]))
    missed = [r for r in rows if r["verdict"] == "MISSED"]
    own = [r for r in missed if r["also_failed_on"] <= 1]
    heads = len(plans)
    full = sum(1 for p in plans.values() if p["plan"]["all"])
    print(f"replay: {len(data['prs'])} merged PRs, {len(rows)} failed tests on {heads} heads; "
          f"{len(rows) - len(missed) - sum(r['verdict'] == 'unknown' for r in rows)} selected, {len(missed)} missed "
          f"({len(own)} seen on this PR only); {full} of {heads} heads planned every suite")
    for r in missed:
        print(f"  MISSED #{r['pr']} {r['head'][:12]} {r['kind']} {r['test']} ({r['why']}; failed on {r['also_failed_on']} PRs) "
              f"job {r['job']}")
    if out:
        summary = {"prs": len(data["prs"]), "failures": len(rows), "missed": len(missed), "missed_own": len(own),
                   "heads": heads, "heads_all": full,
                   "units_per_head": {h: len(p["plan"]["units"]) for h, p in plans.items()}, "rows": rows}
        out.write_text(json.dumps(summary, indent=1, default=str))
    return 1 if missed else 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0], epilog=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--since", required=True)
    c.add_argument("--until", default="9999")
    c.add_argument("--out", type=Path, required=True)
    c.add_argument("--max-runs", type=int, default=400)
    k = sub.add_parser("check")
    k.add_argument("failures", type=Path)
    k.add_argument("--metadata", type=Path, required=True)
    k.add_argument("--json", type=Path)
    args = parser.parse_args(argv)
    if args.cmd == "collect":
        return collect(args.since, args.until, args.out, args.max_runs)
    return check(args.failures, args.metadata, args.json)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
