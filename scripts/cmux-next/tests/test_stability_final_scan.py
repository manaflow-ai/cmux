#!/usr/bin/env python3
"""stability_final_scan.py (p10-stability-151): the per-item scans behind stability-final.sh's rows.

    python3 -I -m unittest scripts/cmux-next/tests/test_stability_final_scan.py
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import stability_final_scan as scan  # noqa: E402


class FfiExportTests(unittest.TestCase):
    def test_guarded_nopanic_and_unguarded_exports(self):
        source = '''
#[unsafe(no_mangle)]
pub extern "C" fn guarded() -> u32 {
    ffi_boundary("guarded", 0, || 1)
}
#[unsafe(no_mangle)]
pub extern "C" fn constant() -> u32 {
    // ffi-nopanic: returns a constant.
    7
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn bare(ptr: *const u8, len: usize) -> usize {
    len
}
type Callback = extern "C" fn(u32);
'''
        self.assertEqual(scan.unguarded_exports(source), ["bare"])

    def test_a_guard_in_a_helper_does_not_hide_an_export(self):
        source = '''
fn helper() -> u32 { ffi_boundary("helper", 0, || 1) }
pub extern "C" fn bare() -> u32 { 2 }
'''
        self.assertEqual(scan.unguarded_exports(source), ["bare"])

    def test_test_modules_are_left_out(self):
        source = '''
pub extern "C" fn real() -> u32 { ffi_boundary("real", 0, || 1) }
#[cfg(test)]
mod tests {
    extern "C" fn callback() -> u32 { 3 }
}
'''
        self.assertEqual(scan.unguarded_exports(source), [])

    def test_declarations_are_not_exports(self):
        self.assertEqual(scan.unguarded_exports('extern "C" fn declared(x: u32);\nfn later() { }\n'), [])


class UnsafeImplTests(unittest.TestCase):
    def test_safety_and_test_reference_needed(self):
        source = '''
// SAFETY: one owner thread at a time (test: ring::tests::moves_between_threads).
unsafe impl Send for Ring {}
// SAFETY: as for Send.
unsafe impl Sync for Ring {}

// SAFETY: one encoder instance per thread.
unsafe impl Send for Encoder {}

// The job handle is used only through its own calls.
unsafe impl Send for Job {}
'''
        self.assertEqual(scan.undocumented_impls(source), [8, 11])


class SuperviseTests(unittest.TestCase):
    def test_policy_and_shutdown_named_or_typed_parameters(self):
        source = '''
fn spawn(name: &str, policy: Fatal, shutdown: ShutdownBehavior) {
    supervisor.supervise_thread(name, policy, shutdown, move |_stop| work());
}
fn direct() {
    supervisor.supervise_task("a", Fatal, ShutdownBehavior::Continue, |_| async {});
    supervisor.supervise_thread_restarting("b", Restart::state_private(), ShutdownBehavior::Block, |_| ());
    supervisor.supervise_task("c", Fatal, behavior, |_| async {});
}
pub fn supervise_thread<F>(&self, name: String, policy: Fatal, shutdown: ShutdownBehavior, body: F) {}
'''
        self.assertEqual(scan.unnamed_supervise_calls(source), [8])


class ForbidUnsafeTests(unittest.TestCase):
    def test_unsafe_code_forms(self):
        self.assertTrue(scan.uses_unsafe(["fn f() { unsafe { g() } }"]))
        self.assertTrue(scan.uses_unsafe(["#[unsafe(no_mangle)]\npub extern \"C\" fn f() {}"]))
        self.assertFalse(scan.uses_unsafe(["#![forbid(unsafe_code)]\n// unsafe { in a comment }\nfn f() {}"]))


class ArtifactTests(unittest.TestCase):
    def write_jsonl(self, path: Path, rows: list[dict]) -> None:
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def full_runs(self) -> list[dict]:
        rows = [{"tool": mode, "crate": crate, "os": os_name, "result": "pass", "findings": 0}
                for os_name, crates in scan.SANITIZER_CRATES.items() for mode in scan.SANITIZER_MODES
                for crate in crates]
        return rows + [{"tool": "miri", "crate": crate, "os": "linux", "result": "pass", "findings": 0}
                       for crate in scan.MIRI_CRATES]

    def test_rust_sanitize_needs_every_run_green(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            self.assertIsNone(scan.rust_sanitize(folder))
            runs = self.full_runs()
            self.write_jsonl(directory / "runs-linux.jsonl", runs)
            (directory / "findings-linux.jsonl").write_text("", encoding="utf-8")
            self.assertEqual(scan.rust_sanitize(folder), [])
            red = [dict(row, result="failed") if row["tool"] == "miri" and row["crate"] == "cmux-rd-proto" else row
                   for row in runs if not (row["os"] == "macos" and row["tool"] == "leak")]
            self.write_jsonl(directory / "runs-linux.jsonl", red)
            self.assertEqual(len(scan.rust_sanitize(folder)), 3)  # 2 macOS leak runs missing, 1 Miri run red

    def test_stability_sig_counts_old_issues_without_an_open_pr(self):
        now = dt.datetime.now(dt.timezone.utc)
        old = (now - dt.timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%SZ")
        new = (now - dt.timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        with tempfile.TemporaryDirectory() as folder:
            issues, prs = Path(folder, "issues.json"), Path(folder, "prs.json")
            issues.write_text(json.dumps([{"number": 10, "createdAt": old}, {"number": 11, "createdAt": old},
                                          {"number": 12, "createdAt": new}, {"number": 13, "createdAt": old}]))
            prs.write_text(json.dumps([{"number": 99, "title": "fix", "body": "Fixes #10", "baseRefName": "feat-cmux-next"},
                                       {"number": 98, "title": "unrelated #110", "body": None, "baseRefName": "main"}]))
            self.assertEqual(scan.stability_sig(str(issues), str(prs), "13"), ["#11"])
            issues.write_text(json.dumps([{"number": n, "createdAt": old} for n in range(scan.LIST_LIMIT)]))
            self.assertEqual(scan.stability_sig(str(issues), str(prs), ""), "truncated")
            self.assertEqual(scan.stability_sig(str(Path(folder, "none.json")), str(prs), ""), "missing")


if __name__ == "__main__":
    unittest.main()
