#!/usr/bin/env python3
"""stability.py: crash-free rates per release, new top signatures, one alert group and one issue per signature.

  python3 -m unittest scripts/perf-lab/tests/test_stability.py
"""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, LAB / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


stability = _load("perf_lab_stability", "stability.py")
lab = _load("perf_lab_lab", "lab.py")
dashboard = _load("perf_lab_dashboard", "dashboard.py")
sheriff = _load("perf_lab_sheriff", "sheriff.py")
alerts = stability.alerts
store_mod = stability.store_mod
issues_mod = stability.issues_mod

TOKEN = "sntrys_S3cretTokenValue"
NOW = datetime(2026, 10, 27, 12, 0, tzinfo=timezone.utc)
ORG = "manaflow"


def release_group(name, sessions, installs, cf_sessions, cf_installs):
    return {"by": {"release": name}, "totals": {"sum(session)": sessions, "count_unique(user)": installs,
                                               "crash_free_rate(session)": cf_sessions,
                                               "crash_free_rate(user)": cf_installs}}


RELEASE_GROUPS = [
    release_group("cmux-next@1.0.0-nightly.900+2026102601", 4000, 300, 0.9975, 0.98),
    release_group("cmux@0.70.0+80", 9000, 900, 0.999, 0.99),          # main's app in the shared project
    release_group("cmux-next@1.0.0-nightly.901+2026102701", 1000, 120, 0.999, 0.9916666),
    release_group("cmux-next@1.0.0-nightly.899+2026102501", 0, 0, None, None),
]


def sentry_issue(sentry_id, *, short, title, events, users, first_seen, github=()):
    return {"id": sentry_id, "shortId": short, "title": title, "culprit": f"{title} culprit", "level": "fatal",
            "count": str(events), "userCount": users, "firstSeen": first_seen, "lastSeen": "2026-10-27T11:00:00Z",
            "permalink": f"https://manaflow.sentry.io/issues/{sentry_id}/",
            "annotations": [{"url": f"https://github.com/manaflow-ai/cmux/issues/{n}"} for n in github]}


class FakeSentry:
    """Answers the paths stability.py reads; records every request."""

    def __init__(self, issues, first_releases, *, groups=RELEASE_GROUPS, totals=None):
        self.issues, self.first_releases, self.groups = issues, first_releases, groups
        self.totals = totals or {"sum(session)": 5000, "count_unique(user)": 380,
                                 "crash_free_rate(session)": 0.998, "crash_free_rate(user)": 0.9842}
        self.requests: list[tuple[str, list[tuple[str, str]]]] = []

    def __call__(self, path, params):
        self.requests.append((path, list(params)))
        names = dict(params)
        if path == f"/organizations/{ORG}/sessions/":
            if names.get("groupBy") == "release":
                return {"groups": self.groups}, {}
            return {"groups": [{"by": {}, "totals": self.totals}]}, {}
        if path == f"/organizations/{ORG}/issues/":
            return list(self.issues), {}
        prefix = f"/organizations/{ORG}/issues/"
        if path.startswith(prefix):
            sentry_id = path[len(prefix):].strip("/")
            version = self.first_releases.get(sentry_id)
            return {"id": sentry_id, "firstRelease": {"version": version} if version else None}, {}
        raise AssertionError(f"unexpected path {path}")


ISSUES = [
    sentry_issue("101", short="CMUXTERM-MACOS-1A", title="EXC_BAD_ACCESS in TabStrip.layout", events=40, users=12,
                 first_seen="2026-10-26T09:00:00Z"),
    sentry_issue("102", short="CMUXTERM-MACOS-1B", title="SIGABRT in DaemonClient.send", events=90, users=30,
                 first_seen="2026-10-27T03:00:00Z"),
    # Returned by the server but first seen before the window: not new.
    sentry_issue("103", short="CMUXTERM-MACOS-OLD", title="old crash", events=500, users=99,
                 first_seen="2026-09-01T00:00:00Z"),
]
FIRST_RELEASES = {"101": "cmux-next@1.0.0-nightly.900+2026102601", "102": "cmux-next@1.0.0-nightly.901+2026102701"}


class FakeIssues:
    """stability_issues.GitHub in memory."""

    def __init__(self, existing=()):
        self.issues = {issue.number: issue for issue in existing}
        self.next_number = 500
        self.writes: list[tuple] = []
        self.lists = 0

    def list_issues(self, label):
        self.lists += 1
        return [issue for issue in self.issues.values() if label in issue.labels]

    def existing_labels(self):
        return {name for issue in self.issues.values() for name in issue.labels}

    def create_label(self, name):
        self.writes.append(("label", name))

    def create_issue(self, title, body, labels):
        number, self.next_number = self.next_number, self.next_number + 1
        self.issues[number] = issues_mod.Issue(number, "OPEN", "", title, body, list(labels))
        self.writes.append(("create", number))
        return number

    def edit_issue(self, number, title, body):
        issue = self.issues[number]
        issue.title, issue.body = title, body
        self.writes.append(("edit", number))

    def comment(self, number, text):
        self.writes.append(("issue-comment", number))

    def close_issue(self, number, text, reason):
        self.writes.append(("close", number))

    def reopen_issue(self, number, text):
        self.writes.append(("reopen", number))

    def rate_remaining(self):
        return {"core": 5000, "graphql": 5000}


class FakeComments:
    """alerts.GitHub's comment read (glaeda-gh) and write, in memory."""

    def __init__(self):
        self.bodies: dict[int, list[str]] = {}

    def issue_comment_bodies(self, number):
        return list(self.bodies.get(number, []))

    def comment(self, number, body):
        self.bodies.setdefault(number, []).append(body)


def parse(*argv):
    parser = argparse.ArgumentParser()
    stability.add_arguments("stability", parser)
    return parser.parse_args(list(argv))


class TempStore:
    def __init__(self):
        self._dir = tempfile.TemporaryDirectory()
        self.path = Path(self._dir.name) / "lab.sqlite"
        handle = store_mod.Store(self.path, clock=lambda: NOW)
        handle.migrate()
        handle.close()

    def open(self, clock=lambda: NOW):
        return store_mod.Store(self.path, clock=clock)

    def cleanup(self):
        self._dir.cleanup()


def run_command(argv, *, fetch, environ=None, github=None, comments=None, clock=lambda: NOW):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = stability.stability_command(parse(*argv), environ={"SENTRY_AUTH_TOKEN": TOKEN} if environ is None
                                           else environ, fetch=fetch, github=github, comments=comments, clock=clock)
    return code, out.getvalue(), err.getvalue()


class WindowTests(unittest.TestCase):
    def test_since(self):
        self.assertEqual(stability.parse_since("7d"), 168)
        self.assertEqual(stability.parse_since("48h"), 48)
        for bad in ("7", "0h", "91d", "1w", "-3d"):
            with self.assertRaises(stability.StabilityError, msg=bad):
                stability.parse_since(bad)
        self.assertEqual(stability.stats_period(168), "7d")
        self.assertEqual(stability.stats_period(36), "36h")


class RateTests(unittest.TestCase):
    def test_release_rows_keep_cmux_next_newest_build_first(self):
        rows = stability.release_rows(RELEASE_GROUPS)
        self.assertEqual([row.release for row in rows], ["cmux-next@1.0.0-nightly.901+2026102701",
                                                         "cmux-next@1.0.0-nightly.900+2026102601",
                                                         "cmux-next@1.0.0-nightly.899+2026102501"])
        newest, older, empty = rows
        self.assertEqual((newest.version, newest.build), ("1.0.0-nightly.901", 2026102701))
        self.assertEqual(older.rates.crash_free_sessions, 0.9975)
        self.assertEqual(older.rates.crashed_sessions, 10)        # 4000 * 0.25 %
        self.assertEqual(older.rates.crashed_installs, 6)         # 300 * 2 %
        self.assertEqual(newest.rates.crashed_installs, 1)
        self.assertIsNone(empty.rates.crash_free_sessions)
        self.assertIsNone(empty.rates.crashed_sessions)

    def test_zero_sessions_has_no_rate_even_if_sentry_sends_one(self):
        rates = stability.Rates.from_totals({"sum(session)": 0, "count_unique(user)": 0,
                                             "crash_free_rate(session)": 1.0, "crash_free_rate(user)": 1.0}, "r")
        self.assertIsNone(rates.crash_free_sessions)
        self.assertIsNone(rates.crash_free_installs)

    def test_bad_rate_or_count_is_refused(self):
        for totals in ({"sum(session)": 10, "crash_free_rate(session)": 99.8},
                       {"sum(session)": 10, "crash_free_rate(session)": "0.99"},
                       {"sum(session)": 1.5}, {"sum(session)": -1}, {"count_unique(user)": True}):
            with self.assertRaises(stability.StabilityError, msg=totals):
                stability.Rates.from_totals(totals, "r")

    def test_fetch_scopes_environment_window_and_release_grouping(self):
        sentry = FakeSentry([], {})
        scope = stability.Scope(ORG, "4510796264636416", "nightly-next", 168)
        overall, rows = stability.fetch_rates(sentry, scope)
        self.assertEqual((overall.sessions, overall.installs, overall.crash_free_sessions), (5000, 380, 0.998))
        self.assertEqual(len(rows), 3)
        for path, params in sentry.requests:
            self.assertIn(("environment", "nightly-next"), params)
            self.assertIn(("statsPeriod", "7d"), params)
            self.assertIn(("project", "4510796264636416"), params)
            self.assertIn(("field", "crash_free_rate(user)"), params)
        self.assertIn(("groupBy", "release"), sentry.requests[1][1])


class SignatureTests(unittest.TestCase):
    def test_new_top_signatures_are_unhandled_first_seen_in_window_most_events_first(self):
        sentry = FakeSentry(ISSUES, FIRST_RELEASES)
        scope = stability.Scope(ORG, "1", "nightly-next", 168)
        signatures = stability.fetch_signatures(sentry, scope, top=10, now=NOW)
        self.assertEqual([s.sentry_id for s in signatures], ["102", "101"])
        self.assertEqual(signatures[0].first_release, FIRST_RELEASES["102"])
        query = dict(sentry.requests[0][1])["query"]
        self.assertIn("error.unhandled:true", query)
        self.assertIn("firstSeen:-168h", query)
        self.assertIn("app:cmux-next", query)
        detail = [params for path, params in sentry.requests if path.endswith("/issues/102/")]
        self.assertEqual(detail, [[("environment", "nightly-next")]])

    def test_top_limits_and_unknown_release(self):
        sentry = FakeSentry(ISSUES, {"102": "cmux@0.70.0+80"})
        scope = stability.Scope(ORG, "1", "nightly-next", 168)
        signatures = stability.fetch_signatures(sentry, scope, top=1, now=NOW)
        self.assertEqual([s.sentry_id for s in signatures], ["102"])
        self.assertIsNone(signatures[0].first_release)  # not a cmux NEXT release name
        self.assertIn("first release unknown", signatures[0].reason())
        self.assertTrue(signatures[0].reason().startswith("stability sentry:102: "))


class ReportTests(unittest.TestCase):
    def test_report_counts_new_signatures_per_release_and_feeds_the_dashboard(self):
        code, out, err = run_command(["--json"], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 0, err)
        result = json.loads(out)
        self.assertEqual(result["schema"], stability.SCHEMA)
        self.assertEqual(result["since_hours"], 168)
        by_release = {row["release"]: row for row in result["releases"]}
        self.assertEqual(by_release["cmux-next@1.0.0-nightly.901+2026102701"]["new_signatures"], 1)
        self.assertEqual(by_release["cmux-next@1.0.0-nightly.900+2026102601"]["new_signatures"], 1)
        self.assertEqual(by_release["cmux-next@1.0.0-nightly.899+2026102501"]["new_signatures"], 0)
        rows = [dashboard.StabilityRow(r["release"], r["crash_free_sessions"], r["crash_free_installs"],
                                       r["new_signatures"]) for r in result["releases"]]
        self.assertIn("99.75 %", dashboard.render_stability(rows))
        self.assertNotIn("groups", result)  # no --db: report only, nothing written
        self.assertNotIn(TOKEN, out + err)

    def test_text_report(self):
        code, out, _ = run_command([], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 0)
        self.assertIn("cmux-next@1.0.0-nightly.901+2026102701", out)
        self.assertIn("CMUXTERM-MACOS-1B", out)
        self.assertNotIn("CMUXTERM-MACOS-OLD", out)

    def test_out_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stability.json"
            code, _, _ = run_command(["--out", str(path)], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(path.read_text())["env"], "nightly-next")


class TokenTests(unittest.TestCase):
    def test_token_only_from_the_environment(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse("--token", TOKEN)
        code, _, err = run_command([], fetch=None, environ={})
        self.assertEqual(code, 2)
        self.assertIn("SENTRY_AUTH_TOKEN is not set", err)

    def test_errors_are_redacted(self):
        def leaky(path, params):
            raise stability.health.SentryError(f"GET {path}: HTTP 401: bad token {TOKEN}")

        code, out, err = run_command([], fetch=leaky)
        self.assertEqual(code, 3)
        self.assertNotIn(TOKEN, out + err)
        self.assertIn("[redacted]", err)

    def test_transport_refuses_plain_http(self):
        with self.assertRaises(stability.health.SentryError):
            stability.health.http_fetch("http://sentry.example.com", TOKEN)

    def test_lab_discovers_the_command(self):
        self.assertIn("stability", lab.discover(LAB))


class GroupTests(unittest.TestCase):
    def setUp(self):
        self.lab = TempStore()
        self.addCleanup(self.lab.cleanup)

    def test_one_group_per_signature_ever(self):
        code, out, err = run_command(["--json", "--db", str(self.lab.path)], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 0, err)
        groups = json.loads(out)["groups"]
        self.assertEqual(sorted(groups["created"]), ["101", "102"])
        self.assertEqual(groups["existing"], {})
        code, out, _ = run_command(["--json", "--db", str(self.lab.path)], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        again = json.loads(out)["groups"]
        self.assertEqual(again["created"], {})
        self.assertEqual(again["existing"], groups["created"])
        store = self.lab.open()
        self.addCleanup(store.close)
        rows = store._db.execute("SELECT * FROM alert_groups ORDER BY id").fetchall()
        self.assertEqual(len(rows), 2)
        self.assertEqual({(r["state"], r["start_pos"], r["end_pos"]) for r in rows}, {("new", -1, -1)})
        history = store._db.execute("SELECT * FROM sheriff_history ORDER BY id").fetchall()
        self.assertEqual([(h["actor"], h["from_state"], h["to_state"]) for h in history],
                         [(stability.ACTOR, None, "new")] * 2)
        # The sheriff loop sees them.
        listed = sheriff.Sheriff(store, session=None, lead_session=None, clock=lambda: NOW).groups(["new"])
        self.assertEqual(sorted(g.id for g in listed), sorted(groups["created"].values()))

    def test_closed_group_is_not_reopened_as_a_second_group(self):
        store = self.lab.open()
        self.addCleanup(store.close)
        signatures = stability.fetch_signatures(FakeSentry(ISSUES, FIRST_RELEASES),
                                                stability.Scope(ORG, "1", "nightly-next", 168), top=10, now=NOW)
        first = stability.record_groups(store, signatures)
        actor = sheriff.Sheriff(store, session="sheriff-1", lead_session=None, clock=lambda: NOW)
        actor.set_state(first.created["102"], "invalid", reason="symbolication noise")
        second = stability.record_groups(store, signatures)
        self.assertEqual(second.created, {})
        self.assertEqual(second.existing, first.created)

    def test_a_perf_alert_never_joins_a_stability_group(self):
        store = self.lab.open()
        self.addCleanup(store.close)
        signatures = stability.fetch_signatures(FakeSentry(ISSUES, FIRST_RELEASES),
                                                stability.Scope(ORG, "1", "nightly-next", 168), top=10, now=NOW)
        created = set(stability.record_groups(store, signatures).created.values())
        series = alerts.SeriesInfo(1, "sk1:x", "cmd-t", "commit_ms", "chromium", "m6/24gb/120hz", 26, "bench",
                                   "ms", "lower")
        report = alerts.DetectReport()
        perf_group = store._write(lambda: alerts._group_for(store._db, store._now(), series, 0, 50, report))
        self.assertNotIn(perf_group, created)

    def test_dry_run_leaves_the_store_alone(self):
        code, out, err = run_command(["--json", "--dry-run", "--db", str(self.lab.path)],
                                     fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 0, err)
        self.assertEqual(len(json.loads(out)["groups"]["created"]), 2)
        store = self.lab.open()
        self.addCleanup(store.close)
        self.assertEqual(store._db.execute("SELECT COUNT(*) FROM alert_groups").fetchone()[0], 0)

    def test_missing_store_is_an_error_not_a_new_store(self):
        missing = self.lab.path.parent / "absent.sqlite"
        code, _, err = run_command(["--db", str(missing)], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 1)
        self.assertIn("no lab store", err)
        self.assertFalse(missing.exists())


class IssueTests(unittest.TestCase):
    def setUp(self):
        self.lab = TempStore()
        self.addCleanup(self.lab.cleanup)

    def sync(self, github, comments, issues=ISSUES, clock=lambda: NOW):
        code, out, err = run_command(["--json", "--db", str(self.lab.path), "--sync-issues"],
                                     fetch=FakeSentry(issues, FIRST_RELEASES), github=github, comments=comments,
                                     clock=clock)
        self.assertEqual(code, 0, err)
        return json.loads(out)

    def issue_of(self, sentry_id):
        store = self.lab.open()
        try:
            group_id = stability.signature_groups(store)[sentry_id]
            return store._db.execute("SELECT issue_number FROM alert_groups WHERE id = ?",
                                     (group_id,)).fetchone()[0], group_id
        finally:
            store.close()

    def test_issues_are_edited_never_duplicated(self):
        github, comments = FakeIssues(), FakeComments()
        first = self.sync(github, comments)
        created = [w for w in github.writes if w[0] == "create"]
        self.assertEqual(len(created), 2)
        number_101, _ = self.issue_of("101")
        number_102, _ = self.issue_of("102")
        self.assertEqual({number_101, number_102}, {number for _, number in created})
        self.assertEqual(first["issues"]["linked"], {"101": number_101, "102": number_102})
        # One sheriff state comment each: the group's current state.
        self.assertEqual({n: len(b) for n, b in comments.bodies.items()}, {number_101: 1, number_102: 1})
        self.assertRegex(comments.bodies[number_101][0], r"perf-lab-alerts state-change=\d+")

        # The next run with new counts edits the issue; it files nothing new and repeats no comment.
        busier = [dict(issue, count=str(int(issue["count"]) + 7)) for issue in ISSUES]
        github.writes.clear()
        self.sync(github, comments, busier)
        self.assertEqual(sorted(w[0] for w in github.writes), ["edit", "edit"])
        self.assertEqual(len(github.issues), 2)
        self.assertEqual({n: len(b) for n, b in comments.bodies.items()}, {number_101: 1, number_102: 1})

        # Same numbers again: nothing to write at all.
        github.writes.clear()
        self.sync(github, comments, busier)
        self.assertEqual(github.writes, [])

        # A sheriff move is posted once.
        store = self.lab.open(clock=lambda: NOW + timedelta(minutes=5))
        try:
            sheriff.Sheriff(store, session="sheriff-1", lead_session=None,
                            clock=lambda: NOW + timedelta(minutes=5)).set_state(self.issue_of("101")[1], "triaged")
        finally:
            store.close()
        later = lambda: NOW + timedelta(minutes=10)  # noqa: E731
        self.sync(github, comments, busier, clock=later)
        self.sync(github, comments, busier, clock=later)
        self.assertEqual(len(comments.bodies[number_101]), 2)
        self.assertIn("new -> triaged", comments.bodies[number_101][1])
        self.assertEqual(len(comments.bodies[number_102]), 1)

    def test_sentry_issue_that_links_a_github_issue_uses_it(self):
        linked = [sentry_issue("102", short="CMUXTERM-MACOS-1B", title="SIGABRT in DaemonClient.send", events=90,
                               users=30, first_seen="2026-10-27T03:00:00Z", github=(77,))]
        github, comments = FakeIssues(), FakeComments()
        result = self.sync(github, comments, linked)
        self.assertEqual([w for w in github.writes if w[0] == "create"], [])
        self.assertEqual(self.issue_of("102")[0], 77)
        self.assertEqual(result["issues"]["linked"], {"102": 77})
        self.assertEqual(len(comments.bodies[77]), 1)

    def test_existing_stability_issue_is_reused(self):
        github = FakeIssues()
        report_doc = {"schema": issues_mod.HEALTH_SCHEMA, "env": "nightly-next", "days": 3, "top_issues": [
            stability.health.normalize_issue(ISSUES[0], [])]}
        tracked, _ = issues_mod.plan_sentry([], report_doc)
        issues_mod.apply(tracked, github, 60, False)
        (number,) = github.issues
        github.writes.clear()
        self.sync(github, FakeComments())
        self.assertEqual(self.issue_of("101")[0], number)
        self.assertEqual(len([w for w in github.writes if w[0] == "create"]), 1)  # only 102's

    def test_dry_run_writes_no_issue(self):
        github, comments = FakeIssues(), FakeComments()
        code, out, err = run_command(["--json", "--dry-run", "--db", str(self.lab.path), "--sync-issues"],
                                     fetch=FakeSentry(ISSUES, FIRST_RELEASES), github=github, comments=comments)
        self.assertEqual(code, 0, err)
        self.assertEqual(github.writes, [])
        self.assertEqual(comments.bodies, {})
        self.assertEqual(len([a for a in json.loads(out)["issues"]["applied"] if a.startswith("create ")]), 2)

    def test_sync_issues_needs_the_store(self):
        code, _, err = run_command(["--sync-issues"], fetch=FakeSentry(ISSUES, FIRST_RELEASES))
        self.assertEqual(code, 2)
        self.assertIn("--db", err)


if __name__ == "__main__":
    unittest.main()
