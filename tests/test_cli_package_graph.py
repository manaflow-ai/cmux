#!/usr/bin/env python3
"""The bundled CLI links no package that pulls in swift-syntax.

swift-syntax is the custom-sidebar interpreter's parser. It belongs to the app
and the sidebar interpreter service, never to `Contents/Resources/bin/cmux`:
SwiftPM products link as whole objects, so a product the CLI only lists still
ships its Swift metadata, and swift-syntax alone was about 60% of the CLI's
Swift symbols (31,539 of them in the v0.65 arm64 build).

This walks the cmux-cli target's package products, follows every local package
they depend on, and fails if any of them depends on swift-syntax.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
FORBIDDEN_REMOTE = "swift-syntax"


def object_body(object_id: str) -> str:
    # Build files are written on one line, other objects across several.
    single = re.search(rf"^\t\t{object_id} /\* [^\n]*\*/ = \{{([^\n]*)\}};$", PROJECT, re.M)
    if single:
        return single.group(1)
    match = re.search(rf"^\t\t{object_id} /\* [^\n]*\*/ = \{{(.*?)^\t\t\}};", PROJECT, re.M | re.S)
    if not match:
        raise AssertionError(f"project.pbxproj has no object {object_id}")
    return match.group(1)


def cli_target_body() -> str:
    match = re.search(
        r"^\t\t(\w+) /\* cmux-cli \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)^\t\t\};", PROJECT, re.M | re.S
    )
    if not match:
        raise AssertionError("project.pbxproj has no cmux-cli native target")
    return match.group(2)


def cli_product_dependency_ids() -> set[str]:
    body = cli_target_body()
    ids: set[str] = set()
    listed = re.search(r"packageProductDependencies = \((.*?)\);", body, re.S)
    if listed:
        ids.update(re.findall(r"(\w+) /\*", listed.group(1)))
    # Products linked by the Frameworks phase count too.
    phases = re.search(r"buildPhases = \((.*?)\);", body, re.S)
    for phase_id in re.findall(r"(\w+) /\* Frameworks \*/", phases.group(1) if phases else ""):
        for build_file in re.findall(r"(\w+) /\* [^*]* in Frameworks \*/", object_body(phase_id)):
            # Xcode ignores a phase entry whose build file is not defined.
            line = re.search(rf"^\t\t{build_file} /\*[^\n]*productRef = (\w+)", PROJECT, re.M)
            if line:
                ids.add(line.group(1))
    return ids


def package_directory(product_id: str) -> tuple[str, Path | None]:
    body = object_body(product_id)
    name = re.search(r"productName = ([^;]+);", body).group(1).strip('"')
    package = re.search(r"package = (\w+)", body)
    if not package:
        return name, None
    reference = object_body(package.group(1))
    path = re.search(r"relativePath = ([^;]+);", reference)
    return name, (ROOT / path.group(1).strip('"')).resolve() if path else None


def local_dependencies(package: Path) -> list[Path]:
    manifest = (package / "Package.swift").read_text(encoding="utf-8")
    return [
        (package / path).resolve()
        for path in re.findall(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"', manifest)
    ]


def remote_dependencies(package: Path) -> list[str]:
    manifest = (package / "Package.swift").read_text(encoding="utf-8")
    return re.findall(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?url:\s*"([^"]+)"', manifest)


class CLIPackageGraphTest(unittest.TestCase):
    def test_cli_links_no_package_that_depends_on_swift_syntax(self):
        offenders = []
        for product_id in sorted(cli_product_dependency_ids()):
            name, package = package_directory(product_id)
            if package is None:
                continue
            stack, seen, chain = [package], set(), {package: [name]}
            while stack:
                current = stack.pop()
                if current in seen:
                    continue
                seen.add(current)
                if any(FORBIDDEN_REMOTE in url for url in remote_dependencies(current)):
                    offenders.append(" -> ".join(chain[current]))
                    continue
                for dependency in local_dependencies(current):
                    chain.setdefault(dependency, chain[current] + [dependency.name])
                    stack.append(dependency)
        self.assertEqual(
            sorted(set(offenders)),
            [],
            "cmux-cli links products whose packages depend on swift-syntax; "
            "the CLI never imports them, so drop them from the cmux-cli target",
        )

    def test_the_walk_sees_the_cli_products(self):
        names = {package_directory(product_id)[0] for product_id in cli_product_dependency_ids()}
        self.assertIn("CmuxControlSocket", names)
        self.assertIn("CMUXAgentLaunch", names)


if __name__ == "__main__":
    unittest.main()
