#!/usr/bin/env python3
"""Offline tests for the VM fuzz's --diag variants (diag.py, fuzz.py, vm.sh): no VM, no app.

Run: python3 -m unittest scripts/fuzz/macos-matrix/test_diag.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import diag  # noqa: E402


class FakeGuest:
    """Answers Guest.sh, .cmux and .pid from canned outputs, keyed by a substring of the command."""

    def __init__(self, answers: dict[str, str], pid: int | None = 4242):
        self.answers, self._pid, self.commands = answers, pid, []

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        self.commands.append(cmd)
        out = next((v for k, v in self.answers.items() if k in cmd), "")
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def cmux(self, args: list[str], timeout: float = 15) -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess(args, 1, "", "debug calls are refused")

    def pid(self) -> int | None:
        return self._pid


def zones_line(*names: str) -> str:
    return json.dumps({"pid": 4242, "zones": list(names)}) + "\n"


class Variants(unittest.TestCase):
    def test_every_named_variant_exists(self):
        self.assertEqual(set(diag.DIAGS),
                         {"gmalloc", "scribble", "probguard", "mtc", "coop-strict", "asan", "tsan", "ubsan"})

    def test_malloc_and_sanitizer_variants_run_with_chromium_off(self):
        for name in ("gmalloc", "scribble", "probguard", "asan", "tsan", "ubsan"):
            self.assertTrue(diag.DIAGS[name].chromium_off, name)
        for name in ("mtc", "coop-strict"):
            self.assertFalse(diag.DIAGS[name].chromium_off, name)

    def test_launch_env(self):
        env = diag.launch_env(diag.DIAGS["gmalloc"], ["/Users/admin/other.dylib"])
        self.assertEqual(env["DYLD_INSERT_LIBRARIES"], "/Users/admin/other.dylib:/usr/lib/libgmalloc.dylib")
        self.assertEqual(env["CMUX_NEXT_CONFIG_FILE"], diag.CONFIG_FILE)
        env = diag.launch_env(diag.DIAGS["scribble"], [])
        self.assertEqual((env["MallocScribble"], env["MallocGuardEdges"]), ("1", "1"))
        self.assertNotIn("DYLD_INSERT_LIBRARIES", env)
        self.assertEqual(diag.launch_env(diag.DIAGS["coop-strict"], []),
                         {"LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"})
        self.assertEqual(diag.launch_env(diag.DIAGS["probguard"], [])["MallocProbGuard"], "1")
        asan = diag.launch_env(diag.DIAGS["asan"], [])["ASAN_OPTIONS"]
        self.assertTrue(asan.startswith(f"log_path={diag.SAN_DIR}/asan:"), asan)

    def test_info_lines_for_vm_sh(self):
        lines = diag.info_lines(diag.DIAGS["tsan"]).splitlines()
        self.assertIn("chromium=off", lines)
        self.assertIn("bundle_suffix=.tsan", lines)
        self.assertEqual([l for l in lines if l.startswith("remove=")],
                         [f"remove={p}" for p in diag.CHROMIUM_RUNTIME])
        mtc = diag.info_lines(diag.DIAGS["mtc"]).splitlines()
        self.assertIn("host_dylib=libMainThreadChecker.dylib", mtc)
        self.assertFalse([l for l in mtc if l.startswith("remove=")])
        self.assertEqual(diag.info_lines(diag.DIAGS["coop-strict"]).splitlines(),
                         ["chromium=on", "bundle_suffix=", "host_dylib="])


class Zones(unittest.TestCase):
    def test_default_and_effective_zone(self):
        z = diag.parse_zones("noise\n" + zones_line(diag.EARLY_ZONE, "DefaultMallocZone", "DefaultPurgeableMallocZone"))
        self.assertEqual(z["default_zone"], diag.EARLY_ZONE)
        self.assertEqual(z["effective_zone"], "DefaultMallocZone")
        self.assertTrue(z["early_zone"])
        self.assertFalse(z["partition_alloc"])

    def test_partition_alloc_zone_is_seen(self):
        z = diag.parse_zones(zones_line("PartitionAlloc", diag.EARLY_ZONE, "DefaultMallocZone"))
        self.assertTrue(z["partition_alloc"])
        self.assertEqual(z["effective_zone"], "PartitionAlloc")

    def test_error_and_no_output(self):
        self.assertEqual(diag.parse_zones('{"pid": 1, "error": "task_for_pid: (os/kern) failure"}\n'),
                         {"error": "task_for_pid: (os/kern) failure"})
        self.assertIn("error", diag.parse_zones("sudo: a password is required"))

    def test_malloc_zones_falls_back_from_sudo(self):
        # The first key that matches answers: the sudo command gets the refusal, the plain one the zones.
        g = FakeGuest({"sudo -n": "sudo: a password is required\n", "malloc-zones": zones_line("GuardMalloc")})
        self.assertEqual(diag.malloc_zones(g, "/Users/admin/malloc-zones", 4242)["default_zone"], "GuardMalloc")
        self.assertEqual(len(g.commands), 2)
        self.assertEqual(diag.malloc_zones(g, "", 4242), {"error": "no malloc-zones tool"})


class Validity(unittest.TestCase):
    clean = {"pid": 7, "malloc": diag.parse_zones(zones_line("DefaultMallocZone")), "chromium_mapped": False}

    def test_clean_chromium_off_run_is_valid(self):
        self.assertEqual(diag.validity(diag.DIAGS["gmalloc"], [], [self.clean]), "")

    def test_partition_alloc_run_is_invalid(self):
        pa = {"pid": 9, "malloc": diag.parse_zones(zones_line("PartitionAlloc", "DefaultMallocZone")),
              "chromium_mapped": False}
        self.assertIn("PartitionAlloc", diag.validity(diag.DIAGS["asan"], [], [self.clean, pa]))

    def test_mapped_framework_or_runtime_left_is_invalid(self):
        mapped = {**self.clean, "chromium_mapped": True}
        self.assertIn("mapped", diag.validity(diag.DIAGS["scribble"], [], [mapped]))
        self.assertIn("still in the app", diag.validity(diag.DIAGS["scribble"], [diag.CHROMIUM_RUNTIME[0]], [self.clean]))

    def test_no_evidence_is_invalid(self):
        blind = {"pid": 7, "malloc": {"error": "no malloc-zones tool"}, "chromium_mapped": None}
        self.assertIn("no snapshot", diag.validity(diag.DIAGS["tsan"], [], [blind]))
        self.assertIn("no snapshot", diag.validity(diag.DIAGS["tsan"], [], []))

    def test_chromium_on_variants_are_never_invalid(self):
        self.assertEqual(diag.validity(diag.DIAGS["mtc"], [], []), "")


class ReportsAndRecord(unittest.TestCase):
    def test_mtc_reports_from_stderr(self):
        stderr = ("Main Thread Checker: UI API called on a background thread: -[NSView setNeedsDisplay:]\n"
                  "PID: 4242, TID: 99\nBacktrace:\n"
                  "Main Thread Checker: UI API called on a background thread: -[NSView setNeedsDisplay:]\n")
        with tempfile.TemporaryDirectory() as out:
            r = diag.Reports(diag.DIAGS["mtc"], out)
            r.harvest_stderr(FakeGuest({"grep -F": stderr}), "end")
            r.collect_files(FakeGuest({}))  # MTC has no report files
            s = r.summary()
            self.assertEqual((s["kind"], s["count"], s["unique"]), ("mtc", 2, 1))
            self.assertTrue(os.path.exists(os.path.join(out, "mtc-stderr.txt")))

    def test_sanitizer_reports_from_log_files(self):
        text = ("== /tmp/fuzz-san/tsan.4242\nWARNING: ThreadSanitizer: data race (pid=4242)\n  Write of size 8\n"
                "WARNING: ThreadSanitizer: data race (pid=4242)\n")
        with tempfile.TemporaryDirectory() as out:
            r = diag.Reports(diag.DIAGS["tsan"], out)
            r.harvest_stderr(FakeGuest({"grep -F": "WARNING: ThreadSanitizer: x"}), "end")  # not read for tsan
            r.collect_files(FakeGuest({"/tmp/fuzz-san/*": text}))
            self.assertEqual(r.summary()["count"], 2)
            self.assertTrue(os.path.exists(os.path.join(out, "tsan-reports.txt")))

    def test_record_has_env_chromium_state_and_default_zone(self):
        d = diag.DIAGS["gmalloc"]
        env = diag.launch_env(d, [])
        g = FakeGuest({"lsof": "0\n", "malloc-zones": zones_line("GuardMalloc", "DefaultPurgeableMallocZone")})
        snap = {"at": "launch", **diag.snapshot(g, "/Users/admin/malloc-zones")}
        with tempfile.TemporaryDirectory() as out:
            rec = diag.record(d, env, [], [snap], diag.Reports(d, out))
        self.assertEqual(rec["env"], env)
        self.assertEqual(rec["chromium"], "off")
        self.assertFalse(rec["chromium_mapped"])
        self.assertEqual(rec["default_zone"], "GuardMalloc")
        self.assertIsNone(rec["invalid"])
        json.dumps(rec)  # summary.json takes it as is

    def test_snapshot_of_a_dead_app(self):
        self.assertEqual(diag.snapshot(FakeGuest({}, pid=None), "/x"), {"error": "the app is not running"})


class VmShArguments(unittest.TestCase):
    """vm.sh refuses a bad --diag before it needs tart (TART_BIN=/nonexistent stops it right after)."""

    def run_vm(self, *args: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as t:
            build = os.path.join(t, "build.zip")
            open(build, "w").close()
            env = {**os.environ, "TART_BIN": "/nonexistent", "FUZZ_WORK": os.path.join(t, "work")}
            return subprocess.run(["bash", os.path.join(HERE, "vm.sh"), *args, build], env=env,
                                  capture_output=True, text=True, timeout=60)

    def test_unknown_diag_is_refused(self):
        r = self.run_vm("--diag", "bogus")
        self.assertEqual(r.returncode, 2)
        self.assertIn("usage: diag.py info NAME", r.stderr)

    def test_diag_needs_fuzz_or_repro(self):
        r = self.run_vm("--suite", "smoke", "--diag", "gmalloc")
        self.assertEqual(r.returncode, 2)
        self.assertIn("--diag needs --suite fuzz or repro", r.stderr)

    def test_known_diag_gets_past_argument_checks(self):
        r = self.run_vm("--diag", "asan")
        self.assertEqual(r.returncode, 2)
        self.assertIn("no tart binary", r.stderr)


if __name__ == "__main__":
    unittest.main()
