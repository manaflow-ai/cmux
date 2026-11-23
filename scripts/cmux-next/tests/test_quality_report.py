#!/usr/bin/env python3
"""The nightly quality report (scripts/cmux-next/quality-report.py): Sentry's crash-free rate and crash issues,
hang-watch's issues as the fallback, the perf cron's interaction p95, the god-vs-small and animation coverage
slots, and the sticky issue's history. No network: Sentry and gh are fakes.
Run: python3 -I scripts/cmux-next/tests/test_quality_report.py (also runs in cmux-next-quality-report.yml)."""
import base64, datetime, importlib.util, json, os, subprocess, tempfile, unittest, zlib
from unittest import mock

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


class ReviewFixes(unittest.TestCase):
    def test_sentry_errors_are_apart_from_crashes_and_hangs(self):
        issues = {"nightly-next": [
            {"shortId": "A", "title": "EXC_BAD_ACCESS", "level": "fatal", "count": "2", "firstSeen": "2026-11-10T01:00:00Z"},
            {"shortId": "B", "title": "App Hanging for at least 8000 ms.", "level": "error", "count": "3", "firstSeen": "2026-11-10T01:00:00Z"},
            {"shortId": "C", "title": "browser failure: renderer gone", "level": "error", "count": "9", "firstSeen": "2026-11-10T01:00:00Z"}]}
        got = qr.sentry_crashes(FakeSentry(issues=issues), 24, SINCE)
        self.assertEqual(got["total"], 5)
        self.assertEqual(got["by_kind"], {"crash": 2, "hang": 3})
        self.assertEqual(got["errors"], 9)
        self.assertEqual([s["id"] for s in got["error_signatures"]], ["C"])

    def test_sentry_list_follows_the_cursor(self):
        pages = [([{"id": 1}], '<https://sentry.io/api/0/x/?cursor=0:100:0>; rel="next"; results="true"'),
                 ([{"id": 2}], '<https://sentry.io/api/0/x/?cursor=0:200:0>; rel="next"; results="false"')]
        seen = []

        class Resp:
            def __init__(self, body, link):
                self.body, self.headers = body, {"Link": link}
            def read(self):
                return json.dumps(self.body).encode()
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False

        def opener(req, timeout):
            seen.append(req.full_url)
            return Resp(*pages[len(seen) - 1])
        self.assertEqual(qr.sentry_get("/x/", [("a", "b")], "tok", opener=opener), [{"id": 1}, {"id": 2}])
        self.assertIn("cursor=0%3A100%3A0", seen[1])

    def test_busy_issue_reads_its_window_comments(self):
        listed = [hang_issue(1, "aaaaaaaaaa", "hang", "cmux X", "2026-11-01T00:00:00Z", [OLD_HANG],
                             comments=[("2026-11-02T00:00:00Z", "More reports: 1.\n\n" + OLD_HANG)] * 100)]
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            if cmd[1] == "issue":
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps(listed), stderr="")
            line = json.dumps({"createdAt": "2026-11-10T04:00:00Z", "body": "More reports: 1.\n\n" + NIGHTLY_HANG})
            return subprocess.CompletedProcess(cmd, 0, stdout=line + "\n", stderr="")
        issues = qr.gh_hang_watch_issues(SINCE, run=run)
        self.assertIn("since=2026-11-09T09:00:00Z", calls[1][2])
        self.assertEqual(qr.hang_watch_crashes(issues, SINCE)["total"], 1)

    def test_regressed_row_shows_its_newest_value(self):
        state = {"last_good": {"measured_at": "2026-10-23T00:00:00Z", "rows": {
                     "webui.chat_open.latest@l": {"p95": 100, "unit": "ms", "budget": 1000}}},
                 "row_history": {"webui.chat_open.latest@l": [{"at": "2026-11-01T00:00:00Z", "p95": 110}]},
                 "regressions": [{"name": "webui.chat_open.latest@l", "p95": 1500, "unit": "ms",
                                  "first_bad": {"measured_at": "2026-11-09T00:00:00Z", "sha": "d" * 40}}],
                 "unconfirmed": [{"name": "webui.new_row.latest@l", "p95": 30, "unit": "ms", "at": "2026-11-09T05:00:00Z"}]}
        got = qr.interaction_p95(state, None)
        self.assertEqual(got["rows"]["webui.chat_open.latest@l"]["p95"], 1500)
        self.assertEqual(got["over_budget"], ["webui.chat_open.latest@l"])
        self.assertEqual(got["held"], ["webui.chat_open.latest@l", "webui.new_row.latest@l"])
        self.assertEqual(got["newest_at"], "2026-11-09T05:00:00Z")

    def test_public_json_names_no_signature(self):
        r = qr.build_report(24, T, None, None, None, None,
                            hang_watch=lambda since: [hang_issue(1, "aaaaaaaaaa", "hang", "cmux Secret.frame", "2026-11-10T03:00:00Z", [NIGHTLY_HANG])])
        text = json.dumps(qr.public_report(r))
        self.assertNotIn("aaaaaaaaaa", text)
        self.assertNotIn("Secret.frame", text)
        self.assertNotIn("cmuxterm-hq/issues", text)
        self.assertEqual(qr.public_report(r)["crashes"]["total"], 1)


class FixForward(unittest.TestCase):
    def test_and_n_more_counts_at_the_post_time(self):
        comment = "More reports: 23 on host.\n\n" + "\n".join([NIGHTLY_HANG] * 20) + "\n- and 3 more\n"
        issue = hang_issue(1, "aaaaaaaaaa", "hang", "cmux X", "2026-11-01T00:00:00Z", [OLD_HANG],
                           comments=[("2026-11-10T04:00:00Z", comment)])
        got = qr.hang_watch_crashes([issue], SINCE)
        self.assertEqual(got["by_channel"], {"NIGHTLY": 23})

    def test_a_sibling_signature_is_its_own(self):
        sibling = ("Another signature of this stall (different callers). hang-watch found 1 cmux hang report(s) with "
                   "signature `bbbbbbbbbb` on host.\n\nReports:\n" + DEV_HANG)
        issue = hang_issue(1, "aaaaaaaaaa", "hang", "cmux X", "2026-11-01T00:00:00Z", [NIGHTLY_HANG],
                           comments=[("2026-11-10T05:00:00Z", sibling)])
        sigs = {s["id"]: s for s in qr.hang_watch_crashes([issue], SINCE)["signatures"]}
        self.assertEqual(sigs["aaaaaaaaaa"]["counts"], {"NIGHTLY": 1})
        self.assertEqual(sigs["bbbbbbbbbb"]["counts"], {"DEV": 1})
        self.assertTrue(sigs["bbbbbbbbbb"]["new"])

    def test_undated_held_reports_are_not_counted(self):
        body = ("Reports:\n" + NIGHTLY_HANG + "\n\nEarlier reports of this signature, held until it recurred:\n"
                "- `/Users/x/Library/Logs/DiagnosticReports/cmux.spin`: build 1.0.0-nightly.40\n")
        issue = {"number": 1, "title": "hang-watch aaaaaaaaaa: hang in cmux X", "createdAt": "2026-11-10T03:00:00Z",
                 "url": "u", "body": body, "comments": []}
        self.assertEqual(qr.hang_watch_crashes([issue], SINCE)["total"], 1)

    def test_sessions_refused_still_counts_sentry_crashes(self):
        issues = {"nightly-next": [{"shortId": "A", "title": "EXC_BAD_ACCESS", "level": "fatal", "count": "2",
                                    "firstSeen": "2026-11-10T01:00:00Z"}]}
        fake = FakeSentry(issues=issues)

        def get(path, params):
            if path.endswith("/sessions/"):
                raise qr.SourceError("Sentry answered HTTP 403 for sessions")
            return fake(path, params)
        r = qr.build_report(24, T, None, None, None, None, sentry_getter=get,
                            hang_watch=lambda since: self.fail("Sentry's issues answered"))
        self.assertIn("403", r["crash_free_session_rate"]["why"])
        self.assertEqual((r["crashes"]["source"], r["crashes"]["total"]), ("sentry", 2))
        self.assertIn("!is:resolved", dict(fake.calls[-1][1])["query"])

    def test_public_outputs_carry_no_session_counts(self):
        r = qr.build_report(24, T, None, None, None, None, sentry_getter=FakeSentry(Sentry.SESSIONS, Sentry.ISSUES),
                            hang_watch=lambda since: [])
        pub = qr.public_report(r)
        self.assertNotIn("sessions", pub["crash_free_session_rate"])
        self.assertNotIn("sessions", json.dumps(pub["crash_free_session_rate"]["by_environment"]))
        self.assertNotIn(" of 1000", qr.render_markdown(r, public=True))
        self.assertIn(" of 1000", qr.render_markdown(r, public=False))


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

    def test_god_vs_small_uses_home_status_for_v2_rows(self):
        got = qr.god_vs_small({"rows": [
            {"name": "bounded-ok", "small_p95": 10, "god_p95": 30, "status": "ok"},
            {"name": "god-max-red", "small_p95": 10, "god_p95": 10, "status": "red",
             "reason": "god p95 exceeds absolute maximum"},
            {"name": "degenerate", "small_p95": 10, "god_p95": 13},
        ]}, None)
        self.assertEqual(got["failing"], ["god-max-red", "degenerate"])

    def test_god_vs_small_keeps_skipped_rows_in_markdown(self):
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [])
        r["god_vs_small"] = qr.god_vs_small({"rows": [
            {"name": "v2.pr01.measure", "status": "skipped", "reason": "PR 1 not landed"},
            {"name": "v2.pr02.measure", "status": "ok", "small_p95": 10, "god_p95": 11},
            {"name": "v2.pr03.measure", "status": "red", "small_p95": 10, "god_p95": 13},
        ]}, None)
        self.assertEqual([row["status"] for row in r["god_vs_small"]["rows"]], ["skipped", "ok", "red"])
        encoded = json.dumps(r["god_vs_small"])
        for name in ("v2.pr01.measure", "v2.pr02.measure", "v2.pr03.measure"):
            self.assertIn(name, encoded)
        md = qr.render_markdown(r, public=False)
        self.assertIn("v2.pr01.measure", md)
        self.assertIn("v2.pr03.measure", md)
        self.assertIn("PR 1 not landed", md)

    def test_god_vs_small_keeps_failed_rows_in_markdown(self):
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [])
        r["god_vs_small"] = qr.god_vs_small({"rows": [
            {"name": "v2.pr01.measure", "status": "failed", "reason": "the gate did not report a measure"},
        ]}, None)
        md = qr.render_markdown(r, public=False)
        self.assertIn("v2.pr01.measure", md)
        self.assertIn("the gate did not report a measure", md)

    def test_god_vs_small_lists_the_homes_errors(self):
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [])
        r["god_vs_small"] = qr.god_vs_small({"rows": [
            {"name": "v2.pr01.measure", "small_p95": 100, "god_p95": 110},
        ], "errors": ["unknown v2 gate row v2.pr99.renamed", 7]}, None)
        self.assertEqual(r["god_vs_small"]["errors"], ["unknown v2 gate row v2.pr99.renamed"])
        for public in (False, True):
            self.assertIn("unknown v2 gate row v2.pr99.renamed", qr.render_markdown(r, public=public))
        self.assertEqual(qr.god_vs_small(None, "no input given")["errors"], [])
        no_rows = qr.god_vs_small({"errors": ["unknown v2 gate row v2.x"]}, None)
        self.assertEqual(no_rows["errors"], ["unknown v2 gate row v2.x"])

    def test_merge_god_small_keeps_rows_and_errors_of_every_input(self):
        """The nightly workflow merges the v2 home's input and the degenerate lab's with merge-god-small; the home's
        `errors` reached the report only through its last stderr line before."""
        with tempfile.TemporaryDirectory() as d:
            home, lab, out = (os.path.join(d, name) for name in ("v2.json", "lab.json", "god-small.json"))
            with open(home, "w") as f:
                json.dump({"rows": [{"name": "v2.a", "small_p95": 1, "god_p95": 1}],
                           "errors": ["unknown v2 gate row v2.b"]}, f)
            with open(lab, "w") as f:
                json.dump([{"name": "lab.c", "small_p95": 2, "god_p95": 2}], f)
            self.assertEqual(qr.main(["merge-god-small", "--out", out, home, lab]), 0)
            with open(out) as f:
                merged = json.load(f)
        self.assertEqual([row["name"] for row in merged["rows"]], ["v2.a", "lab.c"])
        self.assertEqual(merged["errors"], ["unknown v2 gate row v2.b"])
        self.assertEqual(qr.god_vs_small(merged, None)["errors"], ["unknown v2 gate row v2.b"])

    def test_the_workflow_merges_through_merge_god_small(self):
        path = os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-quality-report.yml")
        with open(path) as f:
            workflow = f.read()
        self.assertIn('quality-report.py merge-god-small --out "$out/god-small.json" "${god_inputs[@]}"', workflow)
        self.assertNotIn('json.dump({"rows": rows}', workflow)

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

    def test_done_today_requires_a_written_home_row(self):
        missing = self.report(9, 1)
        self.assertFalse(qr.sticky_done_today(qr.sticky_body(missing, "md", ""), "2026-11-10"))
        good = self.report(10, 1)
        good["v2_home"] = {"status": "wrote", "exit": 0, "error": None, "why": None}
        self.assertTrue(qr.sticky_done_today(qr.sticky_body(good, "md", ""), "2026-11-10"))
        bad = self.report(10, 1)
        bad["v2_home"] = {"status": "no report", "exit": 124, "error": "ran past 17 minutes", "why": None}
        self.assertFalse(qr.sticky_done_today(qr.sticky_body(bad, "md", ""), "2026-11-10"))

    def test_write_sticky_keeps_good_day_against_bad_run(self):
        good = self.report(10, 1)
        good["v2_home"] = {"status": "wrote", "exit": 0, "error": None, "why": None}
        old_body = qr.sticky_body(good, "good", "")
        bad = self.report(10, 2)
        bad["v2_home"] = {"status": "no report", "exit": 124, "error": "ran past 17 minutes", "why": None}
        calls = []

        def run(cmd, **kw):
            calls.append((cmd, kw.get("input")))
            if cmd[2] == "list":
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([{"number": 7, "title": qr.STICKY_TITLE,
                                                                                "body": old_body}]), stderr="")
            raise AssertionError("a good sticky row must not be edited by a bad run")

        with mock.patch("sys.stdout", new_callable=__import__("io").StringIO) as output:
            self.assertEqual(qr.write_sticky(bad, "bad", "o/r", run=run), "#7")
        self.assertEqual(len(calls), 1)
        self.assertIn("kept", output.getvalue())
        self.assertTrue(qr.sticky_done_today(old_body, "2026-11-10"))

    def test_write_sticky_replaces_bad_day_with_good_run(self):
        bad = self.report(10, 1)
        bad["v2_home"] = {"status": "no report", "exit": 124, "error": "ran past 17 minutes", "why": None}
        old_body = qr.sticky_body(bad, "bad", "")
        good = self.report(10, 2)
        good["v2_home"] = {"status": "wrote", "exit": 0, "error": None, "why": None}
        calls = []

        def run(cmd, **kw):
            calls.append((cmd, kw.get("input")))
            if cmd[2] == "list":
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([{"number": 7, "title": qr.STICKY_TITLE,
                                                                                "body": old_body}]), stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        self.assertEqual(qr.write_sticky(good, "good", "o/r", run=run), "#7")
        self.assertEqual(calls[-1][0][2], "edit")
        self.assertTrue(qr.sticky_done_today(calls[-1][1], "2026-11-10"))


class V2Home(unittest.TestCase):
    """hq#11702: a gate home that writes nothing is the report's first line and the night's history row."""
    # Nightly quality report run 43783944322 (2026-11-16 01:03Z): the home exited 2 before it wrote anything.
    STDERR = ("   Compiling acpmux v0.1.0\n"
              'v2 bench: "/home/runner/_work/_temp/quality/v2-measures.ndjson": '
              "v2.pr08.mirror_local_row_thirty has no numeric small_p95\n")

    def report(self, state, day=10):
        return qr.build_report(24, T.replace(day=day), None, None, None, None, hang_watch=lambda since: [],
                               v2_home_state=state)

    def test_a_home_that_writes_nothing_is_the_first_line(self):
        with tempfile.TemporaryDirectory() as d:
            state = qr.v2_home(2, self.STDERR, os.path.join(d, "v2-god-small.json"))
        self.assertEqual(state["status"], "no report")
        self.assertIn("mirror_local_row_thirty has no numeric small_p95", state["error"])
        self.assertTrue(state["error"].startswith("v2 bench:"), "the home's own line, not cargo's")
        r = self.report(state)
        for public in (False, True):
            md = qr.render_markdown(r, public=public)
            first = md.split("\n")[2]
            self.assertTrue(first.startswith("**v2 gates: no report.**"), md)
            self.assertIn("mirror_local_row_thirty has no numeric small_p95", first)
            self.assertLess(md.index("v2 gates: no report"), md.index("| Metric |"))
        self.assertIn("no report (exit 2", qr.headline(r)["v2 gate home"])
        body = qr.sticky_body(r, qr.render_markdown(r, public=False), "")
        history = json.loads(qr.HISTORY_RE.search(body).group(1))
        self.assertEqual(history[-1]["v2_home"], "no report")
        self.assertIn("(v2 home: no report)", body.split("## Over time")[1])

    def test_a_home_that_writes_has_no_first_line(self):
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "v2-god-small.json")
            with open(out, "w") as f:
                f.write('{"rows": []}')
            state = qr.v2_home(0, "", out)
            wrote_nonzero = qr.v2_home(1, "v2 bench: row x failed\n", out)
        self.assertEqual(state["status"], "wrote")
        r = self.report(state)
        md = qr.render_markdown(r, public=False)
        self.assertNotIn("v2 gates:", md)
        self.assertEqual(qr.headline(r)["v2 gate home"], "wrote")
        self.assertEqual(json.loads(qr.HISTORY_RE.search(qr.sticky_body(r, md, "")).group(1))[-1]["v2_home"], "wrote")
        self.assertEqual(wrote_nonzero["status"], "exited 1")
        self.assertIn("**v2 gates: the gate home exited 1**", qr.render_markdown(self.report(wrote_nonzero), public=False))

    def test_exit_zero_with_no_output_is_still_no_report(self):
        with tempfile.TemporaryDirectory() as d:
            state = qr.v2_home(0, "", os.path.join(d, "missing.json"))
        self.assertEqual((state["status"], state["error"]), ("no report", "it printed no error"))

    def test_a_home_killed_by_its_timeout_reads_unfinished(self):
        state = qr.v2_home(qr.V2_HOME_UNFINISHED, "running 40 rows\n", None)
        self.assertEqual(state["status"], "no report")
        self.assertIn("did not finish", state["error"])
        self.assertIn("running 40 rows", state["error"])

    def test_a_home_cut_by_its_timeout_names_the_limit(self):
        state = qr.v2_home(124, "Compiling acpmux v0.1.0\n", None, seconds=1020, limit=1020)
        self.assertEqual(state["status"], "no report")
        self.assertIn("ran past 17 minutes", state["error"])

    def test_home_seconds_and_limit_are_in_metrics_and_first_lines(self):
        with tempfile.TemporaryDirectory() as d:
            output = os.path.join(d, "v2-god-small.json")
            with open(output, "w") as f:
                f.write('{"rows": []}')
            state = qr.v2_home(0, "", output, seconds=800, limit=1020)
        self.assertEqual((state["seconds"], state["limit"]), (800, 1020))
        r = self.report(state)
        self.assertEqual((r["v2_home"]["seconds"], r["v2_home"]["limit"]), (800, 1020))
        self.assertIn("over 70% of the 17-minute limit", qr.render_markdown(r, public=False))

    def test_a_long_error_is_cut_and_no_run_is_no_line(self):
        state = qr.v2_home(2, "v2 bench: " + "x" * 1000, None)
        self.assertEqual(len(state["error"]), qr.V2_HOME_ERROR_MAX)
        r = self.report(None)
        self.assertIsNone(r["v2_home"]["status"])
        self.assertNotIn("v2 gates:", qr.render_markdown(r, public=False))
        self.assertIsNone(qr.history_row(r)["v2_home"])

    def test_main_reads_the_three_flags(self):
        with tempfile.TemporaryDirectory() as d:
            err = os.path.join(d, "v2-home.stderr")
            with open(err, "w") as f:
                f.write(self.STDERR)
            out_json, out_md = os.path.join(d, "r.json"), os.path.join(d, "r.md")
            # No gh on PATH: the hang-watch read fails as a source error, with no network.
            with mock.patch.dict(os.environ, {"PATH": d, "SENTRY_AUTH_TOKEN": ""}):
                code = qr.main(["report", "--json", out_json, "--md", out_md, "--v2-home-exit", "2",
                                "--v2-home-stderr", err, "--v2-home-output", os.path.join(d, "v2-god-small.json"),
                                "--v2-home-seconds", "800", "--v2-home-limit", "1020"])
            self.assertEqual(code, 0)
            with open(out_md) as f:
                self.assertIn("**v2 gates: no report.**", f.read())
            with open(out_json) as f:
                report = json.load(f)
                self.assertEqual(report["v2_home"]["exit"], 2)
                self.assertEqual(report["v2_home"]["seconds"], 800)


class WorkflowRepair(unittest.TestCase):
    def test_home_uses_gate_timeout_and_sticky_done_check(self):
        path = os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-quality-report.yml")
        with open(path) as f:
            workflow = f.read()
        self.assertIn("cargo bench --profile gate -p acpmux --bench v2", workflow)
        self.assertNotIn("cargo bench -q -p acpmux --bench v2", workflow)
        self.assertIn("timeout --signal=TERM", workflow)
        self.assertIn("v2-home.seconds", workflow)
        self.assertIn("done-today", workflow)
        self.assertNotIn("actions/cache/restore", workflow)
        self.assertNotIn("actions/cache/save", workflow)

    def test_cargo_steps_before_the_home_end_inside_their_step_limit(self):
        # Nov 19: a continue-on-error cargo step ahead of the home hit its timeout-minutes; the CI runner signalled
        # only the step's shell, a cargo it left behind held the shared target directory's lock, and the home waited
        # out its 17 minutes on "Blocking waiting for file lock". Every such step must run its cargo under
        # `timeout`, which ends the whole process group, with the limit and kill grace inside timeout-minutes.
        root = os.path.join(HERE, "..", "..", "..")
        steps = workflow_steps(os.path.join(root, ".github", "workflows", "cmux-next-quality-report.yml"))
        home = next(i for i, step in enumerate(steps) if step["keys"].get("id") == "v2-home")
        home_dir = steps[home]["keys"].get("working-directory")
        checked = []
        for step in steps[:home]:
            keys = step["keys"]
            if keys.get("continue-on-error") != "true" or keys.get("working-directory") != home_dir:
                continue
            cargo_lines = [line for line in step["run"] if runs_cargo(line, root, home_dir)]
            if not cargo_lines:
                continue
            name = keys.get("name")
            checked.append(name)
            self.assertIn("timeout-minutes", keys, f"{name}: a cargo step ahead of the home needs timeout-minutes")
            step_limit = int(keys["timeout-minutes"]) * 60
            for line in cargo_lines:
                bound = timeout_bound(line)
                self.assertIsNotNone(bound, f"{name}: not wrapped in timeout: {line}")
                self.assertLess(bound, step_limit, f"{name}: timeout plus kill grace {bound} s is not under {step_limit} s")
        self.assertIn("Run v2 gate measures", checked)

    def test_the_gate_step_and_the_job_leave_a_slow_night_room(self):
        # The gate step has taken 54 to 60 minutes on this job's runner, and one night finished at 57m27s. A limit
        # under that cuts a run that would have finished, the home reports missing measures and the last step fails
        # the job. The job's own limit must also hold every bounded step at its limit, or the job is cut first.
        path = os.path.join(HERE, "..", "..", "..", ".github", "workflows", "cmux-next-quality-report.yml")
        steps = workflow_steps(path)
        gate = next(step for step in steps if step["keys"].get("name") == "Run v2 gate measures")
        limits = [timeout_parts(line)[0] for line in gate["run"] if timeout_parts(line) is not None]
        self.assertEqual(len(limits), 1)
        self.assertGreaterEqual(limits[0], 75 * 60, "the gate script's limit leaves under 15 minutes over a 60-minute run")
        with open(path, encoding="utf-8") as f:
            job = [line.split(":", 1)[1] for line in f.read().splitlines() if line.startswith("    timeout-minutes:")]
        self.assertEqual(len(job), 1)
        bounded = sum(int(step["keys"]["timeout-minutes"]) for step in steps if "timeout-minutes" in step["keys"])
        self.assertGreaterEqual(int(job[0]), bounded, f"the job's limit is under its steps' limits ({bounded} min)")


def workflow_steps(path):
    """The job's steps as {"keys": top-level scalars, "run": logical lines of run}, read without a YAML library."""
    steps, step, in_run = [], None, False
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for raw in lines:
        stripped = raw.strip()
        if raw.startswith("      - "):
            step, in_run = {"keys": {}, "run": []}, False
            steps.append(step)
            raw = "        " + raw[8:]
            stripped = raw.strip()
        if step is None:
            continue
        indent = len(raw) - len(raw.lstrip())
        if stripped and indent < 8:
            step, in_run = None, False
            continue
        if in_run and (indent >= 10 or not stripped):
            if stripped and not stripped.startswith("#"):
                step["run"].append(stripped)
            continue
        in_run = False
        if indent == 8 and ":" in stripped and not stripped.startswith("#"):
            key, _, value = stripped.partition(":")
            value = value.strip()
            if key == "run":
                in_run = True
                if value and value != "|":
                    step["run"].append(value)
            else:
                step["keys"][key] = value
    for step in steps:
        joined, buf = [], ""
        for line in step["run"]:
            buf += line[:-1] + " " if line.endswith("\\") else line
            if not line.endswith("\\"):
                joined.append(buf)
                buf = ""
        step["run"] = joined
    return steps


def runs_cargo(line, root, working_dir):
    words = line.split()
    if "cargo" in words:
        return True
    for word in words:
        if word.endswith(".sh"):
            script = os.path.normpath(os.path.join(root, working_dir or "", word))
            if os.path.isfile(script):
                with open(script, encoding="utf-8") as f:
                    if any(w == "cargo" for w in f.read().split()):
                        return True
    return False


def timeout_bound(line):
    """Seconds `timeout` lets the line's command live, limit plus kill grace; None when not wrapped in timeout."""
    parts = timeout_parts(line)
    return None if parts is None else parts[0] + parts[1]


def timeout_parts(line):
    """(limit, kill grace) in seconds of a line wrapped in `timeout --kill-after=G LIMIT`; None otherwise."""
    def seconds(text):
        text = text.strip('"')
        scale = {"s": 1, "m": 60, "h": 3600}.get(text[-1:], None)
        return float(text[:-1]) * scale if scale else float(text)

    words = line.split()
    if not words or words[0] != "timeout":
        return None
    grace, rest = None, words[1:]
    while rest and rest[0].startswith("-"):
        if rest[0].startswith("--kill-after="):
            grace = seconds(rest[0].split("=", 1)[1])
        rest = rest[1:]
    if not rest or grace is None:
        return None
    try:
        return seconds(rest[0]), grace
    except ValueError:
        return None


def ci_commit(oid, at, suites):
    """suites: {workflow: {job: [conclusion per attempt, in start order]}}"""
    nodes = []
    for wf, jobs in suites.items():
        runs = []
        for job, concl in jobs.items():
            for i, c in enumerate(concl):
                runs.append({"name": job, "conclusion": c, "startedAt": f"{at[:11]}0{i}:00:00Z", "completedAt": None})
        nodes.append({"app": {"slug": "github-actions"}, "workflowRun": {"workflow": {"name": wf}}, "checkRuns": {"nodes": runs}})
    return {"oid": oid, "committedDate": at, "checkSuites": {"nodes": nodes}}


class CIHealth(unittest.TestCase):
    # newest first, as GitHub's history gives them
    COMMITS = [
        ci_commit("c3", "2026-11-10T03:00:00Z", {"web": {"lint": ["FAILURE"], "tests": ["SUCCESS"], "slow": [None]},
                                                 "guards": {"guard": ["CANCELLED"]}}),
        ci_commit("c2", "2026-11-10T02:00:00Z", {"web": {"lint": ["SUCCESS"], "tests": ["FAILURE", "SUCCESS"], "slow": ["SUCCESS"]},
                                                 "guards": {"guard": ["FAILURE"]}}),
        ci_commit("c1", "2026-11-10T01:00:00Z", {"web": {"lint": ["SKIPPED"], "tests": ["TIMED_OUT"], "slow": ["SUCCESS"]},
                                                 "guards": {"guard": ["SUCCESS"]}}),
    ]

    def test_green_share_takes_each_checks_newest_finished_run(self):
        h = qr.ci_branch_health(self.COMMITS)
        # lint red at c3; tests green at c3; slow still running at c3 so c2's green; guard cancelled at c3 so c2's red
        self.assertEqual((h["checks"], h["green_checks"], h["green_share"]), (4, 2, 0.5))
        self.assertEqual([x["check"] for x in h["red_now"]], ["guards / guard", "web / lint"])
        self.assertEqual(h["head_sha"], "c3")

    def test_flake_is_red_then_green_on_the_same_commit(self):
        h = qr.ci_branch_health(self.COMMITS)
        # pairs: c3 lint, tests; c2 lint, tests, slow, guard; c1 tests, slow, guard (skipped and cancelled say nothing)
        self.assertEqual((h["pairs"], h["flaky_pairs"]), (9, 1))
        self.assertEqual(h["flaky"], [{"check": "web / tests", "flaky": 1}])
        # a red final after a green attempt is red, not a flake
        h2 = qr.ci_branch_health([ci_commit("x", "2026-11-10T01:00:00Z", {"w": {"j": ["SUCCESS", "FAILURE"]}})])
        self.assertEqual((h2["flaky_pairs"], h2["green_share"]), (0, 0.0))

    def test_a_dispatch_on_the_same_commit_is_another_attempt(self):
        c = ci_commit("x", "2026-11-10T01:00:00Z", {"w": {"j": ["FAILURE"]}})
        c["checkSuites"]["nodes"].append({"app": {"slug": "github-actions"}, "workflowRun": {"workflow": {"name": "w"}},
                                          "checkRuns": {"nodes": [{"name": "j", "conclusion": "SUCCESS", "startedAt": "2026-11-10T09:00:00Z"}]}})
        h = qr.ci_branch_health([c])
        self.assertEqual((h["pairs"], h["flaky_pairs"], h["green_share"]), (1, 1, 1.0))

    def test_branches_pool_and_a_failed_branch_says_why(self):
        def hist(repo, branch, n):
            if branch == "gone":
                raise qr.SourceError("no such branch")
            return self.COMMITS[:n]
        ci = qr.ci_health(["feat", "gone"], 50, "o/r", hist)
        self.assertEqual((ci["checks"], ci["green_share"], ci["source"]), (4, 0.5, "github-checks"))
        self.assertEqual(ci["branches"]["gone"], {"why": "no such branch"})
        self.assertIsNone(ci["why"])
        none = qr.ci_health(["gone"], 50, "o/r", hist)
        self.assertIsNone(none["green_share"])
        self.assertIn("no such branch", none["why"])

    def test_an_odd_reply_costs_only_that_branch(self):
        def hist(repo, branch, n):
            if branch == "odd":
                return [{"checkSuites": None, "oid": "x"}, None]
            return self.COMMITS
        ci = qr.ci_health(["feat", "odd"], 50, "o/r", hist)
        self.assertEqual(ci["green_share"], 0.5)
        self.assertIn("unreadable check runs", ci["branches"]["odd"]["why"])
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [], ci_branches=["feat", "odd"], ci_history=hist)
        self.assertTrue(qr.headline(r)["CI checks green on base"].endswith("newest run on feat"))

    def test_history_pages_until_enough_commits(self):
        calls = []
        def graphql(q, v):
            calls.append(v)
            page = len(calls)
            nodes = [ci_commit(f"p{page}c{i}", "2026-11-10T01:00:00Z", {}) for i in range(v["n"])]
            return {"data": {"repository": {"object": {"history": {"nodes": nodes, "pageInfo": {"hasNextPage": True, "endCursor": f"k{page}"}}}}}}
        out = qr.gh_ci_history("o/r", "feat", 12, graphql)
        self.assertEqual(len(out), 12)
        self.assertEqual([c["n"] for c in calls], [5, 5, 2])
        self.assertEqual([c["after"] for c in calls], [None, "k1", "k2"])
        self.assertEqual(calls[0]["expr"], "feat")

    def test_graphql_error_is_a_source_error(self):
        with self.assertRaises(qr.SourceError):
            qr.gh_ci_history("o/r", "feat", 5, lambda q, v: {"errors": [{"message": "Bad credentials"}]})
        fail = lambda *a, **k: subprocess.CompletedProcess(a, 1, "", "HTTP 401")
        with self.assertRaises(qr.SourceError):
            qr.gh_graphql("q", {"n": 5}, run=fail)

    def test_report_headline_markdown_and_sticky_carry_the_two_numbers(self):
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                            ci_branches=["feat"], ci_history=lambda repo, b, n: self.COMMITS)
        h = qr.headline(r, public=True)
        self.assertIn("50.00% of 4 checks", h["CI checks green on base"])
        self.assertIn("11.11% of 9", h["CI flake rate"])
        md = qr.render_markdown(r, public=True)
        self.assertIn("### CI health", md)
        self.assertIn("`guards / guard` 1/2", md)
        body = qr.sticky_body(r, md, "")
        self.assertIn("| CI green | CI flake |", body)
        self.assertIn("| 50.00% | 11.11% |", body)
        self.assertEqual(qr.public_report(r)["ci_health"]["green_share"], 0.5)

    def test_empty_checks_token_says_so_and_a_set_one_is_used(self):
        seen = {}
        def run(cmd, **k):
            seen["env"] = k.get("env")
            return subprocess.CompletedProcess(cmd, 0, "{}", "")
        old = os.environ.get("CI_GH_TOKEN")
        try:
            os.environ["CI_GH_TOKEN"] = ""
            with self.assertRaises(qr.SourceError) as e:
                qr.gh_graphql("q", {}, run=run)
            self.assertIn("no checks-read token", str(e.exception))
            os.environ["CI_GH_TOKEN"] = "t0k"
            qr.gh_graphql("q", {}, run=run)
            self.assertEqual(seen["env"]["GH_TOKEN"], "t0k")
        finally:
            if old is None:
                os.environ.pop("CI_GH_TOKEN", None)
            else:
                os.environ["CI_GH_TOKEN"] = old

    def test_no_branches_is_a_slot_not_a_failure(self):
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [])
        self.assertIsNone(r["ci_health"]["green_share"])
        self.assertIn("n/a (no --ci-branches given)", qr.headline(r)["CI flake rate"])
        self.assertNotIn("### CI health", qr.render_markdown(r, public=False))


def journey(surface, at, cells, missing=()):
    return {"schema": 1, "surface": surface, "generated_at": at, "build": "abc", "run_url": f"https://ci/{surface}",
            "cells": cells, "missing_accounts": list(missing)}


class FirstUserJourney(unittest.TestCase):
    WEB = journey("web", "2026-11-10T05:00:00Z", [
        {"cell": "claude/working", "harness": "claude", "state": "working", "outcome": "pass", "steps": 40, "reds": []},
        {"cell": "codex/expired", "harness": "codex", "state": "expired", "outcome": "red", "steps": 31, "reds": [
            {"rule": "raw-error-code", "where": "chat", "step": "send", "detail": "HTTP 429 | usage_limit_reached"},
            {"rule": "error-without-next-step", "where": "chat", "step": "send", "detail": "no button"}]},
        {"cell": "cursor/expired", "harness": "cursor", "state": "expired", "outcome": "needs-account", "steps": 0}],
        missing=["cursor"])

    def write(self, d, name, doc):
        path = os.path.join(d, name)
        with open(path, "w") as f:
            json.dump(doc, f)
        return path

    def test_counts_cells_and_groups_reds_by_rule(self):
        with tempfile.TemporaryDirectory() as d:
            got = qr.first_user_journey([self.write(d, "web.json", self.WEB)], T)
        web = got["surfaces"]["web"]
        self.assertEqual((web["cells"], web["pass"], web["red"], web["needs_account"], web["steps"]), (3, 1, 1, 1, 71))
        self.assertEqual(web["reds_by_rule"], {"error-without-next-step": 1, "raw-error-code": 1})
        self.assertEqual((got["cells"], got["red_cells"], got["reds"]), (3, 1, 2))
        self.assertEqual(web["missing_accounts"], ["cursor"])

    def test_stale_and_missing_surfaces_say_why_and_count_nothing(self):
        old = journey("ios", "2026-11-07T00:00:00Z", [{"cell": "ios/onboarding", "outcome": "red", "reds": [{"rule": "dead-button"}]}])
        with tempfile.TemporaryDirectory() as d:
            got = qr.first_user_journey([self.write(d, "web.json", self.WEB), self.write(d, "ios.json", old),
                                         os.path.join(d, "mac.json")], T)
        self.assertIn("stale", got["surfaces"]["ios"]["why"])
        self.assertIn("does not exist", got["surfaces"]["input3"]["why"])
        self.assertEqual(got["red_cells"], 1, "only the fresh web surface counts")
        self.assertEqual(qr.first_user_journey([], T)["why"], "no input given")

    def test_report_markdown_history_and_public_detail(self):
        with tempfile.TemporaryDirectory() as d:
            r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                                journey_paths=[self.write(d, "web.json", self.WEB)])
        self.assertEqual(qr.headline(r)["First-user journey"], "1 red of 3 cells, 2 reds (web 1/3)")
        private, public = qr.render_markdown(r, public=False), qr.render_markdown(r, public=True)
        self.assertIn("### First-user journey", public)
        self.assertIn("`cursor`", public)
        self.assertIn("HTTP 429 / usage_limit_reached", private, "a red's detail cannot break the table")
        self.assertNotIn("HTTP 429", public, "red details stay in the private sticky")
        row = qr.history_row(r)
        self.assertEqual((row["journey_red"], row["journey_cells"]), (1, 3))
        self.assertIn("| 1/3 |", qr.sticky_body(r, "md", ""))
        pub = json.dumps(qr.public_report(r))
        for private in ("HTTP 429", "codex/expired", "https://ci/web"):
            self.assertNotIn(private, pub, "the public JSON carries counts only")
        self.assertIn("https://ci/web", private)
        self.assertNotIn("https://ci/web", public)

    def test_odd_shapes_count_nothing_wrong_and_never_crash(self):
        odd = journey(["web"], "2026-11-10T05:00:00Z", [
            {"cell": "x", "outcome": "pass", "steps": True}, "not a cell"])
        odd["missing_accounts"] = "cursor"
        dup = journey("web", "2026-11-10T05:00:00Z", [{"cell": "y", "outcome": "red", "reds": [{"rule": "dead-button"}]}])
        with tempfile.TemporaryDirectory() as d:
            got = qr.first_user_journey([self.write(d, "a.json", self.WEB), self.write(d, "b.json", odd),
                                         self.write(d, "c.json", dup)], T)
        self.assertEqual(sorted(got["surfaces"]), ["input2", "input3", "web"], "a bad or repeated surface never overwrites")
        self.assertEqual((got["surfaces"]["input2"]["steps"], got["surfaces"]["input2"]["missing_accounts"]), (0, []))

    def test_a_non_text_stamp_or_reds_value_costs_that_surface_never_the_report(self):
        stamp = journey("web", 1, [{"cell": "x", "outcome": "pass"}])
        reds = journey("ios", "2026-11-10T05:00:00Z", [{"cell": "y", "outcome": "red", "reds": 1}])
        with tempfile.TemporaryDirectory() as d:
            got = qr.first_user_journey([self.write(d, "a.json", stamp), self.write(d, "b.json", reds)], T)
            r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                                journey_paths=[self.write(d, "c.json", stamp)])
        self.assertEqual(got["surfaces"]["web"]["why"], "the results have no generated_at")
        self.assertEqual((got["surfaces"]["ios"]["red"], got["surfaces"]["ios"]["reds_by_rule"]), (1, {}))
        self.assertIn("n/a", qr.headline(r)["First-user journey"])

    def test_fetch_takes_the_newest_run_that_kept_the_artifact(self):
        calls = []

        def run(cmd, **kw):
            calls.append(cmd)
            if cmd[2] == "list":
                return subprocess.CompletedProcess(cmd, 0, stdout=json.dumps([{"databaseId": 9}, {"databaseId": 8}]), stderr="")
            return subprocess.CompletedProcess(cmd, 0 if cmd[3] == "8" else 1, stdout="", stderr="no artifact")
        self.assertEqual(qr.fetch_journey("o/r", "w.yml", "first-user-journey-web", "/tmp/x", run=run), "8")
        with self.assertRaises(qr.SourceError):
            qr.fetch_journey("o/r", "w.yml", "a", "/tmp/x", run=lambda cmd, **kw: subprocess.CompletedProcess(
                cmd, 0, stdout="[]", stderr=""))


class NightlySpeed(unittest.TestCase):
    """The nightly_speed metric from scripts/ci/nightly_speed.py's history in its cmuxterm-hq issue."""

    DOC = {"budget_min": 30.0, "top_stages": ["promote", "c_build", "g_sign"], "records": [
        {"feed_at": "2026-11-10T08:00:00Z", "merge_to_feed": 20.0, "stages": {"promote": 2, "c_build": 9, "g_sign": 8, "c1_compile": 50}},
        {"feed_at": "2026-11-10T06:00:00Z", "merge_to_feed": 104.0, "stages": {"promote": 3, "c_build": 16, "g_sign": 20}},
        {"feed_at": "2026-11-09T20:00:00Z", "merge_to_feed": 151.0, "stages": {"promote": 3, "c_build": 15, "g_sign": 22}},
        {"feed_at": "2026-11-09T20:00:00Z", "merge_to_feed": None, "stages": {}},
        {"feed_at": "2026-11-08T20:00:00Z", "merge_to_feed": 999.0, "stages": {"g_sign": 900}},
    ]}

    def body(self, doc):
        return f"{qr.SPEED_MARK}\nreport\n<!-- nightly-speed-history: {json.dumps(doc)} -->\n"

    def test_window_p50_p95_over_budget_and_largest_stage(self):
        sp = qr.nightly_speed(self.DOC, None, SINCE)
        self.assertEqual((sp["published"], sp["p50_min"], sp["p95_min"], sp["over_budget"]), (4, 104.0, 146.3, 2))
        self.assertEqual((sp["largest_stage"], sp["largest_stage_p50_min"]), ("g_sign", 20), "a nested step never wins")
        self.assertIn("p95 146.3 min (budget p95 under 30); 2 of 4 published over budget; largest stage g_sign", qr.speed_line(sp))

    def test_reads_the_issue_and_says_why_when_it_cannot(self):
        ok = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, json.dumps(
            [{"number": 3, "title": qr.SPEED_TITLE, "body": self.body(self.DOC)}, {"number": 4, "title": qr.SPEED_TITLE, "body": "no mark"}]), "")
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                            speed_history=lambda: qr.gh_speed_history(run=ok))
        self.assertEqual(r["nightly_speed"]["p50_min"], 104.0)
        self.assertIn("| 146.3 |", qr.sticky_body(r, "md", ""))
        self.assertIn("Nightly merge to feed", qr.render_markdown(r, public=True))
        none = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, "[]", "")
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                            speed_history=lambda: qr.gh_speed_history(run=none))
        self.assertIsNone(r["nightly_speed"]["p50_min"])
        self.assertIn("has not written it", r["nightly_speed"]["why"])
        fail = lambda cmd, **k: subprocess.CompletedProcess(cmd, 1, "", "HTTP 403")
        with self.assertRaises(qr.SourceError):
            qr.gh_speed_history(run=fail)
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [])
        self.assertEqual(qr.headline(r)["Nightly merge to feed"], "n/a (no speed history source given)")

    def test_reads_the_compressed_history_and_refuses_a_corrupt_one(self):
        def reader(body):
            issues = [{"number": 3, "title": qr.SPEED_TITLE, "body": body}]
            listed = lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, json.dumps(issues), "")
            return lambda: qr.gh_speed_history(run=listed)
        z = base64.b64encode(zlib.compress(json.dumps(self.DOC, separators=(",", ":")).encode(), 9)).decode()
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [],
                            speed_history=reader(f"{qr.SPEED_MARK}\nreport\n<!-- nightly-speed-history-z: {z} -->\n"))
        self.assertEqual(r["nightly_speed"]["p50_min"], 104.0)
        bomb = base64.b64encode(zlib.compress(b" " * (qr.SPEED_INFLATE_CAP + 10), 9)).decode()
        for bad in ("not base64!", base64.b64encode(b"not zlib").decode(), bomb):
            # The compressed form wins over a plain one beside it, and a corrupt one is no history.
            with self.assertRaises(qr.SourceError):
                reader(f"{qr.SPEED_MARK}\n<!-- nightly-speed-history-z: {bad} -->\n" + self.body(self.DOC))()

    def test_valid_json_of_another_shape_is_no_history_and_an_odd_value_is_skipped(self):
        def reader(doc):
            z = base64.b64encode(zlib.compress(json.dumps(doc).encode(), 9)).decode()
            issues = [{"number": 3, "title": qr.SPEED_TITLE, "body": f"{qr.SPEED_MARK}\n<!-- nightly-speed-history-z: {z} -->\n"}]
            return lambda: qr.gh_speed_history(run=lambda cmd, **k: subprocess.CompletedProcess(cmd, 0, json.dumps(issues), ""))
        for doc in ({"records": 1}, {"records": {"a": 1}}, {"records": None}, {"budget_min": 30}, [1], 5):
            with self.assertRaises(qr.SourceError, msg=doc):
                reader(doc)()
            self.assertEqual(qr.nightly_speed(doc, None, SINCE)["why"], "no speed history", doc)
        odd = [1, None, {"feed_at": 5, "merge_to_feed": 1.0}, {"feed_at": "2026-11-10T08:00:00Z", "merge_to_feed": "20", "stages": 3},
               {"feed_at": "2026-11-10T08:00:00Z", "merge_to_feed": 10 ** 400, "stages": {"promote": True, "g_sign": "8"}}]
        doc = {**self.DOC, "budget_min": "30", "records": odd + self.DOC["records"]}
        r = qr.build_report(24, T, None, None, None, None, hang_watch=lambda since: [], speed_history=reader(doc))
        sp = r["nightly_speed"]
        self.assertEqual((sp["published"], sp["p50_min"], sp["p95_min"], sp["over_budget"], sp["budget_min"]),
                         (6, 104.0, 146.3, 2, 30.0))
        self.assertEqual((sp["largest_stage"], sp["largest_stage_p50_min"]), ("g_sign", 20))
        self.assertIsNone(qr.nightly_speed({**doc, "top_stages": "promote"}, None, SINCE)["largest_stage"])


if __name__ == "__main__":
    unittest.main()
