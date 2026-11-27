from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.phone_default_speed import BENCH

FIXTURE = Path(__file__).parent / "fixtures" / "phone-default-speed" / "check.log"


LOCK_SCRIPT = Path(__file__).resolve().parents[1] / "phone-default-speed/check_lock.py"
spec = importlib.util.spec_from_file_location("phone_default_speed_lock", LOCK_SCRIPT)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


class PhoneDefaultSpeedTest(unittest.TestCase):
    def context(self):
        return Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")

    def test_production_dependency_drift_is_rejected(self):
        root = {"name": "ghostty-vt", "version": "0.1.0", "dependencies": ["unicode-width"]}
        dependency = {"name": "unicode-width", "version": "0.2.2", "checksum": "a"}
        changed = dict(dependency, version="0.2.3")
        self.assertNotEqual(lock.closure([root, dependency], root["name"]),
                            lock.closure([root, changed], root["name"]))
        with self.assertRaises(ValueError):
            lock.closure([root], root["name"])

    def test_workspace_optional_features_do_not_require_unmeasured_dependencies(self):
        root = {"name": "ghostty-vt", "version": "0.1.0", "dependencies": ["bitflags"]}
        flags = {"name": "bitflags", "version": "2.13.2", "checksum": "same"}
        optional = {"name": "serde_core", "version": "1.0.229"}
        production = [root, dict(flags, dependencies=["serde_core"]), optional]
        lock.compare_locks([production, [root, flags]], {"bitflags"})
        for change in ({"version": "2.14.0"}, {"checksum": "other"}, {"source": "other"}):
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "dependency drift"):
                lock.compare_locks([production, [root, dict(flags, **change)]], {"bitflags"})

    def test_lock_scope_includes_renamed_target_and_build_dependencies(self):
        manifest = {"dependencies": {"width": {"package": "unicode-width"}},
                    "dev-dependencies": {"ghostty-vt": {}},
                    "target": {"cfg(unix)": {"dependencies": {"libc": "1"}}},
                    "build-dependencies": {"cc": "1"}}
        self.assertEqual(lock.runtime_names(manifest), {"unicode-width", "libc", "cc"})

    def test_actual_run_has_every_case(self):
        context = self.context()
        BENCH.ingest(context, FIXTURE)
        self.assertEqual(len(context.rows), 4)
        self.assertTrue(all(row["unit"] == "count" and row["value"] > 0 for row in context.rows))
        self.assertEqual({row["labels"]["seeded_lines"] for row in context.rows}, {"100", "10000"})

    def test_incomplete_or_duplicated_run_is_not_a_measurement(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "partial.log"
            path.write_text("primary-100\t42 Ir / 10 operations\n")
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)
            path.write_text(FIXTURE.read_text() + FIXTURE.read_text())
            with self.assertRaises(BenchError):
                BENCH.ingest(self.context(), path)


if __name__ == "__main__":
    unittest.main()
