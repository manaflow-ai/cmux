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
            affects_pins = policy.dependency_call_delta_affects_pins(
                "Consumer",
                current,
                policy.package_graph(current),
                previous,
                policy.package_graph(previous),
            )

            self.assertFalse(affects_pins)

    def test_changed_remote_requirement_affects_consumer_pins(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current = self.make_package_tree(
                root / "current", wrapper="WrapperB", wrapper_b_version="2.0.0"
            )
            previous = self.make_package_tree(root / "previous", wrapper="WrapperA")

            self.assertTrue(
                policy.dependency_call_delta_affects_pins(
                    "Consumer",
                    current,
                    policy.package_graph(current),
                    previous,
                    policy.package_graph(previous),
                )
            )

    def test_unknown_dependency_form_stays_strict(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current = self.make_package_tree(root / "current", wrapper="WrapperB")
            previous = self.make_package_tree(root / "previous", wrapper="WrapperA")
            current["Consumer"].write_text(
                "// swift-tools-version: 6.0\n"
                "import PackageDescription\n"
                "let package = Package(name: \"Consumer\", "
                "dependencies: [.package(id: dependencyID, from: \"1.0.0\")])\n",
                encoding="utf-8",
            )

            self.assertTrue(
                policy.dependency_call_delta_affects_pins(
                    "Consumer",
                    current,
                    policy.package_graph(current),
                    previous,
                    policy.package_graph(previous),
                )
            )

    def make_package_tree(
        self,
        root: Path,
        *,
        wrapper: str,
        wrapper_b_version: str = "1.2.3",
    ) -> dict[str, Path]:
        manifests: dict[str, Path] = {}
        for package in ("Consumer", "WrapperA", "WrapperB"):
            manifest = root / package / "Package.swift"
            manifest.parent.mkdir(parents=True, exist_ok=True)
            version = wrapper_b_version if package == "WrapperB" else "1.2.3"
            dependency = (
                f'.package(path: "../{wrapper}")'
                if package == "Consumer"
                else f'.package(url: "https://example.com/remote.git", exact: "{version}")'
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
