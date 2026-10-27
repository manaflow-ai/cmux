#!/usr/bin/env python3
"""Offline tests of driver_tui.py and gen_tui.py (p15-oracle-234): no daemon, no cmux-tui build.

Run: python3 -I scripts/cmux-next/oracle/driver_tui_test.py
The live test is `linux_run.sh run REF --suite tui -- --product tui` on the VM (or `oracle.py run --product tui
--suite tui --binary CMUX_TUI` inside a runnerd job): every case passes, twice.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import driver_tui  # noqa: E402
import gen_tui  # noqa: E402
import normalize  # noqa: E402
from driver_daemon import CaseError  # noqa: E402
from driver_tui import Renames, Screen, key_bytes  # noqa: E402


def screen_of(data: bytes, cols: int = 20, rows: int = 4) -> Screen:
    screen = Screen(cols, rows)
    screen.feed(data)
    return screen


def step(*keys: str) -> Dict[str, Any]:
    return {"id": "s", "op": "tui.key", "args": {"keys": list(keys)}}


class Keystrokes(unittest.TestCase):
    def test_printable_and_shifted_keys_are_their_characters(self) -> None:
        self.assertEqual(key_bytes("t"), b"t")
        self.assertEqual(key_bytes("shift+w"), b"W")
        self.assertEqual(key_bytes("shift+5"), b"%")
        self.assertEqual(key_bytes("shift+'"), b'"')
        self.assertEqual(key_bytes("plus"), b"+")

    def test_ctrl_and_alt_letters_are_legacy_bytes(self) -> None:
        self.assertEqual(key_bytes("ctrl+b"), b"\x02")
        self.assertEqual(key_bytes("alt+n"), b"\x1bn")
        self.assertEqual(key_bytes("ctrl+alt+b"), b"\x1b\x02")

    def test_named_keys_and_their_modified_forms(self) -> None:
        self.assertEqual(key_bytes("return"), b"\r")
        self.assertEqual(key_bytes("shift+tab"), b"\x1b[Z")
        self.assertEqual(key_bytes("pagedown"), b"\x1b[6~")
        self.assertEqual(key_bytes("ctrl+pagedown"), b"\x1b[6;5~")
        self.assertEqual(key_bytes("shift+left"), b"\x1b[1;2D")
        self.assertEqual(key_bytes("alt+left"), b"\x1b\x1b[D")

    def test_escape_cmd_and_ctrl_shift_are_csi_u_reports(self) -> None:
        self.assertEqual(key_bytes("escape"), b"\x1b[27u")
        self.assertEqual(key_bytes("cmd+k"), b"\x1b[107;9u")
        self.assertEqual(key_bytes("ctrl+shift+a"), b"\x1b[97;6u")
        self.assertEqual(key_bytes("alt+escape"), b"\x1b[27;3u")

    def test_fn_and_unknown_keys_are_refused(self) -> None:
        for stroke in ("fn+f1", "hyper+a", "ctrl+", "f13"):
            with self.subTest(stroke=stroke), self.assertRaises(driver_tui.KeystrokeError):
                key_bytes(stroke)

    def test_every_corpus_keystroke_is_sendable(self) -> None:
        for case in gen_tui.CASES:
            for each in case.steps:
                if each["op"] == "tui.key":
                    driver_tui.check_keys(each)

    def test_a_step_that_leaves_the_prefix_armed_is_refused(self) -> None:
        with self.assertRaises(CaseError):
            driver_tui.check_keys(step("ctrl+b"))
        with self.assertRaises(CaseError):
            driver_tui.check_keys(step("ctrl+b", "ctrl+b", "ctrl+b"))
        self.assertEqual(driver_tui.check_keys(step("ctrl+b", "ctrl+b")), [b"\x02", b"\x02"])
        self.assertEqual(driver_tui.check_keys(step("ctrl+b", "t")), [b"\x02", b"t"])


class Screens(unittest.TestCase):
    def test_text_lands_at_the_cursor_and_erases_clear_it(self) -> None:
        screen = screen_of(b"\x1b[2;3Habc\x1b[1;1Hxyz\x1b[2;4H\x1b[K")
        self.assertEqual(screen.lines()[:2], ["xyz", "  a"])
        screen.feed(b"\x1b[2J")
        self.assertEqual(screen.lines(), ["", "", "", ""])

    def test_wide_characters_take_two_cells_and_wrap_at_the_edge(self) -> None:
        screen = screen_of("\x1b[1;19H界x".encode(), cols=20)
        self.assertEqual(screen.lines()[0], " " * 18 + "界")
        self.assertEqual(screen.lines()[1], "x")

    def test_the_alternate_screen_is_separate_and_the_main_one_returns(self) -> None:
        screen = screen_of(b"main\x1b[?1049h\x1b[Halt")
        self.assertEqual(screen.lines()[0], "alt")
        screen.feed(b"\x1b[?1049l")
        self.assertEqual(screen.lines()[0], "main")

    def test_osc_and_apc_strings_draw_nothing(self) -> None:
        screen = screen_of(b"\x1b]0;title\x07\x1b_Gi=31;AAAA\x1b\\ok\x1b]52;c;eA==\x1b\\")
        self.assertEqual(screen.lines()[0], "ok")

    def test_a_cell_keeps_the_style_it_was_written_with(self) -> None:
        plain = screen_of(b"ab")
        colored = screen_of(b"\x1b[38;5;110;1ma\x1b[0mb")
        self.assertEqual(plain.lines(), colored.lines())
        self.assertEqual(colored.styles()[0], "1*bold,fg=5:110|19*")
        self.assertNotEqual(driver_tui.screen_digest(plain, Renames()), driver_tui.screen_digest(colored, Renames()))

    def test_sgr_forms_canonicalize_to_one_style(self) -> None:
        semicolons = screen_of(b"\x1b[38;2;1;2;3;48;5;9mx")
        colons = screen_of(b"\x1b[38:2::1:2:3m\x1b[48:5:9mx")
        self.assertEqual(semicolons.styles(), colons.styles())
        reset = screen_of(b"\x1b[1;31mx\x1b[22;39my")
        self.assertEqual(reset.styles()[0], "1*bold,fg=1|19*")

    def test_an_erase_fills_with_the_current_background(self) -> None:
        screen = screen_of(b"\x1b[48;5;236m\x1b[2J")
        self.assertEqual(screen.styles()[0], "20*bg=5:236")

    def test_cursor_visibility_and_position(self) -> None:
        screen = screen_of(b"\x1b[?25l\x1b[3;5H")
        self.assertEqual((screen.row, screen.col, screen.cursor_visible), (2, 4, False))


class CaseNames(unittest.TestCase):
    ROOT = "/tmp/o/pq9x3c/kofmvu"

    def renames(self) -> Renames:
        return Renames([(self.ROOT, "$ROOT"), ("oracle-1brmm3", "oracle")])

    def test_names_are_replaced_at_their_own_width(self) -> None:
        text = f"[oracle-1brmm3] {self.ROOT}/x"
        out = self.renames().apply(text)
        self.assertEqual(len(out), len(text))
        self.assertEqual(out, "[oracle_______] $ROOT_______________/x")

    def test_a_middle_truncated_path_is_replaced_too(self) -> None:
        self.assertEqual(self.renames().apply("  /tmp/o/p...c/kofmvu│x"), "  $ROOT______________│x")
        self.assertEqual(self.renames().apply("/t...u"), "$ROOT_")

    def test_other_ellipses_are_left_alone(self) -> None:
        for text in ("a.../b", "filt…", "/tmp/o/...", "...kofmvu"):
            with self.subTest(text=text):
                self.assertEqual(self.renames().apply(text), text)

    def test_two_cases_with_different_roots_hash_equal(self) -> None:
        first = screen_of(b"/tmp/o/pq9x3c/kofmvu [oracle-1brmm3]", cols=40)
        second = screen_of(b"/tmp/o/zz0000/abcdef [oracle-zzzzzz]", cols=40)
        other = Renames([("/tmp/o/zz0000/abcdef", "$ROOT"), ("oracle-zzzzzz", "oracle")])
        self.assertEqual(driver_tui.screen_digest(first, self.renames()), driver_tui.screen_digest(second, other))


class Facet(unittest.TestCase):
    def test_the_facet_matches_the_snapshot_schema(self) -> None:
        doc = json.loads(Path(normalize.DEFAULT_SCHEMA).read_text(encoding="utf-8"))
        facet_schema = doc["properties"]["facets"]["properties"][driver_tui.TUI_FACET]
        value = driver_tui.facet_value(screen_of(b"x"), Renames(), None)
        self.assertEqual(sorted(value), sorted(facet_schema["required"]))
        self.assertRegex(value["screenSha256"], facet_schema["properties"]["screenSha256"]["pattern"])
        self.assertIn(driver_tui.TUI_FACET, doc["properties"]["meta"]["properties"]["facets"]["items"]["enum"])

    def test_the_prefix_bar_is_found_where_the_tui_draws_it(self) -> None:
        screen = screen_of(" Ctrl-b  ›  Ctrl-b  Send prefix".encode(), cols=40, rows=2)
        self.assertTrue(driver_tui.prefix_bar_shown(screen))
        self.assertFalse(driver_tui.prefix_bar_shown(screen_of(b"Ctrl-b")))


class Pty(unittest.TestCase):
    """TuiProcess against a stand-in program: the screen follows its output, keys reach it, a hang-up ends it."""

    PROGRAM = ("import os, sys, tty\n"
               "tty.setraw(0)\n"
               "os.write(1, b'\\x1b[?1049h\\x1b[Hready')\n"
               "while True:\n"
               "    data = os.read(0, 64)\n"
               "    if not data or data == b'q':\n"
               "        break\n"
               "    os.write(1, b'\\x1b[2;1H' + data.hex().encode())\n")

    def spawn(self, root: Path) -> driver_tui.TuiProcess:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        return driver_tui.TuiProcess([sys.executable, "-I", "-c", self.PROGRAM], env, str(root), root / "log",
                                     cols=30, rows=4)

    def test_keys_reach_the_program_and_its_output_reaches_the_screen(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tui = self.spawn(Path(tmp))
            deadline = time.monotonic() + 30
            self.assertTrue(tui.wait_screen(lambda s: s.lines()[0] == "ready", deadline))
            tui.write(key_bytes("escape"))
            self.assertTrue(tui.wait_screen(lambda s: s.lines()[1] == b"\x1b[27u".hex(), deadline))
            tui.write(b"q")
            self.assertEqual(tui.proc.wait(30), 0)
            self.assertEqual(tui.hang_up(5), 0)

    def test_a_hang_up_ends_a_program_that_reads_its_terminal(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tui = self.spawn(Path(tmp))
            self.assertTrue(tui.wait_screen(lambda s: s.lines()[0] == "ready", time.monotonic() + 30))
            self.assertIsNotNone(tui.hang_up(10))
            self.assertFalse(tui.running)
            with self.assertRaises(driver_tui.TuiExited):
                tui.write(b"x")


class Corpus(unittest.TestCase):
    def test_the_checked_in_corpus_is_the_generators(self) -> None:
        self.assertEqual(gen_tui.main(["--check"]), 0)

    def test_every_inventory_action_has_a_case_or_a_reason(self) -> None:
        report = gen_tui.coverage()
        tui_actions, menu_actions = gen_tui.load_inventory()
        self.assertEqual(sorted(report["tui_actions"]), sorted(tui_actions))
        self.assertEqual(sorted(report["menu_actions"]), sorted(menu_actions))
        self.assertEqual(report["covered"] + len(report["excluded"]), report["total"])
        self.assertEqual(report["missing"], [])
        cases = {case.name for case in gen_tui.CASES}
        for kind in ("tui_actions", "menu_actions"):
            for name, entry in report[kind].items():
                with self.subTest(action=name):
                    self.assertTrue(set(entry.get("cases", ())) <= cases)
                    self.assertTrue(entry.get("cases") or len(entry.get("reason", "")) >= 20)

    def test_an_unknown_or_unreasoned_action_is_refused(self) -> None:
        extra = gen_tui.TuiCase("x", "x", ("no-such-action",), (gen_tui.keys_step("act", ["t"]),))
        with self.assertRaisesRegex(ValueError, "no-such-action is not in the inventory"):
            gen_tui.coverage((*gen_tui.CASES, extra))
        without = tuple(case for case in gen_tui.CASES if case.name != "split-down")
        with self.assertRaisesRegex(ValueError, "split-down has neither"):
            gen_tui.coverage(without)

    def test_each_known_nondeterminism_names_a_case_and_its_cause(self) -> None:
        report = gen_tui.coverage()
        self.assertEqual(sorted(report["nondeterministic"]), sorted(gen_tui.RACES))
        with self.assertRaisesRegex(ValueError, "RACES names split-right, which is not a case"):
            gen_tui.coverage(tuple(case for case in gen_tui.CASES if case.name != "split-right")
                             + (gen_tui.TuiCase("split-right-2", "x", ("split-right",), gen_tui.SPLIT),))

    def test_every_case_requires_tui_and_runs_on_linux(self) -> None:
        for case in gen_tui.CASES:
            data = gen_tui.case_json(case)
            with self.subTest(case=case.name):
                self.assertIn("tui", data["requires"])
                self.assertEqual(data["platforms"], ["linux"])
                ops = {each["op"] for each in data["steps"]}
                self.assertEqual("resource_api" in data["requires"], "resource.call" in ops)

    def test_a_step_that_leaves_pane_mode_is_followed_by_one_that_settles(self) -> None:
        for case in gen_tui.CASES:
            steps: List[Dict[str, Any]] = list(case.steps)
            for index, each in enumerate(steps):
                if each.get("checkpoint") == ["before"]:
                    with self.subTest(case=case.name, step=each["id"]):
                        following = steps[index + 1] if index + 1 < len(steps) else None
                        self.assertIsNotNone(following, "a before-only step needs a step after it that closes it")
                        self.assertNotIn("before", following.get("checkpoint", ["settled"]))

    def test_the_frontend_config_binds_free_chords(self) -> None:
        taken = {"t", "B", "N", "%", '"', "x", "X", ",", "$", "&", "p", "n", "c", "(", "w", ")", "W", "D", "s", "m",
                 "e", "S", "g", "U", "o", "h", "l", "k", "j", "+", "-", "z", "{", "}", "[", "<", ">", "r", "u", "?",
                 "d", *"0123456789"}
        for chord in (gen_tui.SELECT_TAB_0_KEY, gen_tui.RENAME_TAB_KEY, gen_tui.USER_COMMAND_KEY):
            self.assertNotIn(chord, taken)
        self.assertEqual(gen_tui.TUI_CONFIG["viewport"], {"animation": False})


if __name__ == "__main__":
    unittest.main()
