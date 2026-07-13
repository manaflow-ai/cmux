#!/usr/bin/env python3
"""Regression tests for the SwiftPM lockfile policy."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).parents[1] / "scripts" / "check-package-resolved-policy.py"
SPEC = importlib.util.spec_from_file_location("package_resolved_policy", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)


class PackageResolvedPolicyTests(unittest.TestCase):
    def test_equivalent_remote_wrappers_do_not_affect_consumer_pins(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current = self.make_package_tree(root / "current", wrapper="WrapperB")
            previous = self.make_package_tree(root / "previous", wrapper="WrapperA")
            current_manifest = current["Consumer"]
            previous_manifest = previous["Consumer"]
            current_calls = policy.package_dependency_calls(
                current_manifest.read_text(encoding="utf-8")
            )
            previous_calls = policy.package_dependency_calls(
                previous_manifest.read_text(encoding="utf-8")
            )

            affects_pins = policy.dependency_call_delta_affects_pins(
                current_calls,
                previous_calls,
                current_manifest,
                current,
                policy.package_graph(current),
                previous,
                policy.package_graph(previous),
                {},
                {},
            )

            self.assertFalse(affects_pins)

    def make_package_tree(self, root: Path, *, wrapper: str) -> dict[str, Path]:
        remote_dependency = (
            '.package(url: "https://example.com/remote.git", exact: "1.2.3")'
        )
        manifests: dict[str, Path] = {}
        for package in ("Consumer", "WrapperA", "WrapperB"):
            manifest = root / package / "Package.swift"
            manifest.parent.mkdir(parents=True, exist_ok=True)
            dependency = (
                f'.package(path: "../{wrapper}")'
                if package == "Consumer"
                else remote_dependency
            )
            manifest.write_text(
                f"// swift-tools-version: 6.0\n"
                f"import PackageDescription\n"
                f"let package = Package(name: \"{package}\", dependencies: [{dependency}])\n",
                encoding="utf-8",
            )
            manifests[package] = manifest
        return manifests


if __name__ == "__main__":
    unittest.main()
