#!/usr/bin/env python3
"""Offline checks of unit.py (no VM, no cargo, no Xcode): the row table, the verdicts, the guest command, and
one `run` against a fake guest (an `ssh` on PATH that runs the command here, with its own HOME).

Run: python3 -I scripts/fuzz/macos-matrix/test_unit.py
"""

from __future__ import annotations

import io
import json
import os
import shlex
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import unit  # noqa: E402


class RowsTests(unittest.TestCase):
    def test_all_rows_in_table_order(self):
        self.assertEqual(unit.parse_rows("all"), list(unit.ROWS))
        self.assertEqual(unit.parse_rows(""), list(unit.ROWS))
        self.assertEqual(unit.parse_rows("pi_mutex,fds"), ["fds", "pi_mutex"])

    def test_unknown_or_repeated_rows_are_refused(self):
        for bad in ("fds,nope", "fds,fds", "FDS", "fds,"):
            with self.assertRaises(ValueError, msg=bad):
                unit.parse_rows(bad)

    def test_the_task_rows_cover_ring_fds_qos_pi_mutex_and_the_swift_ring(self):
        self.assertEqual(set(unit.ROWS), {"output_ring", "fds", "qos", "pi_mutex", "shared_output_ring"})
        swift = [p for parts in unit.ROWS.values() for p in parts if isinstance(p, unit.Swift)]
        self.assertEqual([(p.target, p.filter) for p in swift], [("CmuxNextIPCTests", "SharedOutputRingTests")])

    def test_worst_verdict(self):
        self.assertEqual(unit.worst(["PASS", "PASS"]), "PASS")
        self.assertEqual(unit.worst(["PASS", "NO-VERDICT"]), "NO-VERDICT")
        self.assertEqual(unit.worst(["NO-VERDICT", "FAIL", "PASS"]), "FAIL")
        self.assertEqual(unit.worst([]), "NO-VERDICT")

    def test_check_rows_and_build_refusals(self):
        with redirect_stderr(io.StringIO()):
            self.assertEqual(unit.main(["check-rows", "fds,qos"]), 0)
            self.assertEqual(unit.main(["check-rows", "fds,bogus"]), 2)
            with mock.patch.dict(os.environ, {"CMUX_CI_STEP_KEY": ""}):
                self.assertEqual(unit.main(["build", "--repo", ".", "--out", "/nonexistent/x"]), 2)


class CargoJsonTests(unittest.TestCase):
    def test_only_test_executables_once_each(self):
        lines = [
            {"reason": "compiler-artifact", "profile": {"test": False}, "executable": None},
            {"reason": "compiler-artifact", "profile": {"test": True}, "executable": "/t/debug/deps/cmux_ipc-1"},
            {"reason": "compiler-message", "message": {}},
            {"reason": "compiler-artifact", "profile": {"test": True}, "executable": "/t/debug/deps/fds-2"},
            {"reason": "compiler-artifact", "profile": {"test": True}, "executable": "/t/debug/deps/fds-2"},
            {"reason": "build-finished", "success": True},
        ]
        text = "\n".join(json.dumps(x) for x in lines) + "\nnot json\n"
        self.assertEqual(unit.test_executables(text), ["/t/debug/deps/cmux_ipc-1", "/t/debug/deps/fds-2"])


class BuilderCargoTests(unittest.TestCase):
    """Builder.cargo with a fake `cargo` on the toolchain PATH (rust() already resolved)."""

    def builder(self, cargo_script: str) -> unit.Builder:
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (tmp / "repo" / "cmux-tui").mkdir(parents=True)
        fake = tmp / "fake"
        fake.mkdir()
        (fake / "cargo").write_text("#!/bin/sh\n" + cargo_script)
        (fake / "cargo").chmod(0o755)
        self.exe = tmp / "fds-2"
        self.exe.write_text("test binary")
        b = unit.Builder(tmp / "repo", tmp / "out")
        b.cargo_env = dict(os.environ, PATH="%s:%s" % (fake, os.environ.get("PATH", "")))
        return b

    def test_each_test_binary_is_copied_once_and_run_with_the_row_filters(self):
        artifact = json.dumps({"reason": "compiler-artifact", "profile": {"test": True}, "executable": "EXE"})
        b = self.builder("echo '%s' | sed \"s|EXE|$FDS_EXE|\"\n" % artifact)
        b.cargo_env["FDS_EXE"] = str(self.exe)
        part = unit.Cargo("cmux-ipc", ("--test", "fds"), ("cmux_ipc_fds",))
        first = b.cargo("fds", 0, part)
        second = b.cargo("fds", 1, part)
        self.assertEqual(first, [{"kind": "rust", "label": "cmux-ipc fds-2", "path": "rust/fds-2",
                                  "args": ["cmux_ipc_fds"]}])
        self.assertEqual(second[0]["path"], "rust/fds-2")
        self.assertEqual((b.bin / "rust" / "fds-2").read_text(), "test binary")
        self.assertEqual(os.listdir(b.bin / "rust"), ["fds-2"])

    def test_a_failed_build_is_the_part_error(self):
        b = self.builder("echo 'error[E0425]' >&2\nexit 101\n")
        parts = b.cargo("pi_mutex", 0, unit.Cargo("cmux-tui-platform", ("--lib",), ("pi_mutex",)))
        self.assertEqual(len(parts), 1)
        self.assertIn("cargo test --no-run exit 101, 0 test binaries", parts[0]["error"])
        self.assertIn("error[E0425]", (b.logs / "pi_mutex-0-cargo.log").read_text())


RUST_OK ="running 3 tests\ntest a ... ok\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 9 filtered out\n"
RUST_FAIL = "running 2 tests\ntest result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out\n"
RUST_NONE = "running 0 tests\ntest result: ok. 0 passed; 0 failed; 0 ignored; 0 measured; 12 filtered out\n"
SWIFT_OK = "◇ Test run started.\n✔ Test run with 6 tests in 1 suite passed after 0.012 seconds.\n"
SWIFT_FAIL = "◇ Test run started.\n✘ Test run with 6 tests in 1 suite failed after 0.012 seconds with 1 issue.\n"


class JudgeTests(unittest.TestCase):
    def test_rust(self):
        self.assertEqual(unit.judge("rust", 0, RUST_OK)[:3], ("PASS", 3, 0))
        self.assertEqual(unit.judge("rust", 101, RUST_FAIL)[:3], ("FAIL", 1, 1))
        self.assertEqual(unit.judge("rust", 0, RUST_NONE)[0], "NO-VERDICT")
        # A test that kills its process (SIGSEGV in a mapping) fails the row; a binary that never ran does not.
        self.assertEqual(unit.judge("rust", 139, "running 4 tests\n")[0], "FAIL")
        self.assertEqual(unit.judge("rust", 134, "dyld: Library not loaded\n")[0], "NO-VERDICT")
        self.assertEqual(unit.judge("rust", 124, "running 4 tests\n")[0], "NO-VERDICT")
        self.assertEqual(unit.judge("rust", 255, "")[0], "NO-VERDICT")
        self.assertEqual(unit.judge("rust", 127, "")[0], "NO-VERDICT")

    def test_swift(self):
        self.assertEqual(unit.judge("swift", 0, SWIFT_OK)[:3], ("PASS", 6, 0))
        self.assertEqual(unit.judge("swift", 1, SWIFT_FAIL)[0], "FAIL")
        self.assertEqual(unit.judge("swift", 0, "✔ Test run with 0 tests passed after 0.001 seconds.\n")[0],
                         "NO-VERDICT")
        # The copied runtime did not load on this macOS: no verdict, never a FAIL.
        verdict, _, _, why = unit.judge("swift", 134, "dyld[812]: Symbol not found: _$s7Testing\n")
        self.assertEqual(verdict, "NO-VERDICT")
        self.assertIn("runtime", why)
        self.assertEqual(unit.judge("swift", 134, "◇ Test run started.\n")[0], "FAIL")


class GuestCommandTests(unittest.TestCase):
    def test_rust_part_runs_its_binary_with_its_filters_under_the_bound(self):
        cmd = unit.guest_command({"kind": "rust", "path": "rust/fds-2", "args": ["cmux_ipc_fds"]})
        self.assertTrue(cmd.startswith('cd "$HOME/unit" || exit 3; '))
        argv = shlex.split(cmd.split("; ", 1)[1])
        self.assertEqual(argv[0:2], ["/usr/bin/perl", "-e"])
        self.assertEqual(argv[2], unit.GUEST_BOUND)
        self.assertEqual(argv[3:], [str(unit.PART_SECONDS), "./rust/fds-2", "cmux_ipc_fds"])

    def test_swift_part_runs_the_helper_with_the_copied_runtime(self):
        binary = "swift/debug/CmuxNextPackageTests.xctest/Contents/MacOS/CmuxNextPackageTests"
        cmd = unit.guest_command({"kind": "swift", "path": binary, "filter": "SharedOutputRingTests"})
        self.assertIn('DYLD_FRAMEWORK_PATH="$HOME/unit/swift/runtime/Frameworks:$HOME/unit/swift/runtime/'
                      'PrivateFrameworks"', cmd)
        self.assertIn('DYLD_LIBRARY_PATH="$HOME/unit/swift/runtime/lib"', cmd)
        argv = shlex.split(cmd.split("; ", 1)[1])
        perl = argv.index("/usr/bin/perl")
        self.assertEqual(argv[perl + 4:], ["./swift/runtime/swiftpm-testing-helper", "--test-bundle-path",
                                           "./" + binary, "--filter", "SharedOutputRingTests", "./" + binary,
                                           "--testing-library", "swift-testing"])


@unittest.skipUnless(os.path.exists("/usr/bin/perl"), "the guest bound needs /usr/bin/perl")
class FakeGuestRunTests(unittest.TestCase):
    """`run` over an `ssh` that runs the command locally with HOME set to a temporary guest home."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="unit-test-"))
        self.home, fake = self.tmp / "home", self.tmp / "fake-bin"
        self.home.mkdir()
        fake.mkdir()
        ssh = fake / "ssh"
        home = shlex.quote(str(self.home))
        ssh.write_text('#!/bin/sh\nfor last; do :; done\nHOME=%s exec /bin/sh -c "$last"\n' % home)
        ssh.chmod(ssh.stat().st_mode | stat.S_IXUSR)
        self.path = mock.patch.dict(os.environ, {"PATH": "%s:%s" % (fake, os.environ.get("PATH", ""))})
        self.path.start()
        self.bin = self.tmp / "bin"
        (self.bin / "rust").mkdir(parents=True)

    def tearDown(self):
        self.path.stop()

    def fake_binary(self, name: str, output: str, status: int) -> str:
        path = self.bin / "rust" / name
        path.write_text("#!/bin/sh\ncat <<'OUT'\n%sOUT\necho \"args: $*\"\nexit %d\n" % (output, status))
        path.chmod(0o755)
        return "rust/" + name

    def test_rows_are_judged_in_the_guest_and_recorded(self):
        manifest = {"runner_ref": "abc", "rows": {
            "fds": [{"kind": "rust", "label": "cmux-ipc fds", "path": self.fake_binary("fds", RUST_OK, 0),
                     "args": ["cmux_ipc_fds"]}],
            "qos": [{"kind": "rust", "label": "platform", "path": self.fake_binary("qos", RUST_OK, 0), "args": ["qos"]},
                    {"kind": "rust", "label": "core", "path": self.fake_binary("core", RUST_FAIL, 101),
                     "args": ["qos"]}],
            "shared_output_ring": [{"kind": "swift", "label": "CmuxNextIPCTests", "error": "no Xcode"}],
        }}
        (self.bin / "manifest.json").write_text(json.dumps(manifest))
        out = self.tmp / "out"
        with redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(unit.run("admin@guest", [], self.bin, out), 0)
        result = json.loads((out / "result.json").read_text())
        verdicts = {r["row"]: r["verdict"] for r in result["rows"]}
        self.assertEqual(verdicts, {"fds": "PASS", "qos": "FAIL", "shared_output_ring": "NO-VERDICT"})
        self.assertEqual(result["verdict"], "FAIL")
        self.assertFalse(result["ok"])
        self.assertEqual(result["failed_steps"], ["qos", "shared_output_ring"])
        self.assertIn("args: cmux_ipc_fds", (out / "fds-0.log").read_text())
        # The binaries ran from the guest's copy.
        self.assertTrue((self.home / "unit" / "rust" / "fds").is_file())
        lines = printed.getvalue().splitlines()
        self.assertTrue(lines[0].startswith("fds "), lines)
        self.assertTrue(lines[-1].startswith("UNIT VERDICT FAIL"), lines)

    def test_every_row_passing_is_a_pass(self):
        manifest = {"rows": {"pi_mutex": [{"kind": "rust", "label": "platform",
                                           "path": self.fake_binary("pi", RUST_OK, 0), "args": ["pi_mutex"]}]}}
        (self.bin / "manifest.json").write_text(json.dumps(manifest))
        with redirect_stdout(io.StringIO()):
            unit.run("admin@guest", [], self.bin, self.tmp / "out")
        result = json.loads((self.tmp / "out" / "result.json").read_text())
        self.assertEqual((result["verdict"], result["ok"], result["failed_steps"]), ("PASS", True, []))


class VmSummaryTests(unittest.TestCase):
    """vm.sh's per-major summary (its last `python3 -I -` heredoc) on unit runs."""

    def summarize(self, results: dict[str, dict], failures: dict[str, str] | None = None):
        with open(os.path.join(HERE, "vm.sh")) as f:
            text = f.read()
        start = text.index("\n", text.index('python3 -I - "$RUN" "$MAJORS"')) + 1
        source = text[start:text.index("\nPY\n", start)]
        run = self.enterContext(tempfile.TemporaryDirectory())
        for major, result in results.items():
            os.makedirs(os.path.join(run, major))
            with open(os.path.join(run, major, "result.json"), "w") as f:
                json.dump(result, f)
        for major, why in (failures or {}).items():
            os.makedirs(os.path.join(run, major), exist_ok=True)
            Path(run, major, "failure").write_text(why)
        for name in ("unit-build/logs/fds-0-cargo.log", "unit-build/bin/manifest.json",
                     "unit-build/bin/rust/fds-2", "unit-build/cargo-target/debug/deps/fds-2"):
            Path(run, name).parent.mkdir(parents=True, exist_ok=True)
            Path(run, name).write_text("x")
        archive = os.path.join(run, "results.tgz")
        done = subprocess.run([sys.executable, "-I", "-", run, ",".join(results or failures), "unit", archive, "",
                               HERE], input=source, capture_output=True, text=True, timeout=60)
        with tarfile.open(archive) as tar:
            names = tar.getnames()
        return done, names

    def result(self, osv: str, **verdicts: str) -> dict:
        rows = [{"row": row, "verdict": v, "parts": [{"label": "%s part" % row, "verdict": v,
                                                       "detail": "" if v == "PASS" else "why"}]}
                for row, v in verdicts.items()]
        verdict = unit.worst(list(verdicts.values()))
        return {"suite": "unit", "os": osv, "verdict": verdict, "ok": verdict == "PASS", "rows": rows,
                "failed_steps": [r for r, v in verdicts.items() if v != "PASS"]}

    def test_rows_pass_on_both_majors(self):
        done, names = self.summarize({"14": self.result("14.8.7", fds="PASS", qos="PASS"),
                                      "15": self.result("15.7.7", fds="PASS", qos="PASS")})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("MATRIX VERDICT PASS", done.stdout.splitlines())
        self.assertIn("14   14.8.7   unit  PASS", done.stdout)
        self.assertIn("       fds                  PASS", done.stdout.splitlines())  # one line per row
        # The logs and the manifest are results; the built tests are not.
        self.assertIn("unit-build/logs/fds-0-cargo.log", names)
        self.assertIn("unit-build/bin/manifest.json", names)
        self.assertFalse([n for n in names if n.startswith(("unit-build/cargo-target", "unit-build/bin/rust"))], names)

    def test_a_failed_row_fails_and_a_missing_result_has_no_verdict(self):
        done, _ = self.summarize({"14": self.result("14.8.7", fds="PASS", pi_mutex="FAIL")})
        self.assertIn("MATRIX VERDICT FAIL", done.stdout.splitlines(), done.stderr)
        self.assertIn("failed=pi_mutex", done.stdout)
        self.assertIn("       pi_mutex             FAIL       pi_mutex part: why", done.stdout.splitlines())
        done, _ = self.summarize({}, failures={"15": "unit.py build failed (unit-build.log)"})
        self.assertIn("MATRIX VERDICT NO-VERDICT", done.stdout.splitlines(), done.stderr)

    def test_a_pass_with_a_failure_file_is_no_verdict(self):
        done, _ = self.summarize({"14": self.result("14.8.7", fds="PASS")}, failures={"14": "unit exit 1"})
        self.assertIn("MATRIX VERDICT NO-VERDICT", done.stdout.splitlines(), done.stderr)


if __name__ == "__main__":
    unittest.main()
