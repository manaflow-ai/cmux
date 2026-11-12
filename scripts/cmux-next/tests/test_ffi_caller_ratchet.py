#!/usr/bin/env python3
"""The port-drift ratchet (scripts/cmux-next/ffi_caller_ratchet.py) and its pre-push layer, on throwaway git repos.

The checker: a function declared in cmux-tui/crates/*/include/*.h counts as called only from a non-test Swift file
under Packages/, outside comments (a string literal counts: dlsym). Typedefs, function-pointer fields, macros and
the extern "C" wrapper are not exports. A new uncalled export fails by name, and so does one that loses its last
caller; a baseline line whose function gained a caller fails until --update drops it; --update never adds a line;
--rev reads the commit, not the working tree. On this checkout the baseline matches the measured count.

The layer (prepush-gate.py port_drift): refuses a push that adds an uncalled export, does not blame a push for the
base's own debt, and skips a push whose Swift lines name no cmux_/acpmux_ function.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_ffi_caller_ratchet.py
"""
from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/ffi_caller_ratchet.py"
GATE = ROOT / "scripts/cmux-next/prepush-gate.py"
HEADER = "cmux-tui/crates/cmux-demo/include/cmux_demo.h"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextDemo/Demo.swift"
TEST_SWIFT = "Packages/macOS/CmuxNext/Tests/CmuxNextDemoTests/DemoTests.swift"
BASELINE = "scripts/cmux-next/ffi-caller-baseline.txt"

HEADER_TEXT = textwrap.dedent("""\
    /* cmux_in_a_comment(void) is not an export. */
    #ifndef CMUX_DEMO_H
    #define CMUX_DEMO_H
    #define CMUX_DEMO_MACRO(x) ((x) + 1)
    #ifdef __cplusplus
    extern "C" {
    #endif
    typedef void (*CmuxDemoCallback)(void *context);
    typedef struct CmuxDemoThing {
      int32_t (*cmux_field_pointer)(int32_t value);
      uint32_t len;
    } CmuxDemoThing;
    uint32_t cmux_demo_called(void);
    bool cmux_demo_by_name(const uint8_t *bytes,
                           size_t len);
    void cmux_demo_comment_only(void);
    void cmux_demo_test_only(void);
    void cmux_demo_uncalled(CmuxDemoThing *thing);
    #ifdef __cplusplus
    }
    #endif
    #endif
    """)

SWIFT_TEXT = textwrap.dedent("""\
    import Foundation
    // cmux_demo_comment_only() would be called here.
    /* cmux_demo_comment_only() */
    let url = "https://example.com" ; let v = cmux_demo_called()
    let symbol = dlsym(handle, "cmux_demo_by_name")
    """)

TEST_SWIFT_TEXT = "func testIt() { cmux_demo_test_only() }\n"

BASELINE_TEXT = (f"{HEADER}\tcmux_demo_comment_only\n{HEADER}\tcmux_demo_test_only\n{HEADER}\tcmux_demo_uncalled\n")


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Fixture:
    def __init__(self) -> None:
        self.dir = Path(tempfile.mkdtemp(prefix="ffi-caller-ratchet-test-"))
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "maintenance.auto", "false")
        self.git("config", "gc.auto", "0")
        self.write("scripts/cmux-next/ffi_caller_ratchet.py", SCRIPT.read_text())
        self.write(HEADER, HEADER_TEXT)
        self.write(SWIFT, SWIFT_TEXT)
        self.write(TEST_SWIFT, TEST_SWIFT_TEXT)
        self.write(BASELINE, BASELINE_TEXT)

    def git(self, *args: str) -> str:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["git", "-C", str(self.dir), *args], check=True, capture_output=True, text=True,
                              env=env).stdout.strip()

    def write(self, path: str, text: str) -> None:
        file = self.dir / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, message: str = "c") -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def check(self, *args: str) -> tuple[int, str]:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--repo", str(self.dir), *args],
                                capture_output=True, text=True)
        return result.returncode, result.stdout + result.stderr

    def cleanup(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)


class CheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()
        self.addCleanup(self.fx.cleanup)

    def test_parses_only_the_exported_functions(self) -> None:
        module = load("ffi_caller_ratchet_under_test", SCRIPT)
        self.assertEqual(module.header_functions(HEADER_TEXT),
                         ["cmux_demo_called", "cmux_demo_by_name", "cmux_demo_comment_only", "cmux_demo_test_only",
                          "cmux_demo_uncalled"])

    def test_baseline_matching_the_tree_passes(self) -> None:
        code, out = self.fx.check("--report")
        self.assertEqual(code, 0, out)
        self.assertIn("2 of 5 exported functions have a Swift caller; 3 have none", out)

    def test_comment_and_test_target_mentions_are_not_callers(self) -> None:
        self.fx.write(BASELINE, f"{HEADER}\tcmux_demo_uncalled\n")
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn("cmux_demo_comment_only is exported", out)
        self.assertIn("cmux_demo_test_only is exported", out)

    def test_a_new_uncalled_export_fails_by_name_with_the_fix(self) -> None:
        self.fx.write(HEADER, HEADER_TEXT.replace("void cmux_demo_uncalled", "int32_t cmux_demo_new(void);\nvoid "
                                                  "cmux_demo_uncalled"))
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"cmux_demo_new is exported in {HEADER} and no Swift outside a test target calls it", out)
        self.assertIn("step B", out)
        self.assertEqual(out.count("is exported in"), 1, out)

    def test_losing_the_last_caller_fails(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT.replace("cmux_demo_called()", "0"))
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn("cmux_demo_called is exported", out)

    def test_a_listed_function_that_gains_a_caller_must_leave_the_baseline(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT + "cmux_demo_uncalled(nil)\n")
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn("cmux_demo_uncalled", out)
        self.assertIn("now has a Swift caller", out)
        code, out = self.fx.check("--update")
        self.assertEqual(code, 0, out)
        self.assertIn("baseline 3 -> 2 entries", out)
        self.assertNotIn("cmux_demo_uncalled", (self.fx.dir / BASELINE).read_text())
        self.assertEqual(self.fx.check()[0], 0)

    def test_update_never_adds_a_line(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT.replace("cmux_demo_called()", "0"))
        code, out = self.fx.check("--update")
        self.assertEqual(code, 1, out)
        self.assertIn("--update never adds it", out)
        self.assertNotIn("cmux_demo_called", (self.fx.dir / BASELINE).read_text())

    def test_rev_reads_the_commit_not_the_working_tree(self) -> None:
        good = self.fx.commit()
        self.fx.write(SWIFT, "")
        self.assertEqual(self.fx.check()[0], 1)
        code, out = self.fx.check("--rev", good)
        self.assertEqual(code, 0, out)

    def test_this_checkout_matches_its_baseline(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--report"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        listed = [line for line in (ROOT / BASELINE).read_text().splitlines() if line and not line.startswith("#")]
        self.assertIn(f"; {len(listed)} have none", result.stdout)


class GateLayerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fx = Fixture()
        self.addCleanup(self.fx.cleanup)
        self.gate = load("cmux_next_prepush_gate_under_test", GATE)
        self.base = self.fx.commit("base")

    def drift(self, head: str) -> list[str]:
        return self.gate.port_drift(self.fx.dir, self.base, head)

    def test_a_push_that_adds_an_uncalled_export_is_refused(self) -> None:
        self.fx.write(HEADER, HEADER_TEXT.replace("void cmux_demo_uncalled", "int32_t cmux_demo_new(void);\nvoid "
                                                  "cmux_demo_uncalled"))
        found = self.drift(self.fx.commit("add an export"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("cmux_demo_new is exported", found[0])

    def test_a_push_that_removes_the_last_caller_is_refused(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT.replace("cmux_demo_called()", "0"))
        found = self.drift(self.fx.commit("drop the caller"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("cmux_demo_called", found[0])

    def test_the_bases_own_debt_is_not_the_pushs(self) -> None:
        self.fx.write(BASELINE, "")  # the base already fails: three uncalled exports, none listed
        self.base = self.fx.commit("base with debt")
        self.fx.write(HEADER, HEADER_TEXT + "/* cmux_demo_called */\n")
        self.assertEqual(self.drift(self.fx.commit("touch the header")), [])

    def test_a_swift_push_naming_no_ffi_function_skips_the_check(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT + "let plain = 1\n")
        head = self.fx.commit("plain swift")
        self.gate.run = lambda *a, **k: self.fail("the checker ran for a push it cannot affect")
        self.assertEqual(self.drift(head), [])


if __name__ == "__main__":
    unittest.main()
