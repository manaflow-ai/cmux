#!/usr/bin/env python3
"""Verify cmux-owned SwiftPM lockfiles are not ignored."""

from __future__ import annotations

from fnmatch import fnmatchcase
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple


ALLOWED_IGNORED_PREFIXES = (
    "vendor/",
    "ghostty/",
)

XCODE_PACKAGE_RESOLVED = (
    "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
XCODE_PROJECT_FILE = "cmux.xcodeproj/project.pbxproj"
IOS_WORKSPACE_PACKAGE_RESOLVED = (
    "ios/cmux.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
IOS_WORKSPACE_FILE = "ios/cmux.xcworkspace/contents.xcworkspacedata"
IOS_XCODE_PROJECT_FILE = "ios/cmux-ios.xcodeproj/project.pbxproj"
EXPECTED_XCODE_LOCKFILES = {
    XCODE_PACKAGE_RESOLVED,
    IOS_WORKSPACE_PACKAGE_RESOLVED,
}
XCODE_PACKAGE_REFERENCE_TOKENS = (
    "XCRemoteSwiftPackageReference",
    "repositoryURL",
    "minimumVersion",
    "exactVersion",
    "revision",
    "branch",
    "requirement =",
)
XCODE_PRODUCT_PACKAGE_LINK_RE = re.compile(
    r"\bpackage\s*=\s*[^;]*\bXCRemoteSwiftPackageReference\b"
)


class PackageNode(NamedTuple):
    """Dependency edges declared by one Package.swift."""

    has_url_dependency: bool
    path_dependencies: list[str]
    # Normalized text of every `.package(url:)` call, so a version-requirement
    # bump on an unchanged URL still counts as a remote-resolution change.
    url_calls: frozenset[str]


EMPTY_PACKAGE_NODE = PackageNode(False, [], frozenset())

PACKAGE_DEPENDENCY_RE = re.compile(r"\.package\(([^)]*)\)", re.DOTALL)
PACKAGE_PATH_ARGUMENT_RE = re.compile(r'\bpath\s*:\s*"([^"]+)"')
PACKAGE_URL_ARGUMENT_RE = re.compile(r'\burl\s*:\s*"[^"]+"')
WORKSPACE_GROUP_LOCATION_RE = re.compile(r'\blocation\s*=\s*"group:([^"]+)"')

SKIPPED_DIRS = {
    ".build",
    ".git",
    ".swiftpm",
    ".ci-source-packages",
    "DerivedData",
    "node_modules",
}


def git_ls_files(*args: str) -> list[str]:
    return [line for line in git_stdout("ls-files", *args).splitlines() if line]


def git_stdout(*args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return result.stdout


def is_allowed_vendor_path(path: str) -> bool:
    return path.startswith(ALLOWED_IGNORED_PREFIXES)


def has_skipped_part(path: str) -> bool:
    return any(part in SKIPPED_DIRS for part in Path(path).parts)


def tracked_package_manifests(*, include_allowed_vendor: bool) -> dict[str, Path]:
    manifests: dict[str, Path] = {}
    for manifest in git_ls_files("*Package.swift"):
        if has_skipped_part(manifest):
            continue
        if not include_allowed_vendor and is_allowed_vendor_path(manifest):
            continue
        path = Path(manifest)
        manifests[path.parent.as_posix()] = path
    return manifests


def tracked_package_manifests_at_ref(
    ref: str,
    *,
    include_allowed_vendor: bool,
) -> dict[str, Path]:
    manifests: dict[str, Path] = {}
    for manifest in git_stdout("ls-tree", "-r", "--name-only", ref).splitlines():
        if Path(manifest).name != "Package.swift":
            continue
        if has_skipped_part(manifest):
            continue
        if not include_allowed_vendor and is_allowed_vendor_path(manifest):
            continue
        path = Path(manifest)
        manifests[path.parent.as_posix()] = path
    return manifests


def package_graph(
    manifests: dict[str, Path],
    *,
    ref: str | None = None,
) -> dict[str, PackageNode]:
    root_by_resolved_path = {
        manifest.parent.resolve(): root for root, manifest in manifests.items()
    }
    graph: dict[str, PackageNode] = {}

    for root, manifest in manifests.items():
        text = (
            file_text_at(ref, manifest.as_posix())
            if ref is not None
            else manifest.read_text(encoding="utf-8")
        )
        if not text:
            continue
        path_dependencies: list[str] = []
        url_calls: set[str] = set()
        for dependency in PACKAGE_DEPENDENCY_RE.findall(text):
            if PACKAGE_URL_ARGUMENT_RE.search(dependency):
                url_calls.add(" ".join(dependency.split()))
            path_match = PACKAGE_PATH_ARGUMENT_RE.search(dependency)
            if path_match is None:
                continue
            dependency_root = (manifest.parent / path_match.group(1)).resolve()
            if dependency_root in root_by_resolved_path:
                path_dependencies.append(root_by_resolved_path[dependency_root])
        graph[root] = PackageNode(
            bool(url_calls), path_dependencies, frozenset(url_calls)
        )

    return graph


def package_dependency_calls(text: str) -> list[str]:
    return [" ".join(dependency.split()) for dependency in PACKAGE_DEPENDENCY_RE.findall(text)]


def closure_remote_dependency_calls(
    root: str,
    graph: dict[str, PackageNode],
) -> frozenset[str]:
    """Every `.package(url:)` call reachable from ``root``.

    This is what `swift package resolve` actually pins, so comparing it across
    refs answers "can a Package.resolved diff exist for this change?".
    """
    calls: set[str] = set()
    for member in package_dependency_closure(root, graph):
        calls.update(graph.get(member, EMPTY_PACKAGE_NODE).url_calls)
    return frozenset(calls)


def has_remote_dependency(
    root: str,
    graph: dict[str, PackageNode],
    memo: dict[str, bool],
    visiting: set[str],
) -> bool:
    if root in memo:
        return memo[root]
    if root in visiting:
        return False
    node = graph.get(root, EMPTY_PACKAGE_NODE)
    has_url_dependency = node.has_url_dependency
    path_dependencies = node.path_dependencies
    visiting.add(root)
    needs_lockfile = has_url_dependency or any(
        has_remote_dependency(dependency, graph, memo, visiting)
        for dependency in path_dependencies
    )
    visiting.remove(root)
    memo[root] = needs_lockfile
    return needs_lockfile


def package_dependency_closure(
    root: str,
    graph: dict[str, PackageNode],
) -> set[str]:
    closure: set[str] = set()

    def visit(current: str) -> None:
        if current in closure:
            return
        closure.add(current)
        for dependency in graph.get(current, EMPTY_PACKAGE_NODE).path_dependencies:
            visit(dependency)

    visit(root)
    return closure


def workspace_package_roots(
    workspace_file: str,
    manifests: dict[str, Path],
    *,
    ref: str | None = None,
) -> set[str]:
    text = (
        file_text_at(ref, workspace_file)
        if ref is not None
        else Path(workspace_file).read_text(encoding="utf-8")
    )
    workspace_parent = Path(workspace_file).parent.parent.resolve()
    root_by_resolved_path = {
        Path(root).resolve(): root for root in manifests
    }
    roots: set[str] = set()
    for location in WORKSPACE_GROUP_LOCATION_RE.findall(text):
        resolved = (workspace_parent / location).resolve()
        if root := root_by_resolved_path.get(resolved):
            roots.add(root)
    return roots


def package_roots_requiring_lockfiles(
    cmux_manifests: dict[str, Path] | None = None,
    graph: dict[str, PackageNode] | None = None,
) -> set[str]:
    if cmux_manifests is None or graph is None:
        all_manifests = tracked_package_manifests(include_allowed_vendor=True)
        cmux_manifests = tracked_package_manifests(include_allowed_vendor=False)
        graph = package_graph(all_manifests)
    memo: dict[str, bool] = {}

    return {
        root for root in cmux_manifests
        if has_remote_dependency(root, graph, memo, set())
    }


def package_lockfile_path(root: str) -> str:
    if root == ".":
        return "Package.resolved"
    return f"{root}/Package.resolved"


def base_ref() -> str:
    if override := os.environ.get("PACKAGE_RESOLVED_POLICY_BASE_REF"):
        return override
    if github_base := os.environ.get("GITHUB_BASE_REF"):
        return f"origin/{github_base}"
    return "origin/main"


def merge_base_with_base_ref() -> str | None:
    try:
        return git_stdout("merge-base", base_ref(), "HEAD").strip()
    except subprocess.CalledProcessError:
        if os.environ.get("GITHUB_BASE_REF") or os.environ.get(
            "PACKAGE_RESOLVED_POLICY_BASE_REF"
        ):
            raise
        return None


def changed_files_since(merge_base: str | None) -> set[str]:
    if merge_base is None:
        return set()
    return set(git_stdout("diff", "--name-only", f"{merge_base}..HEAD").splitlines())


def file_text_at(ref: str, path: str) -> str:
    try:
        return git_stdout("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return ""


def xcode_package_reference_changed(
    project_file: str,
    merge_base: str | None,
    changed_files: set[str],
) -> bool:
    if merge_base is None or project_file not in changed_files:
        return False
    diff = git_stdout(
        "diff",
        "--unified=0",
        f"{merge_base}..HEAD",
        "--",
        project_file,
    )
    for line in diff.splitlines():
        if not line.startswith(("+", "-")) or line.startswith(("+++", "---")):
            continue
        # A product dependency's `package = ... XCRemoteSwiftPackageReference`
        # field only links a product to an already-declared package. Adding or
        # removing that linkage does not change Xcode's resolved package graph,
        # so it must not require a Package.resolved diff.
        if XCODE_PRODUCT_PACKAGE_LINK_RE.search(line):
            continue
        if any(token in line for token in XCODE_PACKAGE_REFERENCE_TOKENS):
            return True
    return False


def is_expected_lockfile_path(lockfile: str, roots: set[str]) -> bool:
    if lockfile in EXPECTED_XCODE_LOCKFILES:
        return True
    if has_skipped_part(lockfile):
        return False
    return Path(lockfile).parent.as_posix() in roots


def ignores_package_resolved(gitignore: Path) -> bool:
    ignored = False

    for raw_line in gitignore.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        is_negated = line.startswith("!")
        pattern = line[1:] if is_negated else line
        pattern = pattern.rstrip("/").lstrip("/")
        if pattern == "Package.resolved" or pattern.endswith("/Package.resolved"):
            ignored = not is_negated
            continue
        if fnmatchcase("Package.resolved", pattern):
            ignored = not is_negated
    return ignored


def main() -> int:
    errors: list[str] = []
    all_manifests = tracked_package_manifests(include_allowed_vendor=True)
    cmux_manifests = {
        root: manifest for root, manifest in all_manifests.items()
        if not is_allowed_vendor_path(manifest.as_posix())
    }
    graph = package_graph(all_manifests)
    roots = set(cmux_manifests)
    tracked_lockfiles = set(git_ls_files("*Package.resolved"))
    required_lockfile_roots = package_roots_requiring_lockfiles(cmux_manifests, graph)
    merge_base = merge_base_with_base_ref()
    changed_files = changed_files_since(merge_base)
    changed_dependency_roots: set[str] = set()
    previous_manifests: dict[str, Path] = {}
    previous_graph: dict[str, PackageNode] = {}

    if merge_base is not None:
        previous_manifests = tracked_package_manifests_at_ref(
            merge_base,
            include_allowed_vendor=True,
        )
        previous_graph = package_graph(previous_manifests, ref=merge_base)
        for root, manifest in all_manifests.items():
            if manifest.as_posix() not in changed_files:
                continue
            current_calls = package_dependency_calls(
                manifest.read_text(encoding="utf-8")
            )
            previous_calls = package_dependency_calls(
                file_text_at(merge_base, manifest.as_posix())
            )
            if current_calls == previous_calls:
                continue
            # Local path-only dependency edits do not always change the resolved
            # external pins. Require a matching Package.resolved diff only when
            # the set of `.package(url:)` calls reachable from this manifest
            # actually differs, since that set is what `swift package resolve`
            # pins. Adding a leaf local-path package whose closure has no remote
            # dependency leaves the lockfiles byte-identical, so demanding a
            # diff there is unsatisfiable (issue #8871).
            if closure_remote_dependency_calls(
                root, graph
            ) != closure_remote_dependency_calls(root, previous_graph):
                changed_dependency_roots.add(root)

    if (
        xcode_package_reference_changed(
            XCODE_PROJECT_FILE,
            merge_base,
            changed_files,
        )
        and XCODE_PACKAGE_RESOLVED not in changed_files
    ):
        errors.append(
            f"{XCODE_PROJECT_FILE} changed SwiftPM package references without "
            f"matching Xcode Package.resolved diff: {XCODE_PACKAGE_RESOLVED}"
        )

    current_ios_workspace_roots = workspace_package_roots(
        IOS_WORKSPACE_FILE,
        all_manifests,
    )
    previous_ios_workspace_roots = (
        workspace_package_roots(
            IOS_WORKSPACE_FILE,
            previous_manifests,
            ref=merge_base,
        )
        if merge_base is not None
        else set()
    )
    current_ios_workspace_dependency_roots: set[str] = set()
    for root in current_ios_workspace_roots:
        current_ios_workspace_dependency_roots.update(
            package_dependency_closure(root, graph)
        )
    previous_ios_workspace_dependency_roots: set[str] = set()
    for root in previous_ios_workspace_roots:
        previous_ios_workspace_dependency_roots.update(
            package_dependency_closure(root, previous_graph)
        )
    ios_workspace_dependencies_changed = bool(
        (
            current_ios_workspace_dependency_roots
            | previous_ios_workspace_dependency_roots
        )
        & changed_dependency_roots
    )
    if ios_workspace_dependencies_changed and merge_base is not None:
        # Same dependent-closure escape as per-root lockfiles: if the union of
        # remote dependency calls reachable from the workspace's roots is
        # unchanged, resolution is byte-identical and no diff can exist.
        current_ws_calls = set()
        for ws_root in current_ios_workspace_roots:
            current_ws_calls |= closure_remote_dependency_calls(ws_root, graph)
        previous_ws_calls = set()
        for ws_root in previous_ios_workspace_roots:
            previous_ws_calls |= closure_remote_dependency_calls(
                ws_root, previous_graph
            )
        if current_ws_calls == previous_ws_calls:
            ios_workspace_dependencies_changed = False
    changed_ios_workspace_members = (
        current_ios_workspace_roots ^ previous_ios_workspace_roots
    )
    current_ios_remote_memo: dict[str, bool] = {}
    previous_ios_remote_memo: dict[str, bool] = {}
    ios_workspace_resolution_membership_changed = any(
        has_remote_dependency(
            root,
            graph,
            current_ios_remote_memo,
            set(),
        )
        or has_remote_dependency(
            root,
            previous_graph,
            previous_ios_remote_memo,
            set(),
        )
        for root in changed_ios_workspace_members
    )
    if (
        ios_workspace_dependencies_changed
        or ios_workspace_resolution_membership_changed
        or xcode_package_reference_changed(
            IOS_XCODE_PROJECT_FILE,
            merge_base,
            changed_files,
        )
    ) and IOS_WORKSPACE_PACKAGE_RESOLVED not in changed_files:
        errors.append(
            "iOS workspace SwiftPM dependencies changed without matching "
            f"Package.resolved diff: {IOS_WORKSPACE_PACKAGE_RESOLVED}"
        )

    for gitignore in sorted(Path(".").rglob(".gitignore")):
        rel = gitignore.as_posix()
        if rel.startswith("./"):
            rel = rel[2:]
        if has_skipped_part(rel):
            continue
        if not ignores_package_resolved(gitignore):
            continue
        if is_allowed_vendor_path(rel):
            continue
        errors.append(
            f"{rel} ignores Package.resolved. cmux-owned SwiftPM lockfiles must be tracked."
        )

    for expected_root in sorted(required_lockfile_roots):
        expected_lockfile = package_lockfile_path(expected_root)
        if expected_lockfile in tracked_lockfiles:
            continue
        errors.append(
            f"Missing Package.resolved for SwiftPM package with remote pins: {expected_lockfile}"
        )

    for root, manifest in sorted(cmux_manifests.items()):
        expected_lockfile = package_lockfile_path(root)
        has_or_requires_lockfile = (
            root in required_lockfile_roots or expected_lockfile in tracked_lockfiles
        )
        if not has_or_requires_lockfile:
            continue
        affected_dependency_roots = (
            package_dependency_closure(root, graph) & changed_dependency_roots
        )
        if not affected_dependency_roots:
            continue
        if expected_lockfile in changed_files:
            continue
        # A dependent whose own reachable `.package(url:)` set is unchanged
        # resolves to byte-identical pins, so demanding a lockfile diff is
        # unsatisfiable (the issue #8871 case, extended to dependents: e.g.
        # adding a leaf local package whose only remote dependency is already
        # pinned identically elsewhere in this root's closure).
        if merge_base is not None and closure_remote_dependency_calls(
            root, graph
        ) == closure_remote_dependency_calls(root, previous_graph):
            continue
        changed_manifests = ", ".join(
            all_manifests[changed_root].as_posix()
            for changed_root in sorted(affected_dependency_roots)
        )
        errors.append(
            f"{changed_manifests} changed SwiftPM package dependencies without "
            f"matching Package.resolved diff: {expected_lockfile}"
        )

    for lockfile in tracked_lockfiles:
        if is_allowed_vendor_path(lockfile):
            continue
        if is_expected_lockfile_path(lockfile, roots):
            continue
        errors.append(f"Unexpected cmux Package.resolved location: {lockfile}")

    if errors:
        print("Package.resolved policy violations:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Package.resolved policy OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
