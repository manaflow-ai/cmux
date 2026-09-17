#!/usr/bin/env python3
"""Behavioral tests for SwiftPM remote-input closure comparisons."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "check-package-resolved-policy.py"
SPEC = importlib.util.spec_from_file_location("package_resolved_policy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


def test_duplicate_path_to_existing_remote_input_is_unchanged() -> None:
    remote_call = '.package(url: "https://example.com/remote.git", from: "1.0.0")'
    previous = {
        "root": POLICY.PackageNode(False, ["path-a"], frozenset()),
        "path-a": POLICY.PackageNode(False, ["remote-owner"], frozenset()),
        "remote-owner": POLICY.PackageNode(True, [], frozenset({remote_call})),
    }
    current = {
        **previous,
        "root": POLICY.PackageNode(False, ["path-a", "path-b"], frozenset()),
        "path-b": POLICY.PackageNode(False, ["remote-owner"], frozenset()),
    }

    assert POLICY.closure_remote_dependency_calls("root", previous) == frozenset(
        {remote_call}
    )
    assert POLICY.closure_remote_dependency_calls("root", current) == (
        POLICY.closure_remote_dependency_calls("root", previous)
    )


def test_new_remote_input_changes_the_closure() -> None:
    remote_call = '.package(url: "https://example.com/new.git", from: "1.0.0")'
    previous = {"root": POLICY.PackageNode(False, [], frozenset())}
    current = {
        "root": POLICY.PackageNode(False, ["path-b"], frozenset()),
        "path-b": POLICY.PackageNode(True, [], frozenset({remote_call})),
    }

    assert POLICY.closure_remote_dependency_calls("root", previous) == frozenset()
    assert POLICY.closure_remote_dependency_calls("root", current) == frozenset(
        {remote_call}
    )


def main() -> int:
    test_duplicate_path_to_existing_remote_input_is_unchanged()
    test_new_remote_input_changes_the_closure()
    print("PASS: SwiftPM policy compares effective remote inputs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
