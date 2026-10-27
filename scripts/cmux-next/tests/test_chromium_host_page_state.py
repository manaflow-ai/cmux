#!/usr/bin/env python3
"""chromium_host_page_state.py, the page_state row of chromium-host-bench.py --kill-host (p01-process-093), against a
fake app: the keys it types, the scroll it asks for, the host it kills and the page it reads after. An app that brings
the tab back with its page state passes; one that brings back only the address (scroll at the top, the field empty),
one that keeps the scroll but loses the typed text, one that never brings the tab back and a build without the host
backend each fail the row. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_page_state.py"""
import json, os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_page_state as page_state  # noqa: E402

URL = "file:///tmp/page-state.html"


class FakeApp:
    """The app as the row sees it. `keeps` names what a restored page gets back ("scroll", "form"); `comes_back`
    False leaves the crash page."""

    def __init__(self, backend="host", keeps=("scroll", "form"), comes_back=True):
        self.backend, self.keeps, self.comes_back = backend, set(keeps), comes_back
        self.host, self.next_host = 100, 101
        self.loaded, self.focused, self.y, self.value = False, False, 0, ""
        self.keys, self.killed, self.now = [], [], 0.0

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            assert params["action"] == "openBrowser.chromium" and params["args"]["url"] == URL
            self.loaded = True
            return {"ok": True}
        if method == "debug.key":
            assert params.get("target") == "page"
            self.keys.append(params["key"])
            if self.focused:
                self.value += params["key"]
            return {"ok": True}
        raise AssertionError(f"unexpected method {method}")

    def page_eval(self, script, tab):
        assert tab == "t1"
        if not self.loaded:
            return None
        if script.startswith("location.href ==="):
            return True
        if script == page_state.READ:
            return json.dumps({"y": self.y, "value": self.value})
        if "focus()" in script:
            self.focused = True
            return True
        if script.startswith("window.scrollTo("):
            self.y = int(script.split("(0, ")[1].split(")")[0])
            return True
        raise AssertionError(f"unexpected script {script}")

    def focused_eval(self, script):
        assert script == page_state.LOADED
        return (True, "t1") if self.loaded else (None, None)

    def host_pids(self):
        return [self.host] if self.host else []

    def kill(self, pid):
        self.killed.append(pid)
        self.host = self.next_host
        self.loaded = self.comes_back
        self.focused = False
        self.y = self.y if "scroll" in self.keeps else 0
        self.value = self.value if "form" in self.keeps else ""

    def wait(self, check, seconds, step=0.1):
        deadline = self.now + seconds
        while self.now <= deadline:
            value = check()
            if value:
                return value
            self.now += step
        return None

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def run(self):
        return page_state.run(self.rpc, self.wait, self.page_eval, self.focused_eval, URL, self.host_pids, self.kill,
                              self.clock, self.sleep)


class PageStateRowTests(unittest.TestCase):
    def test_a_tab_back_with_its_scroll_and_typed_text_passes(self):
        app = FakeApp()
        row, ran = app.run()
        self.assertTrue(ran)
        self.assertTrue(row["pass"], row)
        self.assertEqual(app.keys, list(page_state.TYPED), "the person's keys, one at a time")
        self.assertEqual(app.killed, [100])
        self.assertEqual(row["after"], {"y": page_state.SCROLL_Y, "value": page_state.TYPED})
        self.assertTrue(row["new_host"])

    def test_a_tab_back_at_its_address_only_fails(self):
        row, ran = FakeApp(keeps=()).run()
        self.assertTrue(ran)
        self.assertTrue(row["back"])
        self.assertFalse(row["scroll"] or row["form"])
        self.assertFalse(row["pass"])

    def test_lost_typed_text_fails(self):
        row, _ = FakeApp(keeps=("scroll",)).run()
        self.assertTrue(row["scroll"])
        self.assertFalse(row["form"])
        self.assertFalse(row["pass"])

    def test_a_tab_that_never_comes_back_fails(self):
        row, _ = FakeApp(comes_back=False).run()
        self.assertFalse(row["back"])
        self.assertIsNone(row["back_ms"])
        self.assertFalse(row["pass"])

    def test_no_host_backend_is_not_run(self):
        row, ran = FakeApp(backend="inproc").run()
        self.assertFalse(ran)
        self.assertIn("not_run", row)
        self.assertFalse(row["pass"])


if __name__ == "__main__":
    unittest.main()
