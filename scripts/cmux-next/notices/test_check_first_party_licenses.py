#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check_first_party_licenses.py (first-party code is GPL-3.0-or-later)."""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import check_first_party_licenses as gate  # noqa: E402

REPO = HERE.parents[2]
GPL_POINTER = "Copyright (c) 2024-present Manaflow, Inc.\n\nThis program is licensed under the GNU General Public License v3.0 or later (GPL-3.0-or-later).\n"
MIT_TEXT = "MIT License\n\nCopyright (c) 2026 Someone\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\n"


class Tree:
    def __init__(self, files: dict[str, str]):
        self._dir = tempfile.TemporaryDirectory()
        self.root = Path(self._dir.name)
        for path, text in files.items():
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            (self.root / path).write_text(text)
        self.files = list(files)

    def problems(self) -> list[str]:
        try:
            return gate.check(self.root, self.files)
        finally:
            self._dir.cleanup()


def pkg(**fields) -> str:
    return json.dumps({"name": "x", **fields})


class FirstPartyLicenseTests(unittest.TestCase):
    def test_gpl_declarations_pass(self):
        problems = Tree({
            "apps/a/package.json": pkg(license="GPL-3.0-or-later"),
            "apps/a/cmux-app.json": json.dumps({"license": "GPL-3.0-or-later"}),
            "apps/a/LICENSE": GPL_POINTER,
            "crates/c/Cargo.toml": '[package]\nname = "c"\nlicense = "GPL-3.0-or-later"\n',
            "py/pyproject.toml": '[project]\nname = "p"\nlicense = "GPL-3.0-or-later"\n'
            'classifiers = ["License :: OSI Approved :: GNU General Public License v3 or later (GPLv3+)"]\n',
            "src/a.ts": "// Copyright 2026 Manaflow, Inc.\n// SPDX-License-Identifier: GPL-3.0-or-later\n",
        }).problems()
        self.assertEqual(problems, [])

    def test_mit_package_json_fails(self):
        problems = Tree({"first-party-apps/x/package.json": pkg(private=True, license="MIT")}).problems()
        self.assertEqual(len(problems), 1)
        self.assertIn("'MIT'", problems[0])

    def test_missing_license_needs_private(self):
        self.assertEqual(Tree({"a/package.json": pkg(private=True)}).problems(), [])
        self.assertEqual(len(Tree({"a/package.json": pkg()}).problems()), 1)

    def test_app_manifest_mit_fails(self):
        problems = Tree({"samples/apps/s/cmux-app.v2.json": json.dumps({"license": "MIT"})}).problems()
        self.assertEqual(len(problems), 1)

    def test_cargo_workspace_inheritance(self):
        files = {
            "ws/Cargo.toml": '[workspace]\nmembers = ["crates/a"]\n[workspace.package]\nlicense = "MIT"\npublish = false\n',
            "ws/crates/a/Cargo.toml": '[package]\nname = "a"\nlicense.workspace = true\npublish.workspace = true\n',
        }
        problems = Tree(files).problems()
        self.assertEqual(len(problems), 2, problems)  # the workspace field and the member that inherits it
        files["ws/Cargo.toml"] = files["ws/Cargo.toml"].replace('"MIT"', '"GPL-3.0-or-later"')
        self.assertEqual(Tree(files).problems(), [])

    def test_cargo_unlicensed_crate_must_not_publish(self):
        self.assertEqual(Tree({"x/Cargo.toml": '[package]\nname = "x"\npublish = false\n'}).problems(), [])
        self.assertEqual(len(Tree({"x/Cargo.toml": '[package]\nname = "x"\n'}).problems()), 1)

    def test_pyproject_mit_and_classifier_fail(self):
        problems = Tree({
            "p/pyproject.toml": '[project]\nname = "p"\nlicense = {text = "MIT"}\n'
            'classifiers = ["License :: OSI Approved :: MIT License"]\n',
        }).problems()
        self.assertEqual(len(problems), 2, problems)

    def test_first_party_mit_license_file_fails(self):
        problems = Tree({"libs/x/LICENSE": MIT_TEXT}).problems()
        self.assertTrue(any("must name GPL-3.0-or-later" in p for p in problems), problems)
        self.assertTrue(any("MIT grant" in p for p in problems), problems)

    def test_spdx_header(self):
        problems = Tree({"src/a.rs": "// SPDX-License-Identifier: MIT\nfn main() {}\n"}).problems()
        self.assertEqual(len(problems), 1)
        # Only a header counts; a string later in the file is data.
        body = "x = 1\n" * 10 + 'TEXT = "SPDX-License-Identifier: MIT"\n'
        self.assertEqual(Tree({"tools/a.py": body}).problems(), [])

    def test_third_party_and_busl_paths(self):
        problems = Tree({
            "cmux-tui/vendor/crossterm/Cargo.toml": '[package]\nname = "crossterm"\nlicense = "MIT"\n',
            "cmux-tui/vendor/crossterm/LICENSE": MIT_TEXT,
            "web/package.json": pkg(private=True, license="BUSL-1.1"),
            "backend/package.json": pkg(private=True),
        }).problems()
        self.assertEqual(problems, [])
        self.assertEqual(len(Tree({"web/package.json": pkg(private=True, license="MIT")}).problems()), 1)

    def test_mixed_package_needs_its_exact_expression(self):
        files = {
            "libs/integrations-core/package.json": pkg(private=True, license="GPL-3.0-or-later AND MIT"),
            "libs/integrations-core/LICENSE": GPL_POINTER,
            "libs/integrations-core/LICENSE-executor": MIT_TEXT,
        }
        self.assertEqual(Tree(files).problems(), [])
        files["libs/integrations-core/package.json"] = pkg(private=True, license="GPL-3.0-or-later")
        self.assertEqual(len(Tree(files).problems()), 1)

    def test_repository_first_party_declarations_are_gpl(self):
        """The product rule on this checkout: every first-party declaration is GPL."""
        problems = gate.check(REPO, gate.tracked_files(REPO))
        self.assertEqual(problems, [], "\n".join(problems))


if __name__ == "__main__":
    unittest.main()
