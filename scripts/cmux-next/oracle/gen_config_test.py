#!/usr/bin/env python3
"""Tests of gen_config.py (p15-oracle-212). Stdlib unittest, run as a script, not in CI.

    python3 -I scripts/cmux-next/oracle/gen_config_test.py
    python3 -I scripts/cmux-next/oracle/gen_config_test.py --rust-dump R.jsonl

The second form also checks a real `oracle_effective` dump: one line per corpus file, and the dump
compared with itself (relabeled swift) has no difference.
"""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gen_config  # noqa: E402

RUST_DUMP: Path | None = None


def write_dump(directory: Path, producer: str, records: dict) -> Path:
    path = directory / f"{producer}.jsonl"
    lines = [json.dumps({"oracle_config_dump": gen_config.DUMP_VERSION, "producer": producer})]
    lines += [json.dumps({"file": file, "dump": dump}) for file, dump in records.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


class CorpusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.files = gen_config.corpus()

    def test_at_least_2000_files_and_every_row_covered(self) -> None:
        coverage = json.loads(self.files["coverage.json"])
        self.assertGreaterEqual(coverage["file_count"], gen_config.MIN_FILES)
        self.assertEqual(coverage["covered"], coverage["total"])
        self.assertEqual(coverage["missing"], [])

    def test_generation_is_deterministic(self) -> None:
        self.assertEqual(self.files, gen_config.corpus())

    def test_every_family_is_present(self) -> None:
        prefixes = ("settings/schema/", "settings/defaults/", "settings/retired/", "settings/mutations/",
                    "managed/", "keybindings/")
        for prefix in prefixes:
            self.assertTrue(any(rel.startswith(prefix) for rel in self.files), prefix)

    def test_every_retired_key_has_files(self) -> None:
        for key in gen_config.retired_keys():
            self.assertIn(f"settings/retired/{gen_config.file_name(key)}-with-live.jsonc", self.files)

    def test_managed_and_keybinding_files_are_strict_json(self) -> None:
        for rel, text in self.files.items():
            if rel.startswith(("managed/", "keybindings/")):
                json.loads(text)

    def test_check_finds_a_changed_and_a_stale_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            gen_config.write_corpus(out, self.files)
            self.assertEqual(gen_config.check_corpus(out, self.files), [])
            (out / "settings/defaults/empty-object.jsonc").write_text("{\"x\": 1}\n", encoding="utf-8")
            (out / "settings/extra.jsonc").write_text("{}\n", encoding="utf-8")
            problems = gen_config.check_corpus(out, self.files)
            self.assertIn("settings/defaults/empty-object.jsonc: differs from a fresh generation", problems)
            self.assertIn("settings/extra.jsonc: not generated (stale)", problems)


class StrokeTests(unittest.TestCase):
    def test_named_keys_and_aliases_read_as_the_app_reads_them(self) -> None:
        swift = {"key": "", "cmd": True, "shift": False, "opt": False, "ctrl": False}
        self.assertEqual(gen_config.canonical_swift_stroke(swift), "cmd+left")
        for text in ("cmd+left", "cmd+←", "cmd+ArrowLeft"):
            self.assertEqual(gen_config.canonical_rust_stroke(text), "cmd+left", text)
        self.assertEqual(gen_config.canonical_rust_stroke("ctrl+f05"), "ctrl+f5")
        self.assertEqual(gen_config.canonical_rust_stroke("cmd+plus"), "cmd+=")
        self.assertEqual(gen_config.canonical_rust_stroke("cmd+K"), "cmd+k")

    def test_plus_key_and_plus_name_differ(self) -> None:
        swift_plus = {"key": "+", "cmd": True}
        self.assertEqual(gen_config.canonical_swift_stroke(swift_plus), "cmd++")
        self.assertNotEqual(gen_config.canonical_rust_stroke("cmd+plus"), "cmd++")

    def test_a_stroke_the_app_cannot_read_never_matches(self) -> None:
        self.assertEqual(gen_config.canonical_rust_stroke("cmd+hyper"), {"unreadable_by_app": "cmd+hyper"})
        self.assertEqual(gen_config.canonical_rust_stroke("cmd+f21"), {"unreadable_by_app": "cmd+f21"})


class DiffTests(unittest.TestCase):
    def test_numbers_and_set_fields_canonicalize(self) -> None:
        swift = {"a.jsonc": {"effective": {"n": 1.0}, "invalid": ["b", "a"]}}
        rust = {"a.jsonc": {"effective": {"n": 1}, "invalid": ["a", "b"]}}
        self.assertEqual(gen_config.diff_records(swift, rust), [])

    def test_difference_is_file_path_swift_rust(self) -> None:
        swift = {"a.jsonc": {"values": {"x.y": True}}, "only-swift.jsonc": {}}
        rust = {"a.jsonc": {"values": {"x.y": False, "x/z": 2}}}
        records = gen_config.diff_records(swift, rust)
        self.assertIn({"file": "a.jsonc", "path": "/values/x.y", "swift": True, "rust": False}, records)
        self.assertIn({"file": "a.jsonc", "path": "/values/x~1z", "rust": 2}, records)
        self.assertIn({"file": "only-swift.jsonc", "path": "", "swift": {}}, records)

    def test_strokes_diff_per_index(self) -> None:
        swift = {"k.jsonc": {"strokes": [{"key": "k", "cmd": True}, None], "bare_when": [True]}}
        rust = {"k.jsonc": {"strokes": ["cmd+k", "cmd+j"], "bare_when": [False]}}
        records = gen_config.diff_records(swift, rust)
        self.assertEqual(
            records,
            [{"file": "k.jsonc", "path": "/bare_when/0", "swift": True, "rust": False},
             {"file": "k.jsonc", "path": "/strokes/1", "swift": None, "rust": "cmd+j"}],
        )

    def test_cmd_diff_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            same = {"a.jsonc": {"readable": True}}
            swift = write_dump(directory, "swift", same)
            rust = write_dump(directory, "rust", same)
            self.assertEqual(gen_config.main(["diff", "--swift", str(swift), "--rust", str(rust)]), 0)
            rust = write_dump(directory, "rust", {"a.jsonc": {"readable": False}})
            out = directory / "divergences.jsonl"
            self.assertEqual(gen_config.main(["diff", "--swift", str(swift), "--rust", str(rust), "--out", str(out)]), 1)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8")),
                             {"file": "a.jsonc", "path": "/readable", "swift": True, "rust": False})
            self.assertEqual(gen_config.main(["diff", "--swift", str(rust), "--rust", str(rust)]), 2)


class RustDumpTests(unittest.TestCase):
    def test_rust_dump_covers_the_corpus_and_matches_itself(self) -> None:
        if RUST_DUMP is None:
            self.skipTest("pass --rust-dump R.jsonl")
        records = gen_config.read_dump(RUST_DUMP, "rust")
        expected = {rel for rel in gen_config.corpus() if rel.endswith(".jsonc")}
        self.assertEqual(set(records), expected)
        with tempfile.TemporaryDirectory() as tmp:
            relabeled = Path(tmp) / "swift.jsonl"
            lines = RUST_DUMP.read_text(encoding="utf-8").splitlines()
            header = json.loads(lines[0])
            header["producer"] = "swift"
            relabeled.write_text("\n".join([json.dumps(header)] + lines[1:]) + "\n", encoding="utf-8")
            # The relabeled Rust strokes are text, not Swift stroke objects, so compare settings files only.
            swift = {f: d for f, d in gen_config.read_dump(relabeled, "swift").items() if not f.startswith("keybindings/")}
            rust = {f: d for f, d in records.items() if not f.startswith("keybindings/")}
            self.assertEqual(gen_config.diff_records(swift, rust), [])


def main() -> int:
    global RUST_DUMP
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--rust-dump", type=Path)
    args, rest = parser.parse_known_args()
    RUST_DUMP = args.rust_dump
    result = unittest.main(argv=[sys.argv[0], *rest], exit=False).result
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
