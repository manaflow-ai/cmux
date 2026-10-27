#!/usr/bin/env python3
"""Tests for disallowed_methods.py (lab only): python3 cmux-tui/lab/clippy/test_disallowed_methods.py"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import disallowed_methods  # noqa: E402


def hit(file_name, line, method, package="cmux-config", kind="lib", column=9):
    return {
        "reason": "compiler-message",
        "package_id": f"path+file:///w/cmux-tui/crates/{package}#0.1.0",
        "target": {"kind": [kind]},
        "message": {
            "code": {"code": "clippy::disallowed_methods"},
            "message": f"use of a disallowed method `{method}`",
            "spans": [{"is_primary": True, "file_name": file_name, "line_start": line, "column_start": column}],
        },
    }


def write_run(lines, finished=True):
    handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
    with handle:
        for line in lines:
            handle.write(json.dumps(line) + "\n")
        handle.write(json.dumps({"reason": "build-finished", "success": finished}) + "\n")
    return handle.name


class DisallowedMethodsTest(unittest.TestCase):
    def setUp(self):
        self.paths = []

    def tearDown(self):
        for path in self.paths:
            os.unlink(path)

    def run_file(self, lines, finished=True, label=None):
        path = write_run(lines, finished)
        self.paths.append(path)
        return (label or os.path.basename(path), path)

    def test_counts_per_crate_and_method(self):
        run = self.run_file([
            hit("crates/cmux-config/src/a.rs", 1, "std::fs::read"),
            hit("crates/cmux-config/src/a.rs", 2, "std::fs::read"),
            hit("crates/cmux-config/src/b.rs", 3, "std::thread::sleep"),
            hit("crates/acpmux/src/c.rs", 4, "std::fs::write", package="acpmux"),
        ])
        crates = disallowed_methods.summarize([run])["crates"]
        self.assertEqual(crates["cmux-config"], {"total": 3, "methods": {"std::fs::read": 2, "std::thread::sleep": 1}})
        self.assertEqual(crates["acpmux"]["total"], 1)

    def test_a_line_both_runs_see_counts_once(self):
        same = hit("crates/cmux-config/src/a.rs", 1, "std::fs::read")
        linux = self.run_file([same], label="linux")
        macos = self.run_file([same, hit("/m/cmux-tui/crates/cmux-config/src/mac.rs", 7, "std::fs::read")], label="macos")
        summary = disallowed_methods.summarize([linux, macos])
        self.assertEqual(summary["crates"]["cmux-config"]["total"], 2)

    def test_one_macro_span_counts_each_method(self):
        # checked_fs!'s `$call($($arg),*)` gives every std call it expands to one span.
        span = ("crates/cmux-config/src/m.rs", 30)
        linux = self.run_file([hit(*span, "std::fs::read"), hit(*span, "std::fs::write")], label="linux")
        macos = self.run_file([hit(*span, "std::fs::write"), hit(*span, "std::fs::File::sync_data")], label="macos")
        crates = disallowed_methods.summarize([linux, macos])["crates"]
        self.assertEqual(crates["cmux-config"], {
            "total": 3,
            "methods": {"std::fs::read": 1, "std::fs::write": 1, "std::fs::File::sync_data": 1},
        })

    def test_check_ignores_the_layers_below_cmux_blocking(self):
        run = self.run_file([
            hit("crates/cmux-threads/src/sync_locks.rs", 226, "std::sync::Condvar::wait", package="cmux-threads"),
            hit("crates/cmux-threads/src/spawn.rs", 45, "std::thread::Builder::spawn", package="cmux-threads"),
            hit("crates/cmux-panic-log/src/lib.rs", 80, "std::fs::OpenOptions::open", package="cmux-panic-log"),
        ])
        self.assertEqual(disallowed_methods.main([run[1], "--check"]), 0)
        summary = disallowed_methods.summarize([run])
        self.assertEqual(summary["crates"]["cmux-threads"]["total"], 2)
        self.assertEqual(summary["crates"]["cmux-panic-log"]["total"], 1)
        self.assertEqual(disallowed_methods.outside_wrappers(summary), 0)

    def test_check_ignores_wrappers_and_build_scripts(self):
        run = self.run_file([
            hit("crates/cmux-threads/src/checked.rs", 30, "std::fs::read", package="cmux-threads"),
            hit("crates/cmux-blocking/src/fs.rs", 11, "std::fs::read", package="cmux-blocking"),
            hit("crates/cmux-config/build.rs", 2, "std::fs::read", kind="custom-build"),
        ])
        self.assertEqual(disallowed_methods.main([run[1], "--check"]), 0)
        crates = disallowed_methods.summarize([run])["crates"]
        self.assertEqual(sorted(crates), ["cmux-blocking", "cmux-threads (checked)"])

    def test_check_fails_on_a_hit_or_an_unfinished_run(self):
        hit_run = self.run_file([hit("crates/cmux-config/src/a.rs", 1, "std::fs::read")])
        self.assertEqual(disallowed_methods.main([hit_run[1], "--check"]), 1)
        unfinished = self.run_file([], finished=False)
        self.assertEqual(disallowed_methods.main([unfinished[1], "--check"]), 1)

    def test_lab_config_names_a_wrapper_for_every_rule(self):
        import tomllib

        config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clippy.toml")
        with open(config_path, "rb") as handle:
            config = tomllib.load(handle)
        blocking = [rule for rule in config["disallowed-methods"] if not rule["path"].startswith("std::thread::")
                    or rule["path"] in ("std::thread::sleep", "std::thread::JoinHandle::join")]
        self.assertTrue(blocking)
        for rule in blocking:
            self.assertIn("cmux_blocking::", rule["reason"], rule["path"])


if __name__ == "__main__":
    unittest.main()
