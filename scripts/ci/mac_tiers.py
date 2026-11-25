#!/usr/bin/env python3
"""The Mac tiers a feat-cmux-next pull request routes, for the step table's `mac` job (ci/steps.toml).

    mac_tiers.py route [--github-output FILE]   every tier as KEY=VALUE (cmux_next_route.py's outputs), printed
    mac_tiers.py has TIER                       the same lines, then exit 0 when TIER is routed, 1 when it is not

A `mac` step's inputs are path globs, a superset of what cmux_next_route.py routes to its tier (that router reads
the SwiftPM target graph and the crate graph, which no glob can say). The step's first line asks this script, so
a path the globs over-route skips in a second, and the step routes exactly what cmux-next.yml's job of the same
tier routed on a pull request.

It reads what cmux-next.yml's path_route job read: the change's paths from $CI_PATHS_FILE (`ci/run` writes it;
unset or empty is an unknown change, which routes every tier), the pull request's labels from $GITHUB_EVENT_PATH,
and the merge commit's first parent as the base (`HEAD^1`, for a change to cmux-next.yml and an app FFI re-pin).
As there, a draft or idle head (scripts/ci/head_tier.py `cheap` or `none`) routes no Mac tier, and a fork's pull
request runs the Swift canary only with `full-ci`. Anything this script cannot read routes every tier.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

# The tiers a `mac` step may ask for, each the cmux_next_route.py output of the same name.
TIERS = ("fast_tier", "swift_canary")


def read_paths(paths_file: str | None) -> list[str] | None:
    if not paths_file:
        return None
    try:
        text = Path(paths_file).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    # `ci/run` writes one path a line; pr-pipeline.yml's own list is `git diff -z` (a NUL after each path).
    return [p for p in (text.split("\0") if "\0" in text else text.splitlines()) if p] or None


def read_event(path: str | None) -> dict:
    try:
        return json.loads(Path(path).read_text(encoding="utf-8")) if path else {}
    except (OSError, ValueError):
        return {}


def base_rev(root: Path) -> str | None:
    """The merge commit's first parent, when HEAD is a merge commit (a pull request's checkout)."""
    try:
        done = subprocess.run(["git", "-C", str(root), "rev-parse", "-q", "--verify", "HEAD^2"],
                              capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            return None
        done = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD^1"], capture_output=True, text=True,
                              timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() or None if done.returncode == 0 else None


def tiers(root: Path, environ: dict[str, str]) -> tuple[dict[str, str], str]:
    """(cmux_next_route.py's outputs, one line saying why) for this run."""
    import cmux_next_route  # noqa: PLC0415 - scripts/ci, beside this file
    import head_tier  # noqa: PLC0415

    event_name = environ.get("GITHUB_EVENT_NAME") or "pull_request"
    event = read_event(environ.get("GITHUB_EVENT_PATH"))
    pr = event.get("pull_request") or {}
    labels = {str(label.get("name") or "") for label in pr.get("labels") or []}
    changed = read_paths(environ.get("CI_PATHS_FILE"))
    base = base_rev(root)
    base_workflow = None
    if base and changed and cmux_next_route.WORKFLOW in changed:
        base_workflow = cmux_next_route.base_workflow_text(root, base)
    repin = None
    if event_name == "pull_request" and "full-ci" not in labels:
        repin = cmux_next_route.pure_ffi_repin(root, changed, base)
    values = cmux_next_route.outputs(cmux_next_route.route(root, event_name, changed, labels, base_workflow, repin))
    why = f"{len(changed) if changed is not None else 'unknown'} changed paths"
    if event_name == "pull_request" and event:
        tier, reason = head_tier.decide(event_name, event)
        if tier in ("cheap", "none"):
            for key in TIERS + ("macos",):
                values[key] = "false"
            why += f"; head tier {tier} ({reason}): no Mac tier"
        head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name")
        if head_repo and head_repo != environ.get("GITHUB_REPOSITORY") and "full-ci" not in labels:
            values["swift_canary"] = "false"
            why += "; a fork's pull request runs the Swift canary only with full-ci"
    return values, why


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("route", "has") or (argv[0] == "has" and (len(argv) != 2 or argv[1] not in TIERS)):
        raise SystemExit(f"usage: mac_tiers.py route [--github-output FILE] | has TIER (one of {', '.join(TIERS)})")
    try:
        values, why = tiers(ROOT, dict(os.environ))
    except Exception as error:  # noqa: BLE001 - anything unread routes every tier
        values, why = {key: "true" for key in TIERS + ("macos",)}, f"the route was not read ({error!r}): every tier"
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    print(f"mac tiers: {why}", file=sys.stderr)
    if argv[0] == "route":
        if len(argv) == 3 and argv[1] == "--github-output":
            with open(argv[2], "a", encoding="utf-8") as out:
                out.write("\n".join(lines) + "\n")
        return 0
    routed = values.get(argv[1]) == "true"
    print(f"mac tier {argv[1]}: {'routed' if routed else 'not routed'}", file=sys.stderr)
    return 0 if routed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
