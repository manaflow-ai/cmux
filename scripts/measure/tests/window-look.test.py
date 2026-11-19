#!/usr/bin/env python3
"""scripts/cmux-next/window_look.py: the look of a measured window, from the option's words to what the running app
says it shows.

Run: python3 -I scripts/measure/tests/window-look.test.py
No app, no socket, no file of a real launch and no real clock: the app's answers are dictionaries, the config files
are a dictionary of texts, and the wait's clock is a counter. So this proves the module's own logic (the keys it
writes, the rows' name, what it takes as the look), NOT what the app draws for a key.
"""
import importlib.util
import itertools
import json
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True  # the module's load leaves no cache folder in the checkout
SPEC = importlib.util.spec_from_file_location("window_look_under_test", Path(__file__).resolve().parents[2] / "cmux-next" / "window_look.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class WindowLook(unittest.TestCase):
    """The option: the keys that the command line names, and no other key, written the ways the app reads them."""

    PICTURE = "background=test-picture,opacity=0.5,blur=frosted"

    def test_opaque_is_the_default_and_changes_nothing(self):
        # The launch, the config and each row's name stay as they were, so the old numbers compare.
        config = {"layout": {"minimumPaneWidth": 80}}
        for value in (None, "opaque"):
            look = M.window_look(value)
            self.assertIsNone(look)
            self.assertEqual(M.look_tag(look), "")
            self.assertIs(M.look_config(config, look), config)
            self.assertEqual(M.look_terminal_lines(look), [])

    def test_the_look_holds_each_named_key_and_no_other(self):
        self.assertEqual(M.window_look(self.PICTURE), {"background": "test-picture", "opacity": 0.5, "blur": "frosted"})
        self.assertEqual(M.window_look("opacity=0.25"), {"opacity": 0.25})
        self.assertEqual(M.window_look(" blur = glass-clear , terminal-opacity=0.5,terminal-blur=8,behind=checker"),
                         {"blur": "glass-clear", "terminal_opacity": 0.5, "terminal_blur": 8, "behind": "checker"})

    def test_the_app_config_gets_the_named_keys_and_keeps_the_rest(self):
        config = {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}}
        made = M.look_config(config, M.window_look(self.PICTURE))
        self.assertEqual(made, {"layout": {"minimumPaneWidth": 80},
                                "appearance": {"theme": "dark", "background": "test-picture", "backgroundOpacity": 0.5,
                                               "backgroundBlur": "frosted"}})
        self.assertEqual(config, {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark"}})

    def test_a_key_that_is_not_named_is_not_written(self):
        self.assertEqual(M.look_config({}, M.window_look("background=test-picture")), {"appearance": {"background": "test-picture"}})
        self.assertEqual(M.look_config({}, M.window_look("opacity=0.5")), {"appearance": {"backgroundOpacity": 0.5}})
        self.assertEqual(M.look_config({}, M.window_look("terminal-blur=8")), {})

    def test_no_terminal_line_is_written_unless_it_is_named(self):
        self.assertEqual(M.look_terminal_lines(M.window_look(self.PICTURE)), [])
        self.assertEqual(M.look_terminal_lines(M.window_look("terminal-opacity=0.5")), ["background-opacity = 0.5"])
        self.assertEqual(M.look_terminal_lines(M.window_look("terminal-blur=8,terminal-opacity=1")),
                         ["background-opacity = 1", "background-blur = 8"])

    def test_the_rows_name_says_each_named_value(self):
        self.assertEqual(M.look_tag(M.window_look(self.PICTURE)), "look-background-test-picture-opacity-0.5-blur-frosted")
        self.assertEqual(M.look_tag(M.window_look("terminal-blur=8,opacity=1,behind=stripes")),
                         "look-terminal-blur-8-opacity-1-over-stripes")

    def test_another_word_is_refused(self):
        for value in ("", "glass", "see-through", "opacity", "opacity=2", "opacity=-0.1", "opacity=nan", "blur=milk",
                      "terminal-blur=-1", "terminal-blur=2.5", "shade=1", "opacity=0.5,opacity=0.6", "behind=wall",
                      "behind=checker", "opaque,opacity=0.5", "opacity=0.5,", "background=", "background=A Picture",
                      "background=../picture", "opacity=unset"):
            with self.assertRaises(ValueError, msg=value):
                M.window_look(value)

    PATHS = "opacity=0.5,appearance.chromeStyle=card,ui.animationSpeed=off,appearance.metrics.titlebarHeight=40"

    def test_a_settings_path_is_a_key_of_the_look(self):
        # Any path of the app's settings, with the value as the settings file has it: a number, true or false, a word.
        self.assertEqual(M.window_look(self.PATHS + ",ui.paneAnimations=true,name=test-look"),
                         {"opacity": 0.5, "appearance.chromeStyle": "card", "ui.animationSpeed": "off",
                          "appearance.metrics.titlebarHeight": 40, "ui.paneAnimations": True, "name": "test-look"})
        self.assertEqual(M.window_look("ui.animationSpeed=off"), {"ui.animationSpeed": "off"})
        self.assertEqual(M.window_look("appearance.metrics.titlebarHeight=40.5,ui.x=false"),
                         {"appearance.metrics.titlebarHeight": 40.5, "ui.x": False})
        # A value of more than one word (a theme's name) is one text.
        self.assertEqual(M.window_look(" appearance.theme = Test Theme 2 ,opacity=0.5"), {"appearance.theme": "Test Theme 2", "opacity": 0.5})

    def test_the_app_config_gets_each_path_and_keeps_the_rest(self):
        config = {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark", "metrics": {"columnGap": 2}}}
        made = M.look_config(config, M.window_look(self.PATHS + ",name=test-look"))
        self.assertEqual(made, {"layout": {"minimumPaneWidth": 80},
                                "appearance": {"theme": "dark", "metrics": {"columnGap": 2, "titlebarHeight": 40},
                                               "backgroundOpacity": 0.5, "chromeStyle": "card"},
                                "ui": {"animationSpeed": "off"}})
        self.assertEqual(config, {"layout": {"minimumPaneWidth": 80}, "appearance": {"theme": "dark", "metrics": {"columnGap": 2}}})
        # The look's name is no settings key.
        self.assertEqual(M.look_config({}, M.window_look("ui.animationSpeed=off,name=test-look")), {"ui": {"animationSpeed": "off"}})
        self.assertEqual(M.look_paths(M.window_look("blur=frosted,terminal-blur=8,ui.animationSpeed=off,behind=stripes,name=test-look")),
                         {"appearance.backgroundBlur": "frosted", "ui.animationSpeed": "off"})

    def test_a_named_look_has_its_name_in_each_row_and_no_value(self):
        self.assertEqual(M.look_tag(M.window_look(self.PATHS + ",name=test-look")), "look-test-look")
        self.assertEqual(M.look_tag(M.window_look("opacity=0.5,name=test-look,behind=stripes")), "look-test-look-over-stripes")
        # With no name each value is in the row's name, a path by its last word and a value's space as a `-`.
        self.assertEqual(M.look_tag(M.window_look("opacity=0.5,ui.animationSpeed=off")), "look-opacity-0.5-animationSpeed-off")
        self.assertEqual(M.look_tag(M.window_look("appearance.theme=Test Theme")), "look-theme-Test-Theme")

    def test_a_path_or_a_name_of_another_form_is_refused(self):
        for value in ("name=test-look", "name=test-look,behind=stripes", "ui.animationSpeed=", ".animationSpeed=off",
                      "ui.=off", "ui..animationSpeed=off", "ui.animationSpeed=a/b", "ui.animationSpeed=../x",
                      "ui.animationSpeed='off'", "ui.animationSpeed=$(off)", "ui.animationSpeed=1e3x;y",
                      "ui.animationSpeed=off,ui.animationSpeed=fast", "opacity=0.5,name=", "opacity=0.5,name=Two Words",
                      "opacity=0.5,name=a,name=b", "ui.animation speed=off", "ui.x=1.2.3", "ui.x=-", "ui.x=1-2",
                      # One settings key two times: a short key and its own path, and a path under another path.
                      "opacity=0.5,appearance.backgroundOpacity=0.5", "appearance.background=test-picture,background=none",
                      "appearance.metrics=1,appearance.metrics.titlebarHeight=40"):
            with self.assertRaises(ValueError, msg=value):
                M.window_look(value)


class LookProblem(unittest.TestCase):
    """A run with a look does not go on as an opaque one: the launch's own config files must hold each named key."""

    ENV = {"CMUX_NEXT_CONFIG_FILE": "/scratch/cmux.json", "CMUX_NEXT_GHOSTTY_CONFIG": "/scratch/ghostty"}

    def problem(self, value, files, env=None):
        return M.look_problem(M.window_look(value), self.ENV if env is None else env, read=files.__getitem__)

    def test_an_opaque_window_reads_no_file(self):
        self.assertIsNone(self.problem("opaque", {}, env={}))

    def test_the_files_hold_the_named_keys(self):
        app = json.dumps({"layout": {}, "appearance": {"background": "test-picture", "backgroundOpacity": 0.5,
                                                       "backgroundBlur": "frosted"}})
        # No terminal line is named: the terminal config file is not read.
        self.assertIsNone(self.problem("background=test-picture,opacity=0.5,blur=frosted", {"/scratch/cmux.json": app}))
        files = {"/scratch/cmux.json": "{}", "/scratch/ghostty": "background-opacity = 0.5\nbackground-blur = 8\n"}
        self.assertIsNone(self.problem("terminal-opacity=0.5,terminal-blur=8", files))

    def test_a_missing_key_or_line_is_named(self):
        files = {"/scratch/cmux.json": json.dumps({"appearance": {"background": "other-picture", "backgroundOpacity": 0.5}}),
                 "/scratch/ghostty": "background-opacity = 0.5\n"}
        problem = self.problem("background=test-picture,opacity=0.5,terminal-opacity=0.5,terminal-blur=8", files)
        self.assertIn("background-blur = 8", problem)
        self.assertIn("'appearance.background'", problem)
        self.assertNotIn("backgroundOpacity", problem)
        self.assertNotIn("background-opacity = 0.5", problem)

    def test_each_settings_path_must_be_in_the_launchs_file(self):
        look = "opacity=0.5,appearance.chromeStyle=card,ui.animationSpeed=off,appearance.metrics.titlebarHeight=40,name=test-look"
        held = {"appearance": {"backgroundOpacity": 0.5, "chromeStyle": "card", "metrics": {"titlebarHeight": 40}},
                "ui": {"animationSpeed": "off"}}
        self.assertIsNone(self.problem(look, {"/scratch/cmux.json": json.dumps(held)}))
        other = {"appearance": {"backgroundOpacity": 0.5, "chromeStyle": "card", "metrics": {"titlebarHeight": 28}}}
        problem = self.problem(look, {"/scratch/cmux.json": json.dumps(other)})
        self.assertIn("'ui.animationSpeed'", problem)
        self.assertIn("'appearance.metrics.titlebarHeight'", problem)
        self.assertNotIn("chromeStyle", problem)
        self.assertNotIn("backgroundOpacity", problem)
        self.assertNotIn("name", problem)

    def test_a_file_that_is_not_there_is_a_problem(self):
        self.assertIn("not read", self.problem("opacity=0.5", {}))
        self.assertIn("not read", self.problem("opacity=0.5", {}, env={}))
        self.assertIn("not read", self.problem("terminal-blur=8", {"/scratch/cmux.json": "{}"}))


class LookResolved(unittest.TestCase):
    """The look is what the running app says that its window shows, not what a file says: the picture's id and the
    tint's alpha of `debug.themes`' backdrop, and the app's own settings answer for each named key."""

    LOOK = "background=test-picture,opacity=0.5,blur=frosted"
    BACKDROP = {"sheet": "", "tint": "#10203080", "glassTint": "", "picture": "test-picture", "blending": "false"}
    SETTINGS = {"background": "test-picture", "backgroundOpacity": 0.5, "backgroundBlur": "frosted"}

    def resolved(self, value, backdrop, settings, *more):
        return M.look_resolved(M.window_look(value), backdrop, settings, *more)

    PATHS = LOOK + ",appearance.chromeStyle=card,ui.animationSpeed=off,appearance.metrics.titlebarHeight=40,name=test-look"
    ROOT = {"appearance": {**SETTINGS, "chromeStyle": "card", "metrics": {"titlebarHeight": 40}},
            "ui": {"animationSpeed": "off"}, "layout": {"minimumPaneWidth": 80}}

    def test_each_settings_path_is_the_apps_own_answer(self):
        # `root`: the app's answer for its whole settings; `motion`: the motion's own answer, with the speed it runs at.
        resolved, problem = self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS, self.ROOT, {"speed": "off"})
        self.assertIsNone(problem)
        self.assertEqual(resolved["motion_speed"], "off")
        # Each setting that the app has, not only the look's: a reader sees what differs from a default.
        self.assertEqual(resolved["app_settings"],
                         {"appearance.background": "test-picture", "appearance.backgroundOpacity": 0.5,
                          "appearance.backgroundBlur": "frosted", "appearance.chromeStyle": "card",
                          "appearance.metrics.titlebarHeight": 40, "ui.animationSpeed": "off", "layout.minimumPaneWidth": 80})

    def test_a_path_that_the_app_did_not_take_fails(self):
        less = {**self.ROOT, "appearance": {**self.SETTINGS, "metrics": {"titlebarHeight": 28}}}
        problem = self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS, less, {"speed": "off"})[1]
        self.assertIn("appearance.chromeStyle is None in the app's settings, not 'card'", problem)
        self.assertIn("appearance.metrics.titlebarHeight is 28 in the app's settings, not 40", problem)
        self.assertNotIn("animationSpeed", problem)
        # The settings say the speed, and the motion runs at another one.
        self.assertEqual(self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS, self.ROOT, {"speed": "fast"})[1],
                         "the app's motion speed is 'fast', not 'off'")
        self.assertIn("the app's motion speed is None, not 'off'", self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS, self.ROOT, None)[1])
        # No answer for the whole settings: each path fails, and the report says that it has no list.
        resolved, problem = self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS, "unavailable", {"speed": "off"})
        self.assertIsNone(resolved["app_settings"])
        self.assertIn("ui.animationSpeed is None in the app's settings, not 'off'", problem)
        self.assertIsNone(self.resolved(self.PATHS, self.BACKDROP, self.SETTINGS)[0]["app_settings"])
        # A number is the same number as a whole one or with a point; true is not 1.
        self.assertIsNone(self.resolved("ui.x=40", {}, {}, {"ui": {"x": 40.0}}, None)[1])
        self.assertIn("ui.x is 1 in the app's settings, not True", self.resolved("ui.x=true", {}, {}, {"ui": {"x": 1}}, None)[1])

    def test_an_opaque_window_says_the_apps_settings_too(self):
        resolved, problem = self.resolved("opaque", {"sheet": "#102030FF", "tint": "", "picture": ""}, {},
                                          {"layout": {"minimumPaneWidth": 80}}, {"speed": "fast"})
        self.assertIsNone(problem)
        self.assertEqual((resolved["app_settings"], resolved["motion_speed"]), ({"layout.minimumPaneWidth": 80}, "fast"))

    def test_the_picture_at_the_named_opacity_passes(self):
        resolved, problem = self.resolved(self.LOOK, self.BACKDROP, self.SETTINGS)
        self.assertIsNone(problem)
        self.assertEqual((resolved["background"], resolved["picture"], resolved["blur"]), ("picture", "test-picture", "frosted"))
        self.assertAlmostEqual(resolved["opacity"], 128 / 255, places=3)
        self.assertFalse(resolved["glass"])

    def test_no_picture_or_another_picture_fails(self):
        resolved, problem = self.resolved(self.LOOK, {**self.BACKDROP, "picture": ""}, self.SETTINGS)
        self.assertEqual(resolved["background"], "none")
        self.assertIn("picture", problem)
        self.assertIn("other-picture", self.resolved(self.LOOK, {**self.BACKDROP, "picture": "other-picture"}, self.SETTINGS)[1])

    def test_another_opacity_fails(self):
        self.assertIn("opacity", self.resolved(self.LOOK, {**self.BACKDROP, "tint": "#102030C0"}, self.SETTINGS)[1])
        # An opaque window paints its sheet and shows no tint: its opacity is 1.
        resolved, problem = self.resolved(self.LOOK, {**self.BACKDROP, "tint": "", "sheet": "#102030FF"}, self.SETTINGS)
        self.assertEqual(resolved["opacity"], 1.0)
        self.assertIn("opacity", problem)

    def test_glass_carries_the_tint_itself(self):
        backdrop = {**self.BACKDROP, "tint": "", "glassTint": "#10203080"}
        resolved, problem = self.resolved("opacity=0.5,blur=glass", backdrop, {"backgroundOpacity": 0.5, "backgroundBlur": "glass"})
        self.assertIsNone(problem)
        self.assertTrue(resolved["glass"])

    def test_a_named_key_that_the_app_did_not_take_fails(self):
        problem = self.resolved(self.LOOK, self.BACKDROP, {**self.SETTINGS, "backgroundBlur": None})[1]
        self.assertIn("appearance.backgroundBlur", problem)
        self.assertNotIn("backgroundOpacity", problem)

    def test_no_picture_is_a_look_too(self):
        settings = {"background": "none", "backgroundOpacity": 0.5}
        self.assertIsNone(self.resolved("background=none,opacity=0.5", {**self.BACKDROP, "picture": ""}, settings)[1])
        self.assertIn("picture", self.resolved("background=none,opacity=0.5", self.BACKDROP, settings)[1])

    def test_an_opaque_window_is_read_and_never_fails(self):
        resolved, problem = self.resolved("opaque", {"sheet": "#102030FF", "tint": "", "picture": ""}, {})
        self.assertIsNone(problem)
        self.assertEqual((resolved["background"], resolved["opacity"]), ("none", 1.0))

    def test_a_backdrop_that_was_not_read_fails_a_look(self):
        for backdrop in (None, {}, {"error": "no window"}):
            resolved, problem = self.resolved(self.LOOK, backdrop, self.SETTINGS)
            self.assertIsNone(resolved["opacity"])
            self.assertIn("picture", problem)


class LookKind(unittest.TestCase):
    """The kind of the look that the app shows: one word for a name (a film's id), with no value of the option."""

    def kind(self, **backdrop):
        shown = {"sheet": "", "tint": "", "glassTint": "", "picture": "", "blending": "false", **backdrop}
        return M.look_kind(M.look_resolved(None, shown, {})[0])

    def test_a_window_that_shows_a_picture_is_a_picture(self):
        self.assertEqual(self.kind(picture="test-picture", tint="#10203080"), "picture")
        self.assertEqual(self.kind(picture="test-picture", glassTint="#10203080"), "picture")  # a picture under glass
        self.assertEqual(self.kind(picture="test-picture", sheet="#102030FF"), "picture")

    def test_glass_with_no_picture_is_glass(self):
        self.assertEqual(self.kind(glassTint="#10203080"), "glass")

    def test_a_tint_below_1_with_no_picture_and_no_glass_is_seethrough(self):
        self.assertEqual(self.kind(tint="#10203080"), "seethrough")
        self.assertEqual(self.kind(tint="#102030FE"), "seethrough")

    def test_a_sheet_or_a_full_tint_is_opaque(self):
        self.assertEqual(self.kind(sheet="#102030FF"), "opaque")
        self.assertEqual(self.kind(tint="#102030FF"), "opaque")

    def test_a_backdrop_that_was_not_read_has_no_kind(self):
        self.assertIsNone(M.look_kind(M.look_resolved(None, None, {})[0]))
        self.assertIsNone(M.look_kind(None))

    def test_the_kind_has_no_value_of_the_look(self):
        for kind in (self.kind(picture="test-picture", tint="#10203080"), self.kind(glassTint="#10203080"), self.kind(tint="#10203080")):
            self.assertRegex(kind, r"^[a-z]+$")


class ShownLook(unittest.TestCase):
    """The read of the running app: its settings answer one time, then its backdrop until it is the look, the tint
    blends no more, or the bound is over. The clock is a counter: 1 s for each read of it, and no sleep."""

    LOOK = "background=test-picture,opacity=0.5"
    SETTINGS = {"background": "test-picture", "backgroundOpacity": 0.5}
    SHOWN = {"sheet": "", "tint": "#10203080", "glassTint": "", "picture": "test-picture", "blending": "false"}

    READS = ["settings.get appearance", "settings.get", "debug.motion read", "debug.themes"]  # one read of the app

    def shown(self, value, backdrops, settings=None, seconds=10.0, more=None, motion=None, raises=()):
        """`shown_look` against an app that has each of `backdrops` in turn as its backdrop (the last one stays). The
        whole settings of the app are its `appearance` answer and `more`; `motion` is its motion answer; a call of
        `raises` raises."""
        calls, ticks, slept = [], itertools.count(), []

        def rpc(method, params=None):
            said = " ".join([method, *(str(word) for word in (params or {}).values())])
            calls.append(said)
            if said in raises:
                raise RuntimeError("a fake fault of the call")
            held = self.SETTINGS if settings is None else settings
            if said == "settings.get appearance":
                return {"path": ["appearance"], "exists": True, "value": held}
            if method == "settings.get":
                return {"path": [], "exists": True, "value": {"appearance": held, **(more or {})}}
            if method == "debug.motion":
                return {"speed": "fast", "pane_animations": True} if motion is None else motion
            reads = calls.count("debug.themes")
            return {"ghostty_background": "#102030", "windows": [{"backdrop": backdrops[min(reads, len(backdrops)) - 1]}]}

        facts, problem = M.shown_look(rpc, M.window_look(value), monotonic=lambda: float(next(ticks)), sleep=slept.append, seconds=seconds)
        return facts, problem, calls, slept

    def test_a_look_that_the_window_shows_at_the_first_read_is_read_one_time(self):
        facts, problem, calls, slept = self.shown(self.LOOK, [self.SHOWN])
        self.assertEqual((problem, calls, slept), (None, self.READS, []))
        self.assertEqual((facts["resolved"]["picture"], facts["backdrop_shown"], facts["terminal_background"]),
                         ("test-picture", self.SHOWN, "#102030"))

    def test_a_picture_that_loads_and_a_tint_that_blends_are_waited_for(self):
        loading, blending = {**self.SHOWN, "picture": ""}, {**self.SHOWN, "blending": "true"}
        facts, problem, calls, slept = self.shown(self.LOOK, [loading, blending, self.SHOWN])
        # The settings and the motion are read one time; only the backdrop is read again.
        self.assertEqual((problem, calls, slept), (None, self.READS + ["debug.themes", "debug.themes"], [0.5, 0.5]))

    PATHS = LOOK + ",ui.animationSpeed=off,appearance.metrics.titlebarHeight=40,name=test-look"
    HELD = {**SETTINGS, "metrics": {"titlebarHeight": 40}}

    def test_the_apps_whole_settings_and_its_motion_speed_are_read(self):
        facts, problem, calls, slept = self.shown(self.PATHS, [self.SHOWN], settings=self.HELD,
                                                  more={"ui": {"animationSpeed": "off"}, "layout": {"minimumPaneWidth": 80}},
                                                  motion={"speed": "off"})
        self.assertEqual((problem, calls, slept), (None, self.READS, []))
        self.assertEqual((facts["resolved"]["motion_speed"], facts["resolved"]["app_settings"]),
                         ("off", {"appearance.background": "test-picture", "appearance.backgroundOpacity": 0.5,
                                  "appearance.metrics.titlebarHeight": 40, "ui.animationSpeed": "off", "layout.minimumPaneWidth": 80}))

    def test_a_path_that_the_app_did_not_take_fails_and_the_settings_are_read_one_time(self):
        # The app holds no `ui` key, and its motion runs at its own speed.
        facts, problem, calls, slept = self.shown(self.PATHS, [self.SHOWN], settings=self.HELD, seconds=3.0)
        self.assertIn("ui.animationSpeed is None in the app's settings, not 'off'", problem)
        self.assertIn("the app's motion speed is 'fast', not 'off'", problem)
        self.assertEqual(calls.count("settings.get"), 1)

    def test_a_read_of_the_whole_settings_or_of_the_motion_that_fails_is_not_read(self):
        # An opaque window never fails: the report says that the list was not read.
        facts, problem, calls, slept = self.shown("opaque", [{"sheet": "#102030FF", "tint": "", "picture": ""}],
                                                  raises=("settings.get", "debug.motion read"))
        self.assertEqual((problem, facts["resolved"]["app_settings"], facts["resolved"]["motion_speed"]), (None, None, None))
        # A look of the short keys only needs neither read.
        self.assertIsNone(self.shown(self.LOOK, [self.SHOWN], raises=("settings.get", "debug.motion read"))[1])
        # An answer that is an error is no settings list.
        facts, problem, calls, slept = self.shown("opaque", [{"sheet": "#102030FF", "tint": "", "picture": ""}], motion={"error": "unknown method"})
        self.assertIsNone(facts["resolved"]["motion_speed"])

    def test_a_look_that_does_not_come_fails_after_the_bound(self):
        facts, problem, calls, slept = self.shown(self.LOOK, [{**self.SHOWN, "picture": ""}], seconds=3.0)
        self.assertIn("the window shows the picture '', not 'test-picture'", problem)
        self.assertEqual(facts["resolved"]["background"], "none")
        self.assertLess(len(slept), 6)  # the bound ends the reads: the clock gives 1 s for each read of it

    def test_an_opaque_window_is_read_one_time_and_never_fails(self):
        facts, problem, calls, slept = self.shown("opaque", [{"sheet": "#102030FF", "tint": "", "picture": "", "blending": "true"}], settings={})
        self.assertEqual((problem, calls, slept, facts["resolved"]["opacity"]), (None, self.READS, [], 1.0))

    def test_an_answer_that_is_no_settings_value_is_kept_as_not_read(self):
        facts, problem, calls, slept = self.shown(self.LOOK, [self.SHOWN], settings="no such path", seconds=2.0)
        self.assertIn("appearance.background is None in the app's settings", problem)
        self.assertEqual(list(facts["resolved"]["settings"]), ["not read"])


class LookHead(unittest.TestCase):
    """A report's first lines: each key that the launch wrote with the app's own answer beside it, each other
    setting that the app holds, and the speed that the motion runs at."""

    LOOK = "opacity=0.5,ui.animationSpeed=off,appearance.theme=Test Theme,name=test-look"

    def head(self, value, app_settings, speed):
        return M.look_head(M.window_look(value), {"resolved": {"app_settings": app_settings, "motion_speed": speed}})

    def test_each_key_of_the_look_has_the_apps_answer_beside_it(self):
        lines = self.head(self.LOOK, {"appearance.backgroundOpacity": 0.5, "appearance.theme": "Test Theme", "ui.animationSpeed": "fast",
                                      "layout.minimumPaneWidth": 80}, "fast")
        self.assertEqual(lines, ["window look test-look: appearance.backgroundOpacity: the launch wrote 0.5, the app answers 0.5",
                                 "window look test-look: ui.animationSpeed: the launch wrote 'off', the app answers 'fast' (NOT THE LOOK)",
                                 "window look test-look: appearance.theme: the launch wrote 'Test Theme', the app answers 'Test Theme'",
                                 "app setting, not of the look: layout.minimumPaneWidth = 80",
                                 "each other setting: not in the app's settings (the app's default)",
                                 "the app's motion speed: 'fast'"])

    def test_an_opaque_window_says_each_setting_that_the_app_holds(self):
        self.assertEqual(self.head("opaque", {"layout.minimumPaneWidth": 80}, "fast"),
                         ["app setting, not of the look: layout.minimumPaneWidth = 80",
                          "each other setting: not in the app's settings (the app's default)", "the app's motion speed: 'fast'"])

    def test_a_list_that_was_not_read_is_said(self):
        self.assertEqual(self.head("ui.animationSpeed=off", None, None),
                         ["window look: ui.animationSpeed: the launch wrote 'off', the app answers NOT READ",
                          "each other setting: NOT READ", "the app's motion speed: NOT READ"])


if __name__ == "__main__":
    unittest.main()
