#!/usr/bin/env python3
"""Route Linux guards; unknown inputs and non-PR events run every guard."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from workflow_guard_groups import (
    GROUPS, GUARD_WORKFLOW, PATH_OWNERS, ROUTING_POLICY_PATHS,
    GuardWorkflowError, groups_for_path, route_direct_paths,
)


GUARD_ROUTES = (
    "linux_guard_tests", "linux_guard_history", "linux_guard_cli", "linux_guard_source",
)
ROUTES = GUARD_ROUTES + ("ghosttykit_release",)

# Inputs a guard step exercises without naming them in its `run:`. Everything a
# step runs directly is read out of ci-guards.yml instead of being listed here,
# so a renamed or deleted guard step cannot leave a stale route behind.
INDIRECT_ROUTE_INPUTS = {
    # The two CLI contracts each exercise the script they are named after.
    "linux_guard_cli": frozenset({
        "Resources/bin/start-cmux-profiling",
        "scripts/ci/resolve-cmux-tui-client-commit.sh",
    }),
    # workflow-guard-tests reads these through an import, a working directory,
    # or yaml.safe_load; PATH_OWNERS is the one place they are declared.
    "linux_guard_tests": frozenset(PATH_OWNERS),
}

# ghosttykit-release-check lives in ci.yml, not ci-guards.yml, so this module
# cannot see that it owns the pinned GhosttyKit artifact. A submodule bump keeps
# the conservative fallback even though workflow-guard-tests also reads it.
GHOSTTYKIT_PROVENANCE = frozenset({"ghostty"})


def route_inputs() -> dict[str, frozenset[str]] | None:
    """Map each guard route to the paths that route's job observes.

    Returns None when ci-guards.yml cannot be read, so the caller falls open to
    every guard rather than routing from a half-known workflow.
    """
    try:
        derived = route_direct_paths(GUARD_WORKFLOW.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, GuardWorkflowError):
        return None
    if set(derived) != set(GUARD_ROUTES):
        return None
    return {
        route: frozenset(derived[route] | INDIRECT_ROUTE_INPUTS.get(route, frozenset()))
        - ROUTING_POLICY_PATHS - GHOSTTYKIT_PROVENANCE
        for route in GUARD_ROUTES
    }


def plain_documentation(path: str) -> bool:
    if path.startswith("skills/cmux-cua/") or path == "docs/cli-contract.md":
        return False
    name = path.rsplit("/", 1)[-1]
    if name in {"AGENTS.md", "CLAUDE.md"}:
        return True
    if "/" not in path and (path == "README.md" or path.startswith("README.")):
        return path.endswith(".md")
    return path.startswith(("docs/", "design/", "plans/")) and path.endswith(".md")


def classify(paths: list[str], *, event: str, macos: str) -> dict[str, bool]:
    all_guards = dict.fromkeys(ROUTES, True)
    if event != "pull_request" or macos not in {"true", "false"} or not paths:
        return all_guards
    inputs = route_inputs()
    if inputs is None:
        return all_guards
    routes = dict.fromkeys(ROUTES, False)
    routes["ghosttykit_release"] = macos == "true"
    for path in paths:
        if not path or path.startswith("/") or ".." in path.split("/"):
            return all_guards
        if plain_documentation(path):
            continue
        # The mixed suite includes source, resource, and packaging contracts.
        # Keep it for code changes until those contracts have finer ownership.
        routes["linux_guard_tests"] = True
        observers = [route for route in GUARD_ROUTES if path in inputs[route]]
        if observers:
            # A guard job runs this path itself, so only those jobs observe it.
            for route in observers:
                routes[route] = True
        elif path.rsplit("/", 1)[-1] in {"Package.swift", "Package.resolved", "project.pbxproj",
                                              "contents.xcworkspacedata", ".gitignore"}:
            routes["linux_guard_history"] = True
            routes["linux_guard_source"] = True
        elif path.startswith(("Sources/", "CLI/", "Resources/", "Packages/",
                              "cmuxTests/", "cmuxCLITests/", "cmuxCLITestSupport/",
                              "cmuxUITests/", "cmux.xcodeproj/",
                              "cmux.xcworkspace/", "vendor/bonsplit/", "ios/")):
            routes["linux_guard_source"] = True
        elif path.startswith(("web/", "webviews/", "cmux-tui/")):
            pass
        else:
            # Workflows, scripts, tests, new top-level areas, and the router
            # itself retain all coverage. New guard inputs cannot silently skip.
            return all_guards
    return routes


def classify_test_groups(paths: list[str], *, event: str, macos: str) -> tuple[str, ...]:
    """Select only workflow-guard-tests groups that can observe this diff."""
    if event != "pull_request" or macos not in {"true", "false"} or not paths:
        return GROUPS

    selected: set[str] = set()
    for path in paths:
        if not path or path.startswith("/") or ".." in path.split("/"):
            return GROUPS
        if plain_documentation(path):
            continue
        owners = groups_for_path(path)
        if owners is None:
            return GROUPS
        selected.update(owners)

    # linux_guard_tests skips documentation-only diffs. Keep a valid non-empty
    # matrix value available anyway so malformed callers cannot create an empty
    # matrix-expansion failure.
    if not selected:
        return GROUPS
    return tuple(group for group in GROUPS if group in selected)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--macos", required=True)
    parser.add_argument("--files-from", type=Path, required=True)
    args = parser.parse_args()
    try:
        paths = args.files_from.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        paths = []
    routes = classify(paths, event=args.event_name, macos=args.macos)
    for name, enabled in routes.items():
        print(f"{name}={'true' if enabled else 'false'}")
    groups = classify_test_groups(paths, event=args.event_name, macos=args.macos)
    print(f"linux_guard_test_groups={json.dumps(groups, separators=(',', ':'))}")


if __name__ == "__main__":
    main()
