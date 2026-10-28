#!/usr/bin/env python3
"""Admission caps are rejected even in new attachment/upload directories."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).parents[1] / "scripts" / "cmux-next" / "check-attachment-caps.py"
SPEC = importlib.util.spec_from_file_location("attachment_caps_guard", SCRIPT)
assert SPEC and SPEC.loader
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class AttachmentCapsGuardTests(unittest.TestCase):
    def test_tree_has_no_user_attachment_cap_names(self):
        self.assertEqual(guard.violations(SCRIPT.parents[2]), [])

    def test_new_source_paths_are_discovered(self):
        for relative in ("webviews/src/uploads/service.ts", "NewModule/Sources/Attachments/Service.swift"):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source = root / relative
                source.parent.mkdir(parents=True)
                source.write_text("let MAX_ATTACHMENT_BYTES = 100\n", encoding="utf-8")
                self.assertEqual(guard.violations(root), [f"{relative}:1: MAX_ATTACHMENT_BYTES"])

    def test_a_file_that_calls_an_upload_is_checked_whatever_its_name(self):
        # optchat-chief's brain/media.rs capped the Chief's sends at 50 MB in a path the
        # name rule never saw.
        source = "pub const MAX_MEDIA_BYTES: u64 = 50_000_000;\nport.upload_attachment(conversation, path);\n"
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            media = root / "Native/OptChat/optchat-chief/src/brain/media.rs"
            media.parent.mkdir(parents=True)
            media.write_text(source, encoding="utf-8")
            (root / "src/brain").mkdir(parents=True)
            (root / "src/brain/state.rs").write_text("const MAX_STATE_BYTES: u64 = 1;\n", encoding="utf-8")
            self.assertEqual(
                guard.violations(root), ["Native/OptChat/optchat-chief/src/brain/media.rs:1: MAX_MEDIA_BYTES"]
            )

    def test_excludes_fixtures_dependencies_and_test_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in ("fixtures/uploads/a.ts", "node_modules/uploads/a.ts", "src/uploads/a.test.ts"):
                source = root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("const MAX_FILE_BYTES = 100\n", encoding="utf-8")
            self.assertEqual(guard.violations(root), [])

    def test_transport_chunks_are_not_original_admission_caps(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "upload.ts").write_text("const MAX_CHUNK_BYTES = 1024; const MAX_TOTAL_BYTES = 100;\n")
            self.assertEqual(guard.violations(root), ["upload.ts:1: MAX_TOTAL_BYTES"])


if __name__ == "__main__":
    unittest.main()
