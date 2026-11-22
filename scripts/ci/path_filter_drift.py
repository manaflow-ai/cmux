#!/usr/bin/env python3
"""Path-filter drift: each workflow's `paths:` filter against the files its jobs read, replayed on merged PRs.

A report, not a check: it never fails a PR and exits 0 whatever it finds. Two directions:

  too wide    the filter starts the workflow for a PR none of whose files the workflow reads. Each such PR is a
              run that could not have caught anything; replayed over the window's merged PRs (one first-parent
              commit on the base branch per squash-merged PR) and priced at the workflow's mean runner-minutes per
              run, it is minutes wasted.
  too narrow  a file a test the workflow runs reads is outside the filter: a red that can read green. This is
              scripts/ci/workflow_paths_cover_inputs.py's finding, listed here as is (it stays the one detector).

What a workflow "reads" is a lower bound built from its own text, never a guess about a toolchain:
  - the files its tests read, transitively (workflow_paths_cover_inputs.Walker);
  - every directory a step runs in (`working-directory:`, a literal `cd DIR`): a build or a test runner run there
    reads that tree;
  - the directory of every manifest a step names (Cargo.toml, Package.swift, package.json, go.mod, *.xcodeproj,
    *.xcworkspace, project.yml, bun.lock), and every tracked file or directory a step or a local action's `with:`
    names by a literal path;
  - the workflow file itself and every local reusable workflow or composite action it calls.
A PR counts as unread only when none of its files falls under any of these. A workflow whose reads cannot be
bounded (a step that runs from the repository root without naming a path, e.g. `make test`; a script that starts
processes it builds at run time, e.g. a step picker) has no read set and is listed under "unbounded", never as too wide: that is what keeps a too-wide count from being a false one.

    python3 scripts/ci/path_filter_drift.py --since 2026-11-21T03:00Z --until 2026-11-22T03:00Z \
        [--base origin/feat-cmux-next] [--minutes RECORDS.jsonl.gz] [--json OUT] [--markdown OUT]

RECORDS is build-fleet/data/ci_per_pr.py's --save output (fields workflow / workflow_path, run, seconds); without it
the report gives run counts only.
"""
from __future__ import annotations

import argparse
import gzip
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_paths_cover_inputs as cover  # noqa: E402
import gh_expressions  # noqa: E402

MANIFESTS = re.compile(r"(^|/)(Cargo\.toml|Package\.swift|package\.json|go\.mod|project\.yml|bun\.lockb?|"
                       r"[^/]+\.xcodeproj|[^/]+\.xcworkspace)$")
PATH_TOKEN = re.compile(r"[A-Za-z0-9_.@+-][A-Za-z0-9_./@+-]*")
# A step that runs one of these from the repository root without naming a path reads an unbounded tree.
TREE_TOOLS = re.compile(r"(^|[\s;&|(])(make|cargo|swift|xcodebuild|bun|npm|pnpm|yarn|npx|bunx|go|tuist|turbo|"
                        r"just|nix)(\s|$)")


def under(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/") if prefix else True


class Reads:
    """A workflow event's read set: files and directory prefixes, or unbounded with the reason."""

    def __init__(self):
        self.files: set[str] = set()
        self.dirs: set[str] = set()
        self.unbounded: list[str] = []

    def covers(self, path: str) -> bool:
        if path in self.files:
            return True
        parts = path.split("/")
        return any("/".join(parts[:n]) in self.dirs for n in range(1, len(parts)))


def literal_paths(repo: cover.Repo, text: str, cwd_rel: str) -> tuple[set[str], set[str]]:
    files, dirs = set(), set()
    for token in PATH_TOKEN.findall(text):
        token = token.strip("./") if token.startswith("./") else token.rstrip("/")
        if not token or "/" not in token and "." not in token:
            continue  # a bare word (`echo`, `main`) is not a path
        for base in (cwd_rel, ""):
            rel = os.path.normpath(os.path.join(base, token)) if base else os.path.normpath(token)
            if rel.startswith(".."):
                continue
            if repo.is_file(rel):
                files.add(rel)
                if MANIFESTS.search(rel):
                    dirs.add(rel.rpartition("/")[0])
                break
            if repo.is_dir(rel) and rel:
                (dirs if MANIFESTS.search(rel) or rel.count("/") >= 1 else dirs).add(rel)
                break
    return files, dirs


def local_calls(document) -> list[str]:
    out = []
    for job in cover.mapping(document.get("jobs")).values():
        if not isinstance(job, dict):
            continue
        uses = str(job.get("uses") or "")
        if uses.startswith("./"):
            out.append(uses[2:])
        for step in job.get("steps") or []:
            if isinstance(step, dict) and str(step.get("uses") or "").startswith("./"):
                out.append(str(step["uses"])[2:])
    return out


def with_values(document) -> list[str]:
    out = []
    for job in cover.mapping(document.get("jobs")).values():
        if not isinstance(job, dict):
            continue
        out.extend(str(v) for v in cover.mapping(job.get("with")).values())
        for step in job.get("steps") or []:
            if isinstance(step, dict):
                out.extend(str(v) for v in cover.mapping(step.get("with")).values())
    return out


ROUTER = re.compile(r"git\s+diff|gh\s+pr\s+diff|changed[-_]files|pulls/[^ ]*/files|/compare/|detect_[a-z_]+\.py|"
                    r"pr_trigger_paths\.py|docs_only_paths\.py|\.py\s+route\b")
# A step that hands the tree to another run or machine: what that run reads is not in this file.
HANDOFF = re.compile(r"gh\s+workflow\s+run|/dispatches\b|repository_dispatch|workflow_dispatch\s+--|"
                     r"fleet_dispatch")
SCRIPT = re.compile(r"\.(sh|bash|py|ts|mts|js|mjs|rb|pl)$")


BUILT_COMMAND = re.compile(r"\b(subprocess\.(run|call|check_call|check_output|Popen)|os\.(system|exec\w*|spawn\w*))\(")


def runs_built_commands(repo: cover.Repo, rel: str) -> bool:
    """A non-test script that starts processes: what they read is decided at run time, not in this text."""
    try:
        return bool(BUILT_COMMAND.search((repo.root / rel).read_text(errors="replace")))
    except OSError:
        return True


def composite_runs(repo: cover.Repo, document) -> set[str]:
    """Run texts of local composite actions (toolchain setup): their reads are listed, never scored as a build."""
    out = set()
    for target in local_calls(document):
        for action in ("action.yml", "action.yaml"):
            path = repo.root / target / action
            if path.is_file():
                steps = cover.mapping(cover.mapping(cover.load_quietly(path, None)).get("runs")).get("steps")
                out.update(str(s["run"]) for s in steps or [] if isinstance(s, dict) and "run" in s)
    return out


def read_set(repo: cover.Repo, walker: cover.Walker, name: str, document, event: str) -> Reads:
    reads = Reads()
    reads.router: list[str] = []
    reads.files.add(name)
    pending, seen = list(local_calls(document)), set()
    while pending:
        target = pending.pop()
        if target in seen:
            continue
        seen.add(target)
        if repo.is_file(target):
            reads.files.add(target)
            nested = cover.load_quietly(repo.root / target, None)
            if isinstance(nested, dict):
                pending.extend(local_calls(nested))
                for value in with_values(nested):
                    files, dirs = literal_paths(repo, value, "")
                    reads.files |= files
                    reads.dirs |= dirs
        else:
            for action in ("action.yml", "action.yaml"):
                if repo.is_file(f"{target}/{action}"):
                    reads.dirs.add(target)
    for value in with_values(document):
        files, dirs = literal_paths(repo, value, "")
        reads.files |= files
        reads.dirs |= dirs
    setup = composite_runs(repo, document)
    for run, workdir, env in cover.steps_for(repo, document, event):
        if "$" in workdir:
            reads.unbounded.append(f"working-directory {workdir}")
            continue
        cwd_rel = os.path.normpath(workdir) if workdir and workdir != "." else ""
        if cwd_rel:
            reads.dirs.add(cwd_rel)
        try:
            text = gh_expressions.EXPRESSION.sub("$__EXPR", run)
        except gh_expressions.Unterminated:
            reads.unbounded.append("a step whose ${{ never ends")
            continue
        first = text.strip().splitlines()[0][:60] if text.strip() else ""
        files, dirs = literal_paths(repo, text, cwd_rel)
        reads.files |= files
        reads.dirs |= dirs
        match = ROUTER.search(text)
        if match:
            line = next(l for l in text.splitlines() if match.group(0) in l)
            reads.router.append(line.strip()[:70])
        match = HANDOFF.search(text)
        if match and run not in setup:
            line = next(l for l in text.splitlines() if match.group(0) in l)
            reads.unbounded.append(f"hands off: `{line.strip()[:60]}`")
        step_dir = cwd_rel
        scripts: list[str] = []
        for words in cover.shell_words(text, None, {}, []):
            if words[0] == "cd" and len(words) == 2:
                target = os.path.normpath(os.path.join(cwd_rel, words[1]))
                if "$" in words[1] or not repo.is_dir(target):
                    if run not in setup:
                        reads.unbounded.append(f"cd {words[1][:40]}")
                    continue
                reads.dirs.add(target)
                cwd_rel = step_dir = target
                continue
            scripts += [p for p in walker.command_entries(words, repo.abs(cwd_rel)) if SCRIPT.search(p)]
        if run in setup:
            continue
        if not step_dir and TREE_TOOLS.search(text) and not dirs and not any(MANIFESTS.search(f) for f in files):
            reads.unbounded.append(f"runs `{first}` from the root")
        cwd = repo.abs(cwd_rel)
        for script in dict.fromkeys(scripts + walker.entries(text, cwd, env)):
            if not script.endswith((".py", ".sh", ".bash")):
                reads.unbounded.append(f"{script} (its reads are not followed)")
                reads.files.add(script)
                continue
            before = {k: set(v) for k, v in walker.unknown.items()}
            closure = walker.closure(script, cwd)
            reads.files.update(closure)
            grew = [k for k, v in walker.unknown.items() if v - before.get(k, set())]
            known = [k for k in closure if walker.unknown.get(k)]
            if grew or known:
                reads.unbounded.append(f"{script} reads paths built at run time")
            runners = [f for f in closure if f.endswith(".py") and not cover.is_test(f) and runs_built_commands(repo, f)]
            if runners:
                reads.unbounded.append(f"{runners[0]} runs commands it builds at run time")
    reads.dirs.discard("")
    return reads


def merged_changes(root: Path, base: str, since: str, until: str) -> list[tuple[str, list[str]]]:
    """(sha, files) for each first-parent commit on base in the window: one per squash-merged PR."""
    out = subprocess.run(["git", "-C", str(root), "log", "--first-parent", "--no-renames", "--format=@%H",
                          "--name-only", f"--since={since}", f"--until={until}", base],
                         capture_output=True, text=True, check=True).stdout
    commits, sha = [], None
    for line in out.splitlines():
        if line.startswith("@"):
            sha = line[1:]
            commits.append((sha, []))
        elif line.strip() and commits:
            commits[-1][1].append(line.strip())
    return commits


def minutes_per_run(records: Path | None, names: dict[str, str]) -> tuple[dict[str, float], int, int]:
    """{workflow file: mean runner-minutes per run}, from ci_per_pr records (PR segment only)."""
    if records is None:
        return {}, 0, 0
    per_run: dict[tuple[str, int], float] = defaultdict(float)
    seen = mapped = 0
    with gzip.open(records, "rt") as handle:
        for line in handle:
            record = json.loads(line)
            if record.get("seg") not in (None, "pr"):
                continue
            seen += 1
            path = record.get("workflow_path") or names.get(record.get("workflow") or "")
            if not path:
                continue
            mapped += 1
            path = path.split("@", 1)[0]
            per_run[(path, record.get("run"))] += (record.get("seconds") or 0) / 60
    totals: dict[str, list[float]] = defaultdict(list)
    for (path, _), minutes in per_run.items():
        totals[path].append(minutes)
    return {p: (sum(v) / len(v), len(v)) for p, v in totals.items()}, seen, mapped


def replay_areas(root: Path, commits: list[tuple[str, list[str]]], kind: str, patterns: list[str]) -> dict:
    """ci.yml's own router (detect_ci_change_areas.py) on each PR its filter admits: the PRs it picks no area for."""
    picked_none, admitted, failed = [], 0, 0
    by_top: dict[str, int] = defaultdict(int)
    for sha, files in commits:
        if not any(cover.admits(kind, patterns, f) for f in files):
            continue
        admitted += 1
        result = subprocess.run([sys.executable, "scripts/ci/detect_ci_change_areas.py", "--event-name",
                                 "pull_request", "--base-sha", f"{sha}^1", "--head-sha", sha], cwd=root,
                                capture_output=True, text=True, timeout=300)
        areas = re.search(r"Resolved areas: (.*)", result.stdout + result.stderr)
        if result.returncode or not areas:
            failed += 1
            continue
        if "=true" not in areas.group(1):
            picked_none.append(sha)
            for top in {f.split("/", 1)[0] if "/" in f else f for f in files}:
                by_top[top] += 1
    return {"admitted": admitted, "no_area": len(picked_none), "failed": failed,
            "no_area_top_dirs": dict(sorted(by_top.items(), key=lambda kv: -kv[1])[:8]), "no_area_shas": picked_none}


def report(root: Path, base: str, since: str, until: str, records: Path | None, areas: bool = False) -> dict:
    branch = base.split("/", 1)[-1]
    repo = cover.Repo.load(root)
    walker = cover.Walker(repo)
    commits = merged_changes(root, base, since, until)
    names, rows, unbounded = {}, [], {}
    workflows = sorted((root / ".github/workflows").glob("*.y*ml"))
    documents = {}
    for workflow in workflows:
        name = f".github/workflows/{workflow.name}"
        try:
            document = cover.load_yaml(workflow)
        except Exception:  # noqa: BLE001 - an unreadable workflow is skipped (the detector lists it)
            continue
        if isinstance(document, dict):
            documents[name] = document
            if document.get("name"):
                names[str(document["name"])] = name
    mean, seen, mapped = minutes_per_run(records, names)
    for name, document in documents.items():
        events = cover.filtered_events(document)
        event = next((e for e in ("pull_request", "pull_request_target") if e in events), None)
        if event is None:
            continue
        kind, patterns = events[event]
        config = cover.mapping(cover.triggers(document).get(event))
        branches = [str(b) for b in config.get("branches") or []]
        if branches and not any(cover.glob_regex(b).match(branch) for b in branches if not b.startswith("!")):
            per_run, runs = mean.get(name, (0.0, 0))
            rows.append({"workflow": name, "event": event, "filter": kind, "patterns": patterns, "started": 0,
                         "unread": 0, "skipped": 0, "runs_observed": runs, "minutes_per_run": round(per_run, 1),
                         "minutes_observed": round(per_run * runs), "wasted_minutes": None, "router": [],
                         "other_base": branches, "unread_by_pattern": {}, "read_dirs": [], "read_files": 0})
            continue
        reads = read_set(repo, walker, name, document, event)
        started = unread = 0
        admitted_unread: dict[str, int] = defaultdict(int)
        for _, files in commits:
            admitted = [f for f in files if cover.admits(kind, patterns, f)]
            if not admitted:
                continue
            started += 1
            if not any(reads.covers(f) for f in files):
                unread += 1
                for f in admitted:
                    for pattern in patterns:
                        if not pattern.startswith("!") and cover.glob_regex(pattern).match(f):
                            admitted_unread[pattern] += 1
        per_run, runs = mean.get(name, (0.0, 0))
        share = unread / started if started else 0.0
        row = {"workflow": name, "event": event, "filter": kind, "patterns": patterns,
               "started": started, "unread": unread, "skipped": len(commits) - started,
               "runs_observed": runs, "minutes_per_run": round(per_run, 1),
               "minutes_observed": round(per_run * runs),
               "wasted_minutes": round(share * per_run * runs),
               "router": sorted(set(reads.router))[:2],
               "unread_by_pattern": dict(sorted(admitted_unread.items(), key=lambda kv: -kv[1])[:5]),
               "read_dirs": sorted(reads.dirs)[:40], "read_files": len(reads.files)}
        if reads.unbounded:
            unbounded[name] = sorted(set(reads.unbounded))[:3]
            row["unbounded"] = True
            row["wasted_minutes"] = None
        rows.append(row)
    ci_areas = None
    if areas and ".github/workflows/ci.yml" in documents:
        kind, patterns = cover.filtered_events(documents[".github/workflows/ci.yml"])["pull_request"]
        ci_areas = replay_areas(root, commits, kind, patterns)
    gaps, _, _ = cover.find_gaps(root)
    rows.sort(key=lambda r: -(r["wasted_minutes"] or 0))
    bounded = [r for r in rows if not r.get("unbounded") and not r["router"] and not r.get("other_base")
               and r["started"]]
    matching = [r for r in bounded if r["unread"] <= 0.05 * r["started"]]
    return {"base": base, "head": subprocess.run(["git", "-C", str(root), "rev-parse", base], capture_output=True,
                                                 text=True).stdout.strip(),
            "since": since, "until": until, "prs": len(commits), "records_seen": seen, "records_mapped": mapped,
            "workflows": rows, "unbounded": unbounded,
            "matching_within_5pct": f"{len(matching)}/{len(bounded)}",
            "too_narrow": [g.__dict__ for g in gaps], "ci_areas": ci_areas}


def markdown(data: dict) -> str:
    rows = data["workflows"]
    lines = [f"# Path-filter drift, {data['since']} to {data['until']}", "",
             f"Base `{data['base']}` at `{data['head'][:12]}`; {data['prs']} merged PRs replayed. Minutes from "
             f"{data['records_mapped']}/{data['records_seen']} PR job records whose workflow file is known; "
             "wasted = runs observed x unread share x minutes per run.", "",
             f"Bounded filters matching their reads within 5% of started runs: {data['matching_within_5pct']}.", "",
             "## Too wide: runs that read none of the PR's files", "",
             "| workflow | PRs admitted | unread | runs | min/run | wasted min | top admitting patterns |",
             "|---|---:|---:|---:|---:|---:|---|"]
    for row in rows:
        if row.get("unbounded") or row["router"] or row.get("other_base") or not row["unread"]:
            continue
        patterns = ", ".join(f"`{p}` {n}" for p, n in list(row["unread_by_pattern"].items())[:3])
        lines.append(f"| {row['workflow'].rsplit('/', 1)[-1]} | {row['started']} | {row['unread']} | "
                     f"{row['runs_observed']} | {row['minutes_per_run']} | {row['wasted_minutes']} | {patterns} |")
    lines += ["", "## Routers: the filter admits, a step reads the diff and decides inside", "",
              "Their filter is wide by design; the minutes are what each started run costs before it decides.", "",
              "| workflow | PRs admitted | runs | min/run | minutes | router step |", "|---|---:|---:|---:|---:|---|"]
    for row in sorted((r for r in rows if r["router"] and not r.get("unbounded")), key=lambda r: -r["minutes_observed"]):
        lines.append(f"| {row['workflow'].rsplit('/', 1)[-1]} | {row['started']} | {row['runs_observed']} | "
                     f"{row['minutes_per_run']} | {row['minutes_observed']} | `{row['router'][0]}` |")
    ci = data.get("ci_areas")
    if ci:
        row = by_name_early = next((r for r in rows if r["workflow"].endswith("/ci.yml")), None)
        share = ci["no_area"] / ci["admitted"] if ci["admitted"] else 0
        lines += ["", "## ci.yml: its filter admits, its own router picks no area", "",
                  f"detect_ci_change_areas.py replayed on the {ci['admitted']} admitted PRs: {ci['no_area']} "
                  f"({share:.0%}) resolve every area false ({ci['failed']} could not be replayed). Upper bound on "
                  f"their minutes: {round(share * row['minutes_observed']) if row else 0} of "
                  f"{row['minutes_observed'] if row else 0} (the always-on jobs still run for them).", "",
                  "Top-level paths in those PRs: " + ", ".join(f"`{k}` {v}" for k, v in ci["no_area_top_dirs"].items())]
    lines += ["", "## Too narrow: a test reads a file its filter does not admit", "",
              "From scripts/ci/workflow_paths_cover_inputs.py.", ""]
    for gap in data["too_narrow"]:
        lines.append(f"- {gap['workflow'].rsplit('/', 1)[-1]} ({gap['event']}): `{gap['input']}` via "
                     f"{' -> '.join(gap['chain'])}")
    lines += ["", "## Unbounded: reads not provable from the workflow text, never counted as too wide", "",
              "| workflow | runs | minutes | why |", "|---|---:|---:|---|"]
    by_name = {r["workflow"]: r for r in rows}
    for name, why in sorted(data["unbounded"].items(), key=lambda kv: -by_name[kv[0]]["minutes_observed"]):
        row = by_name[name]
        lines.append(f"| {name.rsplit('/', 1)[-1]} | {row['runs_observed']} | {row['minutes_observed']} | "
                     f"{'; '.join(w.replace('|', '/') for w in why)} |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--base", default="origin/feat-cmux-next")
    parser.add_argument("--since", required=True)
    parser.add_argument("--until", required=True)
    parser.add_argument("--minutes", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--replay-ci-areas", action="store_true", help="also replay ci.yml's area router per PR")
    parser.add_argument("--markdown", type=Path)
    args = parser.parse_args(argv)
    data = report(Path(args.root), args.base, args.since, args.until, args.minutes, args.replay_ci_areas)
    if args.json:
        args.json.write_text(json.dumps(data, indent=1) + "\n")
    text = markdown(data)
    if args.markdown:
        args.markdown.write_text(text)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
