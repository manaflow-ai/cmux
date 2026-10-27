#!/usr/bin/env python3
"""stability-health.py reads cmux NEXT field stability from Sentry; recorded API responses stand in for Sentry.

1. Release health: crash-free sessions and users (overall and per release), sessions by status, session-hours.
2. Lag spikes per 1k session-hours by bucket; hangs >= 2 s split into own and other-owner; unclean exits per session.
3. Top issues page through Sentry's Link cursor, carry their GitHub links, and the other-owner map claims issues only
   by GitHub issue or Sentry short id (a hang whose culprit names makeKeyWindow but has no link stays own); claimed
   issues form the other-owner row, not the hang check. The owner map refuses an entry without an ETA or with a pattern.
4. Done check 21 targets: --check exits 1 on a miss and 0 when all are met; no unclean-exit data is a miss, not 0 %;
   a lag spike signature without a GitHub issue is a miss.
5. JSON and table output.
6. The token comes only from SENTRY_AUTH_TOKEN and is never printed: no token is exit 2; an HTTP error whose body
   echoes the token is redacted, also across the 300-byte cut; a redirect to another host and a non-HTTPS URL are
   refused; the token is sent as a Bearer header to a loopback server.
7. A cut-off body or a payload of an unexpected shape is a Sentry API error (exit 3), not a traceback (exit 1).

    python3 -I -m pytest scripts/cmux-next/tests/test_stability_health.py
    python3 -I -m unittest discover -s scripts/cmux-next/tests -p test_stability_health.py
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any

SCRIPT = Path(__file__).resolve().parents[1] / "stability-health.py"


def load():
    spec = importlib.util.spec_from_file_location("stability_health", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve annotations through the module
    spec.loader.exec_module(module)
    return module


health = load()
TOKEN = "sntrys_TESTTOKEN_0123456789abcdef"

# Recorded shapes of the Sentry API (organizations/{org}/sessions, events, issues).
SESSIONS_TOTALS = {"groups": [{"by": {}, "totals": {
    "sum(session)": 20000, "count_unique(user)": 900, "crash_free_rate(session)": 0.99950,
    "crash_free_rate(user)": 0.9911, "avg(session.duration)": 5_400_000.0}}]}
SESSIONS_BY_STATUS = {"groups": [
    {"by": {"session.status": "healthy"}, "totals": {"sum(session)": 19880}},
    {"by": {"session.status": "errored"}, "totals": {"sum(session)": 100}},
    {"by": {"session.status": "crashed"}, "totals": {"sum(session)": 10}},
    {"by": {"session.status": "abnormal"}, "totals": {"sum(session)": 10}}]}
SESSIONS_BY_RELEASE = {"groups": [
    {"by": {"release": "cmux-next@0.70.0+900"}, "totals": {
        "sum(session)": 15000, "count_unique(user)": 800, "crash_free_rate(session)": 0.9996,
        "crash_free_rate(user)": 0.992}},
    {"by": {"release": "cmux-next@0.70.0+899"}, "totals": {
        "sum(session)": 5000, "count_unique(user)": 300, "crash_free_rate(session)": 0.9992,
        "crash_free_rate(user)": None}}]}
# The stall_bucket values LagSpikeEvent.bucket sends.
LAG_BUCKETS = {"data": [{"tags[stall_bucket]": "250-500ms", "count()": 200},
                        {"tags[stall_bucket]": "500ms-1s", "count()": 60},
                        {"tags[stall_bucket]": "1-2s", "count()": 30},
                        {"tags[stall_bucket]": "2s+", "count()": 10}]}
EXIT_OUTCOMES = {"data": [{"tags[exit_outcome]": "clean", "count()": 19000},
                          {"tags[exit_outcome]": "crash-caught", "count()": 10},
                          {"tags[exit_outcome]": "unclean-no-report", "count()": 8}]}


def raw_issue(n: int, title: str, events: int, culprit: str = "", annotations: list[Any] | None = None) -> dict[str, Any]:
    return {"id": str(1000 + n), "shortId": f"CMUXTERM-MACOS-{n}", "title": title, "culprit": culprit,
            "level": "error", "count": str(events * 3), "userCount": 40, "firstSeen": "2026-10-20T00:00:00Z",
            "lastSeen": "2026-10-25T00:00:00Z", "permalink": f"https://manaflow.sentry.io/issues/{1000 + n}/",
            "filtered": {"count": str(events), "userCount": 5}, "annotations": annotations or []}



def link(number: int) -> dict[str, str]:
    return {"displayName": f"GitHub #{number}", "url": f"https://github.com/manaflow-ai/cmux/issues/{number}"}


# Sentry takes a native event's culprit from its first in-app frame: a cmux Swift function, never the AppKit frame
# -[NSWindow makeKeyWindow]. Hang C is claimed only because its Sentry issue links #24913.
HANG_ISSUES = [
    raw_issue(1, "MainThreadHang: main thread busy for 2 s and counting", 3, culprit="WorkspaceStore.apply(_:)"),
    raw_issue(2, "MainThreadHang: main thread busy for 10 s and counting", 7, culprit="BrowserWindow.makeKey()",
              annotations=[link(24913)]),
]
SPIKE_ISSUES = [
    raw_issue(20, "MainThreadStall: main thread stalled 250-500ms", 200, culprit="SidebarModel.rebuild()",
              annotations=[link(30010)]),
    raw_issue(21, "MainThreadStall: main thread stalled 2s+", 10, culprit="BrowserWindow.makeKey()",
              annotations=[link(24913)]),
]
TOP_PAGE_1 = [
    raw_issue(10, "EXC_BAD_ACCESS: TerminalSurface.draw", 50, annotations=[link(30001)]),
    raw_issue(11, "SIGABRT: CEF renderer", 30, annotations=['<a href="https://github.com/manaflow-ai/cmux/issues/24913">#24913</a>']),
]
TOP_PAGE_2 = [raw_issue(12, "NSInternalInconsistencyException", 20)]
LINK_MORE = ('<https://sentry.io/api/0/organizations/manaflow/issues/?cursor=0:0:1>; rel="previous"; results="false"; '
             'cursor="0:0:1", <https://sentry.io/api/0/organizations/manaflow/issues/?cursor=0:100:0>; rel="next"; '
             'results="true"; cursor="0:100:0"')
LINK_END = ('<https://sentry.io/api/0/organizations/manaflow/issues/?cursor=0:100:0>; rel="next"; results="false"; '
            'cursor="0:200:0"')

OWNERS = [{"owner": "PL-cefhost", "github_issue": 24913, "eta": "2026-11-15", "why": "CEF API 30",
           "sentry_issues": []}]


class Recorded:
    """A Fetch that answers from recorded responses and keeps every request."""

    def __init__(self, **overrides: Any) -> None:
        self.calls: list[tuple[str, list[tuple[str, str]]]] = []
        self.responses = {"totals": SESSIONS_TOTALS, "status": SESSIONS_BY_STATUS, "release": SESSIONS_BY_RELEASE,
                          "lag": LAG_BUCKETS, "exits": EXIT_OUTCOMES, "hangs": HANG_ISSUES,
                          "spikes": SPIKE_ISSUES, "top": [TOP_PAGE_1, TOP_PAGE_2]}
        self.responses.update(overrides)

    def __call__(self, path: str, params: list[tuple[str, str]]) -> tuple[Any, dict[str, str]]:
        self.calls.append((path, params))
        p = dict(params)
        if path.endswith("/sessions/"):
            key = {"session.status": "status", "release": "release"}.get(p.get("groupBy", ""), "totals")
            return copy.deepcopy(self.responses[key]), {}
        if path.endswith("/events/"):
            return copy.deepcopy(self.responses["lag" if "stall_bucket" in p["query"] else "exits"]), {}
        if path.endswith("/issues/"):
            if "main_thread_watchdog" in p["query"]:
                return copy.deepcopy(self.responses["hangs"]), {}
            if "main_thread_stall" in p["query"]:
                return copy.deepcopy(self.responses["spikes"]), {}
            pages = self.responses["top"]
            page = 1 if p.get("cursor") == "0:100:0" else 0
            more = page + 1 < len(pages)
            return copy.deepcopy(pages[page]), {"link": LINK_MORE if more else LINK_END}
        raise AssertionError(f"unexpected path {path}")


def run(argv: list[str], fetch: Any = None, environ: dict[str, str] | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with tempfile.TemporaryDirectory() as tmp:
        owners = Path(tmp) / "owners.json"
        owners.write_text(json.dumps({"owners": OWNERS}))
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = health.main(["--owners", str(owners), *argv], environ={} if environ is None else environ,
                               fetch=fetch)
    return code, out.getvalue(), err.getvalue()


def report(**overrides: Any) -> dict[str, Any]:
    code, out, _ = run(["--json", "--top", "3"], fetch=Recorded(**overrides))
    assert code == 0, out
    return json.loads(out)


class ReleaseHealthTests(unittest.TestCase):
    def test_crash_free_sessions_users_and_session_hours(self) -> None:
        s = report()["sessions"]
        self.assertEqual(s["sessions"], 20000)
        self.assertEqual(s["users"], 900)
        self.assertAlmostEqual(s["crash_free_sessions_pct"], 99.95)
        self.assertAlmostEqual(s["crash_free_users_pct"], 99.11)
        # 20000 sessions x 1.5 h average.
        self.assertEqual(s["session_hours"], 30000.0)
        self.assertEqual(s["by_status"], {"healthy": 19880, "errored": 100, "crashed": 10, "abnormal": 10})

    def test_per_release_rows(self) -> None:
        releases = report()["releases"]
        self.assertEqual([r["release"] for r in releases], ["cmux-next@0.70.0+900", "cmux-next@0.70.0+899"])
        self.assertAlmostEqual(releases[0]["crash_free_sessions_pct"], 99.96)
        self.assertIsNone(releases[1]["crash_free_users_pct"])

    def test_requests_scope_project_environment_period_and_app_tag(self) -> None:
        fetch = Recorded()
        run(["--json", "--env", "rc-next", "--days", "7"], fetch=fetch)
        for path, params in fetch.calls:
            p = dict(params)
            self.assertEqual(p["environment"], "rc-next", path)
            self.assertEqual(p["statsPeriod"], "7d", path)
            self.assertEqual(p["project"], health.DEFAULT_PROJECT_ID, path)
            if not path.endswith("/sessions/"):
                self.assertIn("app:cmux-next", p["query"], path)


class RatesTests(unittest.TestCase):
    def test_lag_spikes_per_1k_session_hours(self) -> None:
        lag = report()["lag_spikes"]
        self.assertEqual(lag["total"], 300)
        self.assertEqual(lag["by_bucket"], {"250-500ms": 200, "500ms-1s": 60, "1-2s": 30, "2s+": 10})
        self.assertEqual(lag["per_1k_session_hours"], 10.0)

    def test_spike_signatures_carry_their_github_issues(self) -> None:
        lag = report()["lag_spikes"]
        self.assertEqual(lag["issues"], 2)
        self.assertEqual(lag["issues_without_github"], [])

    def test_hangs_split_own_and_other_owner(self) -> None:
        hangs = report()["hangs"]
        self.assertEqual(hangs["own_events"], 3)
        self.assertEqual(hangs["other_owner_events"], 7)
        self.assertEqual(hangs["min_seconds"], 2)
        self.assertEqual(hangs["own_per_1k_session_hours"], 0.1)

    def test_unclean_exits_per_session(self) -> None:
        exits = report()["unclean_exits"]
        self.assertEqual(exits["no_report"], 8)
        self.assertEqual(exits["no_report_pct_of_sessions"], 0.04)
        self.assertEqual(exits["no_report_per_1k_sessions"], 0.4)
        self.assertEqual(exits["abnormal_sessions"], 10)

    def test_unclean_exits_per_1k_sessions(self) -> None:
        # Every outcome but clean and system-shutdown is unclean: 10 crash-caught + 8 unclean-no-report.
        exits = report()["unclean_exits"]
        self.assertEqual(exits["total"], 18)
        self.assertEqual(exits["per_1k_sessions"], 0.9)
        self.assertEqual(exits["launches_reported"], 19018)
        outcomes = {"data": [{"tags[exit_outcome]": "clean", "count()": 19000},
                             {"tags[exit_outcome]": "signal", "count()": 6},
                             {"tags[exit_outcome]": "exception", "count()": 2},
                             {"tags[exit_outcome]": "unclean-no-report", "count()": 12},
                             {"tags[exit_outcome]": "system-shutdown", "count()": 40}]}
        exits = report(exits=outcomes)["unclean_exits"]
        self.assertEqual(exits["total"], 20)
        self.assertEqual(exits["per_1k_sessions"], 1.0)
        self.assertEqual(exits["by_outcome"]["system-shutdown"], 40)

    def test_no_session_hours_gives_no_rate(self) -> None:
        totals = copy.deepcopy(SESSIONS_TOTALS)
        totals["groups"][0]["totals"]["avg(session.duration)"] = None
        r = report(totals=totals)
        self.assertIsNone(r["sessions"]["session_hours"])
        self.assertIsNone(r["lag_spikes"]["per_1k_session_hours"])


class IssuesTests(unittest.TestCase):
    def test_top_issues_follow_the_cursor_and_stop_at_top(self) -> None:
        fetch = Recorded()
        code, out, _ = run(["--json", "--top", "3"], fetch=fetch)
        self.assertEqual(code, 0)
        top = json.loads(out)["top_issues"]
        self.assertEqual([i["short_id"] for i in top], ["CMUXTERM-MACOS-10", "CMUXTERM-MACOS-11", "CMUXTERM-MACOS-12"])
        cursors = [dict(p).get("cursor") for path, p in fetch.calls
                   if path.endswith("/issues/") and "is:unresolved" in dict(p)["query"]]
        self.assertEqual(cursors, [None, "0:100:0"])

    def test_top_issues_skip_the_exit_outcome_events(self) -> None:
        # One exit_outcome event per launch (most of them clean) would otherwise be the top issue.
        fetch = Recorded()
        run(["--json", "--top", "3"], fetch=fetch)
        queries = [dict(p)["query"] for path, p in fetch.calls
                   if path.endswith("/issues/") and "is:unresolved" in dict(p)["query"]]
        self.assertTrue(queries)
        for query in queries:
            self.assertIn("!has:exit_outcome", query)

    def test_top_stops_without_a_next_page(self) -> None:
        code, out, _ = run(["--json", "--top", "50"], fetch=Recorded(top=[TOP_PAGE_1]))
        self.assertEqual(code, 0)
        self.assertEqual(len(json.loads(out)["top_issues"]), 2)

    def test_events_are_the_period_counts_and_github_links_are_read(self) -> None:
        top = report()["top_issues"]
        self.assertEqual(top[0]["events"], 50)
        self.assertEqual(top[0]["github"], [30001])
        self.assertEqual(top[1]["github"], [24913])
        self.assertEqual(top[2]["github"], [])

    def test_other_owner_by_github_issue_and_short_id(self) -> None:
        r = report()
        self.assertEqual(r["top_issues"][1]["owner"]["owner"], "PL-cefhost")
        self.assertIsNone(r["top_issues"][0]["owner"])
        self.assertEqual(r["hangs"]["issues"][1]["owner"]["owner"], "PL-cefhost")
        owners = [{"owner": "PL-x", "github_issue": None, "eta": None, "sentry_issues": ["CMUXTERM-MACOS-12"]}]
        issue = health.normalize_issue(TOP_PAGE_2[0], owners)
        self.assertEqual(issue["owner"]["owner"], "PL-x")
        self.assertIsNone(health.normalize_issue(TOP_PAGE_1[0], owners)["owner"])

    def test_other_owner_row(self) -> None:
        rows = report()["other_owner"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["owner"], "PL-cefhost")
        self.assertEqual(rows[0]["hang_events"], 7)
        self.assertEqual(rows[0]["issue_events"], 30)
        self.assertEqual(rows[0]["issues"], ["CMUXTERM-MACOS-2", "CMUXTERM-MACOS-11"])

    def test_an_own_hang_naming_make_key_window_without_the_link_stays_own(self) -> None:
        hangs = [raw_issue(3, "MainThreadHang: main thread busy for 4 s and counting", 5,
                           culprit="-[NSWindow makeKeyWindow]")]
        r = report(hangs=hangs)
        self.assertIsNone(r["hangs"]["issues"][0]["owner"])
        self.assertEqual(r["hangs"]["own_events"], 5)
        self.assertEqual(r["hangs"]["other_owner_events"], 0)

    def test_the_checked_in_owner_map_loads(self) -> None:
        owners = health.load_owners(health.DEFAULT_OWNERS)
        self.assertTrue(owners)
        for owner in owners:
            self.assertTrue(owner["owner"] and owner["eta"] and owner["github_issue"])

    def owners_exit(self, entry: dict[str, Any]) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / "owners.json"
            bad.write_text(json.dumps({"owners": [entry]}))
            err = io.StringIO()
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                code = health.main(["--owners", str(bad)], environ={}, fetch=Recorded())
        return code, err.getvalue()

    def test_an_owner_without_an_eta_is_exit_2(self) -> None:
        code, err = self.owners_exit({"owner": "PL-x", "github_issue": 1, "eta": None})
        self.assertEqual(code, 2)
        self.assertIn("PL-x has no eta", err)

    def test_an_owner_pattern_is_refused(self) -> None:
        code, err = self.owners_exit({"owner": "PL-x", "github_issue": 1, "eta": "soon", "pattern": "makeKeyWindow"})
        self.assertEqual(code, 2)
        self.assertIn("pattern is not supported", err)

    def test_an_owner_without_a_github_issue_is_exit_2(self) -> None:
        code, err = self.owners_exit({"owner": "PL-x", "eta": "soon", "sentry_issues": ["CMUXTERM-MACOS-1"]})
        self.assertEqual(code, 2)
        self.assertIn("bad owners file", err)


class CheckTests(unittest.TestCase):
    def test_all_targets_met_exits_0(self) -> None:
        code, out, _ = run(["--check"], fetch=Recorded())
        self.assertEqual(code, 1, "the recorded own hang (3 events) misses the 0-hang target")
        hangs = [i for i in HANG_ISSUES if i["annotations"]]
        code, out, _ = run(["--check", "--json"], fetch=Recorded(hangs=hangs))
        self.assertEqual(code, 0, out)
        self.assertTrue(all(c["ok"] for c in json.loads(out)["checks"]))

    def test_each_target_misses(self) -> None:
        totals = copy.deepcopy(SESSIONS_TOTALS)
        totals["groups"][0]["totals"]["crash_free_rate(session)"] = 0.998
        lag = {"data": [{"tags[stall_bucket]": "250-500ms", "count()": 301}]}
        exits = {"data": [{"tags[exit_outcome]": "unclean-no-report", "count()": 21}]}
        code, out, _ = run(["--check", "--json"], fetch=Recorded(totals=totals, lag=lag, exits=exits, hangs=[]))
        self.assertEqual(code, 1)
        missed = {c["name"] for c in json.loads(out)["checks"] if not c["ok"]}
        self.assertEqual(missed, {"crash_free_sessions_pct", "unclean_no_report_pct",
                                  "lag_spikes_per_1k_session_hours"})

    def test_a_spike_signature_without_a_github_issue_is_a_miss(self) -> None:
        spikes = SPIKE_ISSUES + [raw_issue(22, "MainThreadStall: main thread stalled 500ms-1s", 4,
                                           culprit="TabStrip.layout()")]
        code, out, _ = run(["--check", "--json"], fetch=Recorded(spikes=spikes, hangs=[]))
        self.assertEqual(code, 1)
        r = json.loads(out)
        self.assertEqual({c["name"] for c in r["checks"] if not c["ok"]}, {"lag_spike_issues_without_github"})
        self.assertEqual([i["short_id"] for i in r["lag_spikes"]["issues_without_github"]], ["CMUXTERM-MACOS-22"])
        code, out, _ = run(["--top", "3"], fetch=Recorded(spikes=spikes, hangs=[]))
        self.assertIn("lag spike signatures: 3, without a GitHub issue 1", out)
        self.assertIn("MISS lag_spike_issues_without_github 1 <= 0", out)

    def test_no_unclean_exit_data_is_a_miss_not_zero(self) -> None:
        code, out, _ = run(["--check", "--json"], fetch=Recorded(exits={"data": []}, hangs=[]))
        self.assertEqual(code, 1)
        check = {c["name"]: c for c in json.loads(out)["checks"]}["unclean_no_report_pct"]
        self.assertIsNone(check["value"])
        self.assertFalse(check["ok"])

    def test_no_sessions_is_a_miss(self) -> None:
        code, out, _ = run(["--check", "--json"], fetch=Recorded(totals={"groups": []}, hangs=[]))
        self.assertEqual(code, 1)
        check = {c["name"]: c for c in json.loads(out)["checks"]}["crash_free_sessions_pct"]
        self.assertIsNone(check["value"])


class OutputTests(unittest.TestCase):
    def test_json_schema(self) -> None:
        r = report()
        self.assertEqual(r["schema"], "cmux-stability-health/v1")
        for key in ("sessions", "releases", "lag_spikes", "hangs", "unclean_exits", "top_issues", "other_owner",
                    "checks"):
            self.assertIn(key, r)

    def test_table(self) -> None:
        code, out, _ = run(["--top", "3"], fetch=Recorded())
        self.assertEqual(code, 0)
        self.assertIn("crash-free sessions 99.95 %  users 99.11 %", out)
        self.assertIn("cmux-next@0.70.0+900", out)
        self.assertIn("lag spikes >= 250 ms: 300 (10.0 per 1k session-hours", out)
        self.assertIn("hangs >= 2 s: own 3, other-owner 7", out)
        self.assertIn("unclean exits: 18 (0.9 per 1k sessions) clean 19000  crash-caught 10  unclean-no-report 8", out)
        self.assertIn("unclean exits without a crash report: 8 (0.04 % of sessions)", out)
        self.assertIn("PL-cefhost: hangs 7, issue events 30, #24913, ETA 2026-11-15", out)
        self.assertIn("MISS own_hang_events 3 <= 0", out)
        self.assertIn("#30001", out)

    def test_an_unexpected_response_shape_is_exit_3(self) -> None:
        shapes = {"status": {"groups": [{"totals": {}}]}, "release": [], "totals": {"detail": "x", "groups": [7]},
                  "lag": {"data": [{"tags[stall_bucket]": "1-2s", "count()": "many"}]}, "hangs": [7]}
        for key, value in shapes.items():
            with self.subTest(key):
                code, out, err = run(["--json"], fetch=Recorded(**{key: value}))
                self.assertEqual(code, 3, err)
                self.assertIn("unexpected response shape from /organizations/manaflow/", err)
                self.assertEqual(out, "")

    def test_bad_days_is_an_argument_error(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            health.parse_args(["--days", "91"])
        self.assertEqual(raised.exception.code, 2)


class _Handler(BaseHTTPRequestHandler):
    seen: list[dict[str, str]] = []
    mode = "ok"

    def do_GET(self) -> None:  # noqa: N802 - http.server's name
        _Handler.seen.append({"path": self.path, "authorization": self.headers.get("Authorization", "")})
        if _Handler.mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "http://127.0.0.2:1/elsewhere")
            self.end_headers()
            return
        if _Handler.mode == "truncated":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", "1000")
            self.end_headers()
            self.wfile.write(b'{"groups": [')
            return
        if _Handler.mode == "error":
            body = json.dumps({"detail": f"Invalid token {self.headers.get('Authorization')}"}).encode()
            self.send_response(401)
        elif _Handler.mode == "long_error":
            # The echoed token starts before the 300-byte cut and ends after it.
            body = ("bad token " + "x" * 250 + " " + self.headers.get("Authorization", "")).encode()
            self.send_response(401)
        else:
            body = json.dumps([] if "/issues/" in self.path else {"groups": []}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args: Any) -> None:
        pass


class TokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), _Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self) -> None:
        _Handler.seen = []
        _Handler.mode = "ok"

    def test_no_token_is_exit_2(self) -> None:
        code, out, err = run([], environ={})
        self.assertEqual(code, 2)
        self.assertIn("SENTRY_AUTH_TOKEN is not set", err)
        self.assertEqual(out, "")

    def test_token_is_sent_as_bearer_header_only(self) -> None:
        fetch = health.http_fetch(self.base, TOKEN)
        data, _ = fetch("/organizations/manaflow/sessions/", [("project", "1")])
        self.assertEqual(data, {"groups": []})
        self.assertEqual(_Handler.seen[0]["authorization"], f"Bearer {TOKEN}")
        self.assertNotIn(TOKEN, _Handler.seen[0]["path"])

    def test_an_http_error_echoing_the_token_is_redacted(self) -> None:
        _Handler.mode = "error"
        code, out, err = run(["--base-url", self.base], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 3)
        self.assertIn("HTTP 401", err)
        self.assertIn("[redacted]", err)
        self.assertNotIn(TOKEN, err + out)

    def test_a_token_echoed_across_the_cut_is_redacted(self) -> None:
        _Handler.mode = "long_error"
        code, out, err = run(["--base-url", self.base], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 3)
        self.assertIn("HTTP 401", err)
        self.assertNotIn("sntrys_", err + out)
        self.assertNotIn(TOKEN[:8], err + out)

    def test_a_cut_off_body_is_exit_3(self) -> None:
        _Handler.mode = "truncated"
        code, out, err = run(["--base-url", self.base], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 3, err)
        self.assertIn("GET /organizations/manaflow/sessions/", err)
        self.assertNotIn(TOKEN, err + out)

    def test_a_redirect_to_another_host_is_refused(self) -> None:
        _Handler.mode = "redirect"
        code, out, err = run(["--base-url", self.base], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 3)
        self.assertIn("refused a redirect", err)
        self.assertNotIn(TOKEN, err + out)
        self.assertEqual(len(_Handler.seen), 1)

    def test_a_non_https_url_is_refused(self) -> None:
        code, out, err = run(["--base-url", "http://sentry.example.com"], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 3)
        self.assertIn("non-HTTPS", err)
        self.assertNotIn(TOKEN, err + out)

    def test_the_token_never_reaches_stdout(self) -> None:
        code, out, err = run(["--json", "--base-url", self.base], environ={"SENTRY_AUTH_TOKEN": TOKEN})
        self.assertEqual(code, 0)
        self.assertNotIn(TOKEN, out + err)


if __name__ == "__main__":
    unittest.main()
