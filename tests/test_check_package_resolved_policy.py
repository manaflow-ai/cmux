#!/usr/bin/env python3
"""Behavioral guards for scripts/check-package-resolved-policy.py.

Regression coverage for https://github.com/manaflow-ai/cmux/issues/8871: adding
a leaf local-path package (no remote dependency anywhere in the added closure)
must not demand a Package.resolved diff, because `swift package resolve` is a
byte-identical no-op for that edit and the demanded diff cannot exist. Remote
reachability changes must still require the lockfile diff.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
POLICY_SCRIPT = ROOT / "scripts" / "check-package-resolved-policy.py"
BASE_BRANCH = "policy-test-base"

REMOTE_DEP_CALL = '.package(url: "https://example.invalid/dep.git", from: "1.0.0")'
BUMPED_REMOTE_DEP_CALL = '.package(url: "https://example.invalid/dep.git", from: "2.0.0")'
LIB_REMOTE_DEP_CALL = '.package(url: "https://example.invalid/lib.git", from: "1.0.0")'

MINIMAL_RESOLVED = '{"pins": [], "version": 2}\n'
MINIMAL_IOS_WORKSPACE = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<Workspace version = "1.0">\n'
    "</Workspace>\n"
)


def run_git(repo: Path, *args: str) -> None:
    subprocess.run(
        [
            "git",
            "-c", "user.name=policy-test",
            "-c", "user.email=policy-test@example.invalid",
            *args,
        ],
        check=True,
        cwd=repo,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def write_manifest(repo: Path, root: str, name: str, dependency_calls: list[str]) -> None:
    dependencies = "".join(f"        {call},\n" for call in dependency_calls)
    manifest = (
        "// swift-tools-version: 5.9\n"
        "import PackageDescription\n"
        "\n"
        "let package = Package(\n"
        f'    name: "{name}",\n'
        "    dependencies: [\n"
        f"{dependencies}"
        "    ]\n"
        ")\n"
    )
    directory = repo / root
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Package.swift").write_text(manifest, encoding="utf-8")


def make_base_repo(repo: Path) -> None:
    """Commit a minimal repo shape the policy script can walk.

    Packages/RemoteApp has a remote pin (and a tracked lockfile); Packages/RemoteLib
    is a second remote-bearing package available for reachability-change cases.
    """
    run_git(repo, "init", "-q", "-b", "main")
    write_manifest(repo, "Packages/RemoteApp", "RemoteApp", [REMOTE_DEP_CALL])
    (repo / "Packages/RemoteApp/Package.resolved").write_text(
        MINIMAL_RESOLVED, encoding="utf-8"
    )
    write_manifest(repo, "Packages/RemoteLib", "RemoteLib", [LIB_REMOTE_DEP_CALL])
    (repo / "Packages/RemoteLib/Package.resolved").write_text(
        MINIMAL_RESOLVED, encoding="utf-8"
    )
    ios_workspace = repo / "ios/cmux.xcworkspace"
    ios_workspace.mkdir(parents=True)
    (ios_workspace / "contents.xcworkspacedata").write_text(
        MINIMAL_IOS_WORKSPACE, encoding="utf-8"
    )
    run_git(repo, "add", "-A")
    run_git(repo, "commit", "-q", "-m", "base")
    run_git(repo, "branch", BASE_BRANCH)


def run_policy(repo: Path) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    environment["PACKAGE_RESOLVED_POLICY_BASE_REF"] = BASE_BRANCH
    return subprocess.run(
        [sys.executable, str(POLICY_SCRIPT)],
        cwd=repo,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def check_leaf_local_dependency_needs_no_lockfile_diff() -> int:
    """Adding a remote-free leaf package must not demand an impossible diff."""
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        make_base_repo(repo)
        write_manifest(repo, "Packages/Leaf", "Leaf", [])
        write_manifest(
            repo,
            "Packages/RemoteApp",
            "RemoteApp",
            [REMOTE_DEP_CALL, '.package(path: "../Leaf")'],
        )
        run_git(repo, "add", "-A")
        run_git(repo, "commit", "-q", "-m", "add leaf local dependency")

        result = run_policy(repo)
        if result.returncode != 0:
            print(result.stdout, end="")
            print(
                "FAIL: leaf local-path dependency (remote-free closure) demanded "
                f"a Package.resolved diff; policy exited {result.returncode}"
            )
            return 1
    print("PASS: leaf local-path dependency needs no lockfile diff")
    return 0


def check_remote_version_bump_still_requires_lockfile_diff() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        make_base_repo(repo)
        write_manifest(repo, "Packages/RemoteApp", "RemoteApp", [BUMPED_REMOTE_DEP_CALL])
        run_git(repo, "add", "-A")
        run_git(repo, "commit", "-q", "-m", "bump remote dependency")

        result = run_policy(repo)
        if result.returncode == 0:
            print(result.stdout, end="")
            print("FAIL: remote version bump without lockfile diff passed the policy")
            return 1
        if "Packages/RemoteApp/Package.resolved" not in result.stdout:
            print(result.stdout, end="")
            print("FAIL: remote version bump violation does not name the lockfile")
            return 1
    print("PASS: remote version bump still requires a lockfile diff")
    return 0


def check_local_dependency_reaching_remote_still_requires_lockfile_diff() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        make_base_repo(repo)
        write_manifest(
            repo,
            "Packages/RemoteApp",
            "RemoteApp",
            [REMOTE_DEP_CALL, '.package(path: "../RemoteLib")'],
        )
        run_git(repo, "add", "-A")
        run_git(repo, "commit", "-q", "-m", "add local dependency with remote closure")

        result = run_policy(repo)
        if result.returncode == 0:
            print(result.stdout, end="")
            print(
                "FAIL: local dependency that adds remote reachability passed "
                "without a lockfile diff"
            )
            return 1
    print("PASS: local dependency adding remote reachability still requires a diff")
    return 0


def check_leaf_removal_needs_no_lockfile_diff() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        make_base_repo(repo)
        write_manifest(repo, "Packages/Leaf", "Leaf", [])
        write_manifest(
            repo,
            "Packages/RemoteApp",
            "RemoteApp",
            [REMOTE_DEP_CALL, '.package(path: "../Leaf")'],
        )
        run_git(repo, "add", "-A")
        run_git(repo, "commit", "-q", "-m", "base with leaf dependency")
        run_git(repo, "branch", "-f", BASE_BRANCH)
        write_manifest(repo, "Packages/RemoteApp", "RemoteApp", [REMOTE_DEP_CALL])
        run_git(repo, "add", "-A")
        run_git(repo, "commit", "-q", "-m", "drop leaf local dependency")

        result = run_policy(repo)
        if result.returncode != 0:
            print(result.stdout, end="")
            print(
                "FAIL: removing a remote-free leaf dependency demanded a "
                f"Package.resolved diff; policy exited {result.returncode}"
            )
            return 1
    print("PASS: removing a leaf local-path dependency needs no lockfile diff")
    return 0


def main() -> int:
    checks = (
        check_leaf_local_dependency_needs_no_lockfile_diff,
        check_remote_version_bump_still_requires_lockfile_diff,
        check_local_dependency_reaching_remote_still_requires_lockfile_diff,
        check_leaf_removal_needs_no_lockfile_diff,
    )
    for check in checks:
        if (return_code := check()) != 0:
            return return_code
    print("PASS: Package.resolved policy matches remote reachability")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
