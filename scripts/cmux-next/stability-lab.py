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

    lanes [--check] [--json]
        Lists the registry's lanes (tier, host class and group, minutes). `--check` exits 1 when a lane
        lacks a field the runner needs, names an unknown placeholder, result parser or host group, or its
        script is missing.

    signatures --lane ID --out DIR [--exit-code N] [--json-out PATH]
        Turns one finished lane run into findings, one crash_signature.py signature each (task 196). A
        failing check (an update-e2e FAIL row, a skew-matrix FAIL row, a failed restore-journey report row)
        is a `lab-check` signature: exception the lane id, frame the check name with run-specific numbers,
        hashes and paths taken out, so the same check failing on two tips is one issue. Crash, panic,
        sanitizer and hang files that match the lane's crash_globs give their own signatures; one that gives
        none is an `unparsed-crash` finding, never dropped. A lane script that rejects its own arguments
        (argparse `error:`) is a finding of the lane harness. A run that never reached the product (host
        refused, no lease, no previous build) is `infra` and has no finding. Each occurrence is its own
        finding (stability_issues.py sync counts them per hash12). A feed lane (tier and subject feed)
        tests published nightly-next builds, not the tip: its findings carry subject feed and the build.
        Prints cmux-stability-lane-result/v1 JSON; exit 0 passed, 1 failed, 75 infra.

Inputs (the runner, task p10-stability-003, writes the state; this file reads it):

    stability-lanes.json   {"lanes": [{"id": "smoke-26", "tier": "fast" | "long", ...}]}
    state.json             {"tips": [{"sha": "<sha>", "lanes": {"<lane id>": {"status": "passed"}}}]}

`tips` may also be an object keyed by sha. A lane value is a status string, an object with `status`, or
a list of runs (the last run counts). Only `passed` and `failed` are verdicts; every other status
(queued, running, cancelled, infra) is reported as pending and does not pass the lane.

Runs anywhere with git and python3; it reads only git, the two JSON files and a lane's output folder.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import crash_signature  # noqa: E402  (next to this script)

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


# --- lanes registry -------------------------------------------------------------------------------

LANE_REQUIRED = ("id", "tier", "kind", "host_class", "minutes", "priority", "never_with", "script")
# fast: each new lab tip, decides its coverage; long: the newest tip; feed: each new newest build of the
# nightly-next feed (a lane that tests published builds, not a tip, and never counts for coverage).
TIERS = ("fast", "long", "feed")
# What a lane's verdict is about: the lab tip it ran for, or the published feed builds it installed.
SUBJECTS = ("tip", "feed")
HOST_CLASSES = ("dedicated", "preemptible")
# What the runner fills in when it submits a lane step. {previous_app} is the DEV build of the lab tip
# before this one, for lanes that set needs_previous_build.
PLACEHOLDERS = frozenset({"app", "previous_app", "job", "out", "host"})
_PLACEHOLDER = re.compile(r"\{([a-z_]+)\}")
# A fast lane group runs its lanes one after another on one host; it must finish within the fast-lane
# window of section 3A (each new tip within ~30 min).
FAST_GROUP_MINUTES = 30


def lane_strings(lane: dict) -> list[str]:
    values: list[str] = []
    for key in ("args", "artifacts", "crash_globs"):
        values.extend(str(item) for item in lane.get(key) or [])
    values.extend(str(value) for value in (lane.get("env") or {}).values())
    values.extend(str(lane[key]) for key in ("stdout",) if lane.get(key))
    if isinstance(lane.get("result"), dict) and lane["result"].get("path"):
        values.append(str(lane["result"]["path"]))
    return values


def lane_problems(registry: object, repo: Path) -> list[str]:
    """Every reason the runner could not run a lane as declared; empty when the registry is usable."""
    problems: list[str] = []
    lanes = lane_entries(registry)
    groups = registry.get("host_groups") or {} if isinstance(registry, dict) else {}
    seen: set[str] = set()
    for lane in lanes:
        name = lane.get("id", "?")
        if name in seen:
            problems.append(f"{name}: declared twice")
        seen.add(name)
        problems.extend(f"{name}: no {key}" for key in LANE_REQUIRED if lane.get(key) in (None, "", []))
        if lane.get("tier") not in TIERS:
            problems.append(f"{name}: tier {lane.get('tier')!r} is not one of {', '.join(TIERS)}")
        subject = lane.get("subject", "tip")
        if subject not in SUBJECTS:
            problems.append(f"{name}: subject {subject!r} is not one of {', '.join(SUBJECTS)}")
        elif (subject == "feed") != (lane.get("tier") == "feed"):
            problems.append(f"{name}: a feed lane has tier feed and subject feed, a tip lane neither")
        elif subject == "tip" and lane.get("needs_build") == "none":
            problems.append(f"{name}: a tip lane must run the tip's build (needs_build none tests nothing of the tip)")
        if lane.get("host_class") not in HOST_CLASSES:
            problems.append(f"{name}: host_class {lane.get('host_class')!r} is not one of {', '.join(HOST_CLASSES)}")
        if not isinstance(lane.get("minutes"), int) or lane.get("minutes", 0) <= 0:
            problems.append(f"{name}: minutes must be a positive integer")
        if lane.get("priority") not in (None, "lowest"):
            problems.append(f"{name}: priority must be lowest (lab work never competes with people)")
        if "bench" not in (lane.get("never_with") or []):
            problems.append(f"{name}: never_with must include bench")
        if lane.get("script") and not (repo / lane["script"]).is_file():
            problems.append(f"{name}: script {lane['script']} is not in the checkout")
        for value in lane_strings(lane):
            unknown = sorted(set(_PLACEHOLDER.findall(value)) - PLACEHOLDERS)
            if unknown:
                problems.append(f"{name}: unknown placeholder {', '.join(unknown)} in {value!r}")
            if "{previous_app}" in value and not lane.get("needs_previous_build"):
                problems.append(f"{name}: uses {{previous_app}} without needs_previous_build")
        result = lane.get("result")
        if result is not None:
            if not isinstance(result, dict) or result.get("parser") not in RESULT_PARSERS:
                problems.append(f"{name}: result parser must be one of {', '.join(sorted(RESULT_PARSERS))}")
            elif not result.get("path"):
                problems.append(f"{name}: result has no path")
        group = lane.get("host_group")
        if group is not None:
            spec = groups.get(group) if isinstance(groups, dict) else None
            if not isinstance(spec, dict):
                problems.append(f"{name}: host_group {group} is not declared in host_groups")
            elif spec.get("host_class") != lane.get("host_class"):
                problems.append(f"{name}: host_class differs from its host_group {group}")
    for group, spec in (groups.items() if isinstance(groups, dict) else []):
        members = [lane for lane in lanes if lane.get("host_group") == group]
        if sorted(spec.get("order") or []) != sorted(lane["id"] for lane in members):
            problems.append(f"host_group {group}: order must list exactly its lanes")
        if spec.get("hosts") != 1:
            problems.append(f"host_group {group}: hosts must be 1 (the group's lanes share one host)")
        fast_minutes = sum(lane.get("minutes", 0) for lane in members if lane.get("tier") == "fast")
        if fast_minutes > FAST_GROUP_MINUTES:
            problems.append(f"host_group {group}: fast lanes take {fast_minutes} min, over {FAST_GROUP_MINUTES}")
    return problems


def cmd_lanes(args: argparse.Namespace) -> int:
    registry = load_json(Path(args.lanes), "lanes registry")
    lanes = lane_entries(registry)
    problems = lane_problems(registry, Path(args.repo)) if args.check else []
    if args.json:
        print(json.dumps({"lanes": lanes, "problems": problems}, indent=2))
    else:
        header = ("LANE", "TIER", "HOST", "GROUP", "MIN", "SCRIPT")
        rows = [(lane["id"], str(lane.get("tier", "-")), str(lane.get("host_class", "-")),
                 str(lane.get("host_group", "-")), str(lane.get("minutes", "-")), str(lane.get("script", "-")))
                for lane in lanes]
        widths = [max(len(cells[index]) for cells in [header, *rows]) for index in range(len(header))]
        for cells in [header, *rows]:
            print("  ".join(cell.ljust(width) for cell, width in zip(cells, widths)).rstrip())
        for problem in problems:
            print(f"problem: {problem}", file=sys.stderr)
    return 1 if problems else 0


# --- lane results -> signatures -------------------------------------------------------------------

LANE_RESULT_SCHEMA = "cmux-stability-lane-result/v1"
LAB_CHECK_KIND = "lab-check"
EXIT_INFRA = 75  # EX_TEMPFAIL: the run says nothing about the product; the runner runs the lane again

_RUN_PATH = re.compile(r"(?:~|/)[\w./@+-]*[\w@+-]")
_RUN_HEX = re.compile(r"\b[0-9a-f]{7,64}\b")
_RUN_NUMBER = re.compile(r"\d+(?:\.\d+)?")
_TRACEBACK = re.compile(r"^Traceback \(most recent call last\):\n(?:.*\n)*?(?P<error>[A-Za-z_][\w.]*)(?::|\n|$)",
                        re.MULTILINE)


def check_frame(check: str) -> str:
    """A check name as a stable frame: paths, hashes and numbers that differ per run are replaced."""
    text = _RUN_PATH.sub("<path>", check.strip())
    text = _RUN_HEX.sub("<hex>", text)
    text = _RUN_NUMBER.sub("N", text)
    return re.sub(r"\s+", " ", text)[:200]


@dataclass
class LaneChecks:
    """What a lane's own report said: None when it wrote no report (the run ended before it)."""

    passed: list[str] = field(default_factory=list)
    # (check, detail, cause): cause names the bug, so checks that fail for one reason share a signature
    failed: list[tuple[str, str, str]] = field(default_factory=list)
    pending: list[str] = field(default_factory=list)


def _last_json_object(text: str) -> object | None:
    """update-e2e prints its results as one indented JSON object at the end of its output."""
    for match in reversed(list(re.finditer(r"^\{", text, re.MULTILINE))):
        try:
            return json.loads(text[match.start():])
        except json.JSONDecodeError:
            continue
    return None


def parse_update_e2e(text: str) -> LaneChecks | None:
    report = _last_json_object(text)
    if not isinstance(report, dict) or not isinstance(report.get("results"), list):
        return None
    checks = LaneChecks()
    for row in report["results"]:
        if not isinstance(row, list) or len(row) < 2:
            continue
        check, state = str(row[0]), str(row[1])
        detail = str(row[2]) if len(row) > 2 else ""
        if state == "PASS":
            checks.passed.append(check)
        elif state == "FAIL":
            checks.failed.append((check, detail, check))
        else:
            checks.pending.append(check)
    return checks


_SKEW_ROW = re.compile(r"^(?P<direction>cli=\w+ daemon=\w+)\s+(?P<case>\S+)\s+(?P<verdict>works|re-exec|fix|FAIL)"
                       r"(?:\s+(?P<detail>.*))?$", re.MULTILINE)
_SKEW_SUMMARY = re.compile(r"^skew-matrix: \d+ pass, \d+ FAIL$", re.MULTILINE)


def parse_skew_matrix(text: str) -> LaneChecks | None:
    if not _SKEW_SUMMARY.search(text):
        return None
    checks = LaneChecks()
    for row in _SKEW_ROW.finditer(text):
        detail = row["detail"] or ""
        # A daemon that does not start fails every case of its direction: one bug, one signature.
        check = f"{row['direction']} {row['case']}"
        if row["verdict"] == "FAIL":
            cause = "daemon did not start" if detail.startswith("daemon did not start") else row["case"]
            checks.failed.append((check, detail, f"{row['direction']} {cause}"))
        else:
            checks.passed.append(check)
    return checks


def parse_restore_journey(text: str) -> LaneChecks | None:
    try:
        rows = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(rows, list):
        return None
    checks = LaneChecks()
    for row in rows:
        if not isinstance(row, dict) or "item" not in row:
            continue
        check, ok = str(row["item"]), row.get("ok")
        if ok is True:
            checks.passed.append(check)
        elif ok is False:
            checks.failed.append((check, str(row.get("detail") or ""), check))
        else:  # "n/a": the row does not apply on this host
            checks.pending.append(check)
    return checks


RESULT_PARSERS = {
    "update-e2e": parse_update_e2e,
    "skew-matrix": parse_skew_matrix,
    "restore-journey": parse_restore_journey,
}

# Output of a run that never had a report but still reached the product: a finding, not infra.
NO_REPORT_FINDINGS = (
    (re.compile(r"the app never opened its control socket"), "app never opened its control socket"),
    (re.compile(r"daemon did not start"), "daemon did not start"),
    # The tip's own bundle has no CLI: a packaging bug. A missing --old (the previous tip's build) stays infra.
    (re.compile(r"^skew-matrix: --new .* is not an executable cmux-tui$", re.MULTILINE), "bundled cmux-tui missing"),
)
# argparse refused the arguments the lane gave its script: the lane or its harness is wrong, never the host.
_USAGE_ERROR = re.compile(r"^usage: .*(?:\n.*)*?\n\S+: error: (?P<error>.+)$", re.MULTILINE)
# update-e2e's first line names the two published builds it installed (a feed lane's subject).
_FEED_BUILDS = re.compile(r"^feed \S+: \d+ items; (?P<from>\S+) -> (?P<to>\S+)$", re.MULTILINE)
UNPARSED_CRASH_KIND = "unparsed-crash"
# A lane script that died on one of these never reached the product (feed download, ssh, lease).
INFRA_ERRORS = frozenset({"URLError", "HTTPError", "TimeoutError", "timeout", "ConnectionError",
                          "ConnectionResetError", "ConnectionRefusedError", "RemoteDisconnected"})


def expand(value: str, out: Path) -> str:
    return value.replace("{out}", str(out))


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def lab_check_signature(lane: str, check: str, detail: str, source: str, cause: str = "") -> dict:
    frames = [check_frame(cause or check)]
    return crash_signature.Signature(
        kind=LAB_CHECK_KIND, process="cmux", exception=lane, frames=frames,
        hash12=crash_signature.signature_hash(LAB_CHECK_KIND, lane, frames), source=source,
        message=detail[:crash_signature.MESSAGE_LIMIT], extra={"check": check},
    ).to_json()


def _only_test_panics(text: str) -> bool:
    """A panic log whose records are all `cargo test` panics: crash_signature skips them on purpose."""
    records = []
    for line in filter(None, (raw.strip() for raw in text.splitlines())):
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            return False
    return bool(records) and all(isinstance(record, dict) and record.get("test") for record in records)


def _crash_process(text: str, name: str) -> str:
    """The crashed process as the report's header names it, else the file name without its time stamp."""
    try:
        header = json.loads(text.split("\n", 1)[0])
    except json.JSONDecodeError:
        header = None
    process = ""
    if isinstance(header, dict):
        process = str(header.get("app_name") or header.get("procName") or header.get("name") or "")
    if not process:
        process = re.sub(r"[-_.]\d{4}-\d{2}-\d{2}.*$", "", Path(name).stem) or Path(name).stem
    # A DEV build's name carries its tag, which differs per tip: the same crash must keep one signature.
    return re.sub(r"^cmux DEV\b.*$", "cmux DEV", process.strip())


def unparsed_crash(lane: str, path: Path, text: str, source: str) -> dict | None:
    """A crash file that matched the lane's crash_globs but gave no signature: still a crash of this run."""
    if not text.strip():
        return None
    kind = crash_signature.detect_kind(text, path.name)
    if kind == "rust-panic" and _only_test_panics(text):
        return None
    file_kind = kind or path.suffix.lstrip(".") or "unknown"
    process = _crash_process(text, path.name)
    frames = [file_kind, process]
    return crash_signature.Signature(
        kind=UNPARSED_CRASH_KIND, process=process, exception=lane, frames=frames,
        hash12=crash_signature.signature_hash(UNPARSED_CRASH_KIND, lane, frames), source=source,
        message=f"{file_kind} report gave no signature: {text.strip()[:200]}"[:crash_signature.MESSAGE_LIMIT],
        extra={"file_kind": file_kind},
    ).to_json()


def no_report_finding(stdout: str) -> tuple[str, str] | None:
    """(check, detail) when output without a report still shows a product or harness bug."""
    usage = _USAGE_ERROR.search(stdout)
    if usage:
        return f"lane harness usage error: {usage['error'].strip()}", usage.group(0).strip()[-300:]
    for pattern, label in NO_REPORT_FINDINGS:
        match = pattern.search(stdout)
        if match:
            return label, match.group(0).strip()[:300]
    return None


def lane_result(lane: dict, out: Path, exit_code: int | None, ignore=None) -> dict:
    """One finished lane run: its verdict, the lane's checks and one finding per occurrence.

    A signature that occurs twice is two findings with one hash12: stability_issues.py sync groups them and
    counts each one. A feed lane's findings carry subject feed and the feed builds, not the lab tip."""
    lane_id = lane["id"]
    stdout_path = Path(expand(lane["stdout"], out)) if lane.get("stdout") else None
    stdout = (read_text(stdout_path) if stdout_path else None) or ""
    result = lane.get("result") or {}
    report_path = Path(expand(result["path"], out)) if result.get("path") else None
    report_text = read_text(report_path) if report_path else None
    checks = RESULT_PARSERS[result["parser"]](report_text) if report_text is not None and result.get("parser") else None
    source = os.path.relpath(report_path, out) if report_path else ""

    findings: list[dict] = []
    reason = ""
    if checks is not None:
        findings.extend(lab_check_signature(lane_id, check, detail, source, cause)
                        for check, detail, cause in checks.failed)
        if exit_code not in (None, 0) and not checks.failed:
            findings.append(lab_check_signature(lane_id, "exit status without a failing check",
                                                f"exit {exit_code}", source))
    else:
        traceback = _TRACEBACK.search(stdout)
        known = no_report_finding(stdout)
        if traceback and traceback["error"].rsplit(".", 1)[-1] in INFRA_ERRORS:
            reason = f"no report: {traceback['error']} (network or host)"
        elif traceback:
            findings.append(lab_check_signature(lane_id, f"lane script error {traceback['error']}",
                                                stdout[traceback.start():].strip()[-300:], source))
        elif known:
            findings.append(lab_check_signature(lane_id, known[0], known[1], source))
        elif exit_code == 0:
            findings.append(lab_check_signature(lane_id, "exit 0 without a report", "", source))
        else:
            lines = [line.strip() for line in stdout.splitlines() if line.strip()]
            last = next((line for line in lines if line.startswith("refused:")), lines[-1] if lines else "")
            reason = f"no report (exit {exit_code}): {last[:200]}" if last else f"no report (exit {exit_code})"

    crash_files = sorted({hit for pattern in lane.get("crash_globs") or []
                          for hit in glob.glob(expand(pattern, out)) if os.path.isfile(hit)})
    for path in crash_files:
        try:
            signatures = crash_signature.signatures_from_path(Path(path), ignore)
        except OSError as error:
            reason = reason or f"crash file unreadable: {path}: {error}"
            continue
        crash_source = os.path.relpath(path, out)
        if not signatures:
            fallback = unparsed_crash(lane_id, Path(path), read_text(Path(path)) or "", crash_source)
            findings.extend([fallback] if fallback else [])
        for signature in signatures:
            record = signature.to_json()
            record["source"] = crash_source
            findings.append(record)

    subject = lane.get("subject", "tip")
    feed = _FEED_BUILDS.search(stdout or report_text or "") if subject == "feed" else None
    builds = {"from": feed["from"], "to": feed["to"]} if feed else None
    for finding in findings:
        finding["lane"] = lane_id
        if subject != "tip":
            finding["subject"] = subject
            if builds:
                finding["build"] = builds["to"]
    status = FAILED if findings else ("infra" if reason else PASSED)
    return {
        "schema": LANE_RESULT_SCHEMA,
        "lane": lane_id,
        "subject": subject,
        "builds": builds,
        "status": status,
        "reason": reason,
        "exit": exit_code,
        "checks": None if checks is None else {
            "passed": len(checks.passed), "failed": [check for check, _, _ in checks.failed], "pending": len(checks.pending),
        },
        "signatures": sorted({finding["hash12"] for finding in findings}),
        "findings": findings,
    }


def cmd_signatures(args: argparse.Namespace) -> int:
    lanes = {lane["id"]: lane for lane in lane_entries(load_json(Path(args.lanes), "lanes registry"))}
    lane = lanes.get(args.lane)
    if lane is None:
        raise LabError(f"lane {args.lane} is not in the registry ({', '.join(sorted(lanes))})")
    out = Path(args.out)
    if not out.is_dir():
        raise LabError(f"lane output folder not found: {out}")
    result = lane_result(lane, out, args.exit_code)
    if args.json_out:
        Path(args.json_out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.json_out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    return {PASSED: 0, FAILED: 1}.get(result["status"], EXIT_INFRA)


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

    lanes = commands.add_parser("lanes", help="list the lanes registry; --check validates it")
    lanes.add_argument("--lanes", default=str(DEFAULT_LANES), help="lanes registry JSON")
    lanes.add_argument("--repo", default=str(ROOT), help="checkout the lane scripts are in (default: this one)")
    lanes.add_argument("--check", action="store_true", help="exit 1 when a lane cannot run as declared")
    lanes.add_argument("--json", action="store_true", help="print JSON instead of the table")
    lanes.set_defaults(handler=cmd_lanes)

    sig = commands.add_parser("signatures", help="one finished lane run -> verdict and signatures")
    sig.add_argument("--lane", required=True, help="lane id in the registry")
    sig.add_argument("--out", required=True, help="the lane's output folder ({out})")
    sig.add_argument("--exit-code", type=int, default=None, help="the lane step's exit status")
    sig.add_argument("--lanes", default=str(DEFAULT_LANES), help="lanes registry JSON")
    sig.add_argument("--json-out", help="also write the result JSON to this path")
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
