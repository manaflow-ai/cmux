#!/usr/bin/env python3
"""React Doctor ratchet for cmux-next's React projects (https://www.react.doctor/).

React Doctor (pinned in scripts/react-doctor/package.json) scans each project in
PROJECTS. Its error-severity findings are counted per (file, rule) and compared
with scripts/ci/react-doctor-baseline.json, the counts the tree had when the gate
started. A count over its baseline row fails: a change may not add a React Doctor
error. A (file, rule) that is not in the baseline must have zero errors, so new
files start clean. Warnings are reported and never fail.

Fixing errors is free. Lower the baseline in the same commit with
--update-baseline so the gain cannot be spent again; the gate prints a notice
when a row is above what the tree has. Raising a row (a rename moves a file's
rows; a React Doctor bump adds rules) also uses --update-baseline, and the
commit says why.

Counts per file and rule, not line fingerprints: moving code inside a file or
editing the lines around an old finding never fails the gate.

Usage (repo root):
  bun run react-doctor                         # every project, like CI on a dispatch
  python3 scripts/ci/react_doctor_gate.py --changed-from origin/feat-cmux-next
  python3 scripts/ci/react_doctor_gate.py --project webviews --update-baseline
  python3 scripts/ci/react_doctor_gate.py --from-json-dir DIR   # reuse reports (DIR/<name>.json)

Exit 1 when a project gained an error or a scan failed; exit 0 otherwise.
The scan runs with --no-score, --no-supply-chain and telemetry off: no project
data leaves the machine.
"""
import argparse
import collections
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BASELINE = os.path.join(HERE, "react-doctor-baseline.json")
TOOL_DIR = os.path.join(REPO, "scripts", "react-doctor")

# Project directories (repo-relative). `backend` is the bun workspace root of
# backend/apps/dashboard; React Doctor finds the dashboard inside it.
PROJECTS = ["webviews", "agent-chat", "backend", "web", "cmux-tui/frontends/web"]

# A change to any of these rescans every project: they decide what the gate does.
GATE_INPUTS = [
    "scripts/ci/react_doctor_gate.py",
    "scripts/ci/react-doctor-baseline.json",
    "scripts/react-doctor/",
    ".github/workflows/cmux-next-react-doctor.yml",
    "tests/test_react_doctor_gate.py",
]
GITHUB = os.environ.get("GITHUB_ACTIONS") == "true"


def report_name(project):
    return project.replace("/", "_")


def changed_projects(base):
    """Projects a diff from `base` to HEAD touches; every project when the diff is unknown."""
    try:
        out = subprocess.run(["git", "diff", "--name-only", base, "HEAD"], cwd=REPO,
                             capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, OSError) as error:
        print(f"react-doctor: diff from {base} unknown ({error}); scanning every project", file=sys.stderr)
        return list(PROJECTS)
    paths = [p for p in out.splitlines() if p]
    return select_projects(paths)


def select_projects(paths):
    """The projects whose files are in `paths`; all of them when a gate input changed."""
    if any(p == g or (g.endswith("/") and p.startswith(g)) for p in paths for g in GATE_INPUTS):
        return list(PROJECTS)
    return [proj for proj in PROJECTS if any(p.startswith(proj + "/") for p in paths)]


def ensure_tool():
    binary = os.path.join(TOOL_DIR, "node_modules", ".bin", "react-doctor")
    if not os.path.exists(binary):
        run_install(TOOL_DIR)
    return binary


def run_install(directory):
    env = {**os.environ, "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1"}
    if os.path.exists(os.path.join(directory, "bun.lock")):
        helper = os.path.join(REPO, "scripts", "ci", "bun-install.sh")
        cmd = ["bash", helper, "--frozen-lockfile", "--ignore-scripts"] if GITHUB else \
              ["bun", "install", "--frozen-lockfile", "--ignore-scripts"]
    else:
        cmd = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
    print(f"react-doctor: installing {os.path.relpath(directory, REPO)} ({' '.join(cmd[:3])})", file=sys.stderr, flush=True)
    subprocess.run(cmd, cwd=directory, env=env, check=True, stdout=sys.stderr)


def scan(binary, project, out_dir):
    directory = os.path.join(REPO, project)
    if not os.path.isdir(os.path.join(directory, "node_modules")):
        run_install(directory)
    out = os.path.join(out_dir, report_name(project) + ".json")
    env = {**os.environ, "REACT_DOCTOR_NO_TELEMETRY": "1", "NO_COLOR": "1"}
    cmd = [binary, ".", "-y", "--no-score", "--no-supply-chain", "--blocking", "none",
           "--json", "--json-out", out]
    result = subprocess.run(cmd, cwd=directory, env=env, capture_output=True, text=True, timeout=1200)
    if result.returncode != 0 or not os.path.exists(out):
        sys.stderr.write(result.stderr[-4000:])
        raise RuntimeError(f"react-doctor exited {result.returncode} on {project}")
    return out


def load_report(path):
    with open(path) as handle:
        report = json.load(handle)
    if not report.get("ok", False) or not report.get("reactDetected", False):
        raise RuntimeError(f"{path}: scan not ok (ok={report.get('ok')}, reactDetected={report.get('reactDetected')}, "
                           f"error={report.get('error')})")
    return report


def diagnostic_path(diagnostic):
    """The file a diagnostic is in, relative to the scanned project directory."""
    ident = diagnostic.get("id") or ""
    head = ident.split("::", 1)[0]
    return head or diagnostic.get("filePath") or "?"


def error_counts(report):
    counts = collections.Counter()
    for d in report.get("diagnostics", []):
        if d.get("severity") == "error":
            counts[f"{diagnostic_path(d)}::{d.get('plugin')}/{d.get('rule')}"] += 1
    return counts


def compare(project, counts, rows):
    """(new, lowered): keys whose count is over the baseline row, keys whose row is over the count."""
    new = {k: (c, rows.get(k, 0)) for k, c in counts.items() if c > rows.get(k, 0)}
    lowered = {k: (counts.get(k, 0), b) for k, b in rows.items() if counts.get(k, 0) < b}
    return new, lowered


def annotate(project, report, new_keys):
    """Print each error of a (file, rule) that went over its row, with its file:line."""
    lines = []
    for d in report.get("diagnostics", []):
        key = f"{diagnostic_path(d)}::{d.get('plugin')}/{d.get('rule')}"
        if d.get("severity") != "error" or key not in new_keys:
            continue
        path = os.path.normpath(os.path.join(project, diagnostic_path(d)))
        msg = f"{d.get('plugin')}/{d.get('rule')}: {d.get('message', '')} Fix: {d.get('help', '')}".replace("\n", " ")
        if GITHUB:
            print(f"::error file={path},line={d.get('line', 1)},col={d.get('column', 1)},"
                  f"title=React Doctor {d.get('rule')}::{msg}")
        lines.append(f"{path}:{d.get('line', '?')}  {msg}")
    return lines


def load_baseline():
    if not os.path.exists(BASELINE):
        return {"projects": {}}
    with open(BASELINE) as handle:
        return json.load(handle)


def write_baseline(baseline):
    baseline["_doc"] = ("React Doctor error counts per project and file::plugin/rule "
                        "(scripts/ci/react_doctor_gate.py). Counts only go down; a raise needs a reason in the commit.")
    baseline["reactDoctor"] = tool_version()
    baseline["projects"] = {p: dict(sorted(r.items())) for p, r in sorted(baseline["projects"].items()) if r}
    with open(BASELINE, "w") as handle:
        json.dump(baseline, handle, indent=1, sort_keys=False)
        handle.write("\n")


def tool_version():
    with open(os.path.join(TOOL_DIR, "package.json")) as handle:
        return json.load(handle)["devDependencies"]["react-doctor"]


def summary(text):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as handle:
            handle.write(text + "\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--project", action="append", help="scan only this project (repeatable)")
    parser.add_argument("--changed-from", metavar="REV", help="scan only projects the diff REV..HEAD touches")
    parser.add_argument("--from-json-dir", metavar="DIR", help="read DIR/<project>.json instead of scanning")
    parser.add_argument("--out-dir", metavar="DIR", help="keep the JSON reports here")
    parser.add_argument("--update-baseline", action="store_true", help="write the scanned projects' counts")
    args = parser.parse_args(argv)

    if args.project:
        unknown = [p for p in args.project if p not in PROJECTS]
        if unknown:
            parser.error(f"unknown project(s) {unknown}; known: {PROJECTS}")
        projects = args.project
    elif args.changed_from:
        projects = changed_projects(args.changed_from)
    else:
        projects = list(PROJECTS)
    if not projects:
        print("react-doctor: no React project changed; nothing to scan")
        summary("React Doctor: no React project changed.")
        return 0

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="react-doctor-")
    os.makedirs(out_dir, exist_ok=True)
    binary = None if args.from_json_dir else ensure_tool()
    baseline = load_baseline()
    failed = False
    table = ["| Project | Errors | Baseline | Warnings | New errors |", "|---|---:|---:|---:|---:|"]
    for project in projects:
        try:
            if args.from_json_dir:
                path = os.path.join(args.from_json_dir, report_name(project) + ".json")
            else:
                print(f"react-doctor: scanning {project}", file=sys.stderr, flush=True)
                path = scan(binary, project, out_dir)
            report = load_report(path)
        except (RuntimeError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
            print(f"::error title=React Doctor::{project}: {error}" if GITHUB else f"error: {project}: {error}")
            table.append(f"| {project} | scan failed | | | |")
            failed = True
            continue
        counts = error_counts(report)
        warnings = sum(1 for d in report.get("diagnostics", []) if d.get("severity") == "warning")
        rows = baseline["projects"].get(project, {})
        if args.update_baseline:
            baseline["projects"][project] = dict(counts)
            rows = baseline["projects"][project]
        new, lowered = compare(project, counts, rows)
        total, base_total = sum(counts.values()), sum(rows.values())
        table.append(f"| {project} | {total} | {base_total} | {warnings} | {sum(c - b for c, b in new.values())} |")
        print(f"react-doctor: {project}: {total} errors (baseline {base_total}), {warnings} warnings")
        if new:
            failed = True
            print(f"react-doctor: {project}: {len(new)} file/rule pair(s) gained errors:")
            for line in annotate(project, report, set(new)):
                print("  " + line)
            for key, (count, row) in sorted(new.items()):
                print(f"    {key}: {count} (baseline {row})")
        if lowered and not args.update_baseline:
            gain = sum(b - c for c, b in lowered.values())
            note = (f"{project}: {gain} baseline error(s) fixed; lower the baseline in this commit: "
                    f"python3 scripts/ci/react_doctor_gate.py --project {project} --update-baseline")
            print(f"::notice title=React Doctor::{note}" if GITHUB else f"note: {note}")
    if args.update_baseline:
        write_baseline(baseline)
        print(f"react-doctor: wrote {os.path.relpath(BASELINE, REPO)}")
    summary("### React Doctor\n\n" + "\n".join(table) + "\n\n" +
            ("**Failed**: a change added React Doctor errors (see the annotations), or a scan failed. "
             "Fix them, or see scripts/ci/react_doctor_gate.py for a reviewed rebaseline." if failed
             else "Passed: no project gained an error."))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
