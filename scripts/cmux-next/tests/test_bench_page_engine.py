#!/usr/bin/env python3
"""A measure says the engine of the page that it timed (decision 2026-11-16).

A tagged build embeds Chromium only when the engine's artifact is at hand. With none it warned in a build log that
no measure step prints, and the app showed each page in WebKit: a New Tab time of that app read as a time of the
default engine. These hold the three parts of the mend:

  - bench_page_engine.py: the engine's name from the app's answer, the rule for a row with another engine than the
    asked one (an error of the row, its times kept apart, never a number), and the lines that a bench prints;
  - scripts/measure/require-chromium.sh: an entry's build requires the engine unless `--allow-no-chromium`, and a
    build that failed for the engine says so in one line;
  - the wiring, by a read of the text: the two entries and the Cmd-T bench use them. No test here builds or
    launches an app.

Runs on any host (Linux included): no app, no fleet.

    python3 scripts/cmux-next/tests/test_bench_page_engine.py
"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
MEASURE = SCRIPTS.parent / "measure"
HELPER = MEASURE / "require-chromium.sh"
sys.path.insert(0, str(SCRIPTS))
import bench_page_engine as engine  # noqa: E402


def row(page_engine, **times):
    return {"command": "new_tab", "key_ms": 2.5, "visible_ms": 9.0, "ready_ms": 31.0, "page_engine": page_engine, **times}


class EngineNameTests(unittest.TestCase):
    def test_the_apps_answer_names_the_engine(self):
        self.assertEqual(engine.page_engine({"pane": "p1", "engine": "cef"}), "cef")
        self.assertEqual(engine.page_engine({"pane": "p1", "engine": "webkit:chromium-unavailable"}),
                         "webkit:chromium-unavailable")

    def test_an_answer_with_no_engine_is_unknown_with_its_reason(self):
        got = engine.page_engine({"error": "pane p1 shows no agent tab", "agent_panes": []})
        self.assertEqual(got, "unknown: pane p1 shows no agent tab")
        for reply in (None, {}, {"engine": ""}, {"engine": 7}, "cef"):
            self.assertTrue(engine.page_engine(reply).startswith("unknown: "), reply)

    def test_the_family_of_an_engine_name(self):
        self.assertEqual(engine.family("cef"), "cef")
        self.assertEqual(engine.family("webkit:chromium-unavailable"), "webkit")
        self.assertEqual(engine.family("webkit:own-host"), "webkit")
        self.assertIsNone(engine.family("unknown: no reply"))
        self.assertIsNone(engine.family(None))


class RowRuleTests(unittest.TestCase):
    def test_a_row_in_the_asked_engine_keeps_its_times(self):
        got = engine.judge(row("cef"), "cef")
        self.assertEqual((got["key_ms"], got["visible_ms"], got["ready_ms"]), (2.5, 9.0, 31.0))
        self.assertNotIn("error", got)
        self.assertNotIn("other_engine", got)

    def test_a_row_in_another_engine_is_an_error_and_its_times_are_kept_apart(self):
        got = engine.judge(row("webkit:chromium-unavailable", frames_to_visible=2), "cef")
        self.assertEqual(got["error"], "page engine webkit:chromium-unavailable, asked: cef")
        # No time stays where a summary reads it: the row counts as a missed run.
        for name in ("key_ms", "visible_ms", "ready_ms", "frames_to_visible"):
            self.assertIsNone(got.get(name), name)
        self.assertEqual(got["other_engine"], {"key_ms": 2.5, "visible_ms": 9.0, "ready_ms": 31.0, "frames_to_visible": 2})
        self.assertEqual(got["page_engine"], "webkit:chromium-unavailable")

    def test_a_measure_of_webkit_refuses_a_chromium_row(self):
        self.assertEqual(engine.judge(row("cef"), "webkit")["error"], "page engine cef, asked: webkit")
        self.assertNotIn("error", engine.judge(row("webkit:own-host"), "webkit"))

    def test_any_engine_judges_no_row(self):
        for name in ("cef", "webkit:chromium-unavailable", "unknown: no reply"):
            got = engine.judge(row(name), "any")
            self.assertNotIn("error", got)
            self.assertEqual(got["ready_ms"], 31.0)

    def test_a_ready_page_whose_engine_was_not_read_is_no_number(self):
        got = engine.judge(row("unknown: timed out"), "cef")
        self.assertEqual(got["error"], "page engine not read (unknown: timed out), asked: cef")
        self.assertIsNone(got.get("ready_ms"))

    def test_a_row_with_no_ready_page_and_no_engine_is_left_as_it_is(self):
        # Cmd-N that opened a terminal, or a page that never got ready: the row has no page time to refuse.
        got = engine.judge(row("unknown: pane p1 shows no agent tab", ready_ms=None), "cef")
        self.assertNotIn("error", got)
        self.assertEqual(got["visible_ms"], 9.0)

    def test_a_native_page_and_a_row_with_no_engine_field_are_not_judged(self):
        self.assertNotIn("error", engine.judge(row("native"), "cef"))
        plain = {"command": "split_right", "key_ms": 1.0, "visible_ms": 4.0}
        self.assertEqual(engine.judge(dict(plain), "cef"), plain)

    def test_an_error_that_the_row_had_is_kept_before_the_engines(self):
        got = engine.judge(row("webkit:own-host", error="late"), "cef")
        self.assertEqual(got["error"], "late; page engine webkit:own-host, asked: cef")


class LineTests(unittest.TestCase):
    def test_the_launch_line_says_the_apps_own_word_on_chromium(self):
        word = engine.chromium_word({"state": "ready", "default_engine": "chromium", "unavailable": None, "pump": {}})
        self.assertEqual(word, {"state": "ready", "unavailable": None, "browser_default_engine": "chromium"})
        self.assertEqual(engine.chromium_line("b", word),
                         "CHROMIUM b: the app says state=ready unavailable=no browser_default_engine=chromium")

    def test_the_launch_line_says_why_the_app_has_no_chromium(self):
        word = engine.chromium_word({"state": "idle", "default_engine": "chromium", "unavailable": "notBundled"})
        self.assertIn("unavailable=notBundled", engine.chromium_line("b", word))

    def test_no_answer_is_said_and_is_no_claim(self):
        word = engine.chromium_word({"error": "no such method"})
        self.assertEqual(word, {"error": "no such method"})
        self.assertEqual(engine.chromium_line("b", word), "CHROMIUM b: the app gave no word (no such method)")
        self.assertEqual(engine.chromium_word(None), {"error": "no reply"})

    def test_the_count_line_names_each_engine_and_the_rows_that_are_no_numbers(self):
        rows = [engine.judge(row("cef"), "cef"), engine.judge(row("cef"), "cef"),
                engine.judge(row("webkit:chromium-unavailable"), "cef"), {"command": "split_right", "visible_ms": 3.0}]
        self.assertEqual(engine.counts(rows), {"cef": 2, "webkit:chromium-unavailable": 1})
        self.assertEqual(engine.counts_line("b", rows, "cef"),
                         "PAGE-ENGINE b: cef 2, webkit:chromium-unavailable 1 (asked: cef; 1 row in another engine, "
                         "counted as missed, its times under other_engine)")

    def test_the_count_line_of_a_run_with_no_page_row_says_so(self):
        self.assertEqual(engine.counts_line("b", [{"command": "split_right"}], "any"),
                         "PAGE-ENGINE b: no row with a page (asked: any)")


def bash(script, *args):
    """Runs `script` with the helper sourced; (exit status, stdout, stderr)."""
    done = subprocess.run(["bash", "-c", f'set -euo pipefail; . "{HELPER}"; {script}', "bash", *args],
                          capture_output=True, text=True, timeout=30, env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    return done.returncode, done.stdout.strip(), done.stderr.strip()


class EntryHelperTests(unittest.TestCase):
    def log(self, text):
        handle = tempfile.NamedTemporaryFile("w", suffix=".log", delete=False)
        self.addCleanup(os.unlink, handle.name)
        handle.write(text)
        handle.close()
        return handle.name

    def test_an_entry_requires_the_engine_by_default(self):
        self.assertEqual(bash('measure_chromium_required "$@"'), (0, "1", ""))
        self.assertEqual(bash('measure_chromium_required "$@"', "--runs=12", "--config=bench"), (0, "1", ""))

    def test_allow_no_chromium_turns_the_requirement_off(self):
        self.assertEqual(bash('measure_chromium_required "$@"', "--runs=12", "--allow-no-chromium"), (0, "0", ""))

    def test_a_build_with_no_source_for_the_engine_names_the_four_sources_and_the_argument(self):
        log = self.log("note: x\nerror: could not download a verified cef.tar.xz (set CMUX_CEF_R2_* or "
                       "~/.secrets/cmux-cef.env, or log in with gh / set GH_TOKEN); see cmuxterm-hq REPAIR.md "
                       "(ensure-cef store parser)\n** BUILD FAILED **\n")
        status, out, err = bash('measure_chromium_failure "$@"', "cmd-t", log)
        self.assertEqual((status, out), (0, ""))
        self.assertEqual(len(err.splitlines()), 1)
        self.assertTrue(err.startswith("cmd-t: the build requires the Chromium engine, and none of its 4 sources gave it"), err)
        for source in ("the host's cache", "the fleet controller's artifact store", "the private bucket", "the private release"):
            self.assertIn(source, err)
        self.assertIn("--allow-no-chromium", err)

    def test_an_engine_that_was_refused_says_the_builds_own_reason(self):
        log = self.log("error: CEF 1.2 was built with DCHECKs on; pin a framework built with dcheck_always_on=false; "
                       "see cmuxterm-hq REPAIR.md (ensure-cef store parser)\n")
        status, _, err = bash('measure_chromium_failure "$@"', "cmd-t", log)
        self.assertEqual(status, 0)
        self.assertIn("CEF 1.2 was built with DCHECKs on", err)
        self.assertNotIn("4 sources", err)
        self.assertIn("--allow-no-chromium", err)

    def test_a_build_that_failed_for_another_reason_gets_no_engine_line(self):
        log = self.log("error: cannot find 'x' in scope\n** BUILD FAILED **\n")
        self.assertEqual(bash('measure_chromium_failure "$@"', "cmd-t", log), (1, "", ""))
        self.assertEqual(bash('measure_chromium_failure "$@"', "cmd-t", "/nonexistent/reload.log"), (1, "", ""))


class WiringTests(unittest.TestCase):
    """By a read of the text: what an entry and a bench must call. A run of an entry needs a Mac build."""

    def test_each_entry_passes_the_requirement_to_its_build_and_says_the_engines_failure(self):
        for name in ("instant-new-surfaces.sh", "chat-open.sh"):
            text = (MEASURE / name).read_text()
            self.assertIn("scripts/measure/require-chromium.sh", text, name)
            self.assertIn('measure_chromium_required "$@"', text, name)
            reloads = [line for line in text.splitlines() if "./scripts/reload.sh" in line and not line.lstrip().startswith("#")]
            self.assertEqual(len(reloads), 1, name)
            self.assertIn('CMUX_NEXT_REQUIRE_CEF="$require_chromium"', reloads[0], name)
            self.assertIn("measure_chromium_failure", text, name)
            self.assertIn("--allow-no-chromium", text, name)

    def test_the_cmd_t_entry_asks_the_bench_for_the_default_engine_unless_webkit_is_allowed(self):
        text = (MEASURE / "instant-new-surfaces.sh").read_text()
        self.assertIn("--page-engine=cef", text)

    def test_the_cmd_t_bench_reads_judges_and_reports_the_engine(self):
        text = (SCRIPTS / "instant-new-surfaces-bench.py").read_text()
        for needle in ('"--page-engine"', "bench_page_engine.page_engine(", "bench_page_engine.judge(",
                       "bench_page_engine.chromium_line(", "bench_page_engine.counts_line(", '"page_engines"', '"chromium"'):
            self.assertIn(needle, text, needle)


if __name__ == "__main__":
    unittest.main()
