#!/usr/bin/env python3
"""Tests for check-catalog-single-source.py: the catalog is the only copy of itself."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-catalog-single-source.py")
SPEC = importlib.util.spec_from_file_location("check_catalog_single_source", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

REPO = Path(__file__).resolve().parents[2]
CATALOG_TEXT = json.dumps(
    {"protocol": "cmux.protocol/2", "operations": {"workspace.list": {"class": "read"}}},
    indent=2,
) + "\n"


class CatalogSingleSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(CHECK.CATALOG, CATALOG_TEXT)
        self.write("cmux-tui/bindings/go/client.go", "package cmux\n")

    def tearDown(self) -> None:
        self.directory.cleanup()

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        subprocess.run(["git", "-C", str(self.root), "add", "--", relative], check=True)

    def run_check(self) -> tuple[int, str]:
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = CHECK.main(["--root", str(self.root)])
        return status, errors.getvalue()

    def test_the_catalog_alone_passes(self) -> None:
        self.assertEqual(self.run_check(), (0, ""))

    def test_a_returned_descriptor_fails_even_when_current(self) -> None:
        _, canonical = CHECK.catalog_digests(CATALOG_TEXT.encode())
        self.write(
            "cmux-tui/bindings/zig/.cmux-resource-api.json",
            json.dumps({"catalog_sha256": canonical}) + "\n",
        )
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("cmux-tui/bindings/zig/.cmux-resource-api.json", errors)
        self.assertEqual(errors.count(".cmux-resource-api.json:"), 1, "one line per copy")

    def test_a_stale_descriptor_fails_too(self) -> None:
        self.write("webviews/.cmux-resource-api.json", '{"catalog_sha256": "' + "0" * 64 + '"}\n')
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("webviews/.cmux-resource-api.json", errors)

    def test_a_pasted_hash_anywhere_fails(self) -> None:
        file_sha, canonical = CHECK.catalog_digests(CATALOG_TEXT.encode())
        self.write("cmux-tui/bindings/java/Catalog.java", f'String SHA = "{canonical}";\n')
        self.write("webviews/src/catalog.ts", f'export const sha = "{file_sha}";\n')
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("cmux-tui/bindings/java/Catalog.java: pastes the SHA-256", errors)
        self.assertIn("webviews/src/catalog.ts: pastes the SHA-256", errors)

    def test_a_byte_copy_of_the_catalog_fails(self) -> None:
        self.write("webviews/src/resource-operations.json", CATALOG_TEXT)
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("webviews/src/resource-operations.json: a byte copy", errors)

    def test_a_missing_catalog_fails(self) -> None:
        subprocess.run(["git", "-C", str(self.root), "rm", "-q", "--", CHECK.CATALOG], check=True)
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("is missing", errors)

    def test_this_repository_has_one_source(self) -> None:
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = CHECK.main(["--root", str(REPO)])
        self.assertEqual(status, 0, errors.getvalue())


if __name__ == "__main__":
    unittest.main()
