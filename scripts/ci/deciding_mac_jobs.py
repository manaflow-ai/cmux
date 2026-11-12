#!/usr/bin/env python3
"""How many Mac jobs decide a pull request head's verdict, from cmux-next.yml and the head's check runs.

Autoland (cmuxterm-hq tools/fleet-reconcilers/next_autoland.py) decides a feat-cmux-next head on its
cmux-next.yml checks: it waits on the compiles and the package tests (`waits_on`), and every other finished
check that is not advisory holds the head on its red (`counts_red`). So each cmux-next.yml job a head runs
on a Mac decides it, and each one waits for a Mac runner first. This counts them, one number per head, so a
change that moves work off the Mac shows as a before and after from the same harness.

    deciding_mac_jobs.py classify            each cmux-next.yml job: linux, mac or other, and its check name
    deciding_mac_jobs.py tally FILE...       FILE is `gh pr view N --json number,statusCheckRollup`
    deciding_mac_jobs.py guard               exit 1 when a deciding job that runs on Linux can reach another runner

`guard` is the detector for a deciding job drifting back to the Mac: each job in LINUX_DECIDING must resolve
to Linux labels only. Run it after changing a `runs-on` in cmux-next.yml; it is not a CI step (no new CI tests).

A job is `linux` when every label its `runs-on` can resolve to is Blacksmith or declared fleet Linux
(tests/runs_on_labels.py, the rule the Linux runner guards use), `mac` when one of them is a macOS or Xcode
label, and `other` otherwise (a build-fleet gateway runner, a portable job a mini may take). `tally` counts
a check run as a Mac job when every cmux-next.yml job of its name is `mac`; a name a Mac job shares with a
Linux one (the Release compile and its Linux admission job) is listed apart as `shared` and not counted. A
skipped, neutral, cancelled, stale or advisory check decided nothing and is left out; a queued one counts. A head with no `cmux-next path routing` check
had no cmux-next.yml run and is left out of the mean.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests"))
from runs_on_labels import Unknown, disallowed_labels, resolve_labels  # noqa: E402
import workflow_jobs  # noqa: E402 - tests/workflow_jobs.py, the one reader of a job's runs-on

WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
ROUTING_CHECK = "cmux-next path routing"
ADVISORY_SUFFIX = "(advisory)"  # next_autoland.ADVISORY_SUFFIX: a check whose name ends so decides nothing
MAC_LABEL = re.compile(r"macos|xcode", re.IGNORECASE)
NOT_RUN = {"SKIPPED", "NEUTRAL", "CANCELLED", "STALE"}  # decided nothing (autoland NO_VERDICT for the last two)
# The cmux-next.yml jobs autoland decides on that run on Linux today (next_autoland WAITED_JOBS and the status
# jobs whose red it counts). A job moved off the Mac joins this list in the same change.
LINUX_DECIDING = {
    "fast-tier-cargo": "cmux-next fast tier (cargo)",
    "compile-status": "cmux-next fleet Release compile",
    "generated-verdict": "cmux-next generated files (shared build)",
    "release-compile-fast-admission": "cmux-next Release compile (Xcode 26)",
    "app-compile-placement": "cmux-next app compile placement",
}


def check_name(job_id: str, job: dict) -> str:
    """The check run's name for a job: its `name`, with a whole-expression name as GitHub shows it unevaluated."""
    name = str(job.get("name") or job_id)
    whole = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", name, re.DOTALL)
    return whole.group(1) if whole else name


def check_names(job_id: str, job: dict) -> list[str]:
    """Every name the job's check run can show: the unevaluated expression (a job skipped before it ran) and each
    quoted literal it can evaluate to (`cond && 'A' || 'B'` gives A and B)."""
    name = check_name(job_id, job)
    literals = re.findall(r"'((?:[^']|'')*)'", name) if name != str(job.get("name") or job_id) else []
    return [name] + [lit.replace("''", "'") for lit in literals if lit and lit != "true"]


def runner_class(runs_on) -> str:
    """linux, mac or other: where a job's `runs-on` can schedule it."""
    if runs_on is None:
        return "other"  # a reusable-workflow caller: its jobs are their own
    if not disallowed_labels(runs_on):
        return "linux"
    labels = resolve_labels(runs_on)
    if any(not isinstance(label, Unknown) and MAC_LABEL.search(str(label)) for label in labels):
        return "mac"
    return "other"


def _cell_value(cell: tuple[str, ...]) -> str | list[str]:
    """One runs-on cell as runs_on_labels reads it: its one label, or the list it asks for."""
    return cell[0] if len(cell) == 1 else list(cell)


def job_runner_class(job: dict) -> str:
    """runner_class of the job's runs-on, read per matrix cell (workflow_jobs.runs_on_label_cells): mac when any
    cell can schedule on a Mac, linux when every cell is Linux, else other. `${{ matrix.runner }}` read as one
    string is one unknown value, so a matrix with a Mac cell would count as other and its checks as no Mac's."""
    cells = workflow_jobs.runs_on_label_cells(job)
    if not cells:
        return "other"  # None: a matrix nothing resolves; []: a reusable-workflow caller, whose jobs are their own
    classes = {runner_class(_cell_value(cell)) for cell in cells}
    return "mac" if "mac" in classes else "linux" if classes == {"linux"} else "other"


def classify(workflow: Path = WORKFLOW) -> dict[str, tuple[str, str]]:
    """job id -> (check name, runner class) for every job of the workflow."""
    jobs = yaml.safe_load(workflow.read_text(encoding="utf-8"))["jobs"]
    return {job_id: (check_name(job_id, job), job_runner_class(job)) for job_id, job in jobs.items()}


def classify_names(workflow: Path = WORKFLOW) -> list[tuple[str, str]]:
    """(check name, runner class) for every name any job's check run can show."""
    jobs = yaml.safe_load(workflow.read_text(encoding="utf-8"))["jobs"]
    return [(name, job_runner_class(job)) for job_id, job in jobs.items()
            for name in check_names(job_id, job)]


def name_classes(pairs: list[tuple[str, str]]) -> dict[str, str]:
    """check name -> mac (every job of the name is mac), shared (a mac job and another), or its one class."""
    by_name = collections.defaultdict(set)
    for name, cls in pairs:
        by_name[name].add(cls)
    return {name: (next(iter(found)) if len(found) == 1 else "shared" if "mac" in found else "other")
            for name, found in by_name.items()}


def head_mac_jobs(rollup: list[dict], names: dict[str, str]) -> tuple[bool, list[str], list[str]]:
    """(had a cmux-next.yml run, its Mac checks that ran, its shared-name checks that ran) for one head."""
    ran = False
    mac, shared = [], []
    for check in rollup:
        if check.get("__typename") != "CheckRun":
            continue
        name = str(check.get("name") or "")
        if name == ROUTING_CHECK:
            ran = True
        if check.get("conclusion") in NOT_RUN or name.rstrip().lower().endswith(ADVISORY_SUFFIX):
            continue
        cls = names.get(name)
        if cls == "mac" and name not in mac:
            mac.append(name)
        elif cls == "shared" and name not in shared:
            shared.append(name)
    return ran, sorted(mac), sorted(shared)


def tally(paths: list[Path], workflow: Path = WORKFLOW) -> dict:
    names = name_classes(classify_names(workflow))
    heads, by_job = [], collections.Counter()
    for path in paths:
        view = json.loads(path.read_text(encoding="utf-8"))
        ran, mac, shared = head_mac_jobs(view.get("statusCheckRollup") or [], names)
        heads.append({"number": view.get("number"), "cmux_next_run": ran, "mac": mac, "shared": shared})
        if ran:
            by_job.update(mac + [f"{name} (shared)" for name in shared])
    counted = [h for h in heads if h["cmux_next_run"]]
    total = sum(len(h["mac"]) for h in counted)
    return {"heads": heads, "heads_with_run": len(counted), "deciding_mac_jobs": total,
            "shared_name_checks": sum(len(h["shared"]) for h in counted),
            "per_head": round(total / len(counted), 2) if counted else None, "by_job": dict(by_job.most_common())}


def guard(workflow: Path = WORKFLOW) -> list[str]:
    """Each LINUX_DECIDING job that is missing, renamed, or can resolve to a runner other than Linux."""
    jobs = yaml.safe_load(workflow.read_text(encoding="utf-8"))["jobs"]
    problems = []
    for job_id, name in LINUX_DECIDING.items():
        job = jobs.get(job_id)
        if job is None:
            problems.append(f"{job_id}: gone from {workflow.name}; update LINUX_DECIDING and autoland's WAITED_JOBS")
            continue
        if check_name(job_id, job) != name:
            problems.append(f"{job_id}: its check is now {check_name(job_id, job)!r}, not {name!r}; "
                            "autoland's WAITED_JOBS and the required checks must follow")
        cells = workflow_jobs.runs_on_label_cells(job)
        if cells is None:
            problems.append(f"{job_id}: may run off Linux: its runs-on reads a matrix value nothing resolves")
            continue
        bad = {}
        for cell in cells or [("",)]:
            bad.update(disallowed_labels(_cell_value(cell)))
        if bad:
            problems.append(f"{job_id}: may run off Linux: " + "; ".join(f"{k} ({v})" for k, v in sorted(bad.items())))
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("classify")
    sub.add_parser("guard")
    counting = sub.add_parser("tally")
    counting.add_argument("files", nargs="+", type=Path)
    counting.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "classify":
        for job_id, (name, cls) in classify().items():
            print(f"{cls}\t{job_id}\t{name}")
        return 0
    if args.command == "guard":
        problems = guard()
        for problem in problems:
            print(f"deciding job off Linux: {problem}", file=sys.stderr)
        if not problems:
            print(f"{len(LINUX_DECIDING)} deciding Linux jobs resolve to Linux runners only")
        return 1 if problems else 0
    result = tally(args.files)
    if args.json:
        print(json.dumps(result, indent=2))
        return 0
    for head in result["heads"]:
        jobs = head["mac"] + [f"{name} (shared)" for name in head["shared"]]
        print(f"#{head['number']}\t{len(head['mac']) if head['cmux_next_run'] else '-'}\t{', '.join(jobs)}")
    print(f"heads with a cmux-next run: {result['heads_with_run']}; deciding Mac jobs: "
          f"{result['deciding_mac_jobs']}; per head: {result['per_head']}; "
          f"shared-name checks (Mac or Linux, not counted): {result['shared_name_checks']}")
    for name, count in result["by_job"].items():
        print(f"  {count}\t{name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
