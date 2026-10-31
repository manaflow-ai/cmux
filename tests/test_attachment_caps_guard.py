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
    def test_checked_in_tree_has_no_unreviewed_caps(self):
        self.assertEqual(guard.violations(SCRIPT.parents[2]), [])

    def check_source(self, source, expected, relative="src/upload.swift"):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root / relative
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            found = guard.violations(root)
            self.assertEqual(len(found), expected, found)

    def test_retained_bounds_only_apply_to_the_named_path_and_symbol(self):
        for relative, symbols in guard.RETAINED_BOUNDS.items():
            for name, reason in symbols.items():
                with self.subTest(path=relative, name=name):
                    self.assertTrue(reason.strip())
                    self.check_source(f"let {name} = 1", 0, relative)
                    self.check_source(f"let {name} = 1", 1, "new/uploads/service.swift")
            if guard.attachment_path(Path(relative)):
                self.check_source("let maximumNewFileBytes = 1", 1, relative)
                self.check_source("guard size <= 1_048_576 else { return failure() }", 1, relative)
                self.check_source("guard files.count <= 64 else { return failure() }", 1, relative)
            self.check_source("let MAX_NEW_ATTACHMENTS = 1", 1, relative)

    def test_camel_case_file_and_stage_caps(self):
        for name in ("maximumFileSize", "maximumUploadBytes", "maximumUploadStageFile", "maximumStagedBytes"):
            with self.subTest(name=name):
                self.check_source(f"let {name} = 100", 1)

    def test_size_named_caps(self):
        for name in ("MAX_FILE_SIZE", "MAX_ATTACHMENT_SIZE", "MAX_TOTAL_SIZE"):
            with self.subTest(name=name):
                self.check_source(f"const {name} = 100", 1)

    def test_count_and_length_admission_comparisons(self):
        for source in (
            "guard data.count <= 1_048_576 else { return failure() }",
            "if (file.length > 1024 * 1024) reject();",
            "if (1_048_576 < data.count) reject();",
            "guard 1_048_576 >= file.length else { return failure() }",
            "if file.len() > 1_048_576 { return Err(error); }",
        ):
            with self.subTest(source=source):
                self.check_source(source, 1)

    def test_decoder_is_scanned_even_without_upload_in_filename(self):
        self.check_source("let maximumUploadStageFile = 1024", 1,
                          "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneRequest+Decoding.swift")

    def test_literal_admission_comparisons(self):
        for source in (
            "guard size <= 1 * 1024 * 1024 * 1024 else { return failure() }",
            "manifest.allSatisfy({ $0.size >= 0 && $0.size <= 1 * 1024 * 1024 * 1024 })",
            "guard manifest.reduce(0) { $0 + $1.size } <= 1 * 1024 * 1024 * 1024 else { return failure() }",
            "if (file.size > (1024 * 1024)) throw new Error('large');",
            "if (1_048_576 < file.size) reject();",
            "guard 1 * 1024 * 1024 * 1024 >= size else { return failure() }",
            "if (files.reduce((sum, file) => sum + file.size, 0) > 1024 * 1024) reject();",
            "if totalBytes > (1 << 30) { return Err(error); }",
            "if file_size >= 1048576 { return Err(error); }",
            "guard size <=\n  1 * 1024 * 1024 * 1024 else { return failure() }",
        ):
            with self.subTest(source=source):
                self.check_source(source, 1)

    def test_transport_and_non_cap_comparisons(self):
        for source in (
            "guard size >= 0, offset + data.count <= stage.size, data.count <= 512 * 1024 else { return failure() }",
            "if (chunk.size > 2 * 1024 * 1024) rejectChunk();",
            "if (frameBytes > 1_048_576) splitFrame();",
            "if range.size > (1 << 20) { splitRange(); }",
            "let maximumUploadStageChunk = 512 * 1024",
            "let maximumChunkBytes = 2 * 1024 * 1024",
            "const MAX_FRAME_BYTES = 2 * 1024 * 1024;",
            "let maximumAge = 30 * 24 * 60 * 60",
            "if (file.size > MAX_CHUNK_BYTES) useChunks();",
            "if (size > 1024) validate();",
            "if (timestamp > 1_048_576) expire();",
            "// size <= 1 * 1024 * 1024 * 1024\nlet message = \"maximumUploadStageFile\";",
            "if (size > runtimeLimit(1024 * 1024)) check();",
        ):
            with self.subTest(source=source):
                self.check_source(source, 0)

    def test_diagnostics_keep_line_numbers_after_comments(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "upload.swift").write_text(
                '/* maximumFileBytes\n size <= 1_048_576 */\n'
                'guard size <= 1_048_576 else { return failure() }\n')
            found = guard.violations(root)
            self.assertEqual(len(found), 1, found)
            self.assertTrue(found[0].startswith("upload.swift:3: literal size cap:"), found)

    def test_literal_parser_does_not_execute_or_expand_arbitrary_expressions(self):
        for expression in ("__import__('os').system('exit 1')", "2 ** 1000000000", "1 << 1000000000"):
            with self.subTest(expression=expression):
                self.assertIsNone(guard.literal_value([expression]))

    def test_new_source_paths_are_discovered(self):
        for relative in ("webviews/src/uploads/service.ts", "NewModule/Sources/Attachments/Service.swift"):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source = root / relative
                source.parent.mkdir(parents=True)
                source.write_text("let MAX_ATTACHMENT_BYTES = 100\n", encoding="utf-8")
                self.assertEqual(guard.violations(root), [f"{relative}:1: MAX_ATTACHMENT_BYTES"])

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

    def test_count_caps_in_upload_paths(self):
        for source in (
            "if (files.length > 10) throw pageError();",
            "guard !list.isEmpty, list.count <= 64 else { return .unsupported(method) }",
            "if (files.length + added.length >= MAX_ATTACHMENTS) break;",
            "guard manifest.count < 65 else { return failure() }",
            "if attachments.len() > 16 { return Err(error); }",
        ):
            with self.subTest(source=source):
                self.check_source(source, 1, "src/uploads/composer.ts")

    def test_count_cap_names_anywhere(self):
        for name in ("MAX_ATTACHMENTS", "MAX_SEND_ATTACHMENTS", "maxAttachments", "MAX_UPLOADS", "maximumUploads"):
            with self.subTest(name=name):
                self.check_source(f"const {name} = 10;", 1, "src/pages/home/store.ts")
        # A file limit outside attachment code (a diff, a git listing) is not an attachment cap.
        for name in ("MAX_FILES", "maximumFiles", "MAX_UNTRACKED_FILES"):
            with self.subTest(name=name):
                self.check_source(f"const {name} = 10;", 0, "src/diff/source.ts")
                self.check_source(f"const {name} = 10;", 1, "src/uploads/service.ts")
        self.check_source("guard key.count >= 32 else { return nil }", 0, "src/attachments/keys.swift")

    def test_literal_counts_outside_upload_paths_are_not_scanned(self):
        # A transcript's layout cache or a diff's file list is not a send's admission.
        self.check_source("if attachments.count > 512 { attachments.removeAll() }", 0, "src/transcript/rows.swift")
        self.check_source("if (files.length > 10) collapse();", 0, "src/diff/list.ts")

    def test_routes_and_non_caps_are_not_count_caps(self):
        for source in (
            "if let manifest, batchToken == nil, manifest.count > 1 { startBatch() }",
            "if (files.length === 0) return;",
            "if (list.count >= 2) showGrid();  // cap-allow: route",
            "// one message or several: cap-allow: route\nif (parts.length > MESSAGE_PARTS) split();",
            "guard text.count <= 40_000 else { return failure() }",
            "if (chunks.length > 100) flush();",
        ):
            with self.subTest(source=source):
                self.check_source(source, 0, "src/uploads/composer.ts")

    def test_route_mark_on_the_line_above(self):
        self.check_source("// cap-allow: route (one message or several)\nif (files.length > 16) split();", 0,
                          "src/uploads/composer.ts")
        self.check_source("// cap-allow: route\n\nif (files.length > 16) split();", 1, "src/uploads/composer.ts")

    def test_warn_mode_annotates_and_exits_zero(self):
        import subprocess, sys
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "upload.ts").write_text("if (files.length > 10) refuse();\n", encoding="utf-8")
            warned = subprocess.run([sys.executable, "-I", str(SCRIPT), "--warn", str(root)], capture_output=True, text=True)
            self.assertEqual(warned.returncode, 0, warned.stdout + warned.stderr)
            self.assertIn("::warning file=upload.ts,line=1,title=attachment cap::literal count cap", warned.stdout)
            failed = subprocess.run([sys.executable, "-I", str(SCRIPT), str(root)], capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)


if __name__ == "__main__":
    unittest.main()
