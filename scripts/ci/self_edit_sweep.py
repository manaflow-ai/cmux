#!/usr/bin/env python3
"""A workflow sweep does not start a journey whose own workflow file is the only path that reached it.

    self_edit_sweep.py decide --workflow .github/workflows/X.yml    # in self-edit-sweep.yml: run=true|false
    self_edit_sweep.py explain --workflow WF FILE...                # offline: what it would decide for these paths

Heavy journey and lab workflows (staging VMs, the degenerate lab) list their own .yml in `on: pull_request: paths:`
so that a change to their logic runs them. A fleet-wide mechanical sweep edits dozens of workflow files at once
(an actions/checkout repin, a retention-days source, runs-on pools, bounded installs) and so started every journey it
touched, 40 to 86 runner-minutes each, again on every push of a sweep that stays open for days. In the controller's
timing feed for 2026-11-26 20:00-22:30Z, 41 of the 69 pull request runs of the gated journeys (1,157 of 2,223
job-minutes) came from four such sweeps (lane/retention-days-one-source 143 workflow files, lane/checkout-v6-1-0-repin
269, lane/runs-on-literal-pools 66, lane/bounded-bun-install 43). Leo, 2026-11-21: "de facto, im asking for 99% fewer
minutes of ci time, period."

The rule: on a pull request, a gated workflow's heavy jobs skip when
  - the change edits at least SWEEP_MIN_WORKFLOWS files under .github/workflows/ (a sweep), and
  - its own pull_request path filter admits no changed file outside .github/workflows/ (the edit reaches it only
    through workflow files: its own and the sweep's), and
  - the pull request does not carry `full-ci` (full-ci runs everything), and
  - $CI_SELF_EDIT_SWEEP_SKIP is not 0 (the repository variable turns the rule off).
A change to any of its other inputs (a script, a crate) still runs it, a pull request that edits fewer workflow files
(a journey's own logic change) still runs it, and dispatch, push and schedule runs never read this. actionlint and the
workflow tests still cover the sweep's syntax. Of the feat-cmux-next merges from 11-12 to 11-27, 45 of about 1,570
that touched a workflow file touched 10 or more, every one a CI-wide change.

Whatever it cannot read (no merge commit, git fails, no path filter found) answers run=true: it starts more, never
less. Stdlib only, plus workflow_paths_cover_inputs.admits (the one GitHub paths-glob implementation in this tree).
Test: tests/test_ci_self_edit_sweep.py.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import workflow_paths_cover_inputs as filters  # noqa: E402

# A change that edits this many workflow files is a sweep. Each gated workflow's caller job pre-filters on the pull
# request's `changed_files` with the same number (tests/test_ci_self_edit_sweep.py keeps them equal), so a smaller
# pull request never starts the gate at all.
SWEEP_MIN_WORKFLOWS = 10
WORKFLOW_DIR = ".github/workflows/"
FULL_CI = "full-ci"


def is_workflow_file(path: str) -> bool:
    return path.startswith(WORKFLOW_DIR)


def changed_files(cwd: str | None = None) -> list[str] | None:
    """Every path the merge commit changes against its first parent (the base tip), as pr_router.py reads them;
    None when there is no merge commit or git fails."""
    try:
        parents = subprocess.run(["git", "rev-list", "--parents", "-n", "1", "HEAD"], cwd=cwd, check=True,
                                 capture_output=True, text=True).stdout.split()
        if len(parents) != 3:
            return None
        out = subprocess.run(["git", "diff", "--name-only", "--no-renames", "-z", "HEAD^1", "HEAD"], cwd=cwd,
                             check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [p for p in out.split("\0") if p]


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def _strip_comment(value: str) -> str:
    return re.sub(r"\s+#.*$", "", value).strip()


def _scan_paths(text: str) -> list[str] | None:
    """`on.pull_request.paths` read by indentation (no PyYAML on every runner): block or flow sequence."""
    lines = text.splitlines()
    path = []  # (indent, key) of the mapping keys we are inside
    i = 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        m = re.match(r"^\s*(['\"]?)([A-Za-z_][\w-]*)\1:\s*(.*)$", raw)
        if not m or raw.lstrip().startswith("- "):
            continue
        while path and path[-1][0] >= indent:
            path.pop()
        key, rest = m.group(2), _strip_comment(m.group(3))
        keys = [k for _, k in path] + [key]
        if keys == ["on", "pull_request", "paths"]:
            if rest.startswith("["):
                body = rest.strip("[]")
                return [_unquote(item) for item in body.split(",") if item.strip()]
            items = []
            while i < len(lines):
                item = lines[i]
                if not item.strip() or item.lstrip().startswith("#"):
                    i += 1
                    continue
                if len(item) - len(item.lstrip(" ")) < indent or not item.lstrip().startswith("- "):
                    break
                items.append(_unquote(_strip_comment(item.lstrip()[2:])))
                i += 1
            return items
        if not rest:
            path.append((indent, key))
    return None


def pull_request_paths(workflow: Path) -> list[str] | None:
    """The workflow's `on.pull_request.paths`, or None when it has none or it cannot be read."""
    try:
        text = workflow.read_text(encoding="utf-8")
    except OSError:
        return None
    try:
        import yaml  # noqa: PLC0415 - optional: a runner without PyYAML reads by indentation
    except ImportError:
        return _scan_paths(text)
    try:
        document = yaml.safe_load(text)
    except yaml.YAMLError:
        return None
    pr = filters.triggers(document).get("pull_request")
    paths = pr.get("paths") if isinstance(pr, dict) else None
    return [str(p) for p in paths] if isinstance(paths, list) else None


def decide(files: list[str] | None, paths: list[str] | None, labels: set[str],
           switch: str = "1") -> tuple[bool, str]:
    """(run, why) for one pull request head."""
    if switch.strip() == "0":
        return True, "CI_SELF_EDIT_SWEEP_SKIP is 0: the rule is off"
    if FULL_CI in labels:
        return True, f"{FULL_CI}: runs everything"
    if files is None:
        return True, "changed files unknown: runs"
    if not paths:
        return True, "no pull_request path filter read: runs"
    workflows = [f for f in files if is_workflow_file(f)]
    if len(workflows) < SWEEP_MIN_WORKFLOWS:
        return True, f"edits {len(workflows)} workflow files (a sweep is {SWEEP_MIN_WORKFLOWS} or more): runs"
    reached = [f for f in files if not is_workflow_file(f) and filters.admits("paths", paths, f)]
    if reached:
        return True, f"a sweep that also changes its input {reached[0]}: runs"
    return False, (f"a workflow sweep ({len(workflows)} workflow files) reaches it only through workflow files: "
                   f"skipped ({FULL_CI} or a dispatch runs it)")


def event_labels() -> set[str]:
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    except (KeyError, OSError, ValueError):
        return set()
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    if event.get("action") == "labeled":
        labels.add(str((event.get("label") or {}).get("name") or ""))
    return labels


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("decide", "explain"))
    parser.add_argument("--workflow", required=True, help=".github/workflows/X.yml, relative to the checkout")
    parser.add_argument("files", nargs="*")
    args = parser.parse_args(argv)
    paths = pull_request_paths(Path(args.workflow))
    if args.mode == "explain":
        run, why = decide(args.files, paths, set())
        print(f"run={'true' if run else 'false'}: {why}")
        return 0
    run, why = decide(changed_files(), paths, event_labels(), os.environ.get("CI_SELF_EDIT_SWEEP_SKIP", "1"))
    line = f"run={'true' if run else 'false'}"
    print(f"{args.workflow}: {line}: {why}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"{args.workflow}: {why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
