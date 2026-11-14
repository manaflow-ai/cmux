#!/usr/bin/env python3
"""The port-drift ratchet (scripts/cmux-next/ffi_caller_ratchet.py) and its pre-push layer, on throwaway git repos.

The checker: a function declared in cmux-tui/crates/*/include/*.h counts as called only from a non-test Swift file
under Packages/, outside comments (a string literal counts: dlsym). Typedefs, function-pointer fields, macros and
the extern "C" wrapper are not exports. A new uncalled export fails by name, and so does one that loses its last
caller; a baseline line whose function gained a caller fails until --update drops it; --update never adds a line;
--rev reads the commit, not the working tree. On this checkout the baseline matches the measured count. An export
the app's pinned library (app-ffi-pin.json's cmux-app-ffi-<sha> source) lacks is a note, not a finding, until the
pin has it; a pin that cannot be read (no file, no tag, a sha git cannot read, no git repo) judges as before.

The layer (prepush-gate.py port_drift): refuses a push that adds an uncalled export, does not blame a push for the
base's own debt, and skips a push whose Swift lines name no cmux_/acpmux_ function. A push adding an export the pin
lacks is not refused; one whose pinned source has it is. A push that only re-pins is not judged; one that re-pins
and adds a caller for one of two awaited exports is refused for the other.

Not a CI job (Lawrence 2026-10-23: no new CI gates): run it yourself after a change to the ratchet:
  python3 -I scripts/cmux-next/tests/test_ffi_caller_ratchet.py
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

# tests/git_fixture_env.py turns off git's background maintenance in temp repos.
_git_fixture_env = importlib.util.spec_from_file_location(
    "git_fixture_env",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "tests", "git_fixture_env.py"),
)
git_fixture_env = importlib.util.module_from_spec(_git_fixture_env)
_git_fixture_env.loader.exec_module(git_fixture_env)

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/cmux-next/ffi_caller_ratchet.py"
GATE = ROOT / "scripts/cmux-next/prepush-gate.py"
HEADER = "cmux-tui/crates/cmux-demo/include/cmux_demo.h"
SWIFT = "Packages/macOS/CmuxNext/Sources/CmuxNextDemo/Demo.swift"
TEST_SWIFT = "Packages/macOS/CmuxNext/Tests/CmuxNextDemoTests/DemoTests.swift"
BASELINE = "scripts/cmux-next/ffi-caller-baseline.txt"
PIN = "Packages/macOS/CmuxNext/app-ffi-pin.json"

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

NEW_EXPORT_HEADER = HEADER_TEXT.replace("void cmux_demo_uncalled",
                                       "int32_t cmux_demo_new(void);\nvoid cmux_demo_uncalled")

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
        self.env = git_fixture_env.fixture_env({k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
        git_fixture_env.init_repo(self.dir, "-b", "main", env=self.env)
        self.git("config", "user.name", "t")
        self.git("config", "user.email", "t@example.com")
        self.write("scripts/cmux-next/ffi_caller_ratchet.py", SCRIPT.read_text())
        self.write(HEADER, HEADER_TEXT)
        self.write(SWIFT, SWIFT_TEXT)
        self.write(TEST_SWIFT, TEST_SWIFT_TEXT)
        self.write(BASELINE, BASELINE_TEXT)

    def git(self, *args: str) -> str:
        return subprocess.run(["git", "-C", str(self.dir), *args], check=True, capture_output=True, text=True,
                              env=self.env).stdout.strip()

    def write(self, path: str, text: str) -> None:
        file = self.dir / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def commit(self, message: str = "c") -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)
        return self.git("rev-parse", "HEAD")

    def pin(self, sha: str, *, url: str | None = None) -> None:
        """Pin the app to the cmux-app-ffi release built from sha (or write this url as is)."""
        url = url or (f"https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-{sha}/"
                      "CCmuxAppFFI.xcframework.zip")
        self.write(PIN, json.dumps({"url": url, "checksum": "0" * 64}))

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

    def test_an_export_the_pinned_library_lacks_is_a_note_not_drift(self) -> None:
        self.fx.pin(self.fx.commit("pinned source"))
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        code, out = self.fx.check()
        self.assertEqual(code, 0, out)
        notes = [line for line in out.splitlines() if line.startswith("ffi-caller-ratchet-note: ")]
        self.assertEqual(len(notes), 1, out)
        self.assertIn(f"cmux_demo_new ({HEADER}) is not exported by the pinned app library (cmux-app-ffi-", notes[0])
        self.assertIn("needs its Swift caller (step B)", notes[0])
        self.assertIn("ffi-caller-ratchet: ok: 6 exported functions, 4 with no Swift caller: 3 in the baseline, 1"
                      " awaiting the pin", out)
        self.assertNotIn("is exported in", out)
        code, out = self.fx.check("--report")
        self.assertEqual(code, 0, out)
        self.assertIn("4 have none; 1 of those are not in the pinned app library yet", out)

    def test_once_the_pin_has_the_export_it_is_drift(self) -> None:
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        self.fx.pin(self.fx.commit("source with the export"))
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn(f"ffi-caller-ratchet: cmux_demo_new is exported in {HEADER} and no Swift outside a test target"
                      " calls it (port drift)", out)
        self.assertNotIn("ffi-caller-ratchet-note: ", out)

    def test_a_pin_that_cannot_be_read_judges_as_before(self) -> None:
        cases = {
            "missing": (None, f"{PIN} is missing"),
            "no tag": ("https://example.com/CCmuxAppFFI.xcframework.zip", f"the url in {PIN} names no cmux-app-ffi-"),
            "unreadable sha": ("https://example.com/cmux-app-ffi-" + "ab" * 20 + "/x.zip",
                               "git cannot read the pinned source of cmux-app-ffi-" + "ab" * 20),
        }
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        for case, (url, why) in cases.items():
            with self.subTest(case):
                (self.fx.dir / PIN).unlink(missing_ok=True)
                if url is not None:
                    self.fx.pin("", url=url)
                code, out = self.fx.check()
                self.assertEqual(code, 1, out)
                self.assertIn("ffi-caller-ratchet: cmux_demo_new is exported in", out)
                self.assertIn(f"ffi-caller-ratchet-note: {why}", out)
                self.assertIn("judged without the pin", out)

    def test_a_repo_that_is_no_git_repo_judges_as_before(self) -> None:
        self.fx.pin(self.fx.commit("pinned source"))
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        shutil.rmtree(self.fx.dir / ".git")
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn("ffi-caller-ratchet: cmux_demo_new is exported in", out)
        self.assertIn("ffi-caller-ratchet-note: git cannot read the pinned source", out)

    def test_no_note_when_nothing_new_is_judged(self) -> None:
        code, out = self.fx.check()  # no pin file, but every uncalled export is listed
        self.assertEqual(code, 0, out)
        self.assertNotIn("ffi-caller-ratchet-note: ", out)

    def test_baseline_and_update_keep_their_rules_with_a_pin(self) -> None:
        self.fx.pin(self.fx.commit("pinned source"))
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        before = (self.fx.dir / BASELINE).read_text()
        code, out = self.fx.check("--update")
        self.assertEqual(code, 0, out)
        self.assertIn("baseline 3 -> 3 entries", out)
        self.assertNotIn("cmux_demo_new", (self.fx.dir / BASELINE).read_text())
        # A listed function that gains a caller still has to leave, and --update still never adds a line.
        self.fx.write(SWIFT, SWIFT_TEXT.replace("cmux_demo_called()", "cmux_demo_uncalled(nil)"))
        code, out = self.fx.check()
        self.assertEqual(code, 1, out)
        self.assertIn("cmux_demo_uncalled", out)
        self.assertIn("now has a Swift caller", out)
        self.assertIn("cmux_demo_called is exported", out)  # in the pinned source, so drift
        code, out = self.fx.check("--update")
        self.assertEqual(code, 1, out)
        self.assertIn("--update never adds it", out)
        baseline = (self.fx.dir / BASELINE).read_text()
        self.assertNotIn("cmux_demo_uncalled", baseline)
        self.assertNotIn("cmux_demo_called", baseline)
        self.assertNotIn("cmux_demo_new", baseline)
        self.assertNotEqual(before, baseline)

    def assert_report_matches_baseline(self, code: int, out: str, listed: int) -> None:
        """--report's uncalled count is the baseline plus the exports the pin lacks (a step A header on base). A
        checkout that cannot read the pinned source (a shallow one) cannot judge, so the test skips; a pinned,
        uncalled, unlisted export (after the re-pin, before step B) is true drift and fails by name."""
        note = next((line for line in out.splitlines() if "judged without the pin" in line), None)
        if note:
            self.skipTest(note)
        self.assertEqual(code, 0, out)
        match = re.search(r"; (\d+) have none; (\d+) of those are not in the pinned app library yet", out)
        self.assertIsNotNone(match, out)
        self.assertEqual(int(match.group(1)), listed + int(match.group(2)), out)

    def test_this_checkout_matches_its_baseline(self) -> None:
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "--report"], capture_output=True, text=True)
        listed = [line for line in (ROOT / BASELINE).read_text().splitlines() if line and not line.startswith("#")]
        self.assert_report_matches_baseline(result.returncode, result.stdout + result.stderr, len(listed))

    def test_the_baseline_match_holds_with_a_step_a_header_and_skips_without_the_pin(self) -> None:
        self.fx.pin(self.fx.commit("pinned source"))
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        self.assert_report_matches_baseline(*self.fx.check("--report"), 3)  # 4 have none = 3 listed + 1 awaiting
        (self.fx.dir / PIN).unlink()
        with self.assertRaises(unittest.SkipTest):
            self.assert_report_matches_baseline(*self.fx.check("--report"), 3)


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

    def test_a_comment_wrapping_the_last_caller_is_judged(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT.replace("let url", "/*\nlet url").replace('let symbol', '*/\nlet symbol'))
        found = self.drift(self.fx.commit("comment out the caller"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("cmux_demo_called", found[0])

    def test_drift_already_on_the_integration_branch_is_not_a_merges(self) -> None:
        # Upstream lost cmux_demo_called's caller (a base red); a branch merges it in with an unrelated header edit.
        self.fx.write(SWIFT, SWIFT_TEXT.replace("cmux_demo_called()", "0"))
        tip = self.fx.commit("upstream drift")
        self.fx.git("update-ref", "refs/remotes/origin/feat-cmux-next", tip)
        self.fx.write(HEADER, HEADER_TEXT + "/* cmux_demo_note */\n")
        head = self.fx.commit("branch work on top")
        self.assertEqual(self.drift(head), [])
        # Without the tip ref the same push is refused for it.
        self.fx.git("update-ref", "-d", "refs/remotes/origin/feat-cmux-next")
        self.assertEqual(len(self.drift(head)), 1)

    def test_a_push_adding_an_export_the_pin_lacks_is_not_refused(self) -> None:
        self.fx.pin(self.base)
        self.base = self.fx.commit("pin the app to the base")
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        self.assertEqual(self.drift(self.fx.commit("step A: a new export")), [])

    def test_a_push_whose_pinned_source_has_the_export_is_refused(self) -> None:
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        source = self.fx.commit("the export, published")
        self.fx.write(HEADER, HEADER_TEXT)
        self.fx.pin(source)
        self.base = self.fx.commit("base pinned to it")
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        found = self.drift(self.fx.commit("the export, no caller"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("cmux_demo_new is exported", found[0])

    def test_a_repin_alone_is_not_refused(self) -> None:
        # The export was step A's and its caller is step B's: a re-pin (the bot's, or by hand) cannot add it.
        self.fx.pin(self.base)
        self.fx.write(HEADER, NEW_EXPORT_HEADER)
        self.base = self.fx.commit("step A merged, pin still old")
        self.fx.pin(self.base)
        self.assertEqual(self.drift(self.fx.commit("re-pin only")), [])

    def test_a_repin_with_a_caller_for_one_of_two_awaited_exports_is_refused_for_the_other(self) -> None:
        self.fx.pin(self.base)
        self.fx.write(HEADER, NEW_EXPORT_HEADER.replace("int32_t cmux_demo_new(void);",
                                                        "int32_t cmux_demo_new(void);\nint32_t cmux_demo_other(void);"))
        self.base = self.fx.commit("step A merged with two exports, pin still old")
        self.fx.pin(self.base)
        self.fx.write(SWIFT, SWIFT_TEXT + "let n = cmux_demo_new()\n")
        found = self.drift(self.fx.commit("re-pin and step B for one of them"))
        self.assertEqual(len(found), 1, found)
        self.assertIn("cmux_demo_other is exported", found[0])

    def test_a_swift_push_naming_no_ffi_function_skips_the_check(self) -> None:
        self.fx.write(SWIFT, SWIFT_TEXT + "let plain = 1\n")
        head = self.fx.commit("plain swift")
        self.gate.run = lambda *a, **k: self.fail("the checker ran for a push it cannot affect")
        self.assertEqual(self.drift(head), [])


if __name__ == "__main__":
    unittest.main()
