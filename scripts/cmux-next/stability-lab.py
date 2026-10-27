#!/usr/bin/env python3
"""Stability lab (plans/cmux-next/chrome-parity/p10-stability.md, section 3A).

The lab runs lanes on each new feat-cmux-next tip that has a fleet DEV build. It does not build every
merge. Instead, it proves that every landed commit is in a tip that passed the fast lanes; bisect assigns
each finding to its merge. ClusterFuzz does the same: it fuzzes revisions, not every CL, and its
regression range bisect (clusterfuzz/src/clusterfuzz/_internal/bot/tasks/utasks/regression_task.py)
gives a crash to a commit.

Subcommands:

    coverage [--since 72h] [--ref origin/feat-cmux-next] [--json] [--json-out PATH] [--check]
        Lists the first-parent commits of REF that landed in the window, newest first. For each commit it
        lists the lab tips that contain it and the lanes that passed and failed on each tip. A commit is
        covered only when a tip that contains it (the commit itself or a later one) passed every fast
        lane of the registry. `--check` exits 1 when a commit is not covered.

    signatures DIR... [--lane L] [--major M] [--sha SHA] [--json-out PATH]
        Reads every artifact a lane left in DIR (recursively) with crash_signature.py and prints its
        findings, the `findings` of a cmux-stability-run/v1 file (stability_issues.py sync). Crashes and
        non-crash failures alike: crash and hang reports, Rust panic and hang JSONL (hangs, blocking stalls,
        slow polls), sanitizer output, BadMessage closes in logs, invariant records, and ErrorJournal
        segments (page JS errors, faults; one directory's segments are one journal, the newest snapshot of
        each entry counts). Each finding names its artifact relative to DIR.

Inputs (the runner, task p10-stability-003, writes the state; this file reads it):

    stability-lanes.json   {"lanes": [{"id": "smoke-26", "tier": "fast" | "long", ...}]}
    state.json             {"tips": [{"sha": "<sha>", "lanes": {"<lane id>": {"status": "passed"}}}]}

`tips` may also be an object keyed by sha. A lane value is a status string, an object with `status`, or
a list of runs (the last run counts). Only `passed` and `failed` are verdicts; every other status
(queued, running, cancelled, infra) is reported as pending and does not pass the lane.

Runs anywhere with git and python3; `coverage` reads only git and the two JSON files.
"""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LANES = ROOT / "scripts/cmux-next/stability-lanes.json"
DEFAULT_STATE = ROOT / "artifacts/stability-lab/state.json"
DEFAULT_REF = "origin/feat-cmux-next"
COVERAGE_SCHEMA = "cmux-stability-coverage/v1"

PASSED = "passed"
FAILED = "failed"


class LabError(Exception):
    """An input the lab cannot use: a missing file, bad JSON, an unknown ref or window."""


# --- inputs ---------------------------------------------------------------------------------------


def load_json(path: Path, what: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        raise LabError(f"{what} not found: {path}") from None
    try:
        return json.loads(text)
    except json.JSONDecodeError as error:
        raise LabError(f"{what} is not JSON: {path}: {error}") from None


def lane_entries(registry: object) -> list[dict]:
    lanes = registry.get("lanes") if isinstance(registry, dict) else None
    if isinstance(lanes, dict):
        return [{"id": lane_id, **(spec if isinstance(spec, dict) else {})} for lane_id, spec in lanes.items()]
    if isinstance(lanes, list) and all(isinstance(lane, dict) and isinstance(lane.get("id"), str) for lane in lanes):
        return lanes
    raise LabError('lanes registry needs "lanes": a list of objects with an "id", or an object keyed by id')


def fast_lanes(registry: object) -> list[str]:
    lanes = sorted(lane["id"] for lane in lane_entries(registry) if lane.get("tier") == "fast")
    if not lanes:
        # With no fast lane every commit would count as covered; refuse instead.
        raise LabError('lanes registry declares no lane with "tier": "fast"')
    return lanes


def lane_status(value: object) -> str:
    if isinstance(value, list):
        if not value:
            return "pending"
        value = value[-1]
    if isinstance(value, dict):
        value = value.get("status")
    return value if isinstance(value, str) and value else "pending"


def lab_tips(state: object) -> dict[str, dict[str, str]]:
    """Returns {tip sha as written: {lane id: status}}."""
    tips = state.get("tips") if isinstance(state, dict) else None
    if isinstance(tips, dict):
        items = [(sha, entry) for sha, entry in tips.items()]
    elif isinstance(tips, list):
        items = [(entry.get("sha"), entry) for entry in tips if isinstance(entry, dict)]
    else:
        raise LabError('lab state needs "tips": a list of {"sha", "lanes"} or an object keyed by sha')
    result: dict[str, dict[str, str]] = {}
    for sha, entry in items:
        if not isinstance(sha, str) or not sha:
            raise LabError("lab state has a tip with no sha")
        lanes = entry.get("lanes", {}) if isinstance(entry, dict) else {}
        if not isinstance(lanes, dict):
            raise LabError(f"lab state tip {sha} has lanes that are not an object")
        statuses = result.setdefault(sha, {})
        statuses.update({lane: lane_status(value) for lane, value in lanes.items()})
    return result


_DURATION = re.compile(r"^(\d+)([mhdw])$")
_UNIT_SECONDS = {"m": 60, "h": 3600, "d": 86400, "w": 604800}


def since_epoch(since: str, now: float) -> int:
    """`72h`, `3d`, `90m`, `1w`, or an ISO date/time (UTC when it has no zone)."""
    match = _DURATION.match(since.strip())
    if match:
        return int(now) - int(match.group(1)) * _UNIT_SECONDS[match.group(2)]
    try:
        moment = dt.datetime.fromisoformat(since.strip())
    except ValueError:
        raise LabError(f"--since {since!r}: use 72h, 3d, 90m, 1w or an ISO date") from None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=dt.timezone.utc)
    return int(moment.timestamp())


# --- git ------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Commit:
    sha: str
    committed_at: int
    subject: str
    first_parent: str | None


class Git:
    def __init__(self, repo: Path) -> None:
        self.repo = repo

    def run(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            raise LabError(f"git {' '.join(args)}: {result.stderr.strip() or result.returncode}")
        return result

    def resolve(self, rev: str) -> str | None:
        result = self.run("rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}", check=False)
        return result.stdout.strip() if result.returncode == 0 else None

    def first_parent_since(self, ref: str, since: int) -> list[Commit]:
        """First-parent commits of ref committed at or after since, newest first."""
        out = self.run(
            "log", "--first-parent", f"--since=@{since}", "--format=%H%x1f%ct%x1f%P%x1f%s", ref, "--"
        ).stdout
        commits = []
        for line in out.splitlines():
            sha, committed, parents, subject = line.split("\x1f", 3)
            if int(committed) < since:
                continue
            commits.append(Commit(sha, int(committed), subject, parents.split()[0] if parents else None))
        return commits

    def reachable(self, tip: str, boundary: str | None) -> set[str]:
        """Commits reachable from tip that are not reachable from boundary."""
        args = ["rev-list", tip] + ([f"^{boundary}"] if boundary else [])
        return set(self.run(*args).stdout.split())


# --- coverage -------------------------------------------------------------------------------------


@dataclass
class TipLanes:
    tip: str
    passed: list[str]
    failed: list[str]
    pending: list[str]
    fast_green: bool

    def as_json(self) -> dict:
        return {
            "tip": self.tip,
            "lanes_passed": self.passed,
            "lanes_failed": self.failed,
            "lanes_pending": self.pending,
            "fast_lanes_passed": self.fast_green,
        }


@dataclass
class CommitCoverage:
    commit: Commit
    tips: list[TipLanes] = field(default_factory=list)

    @property
    def covering_tip(self) -> str | None:
        return next((tip.tip for tip in self.tips if tip.fast_green), None)

    def as_json(self) -> dict:
        return {
            "sha": self.commit.sha,
            "committed_at": self.commit.committed_at,
            "subject": self.commit.subject,
            "covered": self.covering_tip is not None,
            "covering_tip": self.covering_tip,
            "tips": [tip.as_json() for tip in self.tips],
        }


def tip_lanes(tip: str, statuses: dict[str, str], fast: list[str]) -> TipLanes:
    passed = sorted(lane for lane, status in statuses.items() if status == PASSED)
    failed = sorted(lane for lane, status in statuses.items() if status == FAILED)
    pending = sorted({lane for lane, status in statuses.items() if status not in (PASSED, FAILED)}
                     | {lane for lane in fast if lane not in statuses})
    return TipLanes(tip, passed, failed, pending, all(statuses.get(lane) == PASSED for lane in fast))


def coverage(git: Git, ref: str, since: int, fast: list[str], tips: dict[str, dict[str, str]]) -> dict:
    head = git.resolve(ref)
    if head is None:
        raise LabError(f"unknown ref {ref}; fetch it first")
    commits = git.first_parent_since(ref, since)
    rows = [CommitCoverage(commit) for commit in commits]
    unknown_tips = []
    resolved: dict[str, dict[str, str]] = {}
    for written, statuses in tips.items():
        sha = git.resolve(written)
        if sha is None:
            unknown_tips.append(written)
        else:
            resolved.setdefault(sha, {}).update(statuses)
    if rows and resolved:
        # Newest tip first (commit date), so each commit lists the tip a reader acts on first.
        newest_first = git.run("rev-list", "--no-walk=sorted", *resolved).stdout.split()
        # A tip reaches a window commit only through the window's own history, so each walk stops at
        # the parent of the oldest window commit.
        boundary = commits[-1].first_parent
        position = {commit.sha: index for index, commit in enumerate(commits)}
        for sha in newest_first:
            lanes = tip_lanes(sha, resolved[sha], fast)
            for commit_sha in git.reachable(sha, boundary) & position.keys():
                rows[position[commit_sha]].tips.append(lanes)
    covered = sum(1 for row in rows if row.covering_tip)
    return {
        "schema": COVERAGE_SCHEMA,
        "ref": ref,
        "head": head,
        "since": since,
        "fast_lanes": fast,
        "summary": {
            "commits": len(rows),
            "covered": covered,
            "uncovered": len(rows) - covered,
            "percent": round(100.0 * covered / len(rows), 1) if rows else 100.0,
        },
        "commits": [row.as_json() for row in rows],
        "unknown_tips": sorted(unknown_tips),
    }


def coverage_table(report: dict) -> str:
    header = ("COMMIT", "LANDED (UTC)", "COVERED", "TIP", "PASSED", "PENDING", "FAILED", "TIPS", "SUBJECT")
    lines = []
    for row in report["commits"]:
        shown = next((tip for tip in row["tips"] if tip["tip"] == row["covering_tip"]), None)
        shown = shown or (row["tips"][0] if row["tips"] else None)
        landed = dt.datetime.fromtimestamp(row["committed_at"], dt.timezone.utc).strftime("%Y-%m-%d %H:%M")
        lines.append((
            row["sha"][:11],
            landed,
            "yes" if row["covered"] else "NO",
            shown["tip"][:11] if shown else "-",
            str(len(shown["lanes_passed"])) if shown else "-",
            str(len(shown["lanes_pending"])) if shown else "-",
            (",".join(shown["lanes_failed"]) or "-") if shown else "-",
            str(len(row["tips"])),
            row["subject"][:60],
        ))
    widths = [max(len(cells[index]) for cells in [header, *lines]) for index in range(len(header) - 1)]
    out = ["  ".join(cell.ljust(width) for cell, width in zip(cells, widths)) + "  " + cells[-1]
           for cells in [header, *lines]]
    summary = report["summary"]
    out.append("")
    out.append(
        f"covered {summary['covered']}/{summary['commits']} ({summary['percent']:.1f} %) of {report['ref']} "
        f"first-parent commits; fast lanes: {', '.join(report['fast_lanes'])}"
    )
    if report["unknown_tips"]:
        out.append(f"lab tips not in this clone (fetch them): {', '.join(report['unknown_tips'])}")
    return "\n".join(out)


def cmd_coverage(args: argparse.Namespace) -> int:
    fast = fast_lanes(load_json(Path(args.lanes), "lanes registry"))
    tips = lab_tips(load_json(Path(args.state), "lab state"))
    report = coverage(Git(Path(args.repo)), args.ref, since_epoch(args.since, time.time()), fast, tips)
    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2) if args.json else coverage_table(report))
    return 1 if args.check and report["summary"]["uncovered"] else 0


# --- signatures -----------------------------------------------------------------------------------

# Artifacts larger than this are a lane's bulk output (videos, core files, traces), not a report.
ARTIFACT_MAX_BYTES = 64 << 20
# Suffixes of reports and logs; anything else in a lane's directory (images, videos, archives) is skipped.
REPORT_SUFFIXES = (".ips", ".crash", ".jsonl", ".ndjson", ".json", ".log", ".txt", ".out", ".err")


def load_crash_signature():
    if "crash_signature" in sys.modules:
        return sys.modules["crash_signature"]
    spec = importlib.util.spec_from_file_location("crash_signature", Path(__file__).resolve().with_name(
        "crash_signature.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules["crash_signature"] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


def artifact_paths(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    if not root.is_dir():
        raise LabError(f"artifact directory not found: {root}")
    return sorted(path for path in root.rglob("*")
                  if path.is_file() and path.suffix.lower() in REPORT_SUFFIXES
                  and path.stat().st_size <= ARTIFACT_MAX_BYTES)


def lane_findings(roots: list[Path], lane: str = "", major: str = "", sha: str = "") -> list[dict]:
    """Every signature in the lanes' artifacts as a stability_issues.py finding, in path order."""
    cs = load_crash_signature()
    ignore = cs.IgnoreList.load()
    findings = []
    for root in roots:
        for group in cs.artifact_groups(artifact_paths(root)):
            try:
                signatures = cs.signatures_from_group(group, ignore)
            except OSError as error:
                raise LabError(f"cannot read {group[0]}: {error}") from None
            for path, signature in signatures:
                artifact = path.name if root.is_file() else path.relative_to(root).as_posix()
                finding = signature.to_json()
                finding["source"] = artifact
                finding.update({key: value for key, value in (("lane", lane), ("major", major), ("sha", sha))
                                if value})
                findings.append(finding)
    return findings


def cmd_signatures(args: argparse.Namespace) -> int:
    findings = lane_findings([Path(path) for path in args.paths], args.lane, args.major, args.sha)
    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(json.dumps({"findings": findings}, indent=2) + "\n", encoding="utf-8")
    for finding in findings:
        print(json.dumps(finding, sort_keys=True))
    return 0


# --- entry ----------------------------------------------------------------------------------------


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="stability-lab.py", description=__doc__.split("\n\n")[0])
    commands = root.add_subparsers(dest="command", required=True)

    cov = commands.add_parser("coverage", help="landed commits and the lab tips that cover them")
    cov.add_argument("--since", default="72h", help="window: 72h, 3d, 90m, 1w or an ISO date (default 72h)")
    cov.add_argument("--ref", default=DEFAULT_REF, help=f"branch whose first-parent commits count (default {DEFAULT_REF})")
    cov.add_argument("--repo", default=str(ROOT), help="git checkout to read (default: this one)")
    cov.add_argument("--lanes", default=str(DEFAULT_LANES), help="lanes registry JSON")
    cov.add_argument("--state", default=os.environ.get("CMUX_STABILITY_LAB_STATE", str(DEFAULT_STATE)),
                     help="lab state JSON (default $CMUX_STABILITY_LAB_STATE or artifacts/stability-lab/state.json)")
    cov.add_argument("--json", action="store_true", help="print JSON instead of the table")
    cov.add_argument("--json-out", help="also write the JSON report to this path")
    cov.add_argument("--check", action="store_true", help="exit 1 when a commit is not covered")
    cov.set_defaults(handler=cmd_coverage)

    sig = commands.add_parser("signatures", help="findings (crashes and non-crash failures) in lane artifacts")
    sig.add_argument("paths", nargs="+", help="a lane's artifact directory, or one artifact")
    sig.add_argument("--lane", default="", help="the lane that made the artifacts")
    sig.add_argument("--major", default="", help="the macOS major it ran on")
    sig.add_argument("--sha", default="", help="the build's commit (stability_issues.py defaults it to the tip)")
    sig.add_argument("--json-out", help='also write {"findings": [...]} to this path')
    sig.set_defaults(handler=cmd_signatures)
    return root


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.handler(args)
    except LabError as error:
        print(f"stability-lab: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
