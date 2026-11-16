#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check-v2-app-callers.py"
SPEC = importlib.util.spec_from_file_location("check_v2_app_callers", SCRIPT)
assert SPEC and SPEC.loader
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def manifest_entry(method, count=1):
    return {
        "path": "Packages/macOS/CmuxNext/Sources/Fixture.swift",
        "symbol": "Fixture.answer",
        "method": method,
        "count": count,
        "owner": "7f",
        "kind": "fixture",
    }


class V2AppCallerCheckerTests(unittest.TestCase):
    def test_current_inventory_passes(self):
        root = SCRIPT.parents[2]
        errors = CHECK.check_inventory(root, SCRIPT.with_name("v2-app-callers.json"))
        self.assertEqual(errors, [])

    def test_new_method_is_unlisted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / CHECK.SOURCE_ROOT
            source.mkdir(parents=True)
            (source / "Fixture.swift").write_text(
                'let request = ["method": "_acpmux/watch"]\n', encoding="utf-8"
            )
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"callers": []}), encoding="utf-8")
            errors = CHECK.check_inventory(root, manifest)
            self.assertTrue(any("unlisted app caller" in error for error in errors), errors)

    def test_excluded_longer_methods_do_not_count_as_v1_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / CHECK.SOURCE_ROOT
            source.mkdir(parents=True)
            (source / "Fixture.swift").write_text(
                '\n'.join(
                    [
                        '"_acpmux/watch_take_over"',
                        '"_acpmux/sessions/restart_harness"',
                        '"_acpmux/watch"',
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"callers": [manifest_entry("_acpmux/watch")]}), encoding="utf-8")
            self.assertEqual(CHECK.check_inventory(root, manifest), [])

    def test_list_capable_recording_rejects_old_methods(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", encoding="utf-8") as recording:
            json.dump(
                {
                    "list_capable": True,
                    "requests": [{"method": "_acpmux/watch"}, {"method": "initialize"}],
                },
                recording,
            )
            recording.flush()
            errors = CHECK.check_recording(Path(recording.name), None)
            self.assertEqual(len(errors), 1)
            self.assertIn("list-capable recording emitted _acpmux/watch", errors[0])

    def test_old_recording_is_allowed_to_use_fallback(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", encoding="utf-8") as recording:
            recording.write('{"list_capable": false, "method": "_acpmux/sessions"}\n')
            recording.flush()
            self.assertEqual(CHECK.check_recording(Path(recording.name), None, {"_acpmux/sessions"}), [])

    def test_old_recording_rejects_an_unnamed_method(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", encoding="utf-8") as recording:
            recording.write('{"list_capable": false, "method": "session/list"}\n')
            recording.flush()
            errors = CHECK.check_recording(Path(recording.name), None, {"_acpmux/sessions"})
            self.assertEqual(len(errors), 1)
            self.assertIn("unnamed fallback session/list", errors[0])


if __name__ == "__main__":
    unittest.main()
