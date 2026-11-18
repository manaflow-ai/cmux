#!/usr/bin/env python3
"""Route each side-lane job measured light to vars.CI_SIDE_LANE_LABELS_LIGHT, from measured job memory.

Leo, 2026-11-17: "we do have a richness in resources, but we're not exactly using them to the fullest extent".
CI_SIDE_LANE_LABELS is one label array for every side job, so the array that a 40 GiB swift-test needs
(["glaeda-side-xcode-26.6", "glaeda-ram-48"]) also keeps a 1 GiB agent-brands test off the 16 GiB minis.
CI_SIDE_LANE_LABELS_LIGHT is a second array for the side jobs whose measured peak fits a 16 GiB host, e.g.
["glaeda-side-xcode-26.6"]. A light job reads it first:

    (vars.CI_SIDE_LANE_LABELS_LIGHT != '' && fromJSON(vars.CI_SIDE_LANE_LABELS_LIGHT) || <the CI_SIDE_LANE_LABELS read>)

so with it unset the job routes exactly as before, and with both arrays unset it is vars.CI_SIDE_LANE_RUNNER.

Which jobs are light comes from cmuxterm-hq build-fleet/data/job-needs.json, never by hand. A job is light when
its mem_peak_mib_max (the job tree's physical footprint over the window, compressed and swapped pages
included) is at most LIGHT_MAX_MIB from at least the file's min_samples runs. A job the file does not measure
stays heavy. side_lane_job_needs.json, beside this script, is the checked-in snapshot of those measurements
for this repository's jobs.

  python3 scripts/ci/side_lane_light_tier.py --needs <cmuxterm-hq>/build-fleet/data/job-needs.json
      refresh the snapshot from a new job-needs.json, then rewrite the workflows
  python3 scripts/ci/side_lane_light_tier.py
      rewrite the workflows from the snapshot
  python3 scripts/ci/side_lane_light_tier.py --check
      exit 1 when a workflow's read differs from the snapshot (tests/test_ci_side_lane_capability_labels.py)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
SNAPSHOT = Path(__file__).resolve().with_name("side_lane_job_needs.json")

LABELS_READ = ("(vars.CI_SIDE_LANE_LABELS != '' && fromJSON(vars.CI_SIDE_LANE_LABELS) || "
               "vars.CI_SIDE_LANE_RUNNER)")
LIGHT_READ = ("(vars.CI_SIDE_LANE_LABELS_LIGHT != '' && fromJSON(vars.CI_SIDE_LANE_LABELS_LIGHT) || "
              f"{LABELS_READ})")
# 10 GiB. A 16 GiB mini (cmux17-24) keeps about 5 GiB for macOS, the runner and its other runner's idle
# baseline, so a job whose worst measured run stays under 10 GiB fits without paging hard. The measured side
# jobs split with a gap here: the heaviest light one peaks at 8.6 GiB (auth-refresh-tests), the lightest heavy
# one at 11.9 GiB (cmux-next.yml release-compile).
LIGHT_MAX_MIB = 10 * 1024
# Another repository's job (manaflow-ai/cmuxterm-hq/...) is keyed with its owner; this repository's are bare.
OTHER_REPO_KEY = re.compile(r"^[^/]+/[^/]+/")
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):(?:\s|$)")
RUNS_ON = re.compile(r"^    runs-on:")


def snapshot_from_needs(needs: dict) -> dict:
    """The snapshot to check in: this repository's jobs and the fields the split reads."""
    jobs = {key: {"mem_peak_mib_max": value["mem_peak_mib_max"], "mem_peak_mib_p90": value["mem_peak_mib_p90"],
                  "n": value["n"]}
            for key, value in needs["jobs"].items() if not OTHER_REPO_KEY.match(key)}
    return {"source": "cmuxterm-hq build-fleet/data/job-needs.json", "schema": needs.get("schema"),
            "generated_at": needs.get("generated_at"), "window": needs.get("window"),
            "min_samples": needs.get("min_samples", 1), "jobs": dict(sorted(jobs.items()))}


def is_light(snapshot: dict, key: str) -> bool:
    """Whether workflow/job (`cmux-next.yml/swift-test`) is measured to fit a 16 GiB host."""
    job = snapshot["jobs"].get(key)
    return bool(job) and job["n"] >= snapshot["min_samples"] and job["mem_peak_mib_max"] <= LIGHT_MAX_MIB


def side_lane_reads() -> list[tuple[Path, int, str]]:
    """(workflow, runs-on line index, workflow/job) for every non-nightly job whose runs-on reads the array."""
    out = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if path.name.startswith("nightly"):
            continue
        job = None
        in_jobs = False
        for index, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
            if not line.strip() or line.startswith("#"):
                continue
            if not line.startswith(" "):
                in_jobs = line.rstrip() == "jobs:"
                job = None
                continue
            header = JOB_HEADER.match(line) if in_jobs else None
            if header:
                job = header.group(1)
            elif job and RUNS_ON.match(line) and LABELS_READ in line:
                out.append((path, index, f"{path.name}/{job}"))
    return out


def rewrite(snapshot: dict) -> dict[Path, str]:
    """Each workflow whose reads change, with its new text."""
    texts: dict[Path, list[str]] = {}
    changed: set[Path] = set()
    for path, index, key in side_lane_reads():
        lines = texts.setdefault(path, path.read_text(encoding="utf-8").splitlines(keepends=True))
        line = lines[index].replace(LIGHT_READ, LABELS_READ)
        if is_light(snapshot, key):
            line = line.replace(LABELS_READ, LIGHT_READ)
        if line != lines[index]:
            lines[index] = line
            changed.add(path)
    return {path: "".join(texts[path]) for path in sorted(changed)}


def light_jobs(snapshot: dict) -> list[str]:
    return sorted({key for _, _, key in side_lane_reads() if is_light(snapshot, key)})


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--needs", type=Path, help="a job-needs.json to refresh the snapshot from")
    parser.add_argument("--check", action="store_true", help="change nothing; exit 1 when a read is stale")
    args = parser.parse_args()
    if args.needs:
        snapshot = snapshot_from_needs(json.loads(args.needs.read_text(encoding="utf-8")))
        text = json.dumps(snapshot, indent=2) + "\n"
        if args.check:
            if SNAPSHOT.read_text(encoding="utf-8") != text:
                print(f"{SNAPSHOT.relative_to(ROOT)} differs from {args.needs}", file=sys.stderr)
                return 1
        else:
            SNAPSHOT.write_text(text, encoding="utf-8")
    snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
    stale = rewrite(snapshot)
    if args.check:
        for path in stale:
            print(f"{path.relative_to(ROOT)}: a side-lane read does not match {SNAPSHOT.name}; "
                  "run python3 scripts/ci/side_lane_light_tier.py", file=sys.stderr)
        return 1 if stale else 0
    for path, text in stale.items():
        path.write_text(text, encoding="utf-8")
    light = light_jobs(snapshot)
    total = len(side_lane_reads())
    print(f"{len(light)} of {total} side-lane runs-on reads are light (max <= {LIGHT_MAX_MIB} MiB):")
    for key in light:
        print(f"  {key} {snapshot['jobs'][key]['mem_peak_mib_max']} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
