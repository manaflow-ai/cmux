#!/usr/bin/env python3
"""scripts/measure/pane-act-spans.py and what scripts/cmux-next/pane-zoom-terminal.py keeps for it. No app runs:
each test gives the reader, or the tool's own round against a stand-in for the app's debug socket, the smallest
fault that it must see. Run: python3 scripts/measure/tests/pane-act-spans.test.py
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
READER = os.path.normpath(os.path.join(HERE, "..", "pane-act-spans.py"))
TOOL = os.path.normpath(os.path.join(HERE, "..", "..", "cmux-next", "pane-zoom-terminal.py"))
SCRATCH = tempfile.mkdtemp(prefix="pane-act-spans-test-")


def tearDownModule():
    shutil.rmtree(SCRATCH, ignore_errors=True)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_tool():
    """The tool as a module. It reads its arguments and makes its scratch folder when it loads: both go to this
    test's folder."""
    argv, folder = sys.argv, tempfile.tempdir
    sys.argv = [TOOL, "--tag", "test", "--app", os.path.join(SCRATCH, "No.app"), "--out", SCRATCH]
    tempfile.tempdir = SCRATCH
    try:
        return load("pane_zoom_terminal_under_test", TOOL)
    finally:
        sys.argv, tempfile.tempdir = argv, folder


reader = load("pane_act_spans_under_test", READER)
tool = load_tool()

A = "layout.act."


def span(part, ms, at):
    return {"name": A + part, "ms": ms, "at_ms": at}


def moves(name, count, value=2.0):
    """`count` samples `name` of a record, one for each frame."""
    return [{"name": name, "t_ms": round(16.7 + 8.3 * at, 1), "v": value} for at in range(count)]


def unzoom(commit=12, travel=0, **change):
    """A whole answer of one unzoom: the key's turn (arm, sizes, report), then the pass and the place in a tick, and
    the samples of a move at a commit that moves 2 panes in each of `commit` frames."""
    spans = [span("arm", 0.1, 10.0), span("sizes", 1.2, 10.1), span("report", 4.0, 11.5), span("pass", 5.0, 16.7),
             span("place", 0.6, 21.7), {"name": "layout", "ms": 160.0, "at_ms": 21.7}]
    samples = moves("clock.dt_ms", 20, 8.3) + moves("layout.commit", commit) + moves("layout.travel", travel, 40.0)
    return {"spans": spans, "spans_full": False, "samples": samples, "work": {"clock": {"max_ms": 3.0, "frames": 20}}, **change}


def without(answer, part):
    return {**answer, "spans": [s for s in answer["spans"] if s["name"] != A + part]}


def row_of(answer, at=0, direction="unzoom"):
    """The row that the tool keeps of `answer`, by the reader's own function."""
    return {"layout": "6x5", "direction": direction, "round": at, **reader.kept(answer)}


class App:
    """A stand-in for the app's debug socket: it answers the tool's calls, with one `debug.motion` answer for each
    record, in their order."""

    def __init__(self, answers):
        self.answers = list(answers)

    def rpc(self, method, params=None, timeout=30):
        stop = (params or {}).get("action") == "stop"
        if method == "debug.motion" and stop:
            return self.answers.pop(0)
        if method == "debug.frames" and stop:
            return {"missed": 0, "max_ms": 9.0, "p99_ms": 8.9, "p95_ms": 8.5, "p50_ms": 8.3, "frames": 140, "refresh_ms": 8.3}
        if method == "debug.window_transition" and stop:
            return {"terminal_grid_reports": 1, "terminal_resizes_sent": 1}
        if method == "debug.hangs":
            return {"hangs": []}
        return {}


def rounds(records):
    """The tool's own round for each (direction, round, answer) of `records`: its runs, its rows and what it printed."""
    app, out, before = App(answer for _, _, answer in records), io.StringIO(), len(tool.ROWS)
    with mock.patch.object(tool, "rpc", app.rpc), mock.patch.object(tool.time, "sleep", lambda seconds: None), \
            contextlib.redirect_stdout(out):
        runs = [tool.round_of("6x5", direction, at) for direction, at, _ in records]
    return runs, tool.ROWS[before:], out.getvalue()


def animated(rows):
    """Whether each row `the zoom animated` of `rows` passed."""
    return [ok for check, _, _, ok in rows if "the zoom animated" in check]


class TheWholeAnswer(unittest.TestCase):
    def test_a_whole_unzoom_gives_each_part_and_its_report(self):
        result = reader.read_act(unzoom())
        self.assertEqual((result["valid"], result["why"]), (True, []))
        self.assertEqual(result["parts"], {A + "arm": {"ms": 0.1, "at_ms": 10.0}, A + "sizes": {"ms": 1.2, "at_ms": 10.1},
                                           A + "pass": {"ms": 5.0, "at_ms": 16.7}, A + "place": {"ms": 0.6, "at_ms": 21.7}})
        self.assertEqual(result["report"]["in_act_ms"], 4.0)
        self.assertEqual(result["report"]["other"], [])
        self.assertEqual(result["order"], [A + part for part in ("arm", "sizes", "report", "pass", "place")])

    def test_a_span_of_another_family_is_not_read(self):
        answer = unzoom()
        answer["spans"].append({"name": "layout.place", "ms": 0.5, "at_ms": 17.0})
        self.assertTrue(reader.read_act(answer)["valid"])
        self.assertEqual(len(reader.kept(answer)["act_spans"]), 5)

    def test_the_row_that_the_tool_keeps_reads_as_the_raw_answer(self):
        self.assertEqual(reader.read_row(row_of(unzoom())), reader.read_act(unzoom()))


class ASpanWithNoEnd(unittest.TestCase):
    def test_a_pass_that_never_ended_is_no_number(self):
        for result in (reader.read_act(without(unzoom(), "pass")), reader.read_row(row_of(without(unzoom(), "pass")))):
            self.assertFalse(result["valid"])
            self.assertEqual(result["parts"], {})
            self.assertIn("layout.act.pass: 0 spans, not 1", result["why"])

    def test_each_one_time_span_that_is_not_there_is_named(self):
        for part in ("arm", "sizes", "pass", "place"):
            result = reader.read_act(without(unzoom(), part))
            self.assertEqual((result["valid"], result["why"]), (False, [f"{A}{part}: 0 spans, not 1"]))

    def test_a_pass_that_an_older_begin_made_too_long_is_no_number(self):
        answer = without(unzoom(), "pass")
        answer["spans"].append(span("pass", 17.7, 4.0))  # it began before its act's arm and ends where the place begins
        result = reader.read_act(answer)
        self.assertFalse(result["valid"])
        self.assertEqual(result["parts"], {})

    def test_a_pass_that_does_not_end_where_the_place_begins_is_no_number(self):
        answer = without(unzoom(), "pass")
        answer["spans"].append(span("pass", 2.0, 16.7))
        self.assertFalse(reader.read_act(answer)["valid"])

    def test_a_span_with_no_time_is_no_number(self):
        for bad in (None, True, -1.0, float("nan"), "5"):
            answer = without(unzoom(), "place")
            answer["spans"].append(span("place", bad, 21.7))
            self.assertFalse(reader.read_act(answer)["valid"], bad)


class AReportOfAnotherFrame(unittest.TestCase):
    def test_a_report_after_the_act_is_not_in_the_acts_sum(self):
        answer = unzoom()
        answer["spans"].append(span("report", 9.0, 600.0))
        result = reader.read_act(answer)
        self.assertTrue(result["valid"])
        self.assertEqual(result["report"]["in_act_ms"], 4.0)
        self.assertEqual(result["report"]["other"], [span("report", 9.0, 600.0)])

    def test_a_report_before_the_act_is_not_in_the_acts_sum(self):
        answer = unzoom()
        answer["spans"].insert(0, span("report", 3.0, 2.0))
        result = reader.read_act(answer)
        self.assertEqual((result["report"]["in_act_ms"], len(result["report"]["other"])), (4.0, 1))

    def test_an_act_with_no_report_in_its_window_has_no_report_number(self):
        answer = without(unzoom(), "report")
        answer["spans"].append(span("report", 30.0, 190.0))  # a zoom: the covered panes are told at the move's end
        result = reader.read_act(answer)
        self.assertTrue(result["valid"])
        self.assertIsNone(result["report"]["in_act_ms"])
        self.assertEqual(len(result["report"]["other"]), 1)


class TwoActsOrAFullList(unittest.TestCase):
    def test_a_second_arm_is_no_number(self):
        answer = unzoom()
        answer["spans"].append(span("arm", 0.1, 12.0))
        self.assertEqual(reader.read_act(answer)["why"], ["layout.act.arm: 2 spans, not 1"])

    def test_a_full_list_is_not_measured(self):
        for result in (reader.read_act(unzoom(spans_full=True)), reader.read_row(row_of(unzoom(spans_full=True)))):
            self.assertFalse(result["valid"])
            self.assertIn("NOT MEASURED", result["why"][0])

    def test_an_answer_without_the_field_is_not_measured(self):
        answer = unzoom()
        del answer["spans_full"]
        self.assertFalse(reader.read_act(answer)["valid"])
        self.assertFalse(reader.read_row(row_of(answer))["valid"])
        self.assertFalse(reader.read_act({"spans_full": False})["valid"])
        self.assertFalse(reader.read_act(None)["valid"])

    def test_an_answer_that_is_an_error_keeps_no_span_and_is_no_number(self):
        for answer in ({"error": "no such method"}, None, []):
            kept = reader.kept(answer)
            self.assertEqual((kept["act_spans"], kept["commit_frames"], kept["travel_frames"]), (None, 0, 0))
            self.assertFalse(reader.read_row(row_of(answer))["valid"])
        self.assertFalse(reader.read_row(None)["valid"])

    def test_a_span_name_that_the_reader_does_not_know_is_no_number(self):
        answer = unzoom()
        answer["spans"].append(span("commit", 1.0, 18.0))
        self.assertFalse(reader.read_act(answer)["valid"])

    def test_spans_in_the_wrong_order_are_no_number(self):
        answer = without(unzoom(), "sizes")
        answer["spans"].append(span("sizes", 1.2, 30.0))
        self.assertFalse(reader.read_act(answer)["valid"])


class TheThreeEdges(unittest.TestCase):
    """The 3 edges of the app's spans that give a wrong COUNT (by a read of the app's code). The rule: a record whose
    count of a one-time span is not 1 is INVALID and gives no number. Each edge exactly, as the app would write it."""

    def test_edge_1_two_changes_before_one_pass_are_no_number(self):
        # 2 `arm` + 2 `sizes` + 1 `pass` + 1 `place`: a second change came before the pass of the first.
        answer = unzoom()
        answer["spans"][2:2] = [span("arm", 0.1, 12.0), span("sizes", 1.1, 12.1)]
        for result in (reader.read_act(answer), reader.read_row(row_of(answer))):
            self.assertFalse(result["valid"])
            self.assertEqual(result["parts"], {})
            self.assertIsNone(result["report"]["in_act_ms"])
            self.assertEqual(result["why"], ["layout.act.arm: 2 spans, not 1", "layout.act.sizes: 2 spans, not 1"])

    def test_edge_2_a_place_with_no_pass_is_no_number(self):
        # A change that arms between the pass's begin and the panes' place: a `place` span and NO `pass` span.
        answer = without(unzoom(), "pass")
        for result in (reader.read_act(answer), reader.read_row(row_of(answer))):
            self.assertFalse(result["valid"])
            self.assertEqual(result["parts"], {})
            self.assertEqual(result["why"], ["layout.act.pass: 0 spans, not 1"])

    def test_edge_3_a_nested_pass_is_no_number(self):
        # A pass in a pass: the second begin is ignored and the inner end closes the span, so ONE `pass` span that is
        # shorter, and 2 `place` spans (the inner one and the outer one). The count of `place` says it.
        answer = without(without(unzoom(), "pass"), "place")
        answer["spans"] += [span("pass", 2.3, 16.7), span("place", 0.5, 19.0), span("place", 0.6, 21.7)]
        for result in (reader.read_act(answer), reader.read_row(row_of(answer))):
            self.assertFalse(result["valid"])
            self.assertEqual(result["parts"], {})
            self.assertEqual(result["why"], ["layout.act.place: 2 spans, not 1"])

    def test_edge_3_a_nested_report_is_one_shorter_span_that_no_reader_can_see(self):
        # A report in a report: ONE `report` span from the outer begin to the INNER end. The answer has nothing that
        # tells it from a short report, so the reader gives the shorter number: the number of `layout.act.report` is
        # a LOWER bound, and the table says `at least` (the class AtLeast).
        answer = without(unzoom(), "report")
        answer["spans"].append(span("report", 1.5, 11.5))
        result = reader.read_act(answer)
        self.assertTrue(result["valid"])
        self.assertEqual(result["report"]["in_act_ms"], 1.5)


class NoPaneThatMoved(unittest.TestCase):
    """An act whose record has each span and no frame in which a pane moved is not the act that the numbers are for
    (the key did nothing, or the panes' move is off): INVALID, no number."""

    WHY = ["no pane moved: 0 `layout.commit` samples above 0 in the record"]

    def test_an_act_with_each_span_and_no_pane_that_moved_is_no_number(self):
        for answer in (unzoom(commit=0), {**unzoom(commit=0), "samples": moves("layout.commit", 12, 0.0)}):
            result = reader.read_row(row_of(answer))
            self.assertEqual((result["valid"], result["parts"], result["why"]), (False, {}, self.WHY))

    def test_frames_of_the_layouts_springs_are_no_move_of_a_pane_at_a_commit(self):
        result = reader.read_row(row_of(unzoom(commit=0, travel=9)))
        self.assertEqual((result["valid"], result["why"]), (False, self.WHY))

    def test_one_frame_in_which_a_pane_moved_is_enough(self):
        self.assertTrue(reader.read_row(row_of(unzoom(commit=1)))["valid"])

    def test_a_row_that_does_not_say_if_a_pane_moved_is_not_measured(self):
        for bad in (None, True, "12", 1.5):
            row = {**row_of(unzoom()), "commit_frames": bad}
            result = reader.read_row(row)
            self.assertFalse(result["valid"], bad)
            self.assertIn("NOT MEASURED", result["why"][0])
        row = row_of(unzoom())
        del row["commit_frames"]
        self.assertFalse(reader.read_row(row)["valid"])

    def test_the_tools_round_of_an_act_that_moved_no_pane_is_no_number(self):
        runs, _, _ = rounds([("unzoom", 0, unzoom(commit=0)), ("unzoom", 1, unzoom())])
        self.assertEqual([reader.read_row(run)["why"] for run in runs], [self.WHY, []])


class TheRowTheZoomAnimated(unittest.TestCase):
    """The tool's row `the zoom animated` read only the layout's springs (`layout.travel`). A zoom that moves its
    panes at a commit steps no spring, so the row failed for a zoom that did move. It now counts the frames of both."""

    def test_a_zoom_that_moves_nothing_fails_the_row(self):
        still = {**unzoom(commit=0), "samples": moves("clock.dt_ms", 20, 8.3) + moves("layout.commit", 12, 0.0)
                 + moves("layout.travel", 12, 0.0)}
        for answer in (unzoom(commit=0), still):
            runs, rows, _ = rounds([("zoom", 0, answer)])
            self.assertEqual(animated(rows), [False])
            self.assertEqual(runs[0]["moving_frames"], 0)

    def test_a_zoom_that_moves_its_panes_at_a_commit_passes_the_row(self):
        runs, rows, _ = rounds([("zoom", 0, unzoom(commit=12, travel=0))])
        self.assertEqual(animated(rows), [True])
        self.assertEqual((runs[0]["moving_frames"], runs[0]["commit_frames"], runs[0]["travel_frames"]), (12, 12, 0))

    def test_a_zoom_that_moves_the_layouts_springs_still_passes_the_row(self):
        runs, rows, _ = rounds([("zoom", 0, unzoom(commit=0, travel=7))])
        self.assertEqual(animated(rows), [True])
        self.assertEqual((runs[0]["moving_frames"], runs[0]["commit_frames"], runs[0]["travel_frames"]), (7, 0, 7))

    def test_an_answer_that_is_an_error_fails_the_row(self):
        _, rows, _ = rounds([("zoom", 0, {"error": "no answer"})])
        self.assertEqual(animated(rows), [False])


def five(direction="unzoom", bad=()):
    """5 rounds of one act, each with its own numbers; the rounds in `bad` have no pass."""
    records = []
    for at in range(5):
        answer = unzoom()
        answer["spans"][2] = span("report", 4.0 + at, 11.5)
        answer["spans"][3] = span("pass", 5.0, round(16.7 + at / 10, 1))
        answer["spans"][4] = span("place", round(0.6 + at / 10, 1), round(21.7 + at / 10, 1))
        records.append((direction, at, without(answer, "pass") if at in bad else answer))
    return records


class AtLeast(unittest.TestCase):
    """A report in a report gives ONE shorter span that no reader can see, so each number of `layout.act.report` is a
    lower bound: the table says `at least` in its head and at each such number, never a plain number."""

    def test_the_head_and_each_number_of_the_report_say_at_least(self):
        records = five()
        records[4][2]["spans"].append(span("report", 9.0, 600.0))
        lines, faults = reader.table([row_of(answer, at) for _, at, answer in records])
        self.assertEqual(faults, 0)
        self.assertTrue(lines[0].endswith("(at least)"), lines[0])
        self.assertEqual([line.split(" | ")[-1] for line in lines[1:7]],
                         [f"at least {value}" for value in (4.0, 5.0, 6.0, 7.0, 8.0, 6.0)])
        self.assertIn("median of 5 valid rounds of 5", lines[6])
        self.assertIn("at least 9.0 ms at 600.0 ms", lines[7])
        self.assertEqual(len(lines), 8)

    def test_an_act_with_no_report_in_its_window_says_none(self):
        rows = [row_of(without(answer, "report"), at, "zoom") for _, at, answer in five("zoom")]
        lines, _ = reader.table(rows)
        self.assertEqual({line.split(" | ")[-1] for line in lines[1:]}, {"none"})


class FewerThanThreeRounds(unittest.TestCase):
    def test_two_valid_rounds_of_five_are_not_measured(self):
        lines, faults = reader.table([row_of(answer, at) for _, at, answer in five(bad=(0, 2, 4))])
        self.assertEqual(faults, 4)
        self.assertEqual(sum("INVALID: layout.act.pass: 0 spans, not 1" in line for line in lines), 3)
        self.assertIn("NOT MEASURED: 2 valid rounds of 5, 3 needed", lines[-1])
        self.assertFalse(any("median" in line for line in lines))

    def test_three_valid_rounds_of_five_have_a_median_and_the_table_still_has_a_fault(self):
        lines, faults = reader.table([row_of(answer, at) for _, at, answer in five(bad=(1, 3))])
        self.assertEqual(faults, 2)
        self.assertIn("6x5 | unzoom | median of 3 valid rounds of 5 | 0.1 | 1.2 | 5.0 | 0.8 | ", lines[-1])

    def test_the_act_that_is_asked_for_is_the_only_one_in_the_table(self):
        rows = [row_of(answer, at, direction) for direction in ("zoom", "unzoom") for _, at, answer in five(direction)]
        self.assertEqual(len(reader.table(rows)[0]), 1 + 2 * 6)
        only = reader.table(rows, "unzoom")[0]
        self.assertEqual((len(only), {line.split(" | ")[1] for line in only[1:]}), (7, {"unzoom"}))


class TheLogAlone(unittest.TestCase):
    """With one failed row the tool ends with exit 1 and the step's artifact does not come back. The tool prints one
    line for each round in the step's log, and those lines alone give the numbers that the artifact gives."""

    def setUp(self):
        records = five("zoom") + five("unzoom", bad=(3,))
        records[7][2]["spans"].append(span("report", 9.0, 600.0))
        records[9] = ("unzoom", 4, unzoom(commit=0))
        runs, _, self.log = rounds(records)
        self.artifact = json.loads(json.dumps({"runs": runs}))

    def test_the_logs_lines_give_the_table_that_the_artifact_gives(self):
        from_log = reader.rows_of_log(self.log)
        self.assertEqual(len(from_log), 10)
        table = reader.table(self.artifact["runs"])
        self.assertEqual(reader.table(from_log), table)
        self.assertEqual(table[1], 2)
        text = "\n".join(table[0])
        self.assertIn("6x5 | zoom | median of 5 valid rounds of 5 | 0.1 | 1.2 | 5.0 | 0.8 | at least 6.0", text)
        self.assertIn("6x5 | unzoom | median of 3 valid rounds of 5 | 0.1 | 1.2 | 5.0 | 0.7 | at least 5.0", text)
        self.assertIn("6x5 | unzoom | 3 | INVALID: layout.act.pass: 0 spans, not 1", text)
        self.assertIn("6x5 | unzoom | 4 | INVALID: no pane moved", text)
        self.assertIn("6x5 | unzoom | 2 | a report outside the act's window, in no number: at least 9.0 ms at 600.0 ms", text)

    def test_text_before_the_mark_changes_nothing(self):
        stamped = "\n".join(f"12:00:{at % 60:02d} stdout | {line}" for at, line in enumerate(self.log.splitlines()))
        self.assertEqual(reader.table(reader.rows_of_log(stamped)), reader.table(self.artifact["runs"]))

    def test_a_line_that_the_log_cut_is_a_fault_and_not_a_lost_round(self):
        lines = self.log.splitlines()
        at = next(index for index, line in enumerate(lines) if line.startswith(reader.MARK))
        lines[at] = lines[at][:len(lines[at]) // 2]
        rows = reader.rows_of_log("\n".join(lines))
        self.assertEqual(len(rows), 10)
        table, faults = reader.table(rows)
        self.assertGreater(faults, 2)
        self.assertTrue(any(f"INVALID: line {at + 1} of the log has the mark and no JSON object" in line for line in table))

    def test_the_command_reads_the_log_and_the_artifact_alike(self):
        paths = [os.path.join(SCRATCH, name) for name in ("step.log", "report.json")]
        open(paths[0], "w").write(self.log)
        json.dump(self.artifact, open(paths[1], "w"))
        printed = []
        for arguments in (["--log", paths[0], "unzoom"], [paths[1], "unzoom"]):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(reader.main(arguments), 1)
            printed.append(out.getvalue())
        self.assertEqual(printed[0], printed[1])
        self.assertIn("median of 3 valid rounds of 5", printed[0])
        self.assertNotIn("| zoom |", printed[0])

    def test_a_log_with_no_round_is_not_measured(self):
        path = os.path.join(SCRATCH, "empty.log")
        open(path, "w").write("launched pid 1\nRESULT FAIL (0/0)\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(reader.main(["--log", path]), 1)
        self.assertIn("NOT MEASURED: no row", out.getvalue())
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(reader.main([]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=1)
