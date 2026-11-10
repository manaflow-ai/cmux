#!/usr/bin/env python3
"""The nightly quality report (scripts/cmux-next/quality-report.py): Sentry's crash-free rate and crash issues,
hang-watch's issues as the fallback, the perf cron's interaction p95, the god-vs-small and animation coverage
slots, and the sticky issue's history. No network: Sentry and gh are fakes.
Run: python3 -I scripts/cmux-next/tests/test_quality_report.py (also runs in cmux-next-quality-report.yml)."""
import datetime, importlib.util, json, os, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("quality_report", os.path.join(HERE, "..", "quality-report.py"))
qr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qr)

T = datetime.datetime(2026, 11, 10, 9, 0, tzinfo=datetime.timezone.utc)
SINCE = T - datetime.timedelta(hours=24)


def hang_issue(number, sig, kind, headline, created, body_lines, comments=(), binary=None):
    title = f"hang-watch {sig}: {kind}{f' ({binary})' if binary else ''} in {headline}"
    body = f"hang-watch found {len(body_lines)} cmux {kind} report(s).\n\nReports:\n" + "\n".join(body_lines)
    return {"number": number, "title": title, "state": "OPEN", "createdAt": created,
            "url": f"https://github.com/manaflow-ai/cmuxterm-hq/issues/{number}", "body": body,
            "comments": [{"createdAt": at, "body": text} for at, text in comments]}


NIGHTLY_HANG = "- `/Users/x/Library/Logs/com.cmuxterm.app.nightly/hangs/hang-2026-11-10T00-26-44.335Z.txt`: 2026-11-10T00:26:44.335Z, for 391.819 s, build 1.0.0-nightly.42 (42) 85b0999"
OLD_HANG = "- `/Users/x/Library/Logs/com.cmuxterm.app.nightly/hangs/hang-2026-11-04T13-50-30.163Z.txt`: 2026-11-04T13:50:30.163Z, for 4.1 s, build 1.0.0-nightly.41"
DEV_HANG = "- `/Users/x/Library/Logs/com.cmuxterm.app.debug.lane/hangs/hang-2026-11-10T05-00-00.000Z.txt`: 2026-11-10T05:00:00.000Z, for 9 s (DEV)"
# A macOS report's local time with its offset: 2026-11-09 17:00 -0800 is 2026-11-10T01:00Z, inside the window.
IPS_CRASH = "- `/Users/x/Library/Logs/DiagnosticReports/cmux NIGHTLY-2026-11-09-170000.ips`: 2026-11-09 17:00:00.00 -0800, build 1.0.0-nightly.42, EXC_BAD_ACCESS"
# 2026-11-08 23:00 -0800 is 2026-11-09T07:00Z, before the window.
IPS_OLD = "- `/Users/x/Library/Logs/DiagnosticReports/cmux NIGHTLY-2026-11-08-230000.ips`: 2026-11-08 23:00:00.00 -0800, build 1.0.0-nightly.40"


class FakeSentry:
    def __init__(self, sessions=None, issues=None, fail=None):
        self.sessions, self.issues, self.fail, self.calls = sessions, issues or {}, fail, []

    def __call__(self, path, params):
        self.calls.append((path, params))
        if self.fail:
            raise qr.SourceError(self.fail)
        if path.endswith("/sessions/"):
            return self.sessions
        env = dict(params)["environment"]
        return self.issues.get(env, [])


class ParseTime(unittest.TestCase):
    def test_iso_z_file_name_and_offset(self):
        self.assertEqual(qr.parse_time("2026-11-10T00:26:44.335Z"), datetime.datetime(2026, 11, 10, 0, 26, 44, tzinfo=datetime.timezone.utc))
        self.assertEqual(qr.parse_time("hang-2026-11-10T00-26-44.335Z.txt"), datetime.datetime(2026, 11, 10, 0, 26, 44, tzinfo=datetime.timezone.utc))
        self.assertEqual(qr.parse_time("2026-11-09 17:00:00.00 -0800"), datetime.datetime(2026, 11, 10, 1, 0, tzinfo=datetime.timezone.utc))
        self.assertIsNone(qr.parse_time("no time here"))


class HangWatch(unittest.TestCase):
    def test_counts_reports_in_window_by_channel_new_and_returning(self):
        issues = [
            hang_issue(1, "aaaaaaaaaa", "hang", "cmux ProcessRunner.run ->", "2026-11-10T03:47:00Z", [NIGHTLY_HANG, OLD_HANG, DEV_HANG]),
            hang_issue(2, "bbbbbbbbbb", "crash", "cmux Foo.bar", "2026-11-01T00:00:00Z", [IPS_OLD],
                       comments=[("2026-11-10T02:00:00Z", "More reports: 1 on host.\n\n" + IPS_CRASH)]),
            hang_issue(3, "cccccccccc", "resource", "cmux sqlite3_wal_checkpoint_v2", "2026-11-10T03:00:00Z", [OLD_HANG],
                       binary="bin/cmux"),
            hang_issue(4, "dddddddddd", "hang", "cmux Came.back", "2026-11-02T00:00:00Z", [OLD_HANG],
                       comments=[("2026-11-10T04:00:00Z", "Came back after the close: 1 on host.\n\n" + NIGHTLY_HANG)]),
            {"number": 5, "title": "not a hang-watch issue", "createdAt": "2026-11-10T00:00:00Z", "body": NIGHTLY_HANG},
        ]
        got = qr.hang_watch_crashes(issues, SINCE)
        self.assertEqual(got["source"], "hang-watch")
        self.assertEqual(got["total"], 4)
        self.assertEqual(got["by_channel"], {"NIGHTLY": 3, "DEV": 1})
        self.assertEqual(got["by_kind"], {"hang": 3, "crash": 1})
        sigs = {s["id"]: s for s in got["signatures"]}
        self.assertNotIn("cccccccccc", sigs, "a signature with no report in the window is not counted")
        self.assertEqual(sigs["aaaaaaaaaa"]["counts"], {"NIGHTLY": 1, "DEV": 1})
        self.assertTrue(sigs["aaaaaaaaaa"]["new"])
        self.assertFalse(sigs["bbbbbbbbbb"]["new"])
        self.assertTrue(sigs["dddddddddd"]["came_back"])
        self.assertEqual((got["new_signatures"], got["returning_signatures"]), (1, 2))
        self.assertEqual(got["signatures"][0]["id"], "aaaaaaaaaa", "the most reports first")

    def test_gh_listing_searches_titles_in_the_window(self):
        seen = {}

        def run(cmd, **kw):
            seen["cmd"] = cmd
            return subprocess.CompletedProcess(cmd, 0, stdout="[]", stderr="")
        self.assertEqual(qr.gh_hang_watch_issues(SINCE, run=run), [])
        search = seen["cmd"][seen["cmd"].index("--search") + 1]
        self.assertIn('"hang-watch" in:title', search)
        self.assertIn("updated:>=2026-11-09T09:00:00Z", search)
        self.assertNotIn("--label", seen["cmd"], "triage replaces the hang-watch label; titles are what stays")

    def test_gh_failure_is_a_source_error(self):
        run = lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, stdout="", stderr="HTTP 404: Not Found")
        with self.assertRaises(qr.SourceError):
            qr.gh_hang_watch_issues(SINCE, run=run)


class Sentry(unittest.TestCase):
    SESSIONS = {"groups": [
        {"by": {"environment": "nightly-next"}, "totals": {"sum(session)": 900, "crash_free_rate(session)": 0.99}},
        {"by": {"environment": "dev"}, "totals": {"sum(session)": 100, "crash_free_rate(session)": 0.9}},
        {"by": {"environment": "production"}, "totals": {"sum(session)": 5000, "crash_free_rate(session)": 0.5}},
    ]}
    ISSUES = {
        "nightly-next": [{"shortId": "CMUX-1", "title": "EXC_BAD_ACCESS", "level": "fatal", "count": "7",
                          "firstSeen": "2026-11-10T01:00:00Z", "permalink": "https://sentry/1"},
                         {"shortId": "CMUX-2", "title": "App hang", "level": "error", "count": "3",
                          "firstSeen": "2026-10-01T00:00:00Z"}],
        "dev": [{"shortId": "CMUX-1", "title": "EXC_BAD_ACCESS", "level": "fatal", "count": "2",
                 "firstSeen": "2026-11-10T01:00:00Z"}],
    }

    def test_crash_free_rate_is_session_weighted_over_next_environments(self):
        got = qr.sentry_crash_free(FakeSentry(self.SESSIONS), 24)
        self.assertEqual(got["sessions"], 1000)
        self.assertAlmostEqual(got["value"], 0.981)
        self.assertNotIn("production", got["by_environment"], "the classic app's environments are not cmux NEXT")

    def test_report_prefers_sentry_and_splits_channels(self):
        fake = FakeSentry(self.SESSIONS, self.ISSUES)
        r = qr.build_report(24, T, None, None, None, None, sentry_getter=fake,
                            hang_watch=lambda since: self.fail("hang-watch is the fallback only"))
        self.assertEqual(r["crashes"]["source"], "sentry")
        self.assertEqual(r["crashes"]["total"], 12)
        self.assertEqual(r["crashes"]["by_channel"], {"NIGHTLY": 10, "DEV": 2})
        one = {s["id"]: s for s in r["crashes"]["signatures"]}
        self.assertEqual(one["CMUX-1"]["counts"], {"NIGHTLY": 7, "DEV": 2})
        self.assertTrue(one["CMUX-1"]["new"])
        self.assertFalse(one["CMUX-2"]["new"])
        query = dict(fake.calls[-1][1])["query"]
        self.assertIn("app:cmux-next", query)

    def test_refused_sentry_falls_back_to_hang_watch_and_says_why(self):
        issues = [hang_issue(1, "aaaaaaaaaa", "hang", "cmux X", "2026-11-10T03:47:00Z", [NIGHTLY_HANG])]
        r = qr.build_report(24, T, None, None, None, None,
                            sentry_getter=FakeSentry(fail="Sentry answered HTTP 403 for /organizations/manaflow/sessions/"),
                            hang_watch=lambda since: issues)
        self.assertIsNone(r["crash_free_session_rate"]["value"])
        self.assertIn("403", r["crash_free_session_rate"]["why"])
        self.assertEqual(r["crashes"]["source"], "hang-watch")
        self.assertIn("403", r["crashes"]["sentry_why"])
        self.assertIn("Sentry was not read", qr.render_markdown(r, public=True))

    def test_no_token_and_no_gh_leaves_both_null(self):
        def broken(since):
            raise qr.SourceError("gh could not list the hang-watch issues: no token")
        r = qr.build_report(24, T, None, None, None, None, hang_watch=broken)
        self.assertIsNone(r["crashes"]["total"])
        self.assertIn("no SENTRY_AUTH_TOKEN", r["crashes"]["why"])
        self.assertIn("n/a", qr.headline(r)["Crashes and hangs"])

    def test_http_error_names_the_scopes(self):
        import urllib.error

        def opener(req, timeout):
            raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, None)
        with self.assertRaisesRegex(qr.SourceError, "org:read and event:read"):
            qr.sentry_get("/organizations/manaflow/sessions/", [], "tok", opener=opener)


class Inputs(unittest.TestCase):
    STATE = {
        "last_good": {"sha": "a" * 40, "measured_at": "2026-10-23T14:54:03Z", "rows": {
            "webui.chat_switch.unread.latest@linux": {"p95": 52.8, "unit": "ms", "budget": 100},
            "webui.transcript_scroll.fling.react_ms@linux": {"p95": 54, "unit": "ms", "budget": 10},
            "webui.chat_switch.unread.idle_cpu_ms@linux": {"p95": 3.5, "unit": "ms", "budget": 5},
            "webui.transcript_replay.long.heap_mb@linux": {"p95": 46, "unit": "MB", "budget": 64},
            "diff.sidecar.manifest_decode_p95@linux": {"p95": 7, "unit": "us", "budget": 1000},
        }},
        "row_history": {"webui.chat_switch.unread.latest@linux": [
            {"at": "2026-11-01T00:00:00Z", "p95": 60, "sha": "b" * 40},
            {"at": "2026-11-09T05:54:54Z", "p95": 120, "sha": "c" * 40}]},
    }

    def test_interaction_rows_take_the_newest_history_value(self):
        got = qr.interaction_p95(self.STATE, None)
        self.assertEqual(sorted(got["rows"]), ["webui.chat_switch.unread.latest@linux", "webui.transcript_scroll.fling.react_ms@linux"])
        self.assertEqual(got["rows"]["webui.chat_switch.unread.latest@linux"]["p95"], 120)
        self.assertEqual(got["rows"]["webui.chat_switch.unread.latest@linux"]["sha"], "c" * 40)
        # 54/10 is further over budget than 120/100.
        self.assertEqual(got["over_budget"], ["webui.transcript_scroll.fling.react_ms@linux", "webui.chat_switch.unread.latest@linux"])
        self.assertEqual(got["worst_p95_ms"], 120)

    def test_god_vs_small_fails_over_the_limit(self):
        got = qr.god_vs_small({"rows": [{"name": "open", "small_p95": 100, "god_p95": 125},
                                        {"name": "switch", "small": 50, "god": 55},
                                        {"name": "scroll", "ratio": 1.21}]}, None)
        self.assertEqual(got["failing"], ["open", "scroll"])
        self.assertEqual(got["worst_ratio"], 1.25)
        self.assertEqual(qr.god_vs_small(None, "no input given")["why"], "no input given")

    def test_anim_coverage_shapes(self):
        self.assertEqual(qr.anim_coverage({"coverage": 0.875}, None)["value"], 0.875)
        self.assertEqual(qr.anim_coverage({"covered": 3, "total": 4}, None)["value"], 0.75)
        self.assertEqual(qr.anim_coverage({"coverage": 87.5}, None)["value"], 0.875)
        self.assertIsNone(qr.anim_coverage(None, "no input given")["value"])

    def test_missing_files_are_slots_not_failures(self):
        with tempfile.TemporaryDirectory() as d:
            r = qr.build_report(24, T, None, os.path.join(d, "none.json"), None, None,
                                hang_watch=lambda since: [])
        self.assertIn("does not exist", r["interaction_p95_ms"]["why"])
        self.assertEqual(r["god_vs_small"]["why"], "no input given")
        json.dumps(r)  # the metrics JSON is serializable


class Sticky(unittest.TestCase):
    def report(self, day, crashes):
        r = qr.build_report(24, T.replace(day=day), None, None, None, None,
                            hang_watch=lambda since: [hang_issue(1, "aaaaaaaaaa", "hang", "cmux X", "2026-11-01T00:00:00Z",
                                                                 [NIGHTLY_HANG.replace("2026-11-10", f"2026-11-{day:02d}")] * crashes)])
        return r

    def test_history_appends_one_row_per_night_and_replaces_the_same_night(self):
        first = qr.sticky_body(self.report(10, 2), "md", "")
        self.assertIn(qr.STICKY_MARK, first)
        again = qr.sticky_body(self.report(10, 3), "md", first)
        nxt = qr.sticky_body(self.report(11, 1), "md", again)
        history = json.loads(qr.HISTORY_RE.search(nxt).group(1))
        self.assertEqual([(h["at"], h["crashes"]) for h in history], [("2026-11-10", 3), ("2026-11-11", 1)])
        table = nxt.split("## Over time")[1]
        self.assertLess(table.index("2026-11-11"), table.index("2026-11-10"), "newest night first")

    def test_writes_only_its_own_issue(self):
        calls = []

        def run(cmd, **kw):
            calls.append((cmd, kw.get("input")))
            if cmd[2] == "list":
                listed = [{"number": 7, "title": qr.STICKY_TITLE, "body": "a person's issue, no marker"}]
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(listed), stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="https://github.com/o/r/issues/8\n", stderr="")
        qr.write_sticky(self.report(10, 1), "md", "o/r", run=run)
        self.assertEqual(calls[-1][0][2], "create", "an issue without the marker is never edited")
        self.assertIn(qr.STICKY_MARK, calls[-1][1])

    def test_public_markdown_names_no_signature(self):
        r = self.report(10, 1)
        self.assertNotIn("aaaaaaaaaa", qr.render_markdown(r, public=True))
        self.assertIn("aaaaaaaaaa", qr.render_markdown(r, public=False))


if __name__ == "__main__":
    unittest.main()
