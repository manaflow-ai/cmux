#!/usr/bin/env python3
"""Validate that every Python regression has a declared, live execution path.

Enforcement is scoped to the pull request that causes the problem.

A test file with no registry entry is a hard failure only when this pull
request is the one that added it (compared against the merge base). A test
that was already unregistered on the base branch is reported as a warning:
it is somebody else's oversight, and failing here would turn every open pull
request red for a reason its author cannot fix.

Everything a pull request can only break by editing the registry itself --
malformed entries, unknown fields, entries pointing at files that no longer
exist, lanes no workflow runs -- stays a hard failure.

Duplicate registrations sit between the two. Two pull requests that each
register the same test merge cleanly into a duplicate nobody wrote, so a
duplicate already present on the base branch warns and one this branch
introduces fails.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

# Tests load this file through importlib, which does not add its directory
# to sys.path the way running it as a script does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_execution_registry import load_registry, parse_registry  # noqa: E402


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "tests" / "test-execution.toml"
WORKFLOWS = ROOT / ".github" / "workflows"
CI_GUARDS = WORKFLOWS / "ci-guards.yml"
RUNNER_RE = re.compile(r"scripts/ci/run_python_test_lane\.py\s+--lane\s+([A-Za-z0-9_.-]+)")
TEST_PATH_RE = re.compile(r"^tests/test_[A-Za-z0-9_.-]+\.py$")
ALLOWED_FIELDS = {"path", "lane", "requirements", "reason"}
INVENTORY_LANES = {"legacy", "manual"}
SUPPORTED_REQUIREMENTS = {"cmux-cli", "fish"}
# A workflow that names a test file in a `run:` step executes it directly,
# which is exactly what the linux-guard lane means.
DIRECT_RUN_LANE = "linux-guard"


def runner_lanes_from_workflow_text(text: str) -> set[str]:
    lanes: set[str] = set()
    for line in text.splitlines():
        executable = line.split("#", 1)[0]
        lanes.update(RUNNER_RE.findall(executable))
    return lanes


def workflow_files(workflows: Path = WORKFLOWS) -> list[Path]:
    return sorted(workflows.glob("*.y*ml"))


def all_workflow_text(workflows: Path = WORKFLOWS) -> str:
    """Every workflow's text, for asking whether a path is executed anywhere.

    A Linux guard does not have to live in ci-guards.yml to be live. The
    always-on lanes run guards too -- testbox-broker-guard.yml deliberately has
    no path filter, and ci-artifact-transport.yml owns its own -- so checking
    ci-guards.yml alone rejects a test that demonstrably executes on every
    pull request.
    """
    return "\n".join(
        workflow.read_text(encoding="utf-8") for workflow in workflow_files(workflows)
    )


def runner_lanes(workflows: Path = WORKFLOWS) -> set[str]:
    lanes: set[str] = set()
    for workflow in workflow_files(workflows):
        lanes.update(runner_lanes_from_workflow_text(workflow.read_text(encoding="utf-8")))
    return lanes


def workflow_running(path: str, workflows: Path = WORKFLOWS) -> str | None:
    """The first workflow whose text already runs `path`, if any."""
    for workflow in workflow_files(workflows):
        if path in workflow.read_text(encoding="utf-8"):
            return workflow.name
    return None


def registration_hint(path: str, workflows: Path = WORKFLOWS, live_lanes: set[str] | None = None) -> str:
    """The exact TOML block to paste, with a lane filled in where we can derive one."""
    workflow = workflow_running(path, workflows)
    if workflow is not None:
        lane = DIRECT_RUN_LANE
        rationale = f"Lane derived from .github/workflows/{workflow}, which already runs {path}."
    else:
        lane = "<lane>"
        lanes = sorted(live_lanes or runner_lanes(workflows))
        choices = ", ".join(lanes) if lanes else "(no runner lane is wired up)"
        rationale = (
            f"No workflow runs {path} directly, so pick the lane that should own it.\n"
            f"      Runner lanes: {choices}.\n"
            f'      Use lane = "{DIRECT_RUN_LANE}" once a ci-guards.yml step runs the file,\n'
            f'      or lane = "manual" with a reason = "..." when it cannot run in CI.'
        )
    return (
        "\n      Paste into tests/test-execution.toml:\n\n"
        "          [[test]]\n"
        f'          path = "{path}"\n'
        f'          lane = "{lane}"\n\n'
        f"      {rationale}"
    )


def merge_base(base_sha: str, root: Path = ROOT) -> str | None:
    """The merge base of `base_sha` and HEAD, or None on a shallow clone."""
    try:
        result = subprocess.run(
            ["git", "merge-base", base_sha, "HEAD"],
            cwd=root,
            text=True,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def comparison_point(base_sha: str, root: Path = ROOT) -> str:
    """Where to diff this branch from.

    `git merge-base <base_sha> HEAD` is the `<base_sha>...HEAD` base. When the
    clone is too shallow for a merge base -- CI fetches the base commit at
    depth 1 -- fall back to the base commit itself, which still names only
    files this branch has and the base branch does not.
    """
    return merge_base(base_sha, root) or base_sha


def newly_added_tests(base_sha: str, root: Path = ROOT) -> set[str]:
    """Test files this branch adds, relative to the merge base with `base_sha`."""
    output = subprocess.check_output(
        [
            "git",
            "diff",
            "--name-only",
            "--diff-filter=A",
            comparison_point(base_sha, root),
            "HEAD",
            "--",
            "tests",
        ],
        cwd=root,
        text=True,
    )
    return {line.strip() for line in output.splitlines() if TEST_PATH_RE.fullmatch(line.strip())}


def duplicated_paths(entries: list[dict[str, object]]) -> set[str]:
    counts = Counter(
        str(entry["path"]) for entry in entries if isinstance(entry.get("path"), str)
    )
    return {path for path, count in counts.items() if count != 1}


def base_duplicated_paths(base_sha: str, root: Path = ROOT) -> set[str]:
    """Paths already registered twice on the base branch.

    Two pull requests that each register the same test merge cleanly and land a
    duplicate nobody wrote, so a duplicate this branch did not create is not
    this branch's failure. `tests/test_sync_test_wiring.py` reached main this
    way through #13738 and #13739.
    """
    point = comparison_point(base_sha, root)
    text = subprocess.check_output(
        ["git", "show", f"{point}:tests/test-execution.toml"],
        cwd=root,
        text=True,
    )
    return duplicated_paths(parse_registry(text, f"{point}:tests/test-execution.toml"))


def validate(
    root: Path = ROOT,
    base_sha: str = "",
    added: set[str] | None = None,
    base_duplicates: set[str] | None = None,
) -> tuple[list[str], list[str], Counter[str]]:
    """Return (hard errors, warnings, lane counts) for the registry under `root`."""
    manifest = root / "tests" / "test-execution.toml"
    workflows = root / ".github" / "workflows"

    errors: list[str] = []
    warnings: list[str] = []

    entries = load_registry(manifest)

    discovered = {
        path.relative_to(root).as_posix()
        for path in (root / "tests").glob("test_*.py")
        if path.is_file()
    }

    paths: list[str] = []
    by_path: dict[str, dict[str, object]] = {}
    for index, entry in enumerate(entries, start=1):
        unknown = sorted(set(entry) - ALLOWED_FIELDS)
        if unknown:
            errors.append(f"entry {index}: unknown fields: {', '.join(unknown)}")

        path = entry.get("path")
        lane = entry.get("lane")
        if not isinstance(path, str) or not TEST_PATH_RE.fullmatch(path):
            errors.append(f"entry {index}: invalid test path {path!r}")
            continue
        if not isinstance(lane, str) or not lane:
            errors.append(f"{path}: lane must be a non-empty string")
            continue

        requirements = entry.get("requirements", [])
        if not isinstance(requirements, list) or not all(isinstance(value, str) for value in requirements):
            errors.append(f"{path}: requirements must be a list of strings")
        else:
            unknown_requirements = sorted(set(requirements) - SUPPORTED_REQUIREMENTS)
            if unknown_requirements:
                errors.append(f"{path}: unsupported requirements: {', '.join(unknown_requirements)}")

        if lane == "manual" and not isinstance(entry.get("reason"), str):
            errors.append(f"{path}: manual tests require a reason")
        if lane != "manual" and "reason" in entry:
            errors.append(f"{path}: reason is only valid for manual tests")

        paths.append(path)
        by_path[path] = entry

    if base_duplicates is None and base_sha:
        try:
            base_duplicates = base_duplicated_paths(base_sha, root)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            warnings.append(f"could not read the base registry at {base_sha}: {error}")
    already_duplicated = base_duplicates or set()

    for path in sorted(path for path, count in Counter(paths).items() if count != 1):
        if path in already_duplicated:
            warnings.append(
                f"{path}: registered more than once. The duplicate is already on the base "
                "branch, so this is a warning and does not fail the build. Delete one of "
                "its [[test]] blocks in tests/test-execution.toml."
            )
        else:
            errors.append(f"{path}: registered more than once")

    # A stale entry can only be produced by the pull request that deletes or
    # renames the test, so it stays a hard failure.
    for path in sorted(set(paths) - discovered):
        errors.append(f"{path}: registry entry points to a missing test")

    live_runner_lanes = runner_lanes(workflows)

    if added is None and base_sha:
        try:
            added = newly_added_tests(base_sha, root)
        except (OSError, subprocess.CalledProcessError) as error:
            # Losing the comparison is an infrastructure problem, not something
            # this pull request did. Warn instead of reddening it.
            warnings.append(
                f"could not compare new tests against {base_sha}: {error}; "
                "unregistered tests are reported as warnings only"
            )

    for path in sorted(discovered - set(paths)):
        hint = registration_hint(path, workflows, live_runner_lanes)
        if added is not None and path in added:
            errors.append(f"{path}: added by this pull request with no execution registry entry.{hint}")
        else:
            warnings.append(
                f"{path}: test exists but has no execution registry entry. "
                "It was not added by this pull request, so this is a warning "
                f"and does not fail the build.{hint}"
            )

    guard_text = all_workflow_text(workflows)
    for path, entry in sorted(by_path.items()):
        lane = entry.get("lane")
        if lane in INVENTORY_LANES:
            continue
        if lane == DIRECT_RUN_LANE:
            if path not in guard_text:
                errors.append(f"{path}: linux-guard lane is not run by any workflow")
        elif lane not in live_runner_lanes:
            errors.append(f"{path}: lane {lane!r} has no workflow invocation")

    if added is not None:
        for path in sorted(added):
            entry = by_path.get(path)
            if entry and entry.get("lane") == "legacy":
                errors.append(f"{path}: newly added tests may not enter the legacy migration lane")

    lane_counts = Counter(str(entry["lane"]) for entry in entries if "lane" in entry)
    return errors, warnings, lane_counts


def report_warnings(warnings: list[str]) -> None:
    """Print warnings, annotate them in Actions, and note them in the step summary."""
    if not warnings:
        return

    for warning in warnings:
        print(f"warning: {warning}")

    if os.environ.get("GITHUB_ACTIONS") == "true":
        for warning in warnings:
            headline = warning.split("\n", 1)[0]
            path = headline.split(":", 1)[0]
            if TEST_PATH_RE.fullmatch(path):
                print(f"::warning file={path}::{headline}")
            else:
                print(f"::warning::{headline}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        return
    lines = ["### Python test execution registry warnings", ""]
    lines.extend(f"- {warning.splitlines()[0]}" for warning in warnings)
    lines.extend(
        [
            "",
            "These tests are unregistered but were not added by this pull request, "
            "so they do not fail it. Register them in `tests/test-execution.toml`.",
            "",
        ]
    )
    try:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    except OSError:
        pass


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-sha", default="")
    args = parser.parse_args(argv)

    try:
        errors, warnings, lane_counts = validate(ROOT, args.base_sha)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1

    report_warnings(warnings)

    if errors:
        print("Python test execution registry validation failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    summary = ", ".join(f"{lane}={count}" for lane, count in sorted(lane_counts.items()))
    discovered = sum(1 for path in (ROOT / "tests").glob("test_*.py") if path.is_file())
    print(f"Python test execution registry valid: {discovered} tests ({summary})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
