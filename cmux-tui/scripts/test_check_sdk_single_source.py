#!/usr/bin/env python3
"""Tests for check-sdk-single-source.py: one source for the catalog and for the SDK IR hash."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("check-sdk-single-source.py")
SPEC = importlib.util.spec_from_file_location("check_sdk_single_source", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)

REPO = Path(__file__).resolve().parents[2]
CATALOG_TEXT = json.dumps(
    {"protocol": "cmux.protocol/2", "operations": {"workspace.list": {"class": "read"}}},
    indent=2,
) + "\n"
IR = "ab" * 32


def manifest(*files: str, ir: str = IR) -> str:
    return json.dumps({"files": [{"path": path} for path in files], "ir_sha256": ir}) + "\n"


class SdkSingleSourceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.write(CHECK.CATALOG, CATALOG_TEXT)
        self.write("cmux-tui/bindings/go/client.go", "package cmux\n")
        self.write("cmux-tui/bindings/rust/src/generated/.cmux-sdk-manifest.json", manifest("metadata.rs", "types.rs"))
        self.write("cmux-tui/bindings/rust/src/generated/metadata.rs", f'pub const SDK_IR_SHA256: &str = "{IR}";\n')
        self.write("cmux-tui/bindings/rust/src/generated/types.rs", "pub struct T;\n")
        self.write("cmux-tui/bindings/zig/src/raw/generated/.cmux-sdk-manifest.json", manifest("protocol.zig"))
        self.write("cmux-tui/bindings/zig/src/raw/generated/protocol.zig", f'pub const ir_sha256 = "{IR}";\n')

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

    def test_one_source_each_passes(self) -> None:
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

    def test_a_pasted_catalog_hash_anywhere_fails(self) -> None:
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
        subprocess.run(["git", "-C", str(self.root), "rm", "-q", "-f", "--", CHECK.CATALOG], check=True)
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("is missing", errors)

    def test_a_hand_pasted_ir_hash_fails(self) -> None:
        self.write("cmux-tui/bindings/rust/src/client.rs", f'const PINNED: &str = "{IR}";\n')
        self.write("cmux-tui/crates/cmux-tui-core/src/identify.rs", f"// IR {IR}\n")
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("cmux-tui/bindings/rust/src/client.rs: pastes the SDK IR SHA-256", errors)
        self.assertIn("cmux-tui/crates/cmux-tui-core/src/identify.rs: pastes the SDK IR SHA-256", errors)
        self.assertNotIn("metadata.rs", errors, "the generator's own constant is the source")

    def test_manifests_that_disagree_fail(self) -> None:
        self.write(
            "cmux-tui/bindings/zig/src/raw/generated/.cmux-sdk-manifest.json",
            manifest("protocol.zig", ir="cd" * 32),
        )
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("disagree about ir_sha256", errors)

    def test_a_second_typed_sdk_package_list_fails(self) -> None:
        # Built from the checker's own list so this file types no copy of it.
        typed = "PACKAGES = (" + ", ".join(f'"{name}"' for name in CHECK.SDK_PACKAGES) + ")\n"
        self.write("cmux-tui/bindings/rust/scripts/sync.py", typed)
        self.assertEqual(self.run_check(), (0, ""), "one home for the list is fine")
        self.write("cmux-tui/scripts/check-boundary.py", typed.replace('"', "'").replace(", ", ",\t"))
        status, errors = self.run_check()
        self.assertEqual(status, 1)
        self.assertIn("cmux-tui/scripts/check-boundary.py: types the SDK package list", errors)
        self.assertIn("cmux-tui/bindings/rust/scripts/sync.py: types the SDK package list", errors)

    # Fails on feat-cmux-next before this change: seven committed descriptors and
    # the package list typed in three files.
    def test_this_repository_has_one_source_each(self) -> None:
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors):
            status = CHECK.main(["--root", str(REPO)])
        self.assertEqual(status, 0, errors.getvalue())


if __name__ == "__main__":
    unittest.main()
