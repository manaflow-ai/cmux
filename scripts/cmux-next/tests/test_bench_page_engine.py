#!/usr/bin/env python3
"""A measure says the engine of the page that it timed (decision 2026-11-16).

A tagged build embeds Chromium only when the engine's artifact is at hand. With none it warned in a build log that
no measure step prints, and the app showed each page in WebKit: a New Tab time of that app read as a time of the
default engine. These hold the three parts of the mend:

  - bench_page_engine.py: the engine's name from the app's answer, the rule for a row with another engine than the
    asked one (an error of the row, its times and frames kept apart, never a number), the Cmd-T bench's rule by
    what a row's command opens, the stop of a bench whose app has no Chromium, and the lines that a bench prints;
  - scripts/measure/require-chromium.sh: an entry's build requires the engine unless `--allow-no-chromium`, an
    entry asks its bench for the engine unless the run goes to a bench with no such argument, and a build that
    failed for the engine says so in one line;
  - the wiring, by a read of the lines that are no comment: the two entries and the two benches use them. No test
    here builds or launches an app.

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


    def test_the_frames_of_a_refused_row_go_with_its_times(self):
        # A summary reads `frames.first_tick_ms` (first_frame_ms_p50): a refused row keeps no frame time either.
        frames = {"first_tick_ms": 4.2, "intervals_ms": [8.3, 8.3]}
        got = engine.judge(row("webkit:chromium-unavailable", frames=dict(frames)), "cef")
        self.assertNotIn("frames", got)
        self.assertEqual(got["other_engine"]["frames"], frames)
        self.assertEqual(engine.judge(row("cef", frames=dict(frames)), "cef")["frames"], frames)

    def test_a_row_that_always_opens_a_page_is_no_number_when_its_engine_was_not_read(self):
        # Cmd-T always opens a page: with no ready time and no engine word, its visible time is still a page's.
        got = engine.judge(row("unknown: timed out", ready_ms=None), "cef", page=True)
        self.assertEqual(got["error"], "page engine not read (unknown: timed out), asked: cef")
        self.assertIsNone(got.get("visible_ms"))
        self.assertEqual(got["other_engine"]["visible_ms"], 9.0)
        self.assertNotIn("error", engine.judge(row("unknown: timed out", ready_ms=None), "any", page=True))
        self.assertNotIn("error", engine.judge(row("cef", ready_ms=None), "cef", page=True))


def never(*_):
    raise AssertionError("the engine was read for a row that needs no read")


class CreatedRowTests(unittest.TestCase):
    """The Cmd-T bench's rule for one row, by what the row's command opens (`judge_created`)."""

    def page_row(self, name, **more):
        return {"command": "link_right", "key_ms": 1.5, "visible_ms": 6.0, "page_ms": 40.0, "engine": name, **more}

    def test_a_page_commands_row_takes_the_engine_that_the_row_names_and_is_judged(self):
        got = engine.judge_created(self.page_row("webkit"), "cef", "page", never)
        self.assertEqual(got["page_engine"], "webkit")
        self.assertEqual(got["error"], "page engine webkit, asked: cef")
        for name in ("key_ms", "visible_ms", "page_ms"):
            self.assertIsNone(got.get(name), name)
        self.assertEqual(got["other_engine"], {"key_ms": 1.5, "visible_ms": 6.0, "page_ms": 40.0})
        kept = engine.judge_created(self.page_row("cef"), "cef", "page", never)
        self.assertEqual((kept["page_engine"], kept["page_ms"]), ("cef", 40.0))
        self.assertNotIn("error", kept)

    def test_a_browser_workspaces_row_is_judged_by_its_chrome_time(self):
        got = engine.judge_created({"command": "browser_workspace", "visible_ms": 7.0, "chrome_ms": 30.0, "page_ms": None,
                                    "engine": "webkit"}, "cef", "page", never)
        self.assertEqual(got["error"], "page engine webkit, asked: cef")
        self.assertIsNone(got.get("chrome_ms"))

    def test_a_page_commands_row_with_no_page_time_says_no_engine(self):
        got = engine.judge_created(self.page_row("webkit", page_ms=None), "cef", "page", never)
        self.assertNotIn("page_engine", got)
        self.assertNotIn("error", got)
        self.assertEqual(got["visible_ms"], 6.0)

    def test_a_page_commands_row_whose_focused_pane_shows_no_browser_is_no_number(self):
        # The app's word `none`: a viewer's page (a diff, the GitHub page), or a browser in a pane that has no focus.
        # That page is a page view in one of the 2 engines, and the row does not say which: its time is no number
        # of the asked engine.
        got = engine.judge_created(self.page_row("none"), "cef", "page", never)
        self.assertEqual(got["page_engine"], "none")
        self.assertEqual(got.get("error"), "page engine not read (none), asked: cef")
        self.assertIsNone(got.get("page_ms"))
        self.assertEqual(got.get("other_engine"), {"key_ms": 1.5, "visible_ms": 6.0, "page_ms": 40.0})
        self.assertEqual(engine.judge_created(self.page_row("none"), "webkit", "page", never).get("error"),
                         "page engine not read (none), asked: webkit")
        unnamed = engine.judge_created(self.page_row(None), "cef", "page", never)
        self.assertEqual(unnamed["page_engine"], "unknown: the row named no engine")
        self.assertEqual(unnamed.get("error"), "page engine not read (unknown: the row named no engine), asked: cef")
        self.assertIsNone(unnamed.get("page_ms"))

    def test_a_measure_of_a_viewers_page_asks_for_any_engine_and_keeps_its_row(self):
        got = engine.judge_created(self.page_row("none"), "any", "page", never)
        self.assertEqual((got["page_engine"], got["page_ms"]), ("none", 40.0))
        self.assertNotIn("error", got)
        self.assertNotIn("other_engine", got)

    def test_a_new_tab_row_reads_the_engine_one_time_after_its_times(self):
        reads = []
        got = engine.judge_created(row(None), "cef", "tab", lambda: reads.append(1) or "webkit:chromium-unavailable")
        self.assertEqual(reads, [1])
        self.assertEqual(got["page_engine"], "webkit:chromium-unavailable")
        self.assertEqual(got["error"], "page engine webkit:chromium-unavailable, asked: cef")

    def test_a_new_tab_row_whose_engine_was_not_read_is_no_number_also_with_no_ready_page(self):
        got = engine.judge_created(row(None, ready_ms=None), "cef", "tab", lambda: "unknown: timed out")
        self.assertEqual(got["error"], "page engine not read (unknown: timed out), asked: cef")
        self.assertIsNone(got.get("visible_ms"))

    def test_a_new_workspace_row_with_no_ready_page_and_no_engine_is_left_as_it_is(self):
        # Cmd-N can open a terminal: no page, no engine, and its times are no page's.
        got = engine.judge_created(row(None, ready_ms=None), "cef", "workspace", lambda: "unknown: pane p1 shows no agent tab")
        self.assertNotIn("error", got)
        self.assertEqual(got["visible_ms"], 9.0)

    def test_a_row_that_showed_nothing_and_a_row_of_no_page_read_no_engine(self):
        missed = engine.judge_created(row(None, visible_ms=None), "cef", "tab", never)
        self.assertNotIn("page_engine", {k: v for k, v in missed.items() if v is not None})
        plain = {"command": "split_right", "key_ms": 1.0, "visible_ms": 4.0}
        self.assertEqual(engine.judge_created(dict(plain), "cef", None, never), plain)


# The app's `unavailable` word in `debug.cef` when the build has no Chromium: an object, as the app sends it.
NOT_BUNDLED = {"code": "notBundled", "detail": None}


class LineTests(unittest.TestCase):
    def test_the_launch_line_says_the_apps_own_word_on_chromium(self):
        word = engine.chromium_word({"state": "ready", "default_engine": "chromium", "unavailable": None, "pump": {}})
        self.assertEqual(word, {"state": "ready", "unavailable": None, "browser_default_engine": "chromium"})
        self.assertEqual(engine.chromium_line("b", word),
                         "CHROMIUM b: the app says state=ready unavailable=no browser_default_engine=chromium")

    def test_the_launch_line_says_why_the_app_has_no_chromium(self):
        # The app's form of `unavailable`: null, or an object with a code and a detail.
        word = engine.chromium_word({"state": "idle", "default_engine": "chromium", "unavailable": NOT_BUNDLED})
        self.assertEqual(word, {"state": "idle", "unavailable": "notBundled", "browser_default_engine": "chromium"})
        self.assertEqual(engine.chromium_line("b", word),
                         "CHROMIUM b: the app says state=idle unavailable=notBundled browser_default_engine=chromium")

    def test_the_launch_line_says_the_detail_of_the_apps_reason_when_it_has_one(self):
        word = engine.chromium_word({"state": "idle", "default_engine": "chromium",
                                     "unavailable": {"code": "startFailed", "detail": "no framework at the path"}})
        self.assertEqual(word["unavailable"], "startFailed: no framework at the path")
        self.assertEqual(engine.chromium_line("b", word), "CHROMIUM b: the app says state=idle "
                         "unavailable=startFailed: no framework at the path browser_default_engine=chromium")

    def test_no_answer_is_said_and_is_no_claim(self):
        word = engine.chromium_word({"error": "no such method"})
        self.assertEqual(word, {"error": "no such method"})
        self.assertEqual(engine.chromium_line("b", word), "CHROMIUM b: the app gave no word (no such method)")
        self.assertEqual(engine.chromium_word(None), {"error": "no reply"})

    def test_an_app_with_no_chromium_stops_a_measure_of_chromium_with_the_argument_for_webkit(self):
        word = engine.chromium_word({"state": "idle", "default_engine": "chromium", "unavailable": NOT_BUNDLED})
        stop = engine.no_chromium(word)
        self.assertIn("(unavailable=notBundled)", stop)
        self.assertNotIn("{", stop)
        self.assertIn("--page-engine=cef", stop)
        self.assertIn("--allow-no-chromium", stop)
        self.assertEqual(len(stop.splitlines()), 1)

    def test_an_app_with_chromium_and_an_app_that_gave_no_word_stop_nothing(self):
        self.assertIsNone(engine.no_chromium(engine.chromium_word({"state": "ready", "unavailable": None})))
        self.assertIsNone(engine.no_chromium(engine.chromium_word({"error": "no such method"})))
        self.assertIsNone(engine.no_chromium(engine.chromium_word(None)))

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

    def test_an_entry_asks_its_bench_for_the_default_engine_by_default(self):
        self.assertEqual(bash('measure_engine_asked "$@"'), (0, "1", ""))
        self.assertEqual(bash('measure_engine_asked "$@"', "--runs=3", "--cases=click,click_again", "--config=bench"), (0, "1", ""))

    def test_an_entry_asks_no_engine_with_allow_no_chromium(self):
        self.assertEqual(bash('measure_engine_asked "$@"', "--runs=3", "--allow-no-chromium"), (0, "0", ""))

    def test_an_entry_asks_no_engine_of_another_bench_that_has_no_such_argument(self):
        # `--fork-open` hands the run to fork-open-bench.py and `--bench=` to another bench: neither takes
        # --page-engine, and argparse ends such a run with exit 2 after the whole build.
        self.assertEqual(bash('measure_engine_asked "$@"', "--fork-open"), (0, "0", ""))
        self.assertEqual(bash('measure_engine_asked "$@"', "--runs=2", "--fork-open", "--config=bench"), (0, "0", ""))
        self.assertEqual(bash('measure_engine_asked "$@"', "--bench=new-pane-start-state"), (0, "0", ""))
        # The build's requirement does not change with them.
        self.assertEqual(bash('measure_chromium_required "$@"', "--fork-open"), (0, "1", ""))

    def test_a_build_with_no_chromium_credits_says_the_engine_and_the_argument(self):
        log = self.log("note: x\nerror: no Chromium CREDITS.html for this CEF; a release must ship it\n** BUILD FAILED **\n")
        status, out, err = bash('measure_chromium_failure "$@"', "cmd-t", log)
        self.assertEqual((status, out), (0, ""))
        self.assertEqual(len(err.splitlines()), 1)
        self.assertTrue(err.startswith("cmd-t: the build requires the Chromium engine"), err)
        self.assertIn("no Chromium CREDITS.html", err)
        self.assertIn("--allow-no-chromium", err)

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


def code_lines(path):
    """The lines of a script that are no comment: a needle in a comment proves no wiring."""
    return [line for line in Path(path).read_text().splitlines() if not line.lstrip().startswith("#")]


class WiringTests(unittest.TestCase):
    """By a read of the text: what an entry and a bench must call. A run of an entry needs a Mac build. Each
    needle is looked for in the lines that are no comment."""

    def assert_entry_asks_the_engine(self, name, condition='"$ask_engine" == 1'):
        lines = [line.strip() for line in code_lines(MEASURE / name)]
        self.assertIn('ask_engine="$(measure_engine_asked "$@")"', lines, name)
        asks = [index for index, line in enumerate(lines) if line == 'set -- --page-engine=cef "$@"']
        self.assertEqual(len(asks), 1, f"{name}: the line that puts --page-engine=cef first")
        # The line before it is its condition: only when the helper says so.
        self.assertEqual(lines[asks[0] - 1], f"if [[ {condition} ]]; then", name)
        # After the entry's own arguments are taken out, so the caller's --page-engine comes later and wins.
        rest = [index for index, line in enumerate(lines) if line.startswith("set -- ${bench_args[@]")]
        self.assertEqual(len(rest), 1, name)
        self.assertLess(rest[0], asks[0], name)

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
        self.assert_entry_asks_the_engine("instant-new-surfaces.sh")

    def test_the_chat_open_entry_asks_the_bench_for_the_default_engine_unless_webkit_is_allowed(self):
        # #62529: chat-open.sh also runs the coordinator-CPU bench (tag != chatopen), which has no --page-engine.
        self.assert_entry_asks_the_engine("chat-open.sh", '"$ask_engine" == 1 && "$tag" == chatopen')
        bench = "\n".join(code_lines(SCRIPTS / "chat-open-bench.py"))
        for needle in ('"--page-engine"', "judge_engine(", '"page_engine_asked"'):
            self.assertIn(needle, bench, needle)

    def test_the_chat_open_bench_stops_at_its_first_launch_when_the_app_has_no_chromium(self):
        bench = "\n".join(code_lines(SCRIPTS / "chat-open-bench.py"))
        for needle in ('"debug.cef"', "bench_page_engine.chromium_word(", "bench_page_engine.no_chromium("):
            self.assertIn(needle, bench, needle)

    def test_the_cmd_t_bench_reads_judges_and_reports_the_engine(self):
        text = "\n".join(code_lines(SCRIPTS / "instant-new-surfaces-bench.py"))
        for needle in ('"--page-engine"', "bench_page_engine.page_engine(", "bench_page_engine.judge_created(",
                       "bench_page_engine.chromium_line(", "bench_page_engine.counts_line(", '"page_engines"', '"chromium"'):
            self.assertIn(needle, text, needle)


if __name__ == "__main__":
    unittest.main()
