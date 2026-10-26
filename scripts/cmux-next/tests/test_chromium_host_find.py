#!/usr/bin/env python3
"""chromium_host_find.py, the --find rows of chromium-host-bench.py (p01-process-048), against a fake app: the keys
the rows send (Cmd-F, the query a key at a time, Cmd-G, Cmd-Shift-G, Escape), the pill state they read (the oracle's
overlays.findBar) and the page scroll they wait for. A correct app passes every row; an app whose pill keeps a
result of an earlier, shorter query (the host-mode race the find id fixes), a pill that never steps, a page that
never scrolls and a build without the host backend each fail the row they break. Runs anywhere (no app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_find.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_find as find  # noqa: E402


def matches(query):
    """What Chromium counts for `query` on the probe page (case-insensitive substrings)."""
    text = "nine nectar needy needed needl needle neon needle needle needle"
    if not query:
        return 0
    count, start = 0, 0
    while (index := text.find(query, start)) != -1:
        count, start = count + 1, index + 1
    return count


class FakeApp:
    """The app as the rows see it. `stale` keeps the count of the query's first letter (a result of an earlier
    search answering the latest); `stuck` ignores Cmd-G; `no_scroll` keeps the page at the top."""

    def __init__(self, backend="host", stale=False, stuck=False, no_scroll=False):
        self.backend, self.stale, self.stuck, self.no_scroll = backend, stale, stuck, no_scroll
        self.open, self.query, self.selected = False, "", None
        self.keys = []

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            return {"backend": self.backend}
        if method == "action.run":
            return {"ok": True}
        if method == "debug.key":
            self.keys.append((params["key"], tuple(params.get("modifiers", ()))))
            self.press(params["key"], set(params.get("modifiers", ())))
            return {"ok": True}
        if method == "debug.oracle.snapshot":
            count = matches(self.query[:1] if self.stale else self.query)
            return {"overlays": {"findBar": {"open": self.open, "pane": "p", "querySha256": None, "matches": count,
                                             "selected": self.selected if count else None}}}
        raise AssertionError(f"unexpected method {method}")

    def press(self, key, modifiers):
        count = matches(self.query)
        if key == "f" and modifiers == {"cmd"}:
            self.open = True
        elif key == "g" and "cmd" in modifiers and not self.stuck and count:
            self.selected = (self.selected + (-1 if "shift" in modifiers else 1)) % count
        elif key == "escape":
            self.open = False
        elif self.open and not modifiers:
            self.query += key
            self.selected = 0

    def page_eval(self, script):
        if "readyState" in script:
            return True
        if "scrollY" in script:
            return 0 if self.no_scroll or self.selected != find.MATCHES - 1 else find.FAR_Y
        raise AssertionError(f"unexpected script {script}")


def instant(check, seconds, step=0.1):
    """The bench's wait() for a fake app that changes only on keys: one read."""
    return check() or None


def run(app):
    return find.run(app.rpc, instant, app.page_eval, "file:///find.html")


class FindRowsTest(unittest.TestCase):
    def test_the_probe_counts_more_for_every_prefix_of_the_query(self):
        for end in range(1, len(find.QUERY)):
            self.assertGreater(matches(find.QUERY[:end]), find.MATCHES, find.QUERY[:end])
        self.assertEqual(matches(find.QUERY), find.MATCHES)
        self.assertEqual(find.PAGE.count("needle"), find.MATCHES)

    def test_a_correct_app_passes_every_row(self):
        app = FakeApp()
        rows, ok = run(app)
        self.assertTrue(ok, rows)
        self.assertEqual(list(rows), list(find.ROWS))
        self.assertEqual(rows["count"]["find_bar"]["matches"], find.MATCHES)
        self.assertEqual([s["expected"] for s in rows["next"]["steps"]], [1, 2, 3])
        self.assertEqual(rows["previous"]["find_bar"]["selected"], find.MATCHES - 2)
        self.assertEqual(app.keys[0], ("f", ("cmd",)))
        self.assertEqual("".join(k for k, m in app.keys if not m and k != "escape"), find.QUERY)
        self.assertEqual(app.keys[-2:], [("g", ("cmd", "shift")), ("escape", ())])

    def test_a_stale_result_of_an_earlier_query_fails_the_count(self):
        rows, ok = run(FakeApp(stale=True))
        self.assertFalse(ok)
        self.assertFalse(rows["count"]["ok"])
        self.assertTrue(rows["open"]["ok"])

    def test_a_pill_that_never_steps_fails_next_and_previous(self):
        rows, ok = run(FakeApp(stuck=True))
        self.assertFalse(ok)
        self.assertTrue(rows["count"]["ok"])
        self.assertFalse(rows["next"]["ok"])
        self.assertFalse(rows["previous"]["ok"])

    def test_a_page_that_never_scrolls_to_the_active_match_fails_next(self):
        rows, ok = run(FakeApp(no_scroll=True))
        self.assertFalse(ok)
        self.assertFalse(rows["next"]["ok"])
        self.assertEqual(rows["next"]["scroll_y"], 0)

    def test_without_the_host_backend_no_row_runs(self):
        app = FakeApp(backend="inProcess")
        rows, ok = run(app)
        self.assertFalse(ok)
        self.assertEqual(set(rows), set(find.ROWS))
        self.assertTrue(all("not_run" in row for row in rows.values()))
        self.assertEqual(app.keys, [])


if __name__ == "__main__":
    unittest.main()
