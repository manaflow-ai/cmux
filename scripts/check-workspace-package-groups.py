#!/usr/bin/env python3
"""Generate / verify the SPM package grouping in cmux.xcworkspace.

The on-disk folder layout is the single source of truth. Every Swift package
lives physically under exactly one group directory:

    Packages/Shared/<pkg>     packages shared by the macOS and iOS apps
    Packages/iOS/<pkg>        iOS-app-only packages
    Packages/macOS/<pkg>      macOS-app-only packages

The root workspace mirrors that shape one-to-one: it has three groups whose
container locations are those folders, and every package directory appears as a
FileRef under its folder's group. To move a package between groups you `git mv`
its directory; this script regenerates the workspace to match.

Usage:
    check-workspace-package-groups.py            # --check (default): exit 1 on drift
    check-workspace-package-groups.py --check
    check-workspace-package-groups.py --write    # rewrite contents.xcworkspacedata
"""

from __future__ import annotations

import argparse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)

PACKAGES_DIR = os.path.join(ROOT, "Packages")
WORKSPACE_DATA = os.path.join(ROOT, "cmux.xcworkspace", "contents.xcworkspacedata")

# Group directories, in the order they appear in the workspace.
GROUPS = ["Shared", "iOS", "macOS"]

# Structural workspace entries that are not Packages/<group>/* folders; kept
# verbatim so regeneration only ever touches package membership.
TOP_LEVEL_PROJECTS = ["group:cmux.xcodeproj", "group:ios/cmux-ios.xcodeproj"]
# The iOS app's own SwiftPM package lives outside Packages/; it heads the iOS
# group.
IOS_APP_PACKAGE_REF = "container:ios/cmuxPackage"
# The Examples group is curated by hand and lives under a different container.
EXAMPLES_GROUP = (
    "container:Examples",
    "Examples",
    [
        "group:TabsVisibleSidebar/TabsVisibleSidebar.xcodeproj",
        "group:SampleSidebarExtensionApp/SampleSidebarExtensionApp.xcodeproj",
        "group:CmuxExtensionSidebarExamples",
    ],
)


def packages_in(group: str) -> list[str]:
    group_dir = os.path.join(PACKAGES_DIR, group)
    if not os.path.isdir(group_dir):
        return []
    return sorted(
        (
            name
            for name in os.listdir(group_dir)
            if os.path.exists(os.path.join(group_dir, name, "Package.swift"))
        ),
        key=str.lower,
    )


def _file_ref(location: str, indent: str) -> str:
    return (
        f"{indent}<FileRef\n"
        f'{indent}   location = "{location}">\n'
        f"{indent}</FileRef>\n"
    )


def _group(location: str, name: str, refs: list[str]) -> str:
    out = f'   <Group\n      location = "{location}"\n      name = "{name}">\n'
    for ref in refs:
        out += _file_ref(ref, "      ")
    out += "   </Group>\n"
    return out


def render() -> str:
    out = '<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
    for loc in TOP_LEVEL_PROJECTS:
        out += _file_ref(loc, "   ")
    for group in GROUPS:
        refs = [f"group:{name}" for name in packages_in(group)]
        if group == "iOS":
            refs = [IOS_APP_PACKAGE_REF] + refs
        out += _group(f"container:Packages/{group}", f"Packages ({group})", refs)
    out += _group(*EXAMPLES_GROUP)
    out += "</Workspace>\n"
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="verify (default)")
    mode.add_argument("--write", action="store_true", help="rewrite the workspace")
    args = ap.parse_args()

    expected = render()

    if args.write:
        with open(WORKSPACE_DATA, "w", encoding="utf-8") as fh:
            fh.write(expected)
        print(f"wrote {os.path.relpath(WORKSPACE_DATA, ROOT)}")
        return 0

    actual = open(WORKSPACE_DATA, encoding="utf-8").read()
    if actual == expected:
        print("OK: workspace package grouping matches the Packages/ folder layout.")
        return 0

    rel = os.path.relpath(WORKSPACE_DATA, ROOT)
    print(
        f"::error file={rel}::workspace package grouping is out of date.\n"
        f"Run: python3 scripts/check-workspace-package-groups.py --write",
        file=sys.stderr,
    )
    import difflib

    sys.stderr.writelines(
        difflib.unified_diff(
            actual.splitlines(keepends=True),
            expected.splitlines(keepends=True),
            fromfile=f"a/{rel}",
            tofile=f"b/{rel}",
        )
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
