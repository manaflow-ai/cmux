#!/usr/bin/env python3
"""Route Linux guards; unknown inputs and non-PR events run every guard."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

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
        elif path.startswith(("Resources/", "Packages/", "cmux.xcodeproj/",
                              "cmux.xcworkspace/", "ios/")):
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


# --- feat-cmux-next ------------------------------------------------------------------
#
# ci.yml routes these groups only for pull requests into main. cmux-next-guards.yml's guard group
# job runs ci-guards.yml's `ci` group on every feat-cmux-next pull request and push; classify_feat
# picks the other groups (and the lockfile and source-lint jobs) from the same ownership as ci.yml:
# groups_for_path and classify's routes. A push runs every routed group, release-notary included.
FEAT_ALWAYS = ("ci",)
# release-notary (nightly, notarization, signing, Sparkle feed and release-notes publication tests) ran on every
# pull request: about 200,000 runner-minutes in 14 days, and none of its 18 PR failures in that window was the
# change's own (cmuxterm-hq plans/ci/baggage-2026-11-05.md). A pull request now runs it when it changes what the
# group reads: a path the group's steps run or PATH_OWNERS gives it, an unknown path outside FEAT_PRODUCT_AREAS
# (top-level entitlements, Resources/, Config/, the Xcode project: every routed group), or one of these.
RELEASE_NOTARY_INPUTS = (
    # Workflow text and registries its tests pin: nightly.yml's jobs, warm-sources.json, the step-coverage map,
    # runners.json, every workflow's runs-on.
    ".github/",
    # The nightly steps, signing, notary and publication scripts, and the CI tooling its tests import.
    "scripts/ci/",
    # The license-compliance, universal-settings and notices tests read the ghostty and ghostty-next submodules.
    "ghostty",
    # The What's New highlights validator (scripts/whats-new/test_digest.py) reads the repository's highlights;
    # the nightly-next identity test reads retired-feed-announcements.json.
    "release-notes/",
    # The live feed check reads the update ring, the feed resolver and the generated update settings; the
    # nightly-next identity test reads the release push listener (the Sparkle appcast client lives beside it).
    "Packages/macOS/CmuxUpdater/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Schema/SettingsSchema+Updates.generated.swift",
    # The notices pair test runs the nightly's notices precondition on a clone of these at HEAD.
    "cmux-tui/dist/",
    "cmux-tui/build-support/notices/",
    "cmux-tui/rust-toolchain.toml",
    # The Chief cache and web-bundle order tests require the committed inspector page.
    "Native/OptChat/optchat-chief/inspector/index.html",
    # Inputs other groups own that release-notary tests also read.
    "scripts/cmux-next/media/path_map.py",
    "skills/cmux-cloud-vm/references/commands.md",
    "tests/test_ci_owned_spm_scratch.py",
    "tests/test_ci_self_hosted_guard.sh",
    "tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py",
    "tests/test_nightly_dedicated_mini.py",
)


def release_notary_input(path: str) -> bool:
    """Whether a feat-cmux-next pull request that changes path runs the release-notary group."""
    return path.startswith(RELEASE_NOTARY_INPUTS) or path.endswith(".entitlements")
# Guards main's iOS release path only (ios-testflight.yml, ios-appstore-upload.yml and the
# ios/scripts upload tooling): those workflows upload only from refs/heads/main, and
# feat-cmux-next never ships from them. tests/pr-lane-exemptions.json holds the reasons.
FEAT_MAIN_ONLY = ("release-ios",)
FEAT_ROUTED = tuple(group for group in GROUPS if group not in FEAT_ALWAYS + FEAT_MAIN_ONLY) + (
    "workflow-guard-history", "workflow-guard-source-lints",
)
FEAT_ROUTE_JOBS = {"linux_guard_history": "workflow-guard-history", "linux_guard_source": "workflow-guard-source-lints"}
# Product source areas no guard group reads beyond what groups_for_path and classify already
# declare. ci.yml runs every group for an unknown path; on feat-cmux-next that was 254 of the last
# 300 commits, because most of them touch these areas. An unknown path here runs no extra group;
# an unknown path anywhere else (workflows, scripts, tests, Resources, ios, agent-chat, a new
# top-level area) still runs every routed group.
FEAT_PRODUCT_AREAS = (
    "Packages/", "webviews/", "cmux-tui/", "Native/", "backend/", "web/", "schemas/",
    "release-notes/", "plans/", "docs/", "design/", "skills/", "unavailable-features/",
    "clients/", "cmux-next-ios/", "workers/", "experiments/", "first-party-apps/",
)


def classify_feat(paths: list[str]) -> tuple[str, ...]:
    """The guard groups and jobs a feat-cmux-next change runs beside the `ci` group.

    No diff, an unsafe path, or an unknown path outside FEAT_PRODUCT_AREAS runs every routed one.
    """
    if not paths:
        return FEAT_ROUTED
    selected: set[str] = set()
    for path in paths:
        if not path or path.startswith("/") or ".." in path.split("/"):
            return FEAT_ROUTED
        if release_notary_input(path):
            selected.add("release-notary")
        if plain_documentation(path):
            continue
        owners = groups_for_path(path)
        routes = classify([path], event="pull_request", macos="false")
        fails_open = routes == dict.fromkeys(ROUTES, True)
        if owners is None or fails_open:
            if not path.startswith(FEAT_PRODUCT_AREAS):
                return FEAT_ROUTED
        selected.update(owners or ())
        if not fails_open:
            selected.update(job for route, job in FEAT_ROUTE_JOBS.items() if routes[route])
    return tuple(name for name in FEAT_ROUTED if name in selected)


# What the workflow guard profile reads: the workflows and the rest of .github/ (runners.json, warm-sources.json),
# the guard tests, and scripts/ci. A push to feat-cmux-next judged only against the previous tip stays green while a
# red persists, so the guard profile sat red on 18 steps of the branch, unseen, until #31366. A push that touches
# these paths is judged on its own instead (guards_new_reds.py --tip): every red step at the tip fails the job. A
# push that touches none keeps the comparison with the previous tip, which still names the push that turned a step red.
FEAT_PUSH_TIP_INPUTS = (".github/", "tests/", "scripts/ci/")


def feat_push_judges_tip(paths: list[str]) -> bool:
    """Whether a feat-cmux-next push with these changed paths is judged at its tip (no base comparison).

    No diff (a new branch, an unreadable previous tip) is judged at its tip too.
    """
    paths = [path for path in paths if path]
    return not paths or any(path.startswith(FEAT_PUSH_TIP_INPUTS) for path in paths)


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--feat-push-tip":
        try:
            paths = Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            paths = []
        print("true" if feat_push_judges_tip([path.strip() for path in paths]) else "false")
        return
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
