#!/usr/bin/env python3
"""chromium_host_renderer_hang.py, the renderer hang row of chromium-host-bench.py --renderer-hang (p01-process-072),
against a fake app on a fake clock. An app with Chrome's semantics passes: the prompt in the hung tab only, after
the 15 s delay, gone while the tab is hidden, back a full delay after the show, and no host banner. An app that
prompts early, prompts in every tab, keeps the timer running while the tab is hidden, shows the prompt at once on
the show, or shows the host's banner fails the row; with the feature off the row says not_run.
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_renderer_hang.py"""
import os, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_renderer_hang as hang  # noqa: E402

APP_PID, HOST_PID = 100, 200
TITLES = {"renderer-hang.html": hang.HANG_TITLE, "renderer-hang-calm.html": hang.CALM_TITLE}


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def wait(self, check, seconds, step=0.5):
        deadline = self.now + seconds
        while self.now <= deadline:
            value = check()
            if value:
                return value
            self.now += step
        return None


class FakeApp:
    """Chromium's hang timer and cmux's prompt as the row sees them. `delay`: seconds from the hung input to the report;
    `everywhere`: every tab prompts; `runs_hidden`: the timer runs and prompts while the tab is hidden; `keeps_prompt`:
    a hidden tab's prompt is still up when it shows again; `banner`: the host's busy banner shows; `feature`: False
    reports no renderer_hangs."""

    def __init__(self, clock, delay=15.0, everywhere=False, runs_hidden=False, keeps_prompt=False, banner=False,
                 feature=True):
        self.clock = clock
        self.delay, self.everywhere, self.runs_hidden = delay, everywhere, runs_hidden
        self.keeps_prompt, self.banner, self.feature = keeps_prompt, banner, feature
        self.tabs = []  # [id, title]
        self.focused = None
        self.hung = None  # the hung tab's id once its input never returned
        self.timer_from = None
        self.prompting = self.gone = False

    def shown(self, tab):
        return tab == self.focused

    def tick(self):
        if self.hung is None or self.gone:
            return
        visible = self.shown(self.hung)
        if self.timer_from is not None and (visible or self.runs_hidden) and \
                self.clock.now - self.timer_from >= self.delay:
            self.prompting = True

    def title(self, tab):
        return next(title for id_, title in self.tabs if id_ == tab)

    # The bench's seams.
    def front(self):
        return APP_PID

    def windows(self, pid):
        return []

    def page_eval(self, script):
        return self.title(self.focused) if script == "document.title" and self.focused else None

    def focus(self, tab):
        was = self.focused
        self.focused = tab
        if was == self.hung and tab != self.hung and not self.runs_hidden:
            # WasHidden: the timer stops and the hang is taken back.
            self.timer_from = None
            if not self.keeps_prompt:
                self.prompting = False
        if tab == self.hung and was != self.hung and self.timer_from is None and not self.gone:
            self.timer_from = self.clock.now  # WasShown restarts the timer

    def rpc(self, method, params=None, timeout=30):
        params = params or {}
        self.tick()
        if method == "action.run" and params.get("action") == "openBrowser.chromium":
            tab = f"tab{len(self.tabs)}"
            self.tabs.append([tab, TITLES.get(os.path.basename(params["args"]["url"]), "")])
            self.focus(tab)
            return {"created": [tab]}
        if method == "action.run" and params.get("action") == "tab.focus":
            self.focus(params["target"].split(":", 1)[1])
            return {}
        if method == "debug.focus":
            return {"windows": [{"model": {"resolved_tab": self.focused},
                                 "topology": [{"tabs": [f"{t}:browser" for t, _ in self.tabs]}]}]}
        if method == "debug.mouse":
            if self.focused and self.title(self.focused) == hang.HANG_TITLE:
                self.hung, self.timer_from = self.focused, self.clock.now
            return {"delivered": 2}
        if method == "debug.cef":
            report = {"host_hang": {"banner": self.prompting}} if self.banner else {}
            if self.feature:
                report["renderer_hangs"] = [
                    {"browser": n, "title": title, "shown": self.shown(tab), "held": False,
                     "prompting": self.prompting and (tab == self.hung or self.everywhere)}
                    for n, (tab, title) in enumerate(self.tabs)]
            return report
        if method == "debug.browser.page_status":
            pressed = params.get("press") == "exit" and self.prompting and self.shown(self.hung)
            if pressed:
                self.prompting, self.gone = False, True
            return {"gone": "1" if self.gone and self.shown(self.hung) else "0",
                    "unresponsive": "1" if self.prompting else "0", "pressed": "1" if pressed else "0"}
        return {}


def run(**variant):
    clock = Clock()
    app = FakeApp(clock, **variant)
    with tempfile.TemporaryDirectory() as out:
        rows, ok = hang.run(app.rpc, clock.wait, app.page_eval, out, lambda: HOST_PID, app.front, app.windows,
                            clock=clock, sleep=clock.sleep)
    return rows["renderer_hang"], ok


class RendererHangRowTests(unittest.TestCase):
    def test_chromes_semantics_pass(self):
        row, ok = run()
        self.assertTrue(ok, row)
        self.assertGreaterEqual(row["show_ms"], hang.EARLIEST_S * 1000)
        self.assertGreaterEqual(row["reshow_ms"], hang.EARLIEST_S * 1000)
        self.assertEqual(row["prompting_tabs"], [hang.HANG_TITLE])
        self.assertIsNone(row["host_banner"], "a build with no host banner reports none")

    def test_a_prompt_before_the_delay_fails(self):
        row, ok = run(delay=2.0)
        self.assertFalse(ok)
        self.assertFalse(row["waited_for_delay"])

    def test_a_prompt_in_every_tab_fails(self):
        row, ok = run(everywhere=True)
        self.assertFalse(ok)
        self.assertFalse(row["that_tab_only"])

    def test_a_timer_that_runs_while_hidden_fails(self):
        row, ok = run(runs_hidden=True)
        self.assertFalse(ok)
        self.assertFalse(row["quiet_while_hidden"] and row["withdrawn"])

    def test_a_prompt_kept_through_the_hide_fails(self):
        row, ok = run(keeps_prompt=True)
        self.assertFalse(ok)
        self.assertFalse(row["withdrawn"])

    def test_the_host_banner_fails(self):
        row, ok = run(banner=True)
        self.assertFalse(ok)
        self.assertTrue(row["host_banner"])

    def test_feature_off_is_not_run(self):
        row, ok = run(feature=False)
        self.assertFalse(ok)
        self.assertIn("not_run", row)

    def test_a_row_that_raises_is_that_rows_failure(self):
        def broken(*args, **kwargs):
            raise RuntimeError("socket gone")
        rows, ok = hang.run(broken, lambda check, seconds: None, lambda script: None, "/nonexistent", lambda: HOST_PID,
                            lambda: APP_PID, lambda pid: [])
        self.assertFalse(ok)
        self.assertIn("socket gone", rows["renderer_hang"]["error"])


if __name__ == "__main__":
    unittest.main()
