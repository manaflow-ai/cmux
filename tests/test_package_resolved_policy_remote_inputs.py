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
    previous = {
        "root": (set(), ["path-a"]),
        "path-a": (set(), ["remote-owner"]),
        "remote-owner": ({"https://example.com/remote.git"}, []),
    }
    current = {
        **previous,
        "root": (set(), ["path-a", "path-b"]),
        "path-b": (set(), ["remote-owner"]),
    }

    assert POLICY.remote_dependency_closure("root", previous) == {
        "https://example.com/remote.git",
    }
    assert POLICY.remote_dependency_closure("root", current) == (
        POLICY.remote_dependency_closure("root", previous)
    )


def test_new_remote_input_changes_the_closure() -> None:
    previous = {"root": (set(), [])}
    current = {
        "root": (set(), ["path-b"]),
        "path-b": ({"https://example.com/new.git"}, []),
    }

    assert POLICY.remote_dependency_closure("root", previous) == set()
    assert POLICY.remote_dependency_closure("root", current) == {
        "https://example.com/new.git",
    }


def main() -> int:
    test_duplicate_path_to_existing_remote_input_is_unchanged()
    test_new_remote_input_changes_the_closure()
    print("PASS: SwiftPM policy compares effective remote inputs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
