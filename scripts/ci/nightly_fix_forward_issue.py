#!/usr/bin/env python3
"""The nightly's lint-class findings, kept in one fix-forward issue instead of stopping the publish.

    nightly_fix_forward_issue.py outputs --report FILE        (in the job that ran the checks)
    nightly_fix_forward_issue.py file --repo OWNER/REPO       (in report-nightly-fix-forward, GH_TOKEN set)

Leo, 2026-11-20, after check:design-tokens held the NEXT nightly for 15 h: "aren't these a bit bad to halt the
nightly on? what about the fixit/ignoring and fixing forward for things?" The nightly runs
fast_gate_webviews_checks.py with --advisory-out: a failed check of class `lint` (CHECK_CLASSES there) is written
to that report and never fails the step; a `blocks` check still does.

`outputs` turns the report into the step outputs `lint_report` (compact JSON, cut to OUTPUT_MAX) and prints one
`::warning` per failed check, so the run's summary names it. No report file means the checks never got that far:
it writes nothing, and the report job stays off.

`file` opens or updates the one open issue titled TITLE with LINT_REPORT (env), the run link and BUILD_SHA, or,
on a clean report, comments that BUILD_SHA passed and closes it. A failed GitHub write is a warning: the nightly
ships whatever this script does (exit 0 always).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_pages  # noqa: E402

TITLE = "Nightly fix-forward: lint-class checks failing"
LABEL = "nightly-fix-forward"
OUTPUT_MAX = 6000  # a job output stays small; the run log holds every finding
EXCERPT_LINES = 20


def load(path: Path) -> dict | None:
    try:
        report = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return report if isinstance(report, dict) else None


def compact(report: dict) -> str:
    """The report as one JSON line within OUTPUT_MAX, findings trimmed per check first."""
    failed = [{"check": item.get("check", "?"), "findings": list(item.get("findings") or [])[:EXCERPT_LINES]}
              for item in report.get("failed") or []]
    text = json.dumps({"failed": failed}, separators=(",", ":"))
    while len(text) > OUTPUT_MAX and any(item["findings"] for item in failed):
        for item in failed:
            if item["findings"]:
                item["findings"].pop()
        text = json.dumps({"failed": failed}, separators=(",", ":"))
    return text  # with every finding trimmed only check names remain, far under OUTPUT_MAX; never cut the JSON


def outputs(report_path: Path, github_output: str | None) -> int:
    report = load(report_path)
    if report is None:
        print(f"nightly fix-forward: no lint report at {report_path}; nothing to file")
        return 0
    line = compact(report)
    for item in report.get("failed") or []:
        first = (item.get("findings") or ["(no finding printed)"])[0]
        print(f"::warning title=nightly lint (fix forward) {item.get('check')}::{first} -- the nightly ships; "
              f"filed in '{TITLE}'")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as out:
            out.write(f"lint_report={line}\n")
    print(f"nightly fix-forward: lint_report={line}")
    return 0


def body(report: dict, run_url: str, sha: str) -> str:
    lines = [f"The nightly built `{sha}` with lint-class checks failing ({run_url}). These never stop the "
             "nightly; fix them forward on feat-cmux-next.", ""]
    for item in report.get("failed") or []:
        lines.append(f"### `{item.get('check')}`")
        lines.append("~~~~")  # a finding may hold ``` itself
        lines.extend(str(f).replace("~~~~", "~ ~ ~ ~") for f in
                     item.get("findings") or ["(no finding printed; see the run log)"])
        lines.append("~~~~")
    lines.append("")
    lines.append("This issue is updated by each nightly (scripts/ci/nightly_fix_forward_issue.py) and closed by the "
                 "first nightly whose lint-class checks all pass.")
    return "\n".join(lines)


def gh(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as exc:  # no gh on the runner, or a hung call: a warning, not a red
        return subprocess.CompletedProcess(["gh", *args], 1, "", str(exc))


def open_issue(repo: str) -> str | None:
    """The open issue titled TITLE that the run's token opened, read from the issues list (as
    report-visual-gate-nightly does), not the search index, which lags and would let a quick rerun open a second."""
    def fetch(url: str):
        # One bounded page per call through gh() (the quota wrapper refuses gh api's paginate flag).
        page = gh("api", url)
        if page.returncode:
            raise RuntimeError(page.stderr.strip()[:300])
        return json.loads(page.stdout or "[]")

    for issue in gh_pages.items(fetch, f"repos/{repo}/issues?state=open&creator=github-actions%5Bbot%5D"):
        if issue.get("pull_request") is None and issue.get("title") == TITLE:
            return str(issue["number"])
    return None


def file(repo: str, report: dict, run_url: str, sha: str) -> int:
    try:
        number = open_issue(repo)
        if not report.get("failed"):
            if number:
                gh("issue", "comment", number, "-R", repo, "--body", f"Lint-class checks pass at `{sha}` ({run_url}).")
                closed = gh("issue", "close", number, "-R", repo)
                if closed.returncode:
                    raise RuntimeError(closed.stderr.strip()[:300])
                print(f"nightly fix-forward: closed #{number}, the checks pass at {sha}")
            return 0
        text = body(report, run_url, sha)
        if number:
            done = gh("issue", "edit", number, "-R", repo, "--body-file", "-", stdin=text)
            gh("issue", "comment", number, "-R", repo, "--body",
               f"Still failing at `{sha}` ({run_url}): " + ", ".join(f"`{i.get('check')}`" for i in report["failed"]))
        else:
            labels = gh("label", "list", "-R", repo, "--search", LABEL, "--json", "name")
            has_label = labels.returncode == 0 and any(l.get("name") == LABEL for l in json.loads(labels.stdout or "[]"))
            done = gh("issue", "create", "-R", repo, "--title", TITLE, "--body-file", "-",
                      *(["--label", LABEL] if has_label else []), stdin=text)
        if done.returncode:
            raise RuntimeError(done.stderr.strip()[:300])
        where = number or done.stdout.strip()
        print(f"::warning title=nightly fix-forward::lint-class checks fail at {sha}; the nightly ships; see {where}")
    except Exception as exc:  # noqa: BLE001  (never the nightly's failure)
        print(f"::warning title=nightly fix-forward::could not write the fix-forward issue: {exc}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    out = sub.add_parser("outputs")
    out.add_argument("--report", type=Path, required=True)
    filed = sub.add_parser("file")
    filed.add_argument("--repo", required=True)
    args = parser.parse_args(argv)
    if args.command == "outputs":
        return outputs(args.report, os.environ.get("GITHUB_OUTPUT"))
    try:
        report = json.loads(os.environ.get("LINT_REPORT") or "{}")
        if not isinstance(report, dict):
            raise ValueError
    except ValueError:
        print("::warning title=nightly fix-forward::LINT_REPORT is not JSON; nothing filed")
        return 0
    run_url = f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/{args.repo}/actions/runs/" \
              f"{os.environ.get('GITHUB_RUN_ID', '')}"
    return file(args.repo, report, run_url, os.environ.get("BUILD_SHA", "?"))


if __name__ == "__main__":
    sys.exit(main())
