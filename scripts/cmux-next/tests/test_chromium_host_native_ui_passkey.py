#!/usr/bin/env python3
"""The passkey row of chromium_host_native_ui.py (chromium-host-bench.py --native-ui, p01-process-067) against a fake
app's `debug.cef` `host_passkeys` counters. A GET that reaches the system sheet and ends with the page's abort or the
system's answer passes; a GET that cmux refuses, a page whose only request is a conditional LIST, and a LIST answered
during the page load before a refused GET each fail. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_native_ui_passkey.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_native_ui as native_ui  # noqa: E402


class FakeApp:
    """The relay as the row sees it. `on_load` and `on_get` are the counter changes the page load and the GET make;
    `on_abort` those the page's abort makes; `outcome` what the page's promise ends with."""

    def __init__(self, on_get, on_abort=None, on_load=None, outcome="AbortError", handler_set=1):
        self.counters = {"handler_set": handler_set, "permission": 2, "requests": 0, "creates": 0, "gets": 0, "lists": 0,
                         "cancels": 0, "sheets": 0, "answered": 0}
        self.on_get, self.on_abort, self.on_load, self.outcome = on_get, on_abort or {}, on_load or {}, outcome
        self.ended = False

    def add(self, changes):
        for key, value in changes.items():
            self.counters[key] = self.counters.get(key, 0) + value

    def rpc(self, method, params=None, timeout=60):
        if method == "debug.cef":
            return {"host_passkeys": dict(self.counters)}
        if method == "action.run":
            self.add(self.on_load)
            return {"ok": True}
        raise AssertionError(f"unexpected method {method}")

    def page_eval(self, script):
        if "readyState" in script:
            return True
        if script == native_ui.PASSKEY_GET:
            self.add(self.on_get)
            return True
        if "abort.abort()" in script:
            self.add(self.on_abort)
            self.ended = True
            return None
        if ".outcome" in script:
            return self.outcome if self.ended else None
        raise AssertionError(f"unexpected script {script}")


def instant(check, seconds, step=0.1):
    """The bench's wait() for a fake app that changes only on the row's own calls: one read."""
    return check() or None


def row(app):
    return native_ui.passkey_row(app.rpc, instant, app.page_eval)


GET = {"requests": 1, "gets": 1}
LIST_ANSWERED = {"requests": 1, "lists": 1, "answered": 1}


class PasskeyRowTest(unittest.TestCase):
    def test_a_get_through_the_sheet_ended_by_the_abort_passes(self):
        result = row(FakeApp(on_get={**GET, "sheets": 1}, on_abort={"cancels": 1}))
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["refused"], {})

    def test_a_get_the_system_answered_after_the_sheet_passes(self):
        result = row(FakeApp(on_get={**GET, "sheets": 1, "answered": 1}, outcome="NotAllowedError"))
        self.assertTrue(result["ok"], result)

    def test_a_list_answered_at_the_page_load_does_not_count(self):
        result = row(FakeApp(on_load=LIST_ANSWERED, on_get={**GET, "sheets": 1}, on_abort={"cancels": 1}))
        self.assertTrue(result["ok"], result)

    def test_a_refused_get_fails(self):
        result = row(FakeApp(on_get={**GET, "refused_notVisible": 1}, outcome="NotAllowedError"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["refused"], {"refused_notVisible": 1})

    def test_a_refusal_after_the_sheet_fails(self):
        result = row(FakeApp(on_get={**GET, "sheets": 1, "refused_clientDataMismatch": 1}, outcome="NotAllowedError"))
        self.assertFalse(result["ok"])

    def test_a_conditional_list_alone_fails(self):
        result = row(FakeApp(on_get=LIST_ANSWERED, on_abort={"cancels": 1}))
        self.assertFalse(result["ok"], result)

    def test_a_list_answered_beside_a_get_cancelled_before_its_sheet_fails(self):
        result = row(FakeApp(on_get={**GET, **LIST_ANSWERED, "requests": 2}, on_abort={"cancels": 1}))
        self.assertFalse(result["ok"], result)

    def test_without_the_handler_the_row_does_not_run(self):
        result = row(FakeApp(on_get=GET, handler_set=0))
        self.assertFalse(result["ok"])
        self.assertIn("not_run", result)


if __name__ == "__main__":
    unittest.main()
