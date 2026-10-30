#!/usr/bin/env python3
"""Every job that runs on macOS says why, once, in .github/runners.json.

macOS runners are the scarce part of CI and Linux runners are the plentiful
part. A job lands on macOS because its `runs-on:` says so, and nothing used to
ask whether the job needed macOS. This module asks.

`.github/runners.json` carries two tables next to the capability map:

* `job_classes`: what kind of work a job does, and whether that kind of work
  needs macOS (`"needs": "macos"`) or runs on Linux (`"needs": "linux"`).
* `macos_jobs`: every workflow job whose `runs-on:` can route to macOS,
  as `"<workflow file>#<job id>"`, mapped to its class.

`check()` fails when:

* a job routes to macOS and has no `macos_jobs` entry (a new macOS job must
  name its class);
* a `macos_jobs` entry names a class whose `needs` is `linux` and the entry
  carries no `linux_followup` (that work belongs on a Linux runner);
* a macOS job reads an owned side-lane label straight from a repository
  variable (`vars.CI_SIDE_LANE_RUNNER`, `vars.CI_LIGHT_LANE_RUNNER`) with no
  placement output (`needs.<job>.outputs...`, a caller's `inputs.pr_*runner`)
  in its `runs-on:`, and its entry carries no `placement_followup`. Such a job
  bypasses placement: it waits on the side label however busy it is, while a
  placement step would spill it to an idle compatible pool;
* a `macos_jobs` entry names a job that no longer exists or no longer routes
  to macOS (the table stays true).

`linux_followup` and `placement_followup` exist only so the table can
describe today's tree: an existing job that should move but has not yet. A new
job never gets one. An entry whose followup no longer applies fails too, so
the list only shrinks.

A job wired to the capability map (`fromJSON(needs.runners.outputs.map).<key>`)
routes to macOS when its key is not a `linux*` key. Otherwise a job "routes to
macOS" when its `runs-on:` (and, for a matrix-driven
`runs-on:`, its strategy) does not plainly name a Linux or Windows runner, or
names a macOS image, a macOS runner variable or an owned Mac pool. An
expression the scan cannot read counts as macOS: an unlisted job fails loudly
instead of slipping through.

Usage:
  python3 scripts/ci/runner_routing_table.py check
  python3 scripts/ci/runner_routing_table.py inventory   # print routed jobs
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import yaml

ROOT = Path(__file__).resolve().parents[2]
MAP_PATH = ROOT / ".github" / "runners.json"
WORKFLOWS = ROOT / ".github" / "workflows"

# Text in a runs-on expression that means "this can be a Mac". Owned Mac pools
# are glaeda-* labels and the repository variables that name them.
MACOS_HINT = re.compile(
    r"macos|glaeda-|MACOS_RUNNER|CI_SIDE_LANE_RUNNER|CI_LIGHT_LANE_RUNNER"
    r"|CI_NEXT_[A-Z_]*POOL|CI_SEED_TRUSTED_POOL|NIGHTLY_[A-Z_]*(RUNNER|POOL)"
    r"|pr_[a-z_]*runner|macos_runner",
    re.IGNORECASE,
)
NON_MAC_HINT = re.compile(r"ubuntu|linux|windows", re.IGNORECASE)

NEEDS = ("macos", "linux")

OWNED_LABEL_VARIABLE = re.compile(r"vars\.CI_(SIDE|LIGHT)_LANE_RUNNER")
PLACEMENT_OUTPUT = re.compile(r"needs\.[\w-]+\.outputs|inputs\.pr_[a-z_]*runner")


def bypasses_placement(runs_on: str) -> bool:
    """The job takes an owned side label from a variable, not from placement."""
    return bool(OWNED_LABEL_VARIABLE.search(runs_on)) and not PLACEMENT_OUTPUT.search(runs_on)


class RoutingTableError(RuntimeError):
    """The routing table is malformed."""


@dataclass(frozen=True)
class Job:
    workflow: str
    job_id: str
    runs_on: str

    @property
    def key(self) -> str:
        return f"{self.workflow}#{self.job_id}"


def load_table(path: Path = MAP_PATH) -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    classes = document.get("job_classes")
    jobs = document.get("macos_jobs")
    if not isinstance(classes, dict) or not classes:
        raise RoutingTableError(f"{path}: job_classes must be a non-empty object")
    if not isinstance(jobs, dict):
        raise RoutingTableError(f"{path}: macos_jobs must be an object")
    for name, spec in classes.items():
        if name.startswith("$"):
            continue
        if not isinstance(spec, dict) or spec.get("needs") not in NEEDS:
            raise RoutingTableError(f"job_classes.{name}.needs must be one of {NEEDS}")
        if not isinstance(spec.get("description"), str) or not spec["description"].strip():
            raise RoutingTableError(f"job_classes.{name} must describe the work in prose")
    normalized: dict[str, dict[str, Any]] = {}
    for key, entry in jobs.items():
        if key.startswith("$"):
            continue
        if isinstance(entry, str):
            entry = {"class": entry}
        if not isinstance(entry, dict) or not isinstance(entry.get("class"), str):
            raise RoutingTableError(f"macos_jobs[{key!r}] must name a class")
        normalized[key] = entry
    return {k: v for k, v in classes.items() if not k.startswith("$")}, normalized


MAP_CAPABILITY = re.compile(r"outputs\.map\)\.([a-z0-9_]+)")


def routes_to_macos(job: dict[str, Any]) -> bool:
    runs_on = json.dumps(job.get("runs-on", ""))
    # A job wired to the capability map names its capability key.
    capabilities = MAP_CAPABILITY.findall(runs_on)
    if capabilities and runs_on.count("${{") == 1:
        return any(not key.startswith("linux") for key in capabilities)
    if "matrix" in runs_on:
        runs_on += json.dumps(job.get("strategy", {}))
    if MACOS_HINT.search(runs_on):
        return True
    return not NON_MAC_HINT.search(runs_on)


def iter_jobs(workflows: Path = WORKFLOWS) -> Iterable[tuple[Job, bool]]:
    """Every runnable job in every workflow, with whether it routes to macOS."""
    for path in sorted(workflows.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job_id, job in (document.get("jobs") or {}).items():
            # A reusable-workflow call runs the callee's jobs, which this scan
            # visits in the callee's own file.
            if not isinstance(job, dict) or "uses" in job:
                continue
            yield Job(path.name, str(job_id), json.dumps(job.get("runs-on", ""))), routes_to_macos(job)


def check(map_path: Path = MAP_PATH, workflows: Path = WORKFLOWS) -> list[str]:
    classes, table = load_table(map_path)
    problems: list[str] = []
    seen: dict[str, bool] = {}
    for job, on_macos in iter_jobs(workflows):
        seen[job.key] = on_macos
        if not on_macos:
            continue
        entry = table.get(job.key)
        if entry is None:
            problems.append(
                f"{job.key} runs on macOS but has no entry in .github/runners.json macos_jobs. "
                f"Add it with the job class that says why it needs a Mac "
                f"(classes: {', '.join(sorted(classes))}), or run it on Linux."
            )
            continue
        spec = classes.get(entry["class"])
        if spec is None:
            problems.append(f"{job.key}: unknown job class {entry['class']!r}")
            continue
        bypass = bypasses_placement(job.runs_on)
        if bypass and not entry.get("placement_followup"):
            problems.append(
                f"{job.key} takes vars.CI_SIDE_LANE_RUNNER / vars.CI_LIGHT_LANE_RUNNER in runs-on "
                f"with no placement output, so it bypasses placement. Route it through the "
                f"workflow's placement job (scripts/ci/side_lane_placement.py) instead."
            )
        elif entry.get("placement_followup") and not bypass:
            problems.append(f"{job.key} no longer bypasses placement; remove its placement_followup")
        if spec["needs"] == "linux" and not entry.get("linux_followup"):
            problems.append(
                f"{job.key} is class {entry['class']!r}, which runs on Linux runners: "
                f"{spec['description']} Move the job to a Linux runner "
                f"(fromJSON(needs.runners.outputs.map).linux, via resolve-runners.yml)."
            )
        elif spec["needs"] == "macos" and entry.get("linux_followup"):
            problems.append(f"{job.key}: class {entry['class']!r} needs macOS; remove its linux_followup")
    for key in sorted(table):
        if key not in seen:
            problems.append(f"macos_jobs[{key!r}] names a job that does not exist; remove the entry")
        elif not seen[key]:
            problems.append(f"macos_jobs[{key!r}] no longer runs on macOS; remove the entry")
    return problems


def main(argv: list[str]) -> int:
    command = argv[1] if len(argv) > 1 else "check"
    if command == "inventory":
        for job, on_macos in iter_jobs():
            if on_macos:
                print(job.key)
        return 0
    if command != "check":
        print(__doc__, file=sys.stderr)
        return 2
    problems = check()
    for problem in problems:
        print(f"::error file=.github/runners.json::{problem}")
    if problems:
        return 1
    _, table = load_table()
    pending = sorted(k for k, v in table.items() if v.get("linux_followup"))
    bypass = sorted(k for k, v in table.items() if v.get("placement_followup"))
    print(
        f"runner routing table: {len(table)} macOS jobs classified; "
        f"{len(pending)} still to move to Linux; {len(bypass)} still bypass placement"
    )
    for key in pending:
        print(f"  linux: {key}: {table[key]['linux_followup']}")
    for key in bypass:
        print(f"  placement: {key}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
