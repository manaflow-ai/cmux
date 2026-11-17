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


if __name__ == "__main__":
    unittest.main()
