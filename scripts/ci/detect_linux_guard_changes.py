#!/usr/bin/env python3
"""Route Linux guards; unknown inputs and non-PR events run every guard."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from workflow_guard_groups import GROUPS, groups_for_path


ROUTES = (
    "linux_guard_tests", "linux_guard_history", "linux_guard_cli",
    "linux_guard_source", "ghosttykit_release",
)
CLI_INPUTS = {
    "Resources/bin/start-cmux-profiling",
    "scripts/ci/resolve-cmux-tui-client-commit.sh",
    "tests/test_start_cmux_profiling.sh",
    "tests/test_ci_resolve_cmux_tui_client_commit.sh",
}
HISTORY_INPUTS = {
    "scripts/check-package-resolved-policy.py",
    "tests/test_package_resolved_policy_remote_inputs.py",
    "tests/test_check_package_resolved_policy.py",
}
# Exact inputs of the Cloud skill coverage check in workflow-guard-tests.
# New tests and skill files retain the conservative fallback until mapped.
WORKFLOW_TEST_INPUTS = {
    "scripts/ci/build_input_fingerprint.py",
    "scripts/ci/find_admitted_build.py",
    "scripts/ci/app_host_test_products.py",
    "scripts/ci/compile-app-host-test-product.sh",
    "scripts/ci/product_input_identity.py",
    "scripts/ci/peer_product_source.py",
    "scripts/ci/restore-app-host-test-product.sh",
    "scripts/ci/reuse_app_host_products.py",
    "scripts/ci/sanitize-xcode-source-packages-cache.py",
    "scripts/ci/persistent_mac_route.py",
    "scripts/ci/build_graph_health.py",
    "tests/test_build_graph_health.py",
    "scripts/ci/swift_incremental_diagnostics.py",
    "tests/test_ci_persistent_mac_compile.py",
    "tests/test_swift_incremental_diagnostics.py",
    "tests/test_ci_self_hosted_guard.sh",
    ".github/review-fabric-policy.json",
    ".github/review-fabric.md",
    ".github/scripts/review_fabric.py",
    "tests/test_review_fabric.py",
    "tests/test_cloud_vm_skill_coverage.py",
    "skills/cmux-cloud-vm/SKILL.md",
    "skills/cmux-cloud-vm/references/commands.md",
    "skills/cmux-cloud-vm/references/agent-workflows.md",
    "skills/cmux-cloud-vm/references/guest.md",
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
        if path in WORKFLOW_TEST_INPUTS:
            pass
        elif path in CLI_INPUTS:
            routes["linux_guard_cli"] = True
        elif path in HISTORY_INPUTS:
            routes["linux_guard_history"] = True
        elif path.rsplit("/", 1)[-1] in {"Package.swift", "Package.resolved", "project.pbxproj",
                                              "contents.xcworkspacedata", ".gitignore"}:
            routes["linux_guard_history"] = True
            routes["linux_guard_source"] = True
        elif path.startswith(("Sources/", "CLI/", "Resources/", "Packages/",
                              "cmuxTests/", "cmuxUITests/", "cmux.xcodeproj/",
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
