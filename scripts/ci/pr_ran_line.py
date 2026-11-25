#!/usr/bin/env python3
"""The one line on a pull request that says which workflows its diff started, and why each one.

Leo, 2026-11-19: "only meaningful tests ... not just there for ticky tack". A person reading a pull request
should see, without opening Actions, what CI ran for this change and what started each workflow. This reads the
`on: pull_request` trigger of every workflow under .github/workflows at the base commit and the pull request's
changed files, and writes one line:

    ran 7 workflows for this diff: web (webviews/src/a.tsx), React Doctor (webviews/src/a.tsx) ...;
    on every PR: PR checks, cmux-next guards ...; not started: 61 (no changed file in their paths)

A workflow is started when its `branches` / `branches-ignore` admit the base branch and its `paths` /
`paths-ignore` admit at least one changed file, with GitHub's rules (workflow_paths_cover_inputs.admits: `**`
crosses directories, later patterns win, `!` negates). Its reason is the first changed file the filter admits,
and "+N" more when several do. A workflow with no path filter is listed under "on every PR": that is the list a
change to CI should keep short, since each of those starts for a Markdown typo too. A job inside a started
workflow may still skip itself (`if:`, a router such as scripts/ci/cmux_next_route.py); the workflow's own run
page says which, and the line names the router where one decides.

pr_red_checks_comment.py writes it as the `ran` section of the status comment (scripts/ci/pr_status.py), so it
costs no job and no step of its own. The line is computed from files at the base commit, never the pull
request's code.

    pr_ran_line.py --base-branch feat-cmux-next --changed-files FILE [--root DIR]   # print the line
"""
from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from workflow_paths_cover_inputs import admits, glob_regex, load_yaml, triggers  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
EVENT = "pull_request"
# The activity types a push to the pull request sends (GitHub's default `types` are opened, synchronize, reopened).
PUSHED = {"opened", "synchronize", "reopened"}
# Workflows whose jobs a router picks after the workflow starts: the line names the router, not each job.
ROUTERS = {
    "cmux-next.yml": "tiers by scripts/ci/cmux_next_route.py",
    "cmux-tui-spec.yml": "jobs by scripts/ci/affected_jobs.py",
    "ci.yml": "jobs by its changes job",
}
SHOWN = 12  # started workflows named in full; the rest are counted


@dataclass
class Started:
    file: str
    name: str
    why: str  # the first admitted changed file (+N), or "" for a workflow with no path filter


def branch_admits(config: dict, branch: str) -> bool:
    """Whether the trigger's branch filter admits a pull request into `branch` (later patterns win, `!` negates)."""
    if "branches" in config:
        return admits("paths", [str(b) for b in config.get("branches") or []], branch)
    if "branches-ignore" in config:
        return admits("paths-ignore", [str(b) for b in config.get("branches-ignore") or []], branch)
    return True


def trigger(document) -> dict | None:
    """The pull_request trigger's settings when a push to a pull request can fire it, else None (no such trigger, or
    one for `closed` or `labeled` only)."""
    events = triggers(document)
    if EVENT not in events:
        return None
    config = events[EVENT] if isinstance(events[EVENT], dict) else {}
    types = config.get("types")
    if types is not None and not PUSHED & {str(t) for t in (types if isinstance(types, list) else [types])}:
        return None
    return config


def started(document, file: str, branch: str, changed: list[str]) -> Started | None:
    """The workflow's pull_request trigger fires for this diff: why, or None when it does not."""
    config = trigger(document)
    if config is None or not branch_admits(config, branch):
        return None
    name = str(document.get("name") or file.removesuffix(".yml"))
    for kind in ("paths", "paths-ignore"):
        if kind in config:
            patterns = [str(p) for p in config.get(kind) or []]
            hits = [path for path in changed if admits(kind, patterns, path)]
            if not hits:
                return None
            more = f" +{len(hits) - 1}" if len(hits) > 1 else ""
            return Started(file, name, hits[0] + more)
    return Started(file, name, "")


def plan(root: Path, branch: str, changed: list[str]) -> tuple[list[Started], int]:
    """Every workflow this diff starts (path-filtered first, in file order), and how many pull_request workflows it
    does not start."""
    runs, skipped = [], 0
    for path in sorted((root / ".github" / "workflows").glob("*.yml")):
        document = load_yaml(path)
        if not isinstance(document, dict) or trigger(document) is None:
            continue
        hit = started(document, path.name, branch, changed)
        if hit is None:
            skipped += 1
        else:
            runs.append(hit)
    return runs, skipped


def line(runs: list[Started], skipped: int) -> str:
    def label(run: Started) -> str:
        router = ROUTERS.get(run.file)
        return f"{run.name} ({router})" if router and not run.why else run.name

    filtered = [r for r in runs if r.why]
    every = [r for r in runs if not r.why]
    parts = [", ".join(f"{label(r)} ({r.why})" for r in filtered[:SHOWN])
             + (f" and {len(filtered) - SHOWN} more" if len(filtered) > SHOWN else "")]
    text = f"ran {len(runs)} workflows for this diff: " + (parts[0] or "none started by a changed file")
    if every:
        text += "; on every PR: " + ", ".join(label(r) for r in every)
    return text + f"; not started: {skipped} (no changed file in their paths)"


def ran_line(root: Path, branch: str, changed: list[str]) -> str:
    return line(*plan(root, branch, changed))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--base-branch", required=True)
    parser.add_argument("--changed-files", type=Path, required=True, help="one repository path per line")
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    changed = [p for p in args.changed_files.read_text(encoding="utf-8").splitlines() if p.strip()]
    print(ran_line(args.root, args.base_branch, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
