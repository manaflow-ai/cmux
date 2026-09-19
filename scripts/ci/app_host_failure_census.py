#!/usr/bin/env python3
"""Census failed app-host tests across GitHub Actions logs."""
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

XCTEST_START = re.compile(r"Test Case '-\[([^]]+) ([^]]+)\]' started\.")
XCTEST_FAIL = re.compile(r"Test Case '-\[([^]]+) ([^]]+)\]' failed")
SWIFT_START = re.compile(r"(?:◇|▶) Test (.+?) started\.")
SWIFT_ISSUE = re.compile(r"✘ Test (.+?) recorded an issue(?: at .*?)?(?::\s*(.*))?$|✘ Test (.+?) recorded an issue(?: \(.*\))?$")
SWIFT_KNOWN_ISSUE = re.compile(r"✘ Test (.+?) recorded a known issue(?: at .*?)?(?::\s*(.*))?$")
SWIFT_FAIL = re.compile(r"✘ Test (.+?) failed(?: after| with)\b")
RESTART = "Restarting after unexpected exit"
KNOWN = re.compile(r"known issue|XCTExpectFailure", re.IGNORECASE)


def _clean(value):
    return re.sub(r"\x1b\[[0-9;]*m", "", value).strip()


def _test_name(kind, suite, name):
    return "{}{}{}".format(suite, "/" if suite else "", name).strip()


def parse_log(text, run_id="unknown", job_id=None):
    """Parse one job log into test observations and restart events."""
    seen = {}
    failed = {}
    assertions = {}
    current = None
    recent = []
    restarts = []
    known_tests = set()
    for raw in text.splitlines():
        line = _clean(raw)
        if not line:
            continue
        xm = XCTEST_START.search(line)
        sm = SWIFT_START.search(line)
        if xm:
            current = _test_name("xctest", xm.group(1), xm.group(2))
            seen.setdefault(current, True)
        elif sm and not KNOWN.search(line):
            current = _clean(sm.group(1)).strip('"')
            seen.setdefault(current, True)
        if RESTART in line:
            restarts.append({"test": current, "line": line})
        fm = XCTEST_FAIL.search(line)
        if fm:
            name = _test_name("xctest", fm.group(1), fm.group(2))
            seen.setdefault(name, True)
            failed[name] = True
            if name not in assertions:
                for candidate in reversed(recent):
                    if ": error:" in candidate:
                        assertions[name] = candidate.split(": error:", 1)[1].strip()
                        break
        if ("recorded an issue" in line or "recorded a known issue" in line) and KNOWN.search(line):
            known_match = SWIFT_KNOWN_ISSUE.search(line) or re.search(r"✘ Test (.+?) recorded an issue", line)
            if known_match:
                known_tests.add(_clean(known_match.group(1)).strip('"'))
            im = None
        else:
            im = SWIFT_ISSUE.search(line)
        if im:
            name = _clean(im.group(1) or im.group(3)).strip('"')
            seen.setdefault(name, True)
            failed[name] = True
            if name not in assertions:
                assertions[name] = _clean(im.group(2) or "") or line
        sf = SWIFT_FAIL.search(line)
        if sf and not KNOWN.search(line):
            name = _clean(sf.group(1)).strip('"')
            seen.setdefault(name, True)
            failed[name] = True
        recent.append(line)
        if len(recent) > 30:
            recent.pop(0)
    for name in known_tests:
        seen.pop(name, None)
        failed.pop(name, None)
        assertions.pop(name, None)
    return {
        "run_id": str(run_id),
        "job_id": str(job_id) if job_id is not None else None,
        "tests_seen": set(seen),
        "tests_failed": set(failed),
        "assertions": assertions,
        "restarts": restarts,
    }


def _run_id_for_file(path):
    match = re.search(r"(?:run[-_])?(\d{6,})", path.name)
    if match:
        return match.group(1)
    # shard*.log files in a directory are one captured run.
    return "log-dir"


def read_log_dir(directory):
    records = []
    for path in sorted(Path(directory).glob("*.log")):
        records.append(parse_log(path.read_text(errors="replace"), _run_id_for_file(path), path.name))
    if not records:
        raise SystemExit("no .log files found in {}".format(directory))
    return records


def _gh_api(endpoint):
    return subprocess.check_output(["gh", "api", endpoint], text=True)


def download_runs(run_ids):
    records = []
    for run_id in run_ids:
        payload = json.loads(_gh_api("repos/manaflow-ai/cmux/actions/runs/{}/jobs?per_page=100".format(run_id)))
        jobs = payload.get("jobs", payload if isinstance(payload, list) else [])
        for job in jobs:
            name = job.get("name", "")
            if not re.search(r"app-host unit tests \([1-6]/6\)", name):
                continue
            try:
                text = _gh_api("repos/manaflow-ai/cmux/actions/jobs/{}/logs".format(job["id"]))
            except subprocess.CalledProcessError as exc:
                print("warning: could not download job {}: {}".format(job["id"], exc), file=sys.stderr)
                continue
            records.append(parse_log(text, run_id, job["id"]))
    return records


def summarize(records):
    tests = defaultdict(lambda: {"runs_seen": set(), "runs_failed": set(), "first_assertion": None})
    restarts = []
    for record in records:
        run_id = str(record["run_id"])
        for name in record["tests_seen"]:
            tests[name]["runs_seen"].add(run_id)
        for name in record["tests_failed"]:
            tests[name]["runs_failed"].add(run_id)
            if tests[name]["first_assertion"] is None:
                tests[name]["first_assertion"] = record["assertions"].get(name)
        for event in record["restarts"]:
            restarts.append({"run_id": run_id, "job_id": record.get("job_id"), **event})
    rows = []
    for name, data in tests.items():
        seen = len(data["runs_seen"])
        failed = len(data["runs_failed"])
        rows.append({"test": name, "runs_seen": seen, "runs_failed": failed,
                     "failure_rate": (failed / seen) if seen else 0.0,
                     "first_assertion": data["first_assertion"]})
    rows.sort(key=lambda row: (-row["failure_rate"], -row["runs_failed"], row["test"]))
    return {"runs": sorted({str(r["run_id"]) for r in records}), "jobs": len(records),
            "tests": rows, "restarts": restarts}


def table(report):
    lines = ["Test | Runs | Failed | Rate | First assertion", "--- | ---: | ---: | ---: | ---"]
    for row in report["tests"]:
        assertion = (row["first_assertion"] or "").replace("|", "\\|")
        lines.append("{} | {}/{} | {} | {:.0%} | {}".format(
            row["test"], row["runs_failed"], row["runs_seen"], row["runs_failed"], row["failure_rate"], assertion))
    lines.append("\nRestarts: {}".format(len(report["restarts"])))
    for event in report["restarts"]:
        lines.append("- {}: {}".format(event["run_id"], event["test"] or "unknown test"))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run_ids", nargs="*", help="ci.yml workflow run IDs")
    parser.add_argument("--log-dir", type=Path, help="read existing .log files instead of downloading")
    parser.add_argument("--json-only", action="store_true", help="omit the text table")
    args = parser.parse_args(argv)
    if bool(args.log_dir) == bool(args.run_ids):
        parser.error("provide run IDs or --log-dir, but not both")
    records = read_log_dir(args.log_dir) if args.log_dir else download_runs(args.run_ids)
    report = summarize(records)
    print(json.dumps(report, indent=2, sort_keys=True))
    if not args.json_only:
        print("\n" + table(report))


if __name__ == "__main__":
    main()
