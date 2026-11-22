#!/usr/bin/env python3
"""cmd-n-paint-e2e.py --screen --window-look: the take runs in the look that was asked, and its report says so.

No app, no display, no fleet. The app is test_screen_active_app.py's function with 4 answers more: its settings
(`settings.get`), the speed of its motion (`debug.motion`), its first window's backdrop and ground (`debug.themes`)
and the theme folder of its bundle (`debug.appearance`). So this proves what the tool writes into the launch's config
files, what it reads from the app before it makes a session, what it says of both, and when it ends the run. It does
not prove that an app on a Mac shows the look.

The words of the option, the config keys and the reads of the app are scripts/cmux-next/window_look.py's (its own
tests: scripts/measure/tests/window-look.test.py); each look of this file is made up for the tests. The look names a
theme, so the module's check of the theme runs in the tool's path: the 2 theme answers of the app here have the
form of that file's own app (`debug.themes` with no name of the theme, `debug.appearance` with the folder), and the
theme files are real files in the test's own folder, because the tool gives the module no reader of its own.

    python3 -I scripts/cmux-next/tests/test_screen_window_look.py
"""
import argparse
import contextlib
import importlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # the imports leave no cache folder in the checkout
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
import test_cmd_n_paint_default as driver  # noqa: E402
import test_screen_active_app as active  # noqa: E402
import window_look as looks  # noqa: E402

new_surface_screen = active.new_surface_screen
frames_of = new_surface_screen.frames_of
WORDS = ("background=aurora,opacity=0.5,blur=frosted,ui.animationSpeed=fast,appearance.metrics.titlebarHeight=40,"
         "appearance.theme=Two+Words,terminal-opacity=0.9,name=mine")
LOOK = looks.window_look(WORDS)
GROUND = "#102030"  # the ground of the look's theme file, and the ground that an app with that theme says
THEME_PROVED = "theme check: the window's ground = the ground of the theme's file in the app's bundle; 1 of the 1 theme files of the bundle has that ground"
MODE = (*driver.NEEDED, "new_surface_screen.py", "new_surface_frames.py", "bench_page_engine.py", "new_surface_look.py", "window_look.py")


def tool():
    """The tool's own file of the look (a test that needs it fails by itself while the file is not there)."""
    return importlib.import_module("new_surface_look")


class App(active.App):
    """The active app's function with its settings. `held`: what the app holds of its settings file (None: the app
    gives no answer). `speed`: the speed that its motion runs at. `backdrop`: what its first window shows. `ground`:
    its first window's ground (None: the answer has no `window_background`). `themes`: the theme folder that the app
    names in its bundle (None: it names none)."""

    def __init__(self, folder, held=None, speed="fast", backdrop=None, ground=None, themes=None, **more):
        super().__init__(folder, **more)
        self.held, self.speed, self.backdrop, self.ground, self.themes = held, speed, backdrop, ground, themes

    def rpc(self, method, params=None, timeout=30):
        if method not in ("settings.get", "debug.motion", "debug.themes", "debug.appearance"):
            return super().rpc(method, params, timeout)
        self.names.append(method)
        if method == "debug.motion":
            return {"speed": self.speed} if self.speed else {}
        if method == "debug.appearance":
            return {"override": None, "effective": "dark", "terminal_background": GROUND, "themes": self.themes}
        if method == "debug.themes":
            if not self.backdrop:
                return {}
            # The shape that the app gives for a theme of the config: no name of the theme is in it.
            window = {"spec": None, "effective_spec": None, "source": "config", "is_dark": True, "backdrop": self.backdrop}
            if self.ground is not None:
                window["window_background"] = self.ground
            return {"windows": [window], "terminals": [], "ghostty_background": GROUND}
        if self.held is None:
            return {}
        path = (params or {}).get("path")
        value = looks.look_value(self.held, path) if path else self.held
        return {"path": path.split(".") if path else [], "exists": value is not None, "value": value}


def bundle_themes(folder, files=None):
    """A theme folder as an app's bundle has it, made in the test's own `folder`: each of `files` is a theme file's
    name with its text (with none: the one file of the look's theme, with the ground of the tests)."""
    themes = Path(folder) / "bundle-themes"
    themes.mkdir(exist_ok=True)
    for name, text in ({"Two Words": f"background = {GROUND}\n"} if files is None else files).items():
        (themes / name).write_text(text)
    return str(themes)


def shown_app(folder, files=None, **changed):
    """An app that holds the look of the tests and shows it. `files`: the theme files of its bundle (`bundle_themes`)."""
    held = looks.look_config({"sidebar": {"side": "right"}}, LOOK)
    shows = dict(held=held, backdrop={"picture": "aurora", "tint": "#10203080", "blending": "false"}, ground=GROUND,
                 themes=bundle_themes(folder, files))
    return App(folder, **{**shows, **changed})


class WindowLookTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="screen-window-look-test-")
        self.addCleanup(lambda: __import__("shutil").rmtree(self.folder, ignore_errors=True))
        self.made = []

    def run_mode(self, app, **changed):
        def make(*asked):
            self.made.append(asked)
            app.workspaces += asked[1]
            return {}
        opts = active.close.options(self.folder, **{**dict(keys="t", gaps="0", window_look=LOOK), **changed})
        screen = new_surface_screen.Screen(opts, app.rpc, app.tools(), sleep=app.pause, make_session=make, clock=app.clock, start=app.start)
        said = io.StringIO()
        with contextlib.redirect_stdout(said):
            report = screen.run()
        return report, said.getvalue().splitlines()

    def parsed(self, *words):
        parser = argparse.ArgumentParser()
        new_surface_screen.add_arguments(parser)
        with contextlib.redirect_stderr(io.StringIO()) as refused:
            try:
                return parser.parse_args(list(words)).window_look, None
            except SystemExit as stop:
                return stop.code, refused.getvalue()

    def test_the_option_takes_the_one_look_modules_words(self):
        self.assertEqual(self.parsed("--window-look", WORDS), (LOOK, None))
        self.assertEqual(LOOK["appearance.theme"], "Two Words")  # a `+` between 2 words is a space
        self.assertEqual((self.parsed(), self.parsed("--window-look", "opaque")), ((None, None), (None, None)))
        code, why = self.parsed("--window-look", "ui.animationSpeed")
        self.assertEqual((code, "--window-look takes opaque or KEY=VALUE" in why), (2, True))

    def test_the_option_refuses_a_panel_behind_the_window_because_this_tool_makes_none(self):
        code, why = self.parsed("--window-look", "opacity=0.5,behind=checker")
        self.assertEqual(code, 2)
        self.assertIn("behind=checker: this tool makes no panel behind its window", why)
        self.assertEqual(self.parsed("--window-look", "opacity=0.5,behind=desktop")[1], None)

    def launch_files(self):
        """The 2 config files as the driver's launch makes them, and the launch's environment."""
        env = {"CMUX_NEXT_CONFIG_FILE": os.path.join(self.folder, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(self.folder, "ghostty")}
        Path(env["CMUX_NEXT_CONFIG_FILE"]).write_text("{}\n")
        Path(env["CMUX_NEXT_GHOSTTY_CONFIG"]).write_text("")
        return env

    def test_the_launch_writes_each_key_of_the_look_into_its_own_config_files(self):
        env = self.launch_files()
        self.assertIsNone(tool().write(LOOK, env))
        self.assertEqual(json.loads(Path(env["CMUX_NEXT_CONFIG_FILE"]).read_text()), {
            "appearance": {"background": "aurora", "backgroundOpacity": 0.5, "backgroundBlur": "frosted",
                           "metrics": {"titlebarHeight": 40}, "theme": "Two Words"},
            "ui": {"animationSpeed": "fast"}})
        self.assertEqual(Path(env["CMUX_NEXT_GHOSTTY_CONFIG"]).read_text(), "background-opacity = 0.9\n")

    def test_a_launch_with_no_look_leaves_its_config_files_as_they_were(self):
        env = self.launch_files()
        self.assertIsNone(tool().write(None, env))
        self.assertEqual((Path(env["CMUX_NEXT_CONFIG_FILE"]).read_text(), Path(env["CMUX_NEXT_GHOSTTY_CONFIG"]).read_text()), ("{}\n", ""))

    def test_a_launch_whose_config_file_can_not_be_written_says_why_and_writes_nothing_else(self):
        env = self.launch_files()
        env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.folder, "no such folder", "cmux.json")
        self.assertIn("the launch's config files were not written", tool().write(LOOK, env))
        self.assertIn("the launch's config files were not written", tool().write(LOOK, {}))

    def test_the_report_says_each_written_key_with_the_apps_answer_before_the_session_is_made(self):
        app = shown_app(self.folder)
        report, said = self.run_mode(app, workspaces=5)
        lines = [line[len("NEW-SURFACE-SCREEN-SETTINGS "):] for line in said if line.startswith("NEW-SURFACE-SCREEN-SETTINGS ")]
        self.assertEqual(lines[:7], [
            "window look mine: appearance.background: the launch wrote 'aurora', the app answers 'aurora'",
            "window look mine: appearance.backgroundOpacity: the launch wrote 0.5, the app answers 0.5",
            "window look mine: appearance.backgroundBlur: the launch wrote 'frosted', the app answers 'frosted'",
            "window look mine: ui.animationSpeed: the launch wrote 'fast', the app answers 'fast'",
            "window look mine: appearance.metrics.titlebarHeight: the launch wrote 40, the app answers 40",
            "window look mine: appearance.theme: the launch wrote 'Two Words', the app answers 'Two Words'",
            "app setting, not of the look: sidebar.side = 'right'"])
        self.assertEqual(lines[7:9], ["each other setting: not in the app's settings (the app's default)", "the app's motion speed: 'fast'"])
        self.assertEqual(lines[9], THEME_PROVED)  # the module's check of the look's theme, by the ground
        self.assertEqual(lines[10], "the first window shows, by the app: the picture 'aurora', opacity 0.502, kind picture")
        self.assertEqual(lines[11], 'the first window\'s theme, by the app: {"spec": null, "effective_spec": null, "source": "config", '
                                    '"window_background": "#102030", "is_dark": true}')
        self.assertEqual(lines[12], "the CLI: not asked (the driver did not launch this app)")
        self.assertEqual(len(lines), 13)
        self.assertEqual(app.names.count("debug.appearance"), 1)  # the bundle's theme folder is asked for one time
        # The lines are the first thing that the run prints, and the app is asked before the session's maker runs.
        self.assertTrue(said[0].startswith("NEW-SURFACE-SCREEN-SETTINGS "), said[0])
        self.assertEqual((len(self.made), report.get("stopped")), (1, None))
        self.assertLess(app.names.index("debug.themes"), app.names.index("debug.window.focus"))
        # The report has them, and its head ends with them: the head's first sentences keep their places.
        self.assertEqual((report["settings"]["lines"], report["settings"]["problem"], report["settings"]["look"]), (lines, None, "look-mine"))
        self.assertEqual(report["head"][0], "the app was active: yes")
        self.assertEqual(report["head"][-len(lines):], lines)
        self.assertEqual(len(report["rows"]), 1)

    def test_an_app_that_answers_another_value_ends_the_run_before_the_session_and_before_a_key(self):
        held = looks.look_config({}, LOOK)
        held["ui"] = {"animationSpeed": "off"}
        app = shown_app(self.folder, held=held, speed="off")
        report, said = self.run_mode(app, workspaces=5)
        self.assertEqual(report.get("stopped"), "window look: ui.animationSpeed is 'off' in the app's settings, not 'fast'; the app's motion "
                                                "speed is 'off', not 'fast': no session made, no tab made, no case recorded")
        self.assertEqual((self.made, report["rows"], report["cases"], report["exit_code"]), ([], [], {}, new_surface_screen.STOPPED_EXIT))
        self.assertEqual([call for call in app.names if call in ("frame_strip", "debug.key", "action.run", "debug.window.focus")], [])
        self.assertIn("NEW-SURFACE-SCREEN-SETTINGS window look mine: ui.animationSpeed: the launch wrote 'fast', the app answers 'off' (NOT THE LOOK)", said)
        self.assertEqual(report["session"], {"asked": 5, "not_made": report["stopped"], "as_asked": False})
        self.assertEqual(said[-1], f"NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED {report['stopped']}")
        # The app is read again for a time (a picture loads, a tint blends), by the tool's own count of its pauses.
        self.assertEqual(app.names.count("debug.themes"), 23)  # 22 reads of the look for 10 s, and 1 read of the window's theme

    def test_a_window_that_does_not_show_the_looks_picture_ends_the_run(self):
        app = shown_app(self.folder, backdrop={"picture": "", "tint": "#10203080", "blending": "false"})
        report, _ = self.run_mode(app)
        self.assertEqual(report.get("stopped"), "window look: the window shows the picture '', not 'aurora': no session made, no tab made, no case recorded")
        self.assertEqual((self.made, report["rows"]), ([], []))

    def test_a_bundle_with_no_file_of_the_looks_theme_ends_the_run(self):
        # The look names a theme and the bundle's theme folder has a file of another theme only: the module's check
        # of the theme runs in this tool's path, and its own text ends the run.
        other = {"Another": "background = #A0B0C0\n"}
        app = shown_app(self.folder, files=other)
        report, said = self.run_mode(app)
        failed = "theme check: the app's bundle has no file of the look's theme: the theme is not proved"
        self.assertEqual(report.get("stopped"), f"window look: {failed}: no session made, no tab made, no case recorded")
        self.assertEqual((self.made, report["rows"], app.names.count("debug.appearance")), ([], [], 1))
        self.assertIn(f"NEW-SURFACE-SCREEN-SETTINGS {failed}", said)
        # The same app with the theme's file beside that file passes, so the file is what the run stopped for.
        report, said = self.run_mode(shown_app(self.folder, files={**other, "Two Words": f"background = {GROUND}\n"}))
        self.assertEqual((report.get("stopped"), len(report["rows"])), (None, 1))
        self.assertIn("NEW-SURFACE-SCREEN-SETTINGS " + THEME_PROVED.replace("1 of the 1 theme files", "1 of the 2 theme files"), said)

    def test_an_app_that_gives_no_settings_answer_does_not_pass_for_the_look(self):
        report, said = self.run_mode(shown_app(self.folder, held=None))
        self.assertIn("window look: ", report.get("stopped", ""))
        self.assertIn("NEW-SURFACE-SCREEN-SETTINGS window look mine: ui.animationSpeed: the launch wrote 'fast', the app answers NOT READ", said)
        self.assertIn("NEW-SURFACE-SCREEN-SETTINGS each other setting: NOT READ", said)

    def test_with_no_look_the_head_says_each_setting_that_the_app_holds_and_no_run_stops(self):
        app = App(self.folder, held={"ui": {"animationSpeed": "off"}}, speed="off")
        report, said = self.run_mode(app, window_look=None)
        self.assertEqual(report["settings"]["lines"], ["app setting, not of the look: ui.animationSpeed = 'off'",
                                                       "each other setting: not in the app's settings (the app's default)",
                                                       "the app's motion speed: 'off'", "the first window shows, by the app: NOT READ",
                                                       "the first window's theme, by the app: NOT READ"])
        self.assertEqual((report.get("stopped"), len(report["rows"]), report["settings"]["look"]), (None, 1, None))
        self.assertEqual(app.names.count("debug.themes"), 2)  # no look: the backdrop one time, the window's theme one time, no CLI call

    def test_with_no_look_an_app_that_answers_nothing_is_said_as_not_read(self):
        report, _ = self.run_mode(App(self.folder, speed=None), window_look=None)
        self.assertEqual(report["settings"]["lines"], ["each other setting: NOT READ", "the app's motion speed: NOT READ",
                                                       "the first window shows, by the app: NOT READ", "the first window's theme, by the app: NOT READ"])
        self.assertEqual((report.get("stopped"), len(report["rows"])), (None, 1))

    def test_options_of_an_older_caller_with_no_look_field_run_as_with_no_look(self):
        opts = active.close.options(self.folder, keys="t", gaps="0")
        self.assertFalse(hasattr(opts, "window_look"))
        app = App(self.folder)
        with contextlib.redirect_stdout(io.StringIO()):
            report = new_surface_screen.Screen(opts, app.rpc, app.tools(), sleep=app.pause, make_session=lambda *asked: {},
                                               clock=app.clock, start=app.start).run()
        self.assertEqual((report.get("stopped"), len(report["rows"]), report["settings"]["look"]), (None, 1, None))

    def test_the_head_says_the_rows_that_the_recorder_lost_in_each_case(self):
        rows = [{"invalid": []}, {"invalid": ["no-row: 2 of the 9 frames have no row", "input: 1 key sent, 0 more tabs"]},
                {"invalid": ["refresh: the 4 rows come each 16.70 ms"]}, {"invalid": ["no-row: 1 frame", "refresh: slow"]}, {"invalid": ["engine: webkit"]}]
        self.assertEqual(frames_of.recorder_lost(rows), {"rows": 3, "of": 5, "not_known": 0, "no_row": 2, "refresh": 2})
        self.assertEqual(frames_of.recorder_lost([]), {"rows": 0, "of": 0, "not_known": 0, "no_row": 0, "refresh": 0})
        cases = {"cmd-t/idle": {"recorder_lost": frames_of.recorder_lost(rows)}, "cmd-w/idle": {"recorder_lost": frames_of.recorder_lost(rows[:1])}}
        self.assertEqual(frames_of.recorder_sentence(cases),
                         "rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): "
                         "cmd-t/idle 3 of 5 (no-row 2, refresh 2); cmd-w/idle 0 of 1")
        self.assertEqual(frames_of.recorder_sentence({}), "rows lost to the recorder: no case recorded")
        report, _ = self.run_mode(shown_app(self.folder), keys="t,w", close_cases="idle")
        self.assertEqual(report["cases"]["cmd-t/idle"]["recorder_lost"], {"rows": 0, "of": 1, "not_known": 0, "no_row": 0, "refresh": 0})
        self.assertIn("rows lost to the recorder (INVALID by `no-row` or `refresh`, a fault of the tool's yield): cmd-t/idle 0 of 1; cmd-w/idle 0 of 1",
                      report["head"])

    def test_the_cli_is_asked_one_time_for_each_key_and_its_fault_stops_nothing(self):
        asked = []

        def run(command, **how):
            asked.append((command, how.get("timeout"), how.get("env")))
            if command[1] == "config":
                return subprocess.CompletedProcess(command, 2, "", "unknown command config\n")
            if command[3] == "appearance.theme":
                raise subprocess.TimeoutExpired(command, 10)
            return subprocess.CompletedProcess(command, 0, '{"key": "x", "customized": true}\n', "")
        launched = {"cli": "/app/bin/cmux", "env": {"HOME": "/h"}, "tag": "t1"}
        lines = tool().cli_try(launched, ["ui.animationSpeed", "appearance.theme"], run=run)
        self.assertEqual([command for command, _, _ in asked], [
            ["/app/bin/cmux", "config", "get", "ui.animationSpeed", "--json"], ["/app/bin/cmux", "settings", "get", "ui.animationSpeed", "--json"],
            ["/app/bin/cmux", "config", "get", "appearance.theme", "--json"], ["/app/bin/cmux", "settings", "get", "appearance.theme", "--json"]])
        self.assertEqual({(limit, env.get("HOME")) for _, limit, env in asked}, {(10, "/h")})
        self.assertEqual(lines, ['the CLI, `settings get ui.animationSpeed`: exit 0: {"key": "x", "customized": true}',
                                 "the CLI, `settings get appearance.theme`: no answer in 10 s"])
        self.assertEqual(tool().cli_try(None, ["ui.animationSpeed"], run=run), ["the CLI: not asked (the driver did not launch this app)"])
        self.assertEqual(tool().cli_try({"cli": "/no/such/cmux", "env": {}, "tag": "t1"}, ["ui.animationSpeed"])[0].split(":")[0],
                         "the CLI, `settings get ui.animationSpeed`")

    def test_the_entrys_check_of_the_words_before_its_build(self):
        module = str(HERE.parent / "new_surface_look.py")
        good = subprocess.run([sys.executable, "-I", module, "--check", WORDS], capture_output=True, text=True, timeout=30, check=False)
        self.assertEqual((good.returncode, good.stdout.strip()), (0, "window look look-mine: 6 settings keys, 1 terminal line"))
        for words in ("ui.animationSpeed", "opacity=0.5,behind=stripes"):
            bad = subprocess.run([sys.executable, "-I", module, "--check", words], capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual((bad.returncode, "--window-look" in bad.stderr), (2, True), words)

    def test_through_the_driver_an_app_with_no_settings_answer_ends_the_run_before_the_ask_for_the_active_app(self):
        asked = ["--screen", "--runs", "1", "--keys", "t", "--gaps", "0", "--page-watch", "0", "--window-look", "ui.animationSpeed=fast,name=mine"]
        got = driver.outcome(str(HERE.parent), asked, bad=False, files=MODE, window=True)
        self.assertEqual((got["exit"], got["stderr"]), (3, []))
        self.assertEqual(got["stdout"][-1], "NEW-SURFACE-SCREEN report only: 0 rows, 0 INVALID, 0 pictures kept; STOPPED window look: "
                                            "ui.animationSpeed is None in the app's settings, not 'fast'; the app's motion speed is None, not "
                                            "'fast': no session made, no tab made, no case recorded")
        self.assertEqual([call for call in got["calls"] if '"debug.window.focus"' in call or '"frame_strip"' in call or '"debug.key"' in call], [])
        self.assertEqual(json.loads(got["report"])["settings"]["look"], "look-mine")

    def test_through_the_driver_a_refused_look_ends_before_a_call_to_the_app(self):
        got = driver.outcome(str(HERE.parent), ["--screen", "--window-look", "opacity=0.5,behind=checker"], bad=False, files=MODE)
        self.assertEqual((got["exit"], got["calls"]), (2, []))
        self.assertIn("this tool makes no panel behind its window", got["stderr"][-1])


if __name__ == "__main__":
    unittest.main()
