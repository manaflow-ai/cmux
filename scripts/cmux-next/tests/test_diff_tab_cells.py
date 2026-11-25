#!/usr/bin/env python3
"""diff_tab_cells makes the same repository each time (the two arms of an A/B read the same tree), chooses
the window from what the page says of its focus, reads the child time words of a rusage buffer, proves that
read with a real child, and drives the diff page only through the app's control methods. The summary of
perf-idle-ab.sh groups the runs of a cell and prints its CPU with the children's CPU."""

from __future__ import annotations

import hashlib
import json
import os
import resource
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import diff_tab_cells as cells  # noqa: E402

ROOT = HERE.parent.parent.parent


def git(root: str, *args: str) -> str:
    # The environment make_repository gives git: no GIT_* of the caller and no global config, so a runner's
    # config (fsmonitor, maintenance) starts nothing that still writes in the scratch folder when it is removed.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(cells._GIT_ENV)
    return subprocess.run(["git", "-C", root, *args], check=True, capture_output=True, text=True, env=env).stdout


def read_json(path: str):
    with open(path) as handle:
        return json.load(handle)


class Repository(unittest.TestCase):
    def test_small_has_the_named_changes_and_is_the_same_each_time(self):
        with tempfile.TemporaryDirectory() as scratch:
            made = [cells.make_repository(os.path.join(scratch, name), "small") for name in ("one", "two")]
            self.assertEqual({k: made[0][k] for k in ("files", "changed_files", "changed_lines", "untracked_bytes")},
                             {"files": 200, "changed_files": 5, "changed_lines": 100, "untracked_bytes": 0})
            states = []
            for repository in made:
                root = repository["root"]
                self.assertEqual(len(git(root, "ls-files").splitlines()), 200)
                stat = [line.split("\t") for line in git(root, "diff", "--numstat").splitlines()]
                self.assertEqual([row[:2] for row in stat], [["20", "20"]] * 5)
                self.assertEqual(git(root, "status", "--porcelain").count("\n"), 5)
                states.append((git(root, "rev-parse", "HEAD"), hashlib.sha256(git(root, "diff").encode()).hexdigest()))
            # The same commit and the same diff: the base arm and the head arm read the same bytes.
            self.assertEqual(states[0], states[1])

    def test_large_names_one_megabyte_of_untracked_text(self):
        spec = cells.SIZES["large"]
        self.assertEqual((spec["files"], spec["changed"], spec["changed"] * spec["lines"], spec["untracked_bytes"]),
                         (20000, 200, 20000, 1 << 20))


class Window(unittest.TestCase):
    def test_only_a_page_that_says_it_has_the_focus_gets_the_short_window(self):
        self.assertEqual(cells.window_seconds(True, 60, 300), 60)
        self.assertEqual(cells.window_seconds(False, 60, 300), 300)
        self.assertEqual(cells.window_seconds(None, 60, 300), 300)

    def test_reads_in_the_window(self):
        self.assertEqual(cells.reads_expected(True, False, 60), 15)
        self.assertEqual(cells.reads_expected(False, False, 300), 10)
        self.assertEqual(cells.reads_expected(None, None, 60), 2)
        self.assertEqual(cells.reads_expected(True, True, 60), 0)

    def test_a_hidden_page_ends_the_run(self):
        self.assertEqual(cells.require_visible({"focus": False, "visibility": "visible"})["focus"], False)
        for facts in ({"hidden": True}, {"visibility": "hidden"}, {"view_hidden": True}, {"error": "no live page cmux.diff"},
                      {"visibility": None, "page_error": "no answer"}):
            with self.assertRaises(SystemExit):
                cells.require_visible(facts)

    def test_a_page_that_cannot_say_ends_the_run_when_its_window_is_not_shown(self):
        shown = {"visibility": None, "view_hidden": False, "window_occluded": False, "in_window": True, "window_visible": True}
        self.assertIs(cells.require_visible(shown), shown)
        for key, value in (("window_occluded", True), ("in_window", False), ("window_visible", False)):
            with self.assertRaises(SystemExit):
                cells.require_visible({**shown, key: value})
        # A page that says it is visible is believed: its own answer is the one that its timer uses.
        self.assertEqual(cells.require_visible({"visibility": "visible", "window_occluded": True})["visibility"], "visible")


class ChildTime(unittest.TestCase):
    def test_child_words_of_the_buffer(self):
        words = list(range(100, 164))
        # Words 12 and 13, in mach ticks of 125/3 ns.
        self.assertEqual(cells.child_cpu_ns(words, 125, 3), (112 + 113) * 125 // 3)

    @staticmethod
    def children_ns(_pid=None):
        used = resource.getrusage(resource.RUSAGE_CHILDREN)
        return int((used.ru_utime + used.ru_stime) * 1e9)

    def test_the_check_sees_a_real_child(self):
        seen = cells.child_time_check(self.children_ns, burn_s=0.2)
        self.assertTrue(seen["ok"], seen)
        self.assertGreaterEqual(seen["seen_ms"], 160)
        self.assertAlmostEqual(seen["seen_ms"], seen["times_ms"], delta=0.2)

    def test_the_check_says_when_the_read_has_a_part_of_the_child_time_only(self):
        # A read of one wrong word: it sees a child, but not the time that the system gives for it.
        seen = cells.child_time_check(lambda _pid: self.children_ns() // 2, burn_s=0.2)
        self.assertFalse(seen["ok"], seen)
        self.assertGreater(seen["seen_ms"], 0)

    def test_the_check_says_when_the_read_sees_no_child(self):
        self.assertFalse(cells.child_time_check(lambda _pid: 7, burn_s=0.05)["ok"])
        self.assertFalse(cells.child_time_check(lambda _pid: None, burn_s=0.05)["ok"])


class FakeApp:
    """The control socket of an app with one Chromium diff page; it records each call."""

    def __init__(self, focus=True, pages=None, fingerprint=True, action=None, matched=True):
        self.calls, self.focus, self.fingerprint, self.matched = [], focus, fingerprint, matched
        self.pages = pages if pages is not None else [{"browser": 9, "origin": "cmux-page://cmux.diff", "hidden": False}]
        self.action_reply = action if action is not None else {"created": ["tab_1"]}
        self.wheel = threading.Event()

    def action(self, action, **args):
        self.calls.append(("action", action, args))
        return self.action_reply

    def call(self, method, params=None, timeout=120):
        params = params or {}
        self.calls.append((method, params.get("action") or params.get("method"), params))
        if method == "debug.cef_pages":
            return {"pages": self.pages}
        if method == "debug.cef_page_devtools":
            if params["method"] == "Input.dispatchMouseEvent":
                if sum(1 for call in self.calls if call[1] == "Input.dispatchMouseEvent") >= 3:
                    self.wheel.set()
                return {"result": "{}"}
            said = json.dumps({"focus": self.focus, "visibility": "visible", "files": 5, "width": 1000, "height": 700})
            return {"result": json.dumps({"result": {"type": "string", "value": said}})}
        if params.get("action") == "state":
            return {"engine": "chromium", "view_hidden": False, "window_occluded": False, "painted": True}
        if params.get("action") == "wait":
            return {"matched": True, "text": "src/d000/f00000.txt"} if self.matched else {"matched": False, "error": "timeout"}
        if params.get("action") == "call":
            if self.fingerprint:
                return {"t": "ok", "id": 1, "value": {"fingerprint": "ab" * 32}}
            # An error that names the operation: its text has the word and it is no fingerprint.
            return {"t": "err", "id": 1, "code": "native.unsupported", "message": "no cmux.diff.git.fingerprint", "retryable": False}
        return {}


class Page(unittest.TestCase):
    def test_facts_have_the_focus_the_page_says(self):
        for focus in (True, False):
            facts = cells.page_facts(FakeApp(focus=focus))
            self.assertEqual((facts["engine"], facts["browser"], facts["focus"], facts["visibility"], facts["width"]),
                             ("chromium", 9, focus, "visible", 1000))

    def test_a_page_with_no_script_call_has_no_focus_answer(self):
        facts = cells.page_facts(FakeApp(pages=[]))
        self.assertEqual((facts["focus"], facts["browser"]), (None, None))
        self.assertEqual(cells.window_seconds(facts["focus"], 60, 300), 300)

    def test_the_visible_page_is_chosen_before_a_hidden_one(self):
        pages = [{"browser": 1, "origin": "cmux-page://cmux.diff", "hidden": True},
                 {"browser": 2, "origin": "https://example.com"},
                 {"browser": 3, "origin": "cmux-page://cmux.diff", "hidden": False}]
        self.assertEqual(cells.chromium_page(pages)["browser"], 3)
        self.assertIsNone(cells.chromium_page([pages[1]]))

    def test_open_asks_for_the_folder_with_the_focus_and_proves_one_read(self):
        app = FakeApp()
        opened = cells.open_tab(app, "/tmp/repository")
        self.assertEqual(app.calls[0], ("action", "openDiffViewer", {"focus": True, "path": "/tmp/repository"}))
        self.assertEqual(app.calls[2][2]["op"], "cmux.diff.git.fingerprint")
        self.assertIn("fingerprint", opened["read"])

    def test_open_goes_on_to_the_first_file_when_the_action_answers_at_its_limit(self):
        late = {"error": "action.run timed out", "code": "timeout", "state": "in_progress"}
        opened = cells.open_tab(FakeApp(action=late), "/tmp/repository")
        self.assertIn("fingerprint", opened["read"])
        with self.assertRaises(SystemExit):
            cells.open_tab(FakeApp(action=late, matched=False), "/tmp/repository")

    def test_open_ends_the_run_when_the_tab_the_first_file_or_the_read_fails(self):
        for app in (FakeApp(action={"error": "The picker opens only when focus is requested."}), FakeApp(matched=False),
                    FakeApp(fingerprint=False)):
            with self.assertRaises(SystemExit):
                cells.open_tab(app, "/tmp/repository")

    def test_scroll_sends_wheel_events_at_the_middle_of_the_page(self):
        app = FakeApp()
        scroller = cells.Scroller(app, cells.page_facts(app), rate=200)
        scroller.start()
        self.assertTrue(app.wheel.wait(30))
        told = scroller.stop()
        wheels = [call[2]["params"] for call in app.calls if call[1] == "Input.dispatchMouseEvent"]
        self.assertGreaterEqual(told["events"], 3)
        self.assertEqual(told["errors"], 0)
        self.assertEqual({(wheel["type"], wheel["x"], wheel["y"]) for wheel in wheels}, {("mouseWheel", 500, 350)})
        self.assertEqual(wheels[0]["deltaY"], 240)

    def test_scroll_ends_the_run_for_a_page_that_is_not_chromium(self):
        app = FakeApp(pages=[])
        with self.assertRaises(SystemExit):
            cells.Scroller(app, cells.page_facts(app)).start()


class Summary(unittest.TestCase):
    def test_cells_are_grouped_and_the_children_count_in_the_total(self):
        script = (ROOT / "scripts" / "measure" / "perf-idle-ab.sh").read_text()
        program = script.split("<<'PY' || status=1\n", 1)[1].split("\nPY\n", 1)[0]

        def run(app, daemon, children, focus):
            return {"child_time_check": {"ok": True, "seen_ms": 312.5}, "samples": [
                {"label": "idle-launch", "kinds": {}},
                {"label": "idle-2", "measure_s": 60 if focus else 300,
                 "diff_tab": {"page": {"focus": focus}, "page_after": {"focus": focus}, "reads_expected": 15 if focus else 10},
                 "kinds": {"app": {"cpu_pct": app, "wakeups_per_s": 3.0},
                           "tui-daemon": {"cpu_pct": daemon, "wakeups_per_s": 1.0, "child_cpu_pct": children}}}]}

        with tempfile.TemporaryDirectory() as scratch:
            runs = os.path.join(scratch, "runs")
            os.makedirs(runs)
            for name, data in (("base-1-cell1", run(2.0, 1.0, 4.0, True)), ("head-1-cell1", run(1.0, 0.5, 0.25, True)),
                               ("base-1-cell2", run(0.5, 0.1, 0.0, False)), ("head-1-cell2", run(0.5, 0.1, 0.0, False))):
                with open(os.path.join(runs, name + ".json"), "w") as handle:
                    json.dump(data, handle)
            out = subprocess.run([sys.executable, "-I", "-c", program, runs, "1", "1:large:rest,1:none:rest"],
                                 check=True, capture_output=True, text=True).stdout
            summary = read_json(os.path.join(scratch, "summary.json"))
        lines = out.splitlines()
        self.assertIn("IDLE-AB window base 1 cell 1:large:rest measure_s 60 focus True focus_after True "
                      "reads_expected 15 scroll_events None scroll_errors None", lines)
        self.assertIn("IDLE-AB child_time_check head 1 cell 1:none:rest ok True seen_ms 312.5", lines)
        self.assertEqual([line for line in lines if line.startswith("IDLE-AB fault")], [])
        self.assertIn("IDLE-AB cpu cell 1:large:rest kind children:tui-daemon base 4.0 [4.0-4.0] n 1 head 0.25 [0.25-0.25] n 1 delta -3.75", lines)
        self.assertIn("IDLE-AB cpu cell 1:large:rest kind total base 7.0 [7.0-7.0] n 1 head 1.75 [1.75-1.75] n 1 delta -5.25", lines)
        self.assertIn("IDLE-AB cpu cell 1:none:rest kind total base 0.6 [0.6-0.6] n 1 head 0.6 [0.6-0.6] n 1 delta 0.0", lines)
        self.assertIn("IDLE-AB median cell 1:large:rest kind app base 3.0 [3.0-3.0] n 1 head 3.0 [3.0-3.0] n 1 delta 0.0", lines)
        self.assertEqual({row["cell"] for row in summary}, {"1:large:rest", "1:none:rest"})

    def test_a_cell_that_is_not_to_be_read_is_a_fault_and_the_exit_is_1(self):
        script = (ROOT / "scripts" / "measure" / "perf-idle-ab.sh").read_text()
        program = script.split("<<'PY' || status=1\n", 1)[1].split("\nPY\n", 1)[0]

        def run(focus, after=None, check=True, scroll=None):
            tab = {"page": {"focus": focus}, "page_after": {"focus": focus if after is None else after}, "reads_expected": 15}
            if scroll is not None:
                tab["scroll"] = scroll
            return {"child_time_check": {"ok": check, "seen_ms": 300.0}, "samples": [
                {"label": "idle-2", "measure_s": 60, "diff_tab": tab,
                 "kinds": {"app": {"cpu_pct": 1.0, "wakeups_per_s": 3.0}}}]}

        sent = {"events": 290, "errors": 0, "rate_per_s": 5}
        with tempfile.TemporaryDirectory() as scratch:
            runs = os.path.join(scratch, "runs")
            os.makedirs(runs)
            for name, data in (
                    # cell 1: one arm with the focus and one without it.
                    ("base-1-cell1", run(True)), ("head-1-cell1", run(False)),
                    # cell 2: the page lost the focus in the window of one run.
                    ("base-1-cell2", run(True)), ("head-1-cell2", run(True, after=False)),
                    # cell 3: the check of the child time read failed in one run.
                    ("base-1-cell3", run(True, check=False)), ("head-1-cell3", run(True)),
                    # cell 4: a scroll cell with too few events, and one with an event that failed.
                    ("base-1-cell4", run(True, scroll={**sent, "events": 100})), ("head-1-cell4", run(True, scroll={**sent, "errors": 2})),
                    # cell 5: a scroll cell with its events and no error.
                    ("base-1-cell5", run(True, scroll=sent)), ("head-1-cell5", run(True, scroll=sent))):
                with open(os.path.join(runs, name + ".json"), "w") as handle:
                    json.dump(data, handle)
            names = "1:small:rest,1:large:rest,4:large:rest,1:small:scroll,1:large:scroll"
            done = subprocess.run([sys.executable, "-I", "-c", program, runs, "1", names], capture_output=True, text=True)
            self.assertTrue(os.path.exists(os.path.join(scratch, "summary.json")))
        self.assertEqual(done.returncode, 1, done.stderr)
        faults = [line for line in done.stdout.splitlines() if line.startswith("IDLE-AB fault")]
        self.assertEqual(sorted({line.split()[3] for line in faults}),
                         ["1:large:rest", "1:small:rest", "1:small:scroll", "4:large:rest"])
        self.assertEqual(len(faults), 6, faults)
        self.assertIn("IDLE-AB child_time_check base 1 cell 4:large:rest ok False seen_ms 300.0", done.stdout.splitlines())
        self.assertIn("IDLE-AB window head 1 cell 1:small:scroll measure_s 60 focus True focus_after True "
                      "reads_expected 15 scroll_events 290 scroll_errors 2", done.stdout.splitlines())

    def test_without_cells_the_lines_are_the_ones_of_before(self):
        script = (ROOT / "scripts" / "measure" / "perf-idle-ab.sh").read_text()
        program = script.split("<<'PY' || status=1\n", 1)[1].split("\nPY\n", 1)[0]
        with tempfile.TemporaryDirectory() as scratch:
            runs = os.path.join(scratch, "runs")
            os.makedirs(runs)
            for arm, wakes in (("base", 4.0), ("head", 3.0)):
                with open(os.path.join(runs, f"{arm}-1-agents.json"), "w") as handle:
                    json.dump({"samples": [{"label": "idle-2", "kinds": {"app": {"cpu_pct": 1.0, "wakeups_per_s": wakes}}}]}, handle)
            out = subprocess.run([sys.executable, "-I", "-c", program, runs, "1", ""],
                                 check=True, capture_output=True, text=True).stdout
            summary = read_json(os.path.join(scratch, "summary.json"))
        self.assertEqual(out.splitlines(), [
            "IDLE-AB run base 1 chats 1 kind app wakeups_per_s 4.0 cpu_pct 1.0",
            "IDLE-AB run head 1 chats 1 kind app wakeups_per_s 3.0 cpu_pct 1.0",
            "IDLE-AB median chats 1 kind app base 4.0 [4.0-4.0] n 1 head 3.0 [3.0-3.0] n 1 delta -1.0"])
        self.assertEqual(summary[0], {"arm": "base", "round": 1, "chats": 1, "kind": "app", "wakeups_per_s": 4.0, "cpu_pct": 1.0})


if __name__ == "__main__":
    unittest.main()
