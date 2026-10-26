#!/usr/bin/env python3
"""The perf cron's I/O paths and multi-tick behavior (scripts/cmux-next/perf-cron.py), with the network, git and
the fleet client faked: the row reference (no baseline ratchet), bisect progress while new tip commits arrive, a
culprit range deeper than the shallow clone (a real git repository), the issue ownership check, manage_issue,
fetch_state paging and download_redirected (a local HTTP server), github_busy, and cmd_run_part's watch/cancel loop
(a fake cmux-ci on disk). Run: python3 -I scripts/cmux-next/tests/test_perf_cron_io.py (not a CI job)."""
import argparse, datetime, http.server, importlib.util, io, json, os, stat, subprocess, sys, tempfile, threading
import unittest, zipfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("perf_cron", os.path.join(HERE, "..", "perf-cron.py"))
cron = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cron)
budgets_mod = cron.load_budgets_module()

T0 = datetime.datetime(2026, 10, 23, 12, 0, tzinfo=datetime.timezone.utc)


def at(hours):
    return T0 + datetime.timedelta(hours=hours)


def row(p95, unit="ms", floor=1.0):
    return {"p50": p95, "p95": p95, "unit": unit, "floor": floor, "budget": None}


def sha(n):
    return f"{n:040x}"


def measure_tip(state, s, rows, t):
    state["current"] = cron.new_measurement(s, "tip", [], t)
    state["current"]["parts"] = {"motion": {"state": "done"}}
    return cron.finish_measurement(state, rows, 8.33, "bench", f"run-{s[-4:]}", t, budgets_mod)


class ReferenceTests(unittest.TestCase):
    def test_a_creep_of_8_percent_per_run_regresses_within_seven_runs(self):
        # 40 ms is over the 10 ms target on every run, so only the relative rule can catch the creep (STRESS close
        # 41.7 ms, New Column 102 ms are such rows). Each run is +8 %: under the 10 % rule against the run before it,
        # but the median of the good values lags, so the creep is a candidate in consecutive runs at the cron's
        # cadence (TIP_EVERY_HOURS). A candidate is never a good value of a full baseline, so it cannot walk the
        # baseline up. From an established baseline (3 values; the first creep run is under the rule and the 4th
        # baseline value, so the spread top is the max, 43.2) it regresses at the 2nd value outside that spread; from
        # one first value the baseline takes the first 2 creep runs (fewer than CONFIRM_SAMPLES values cannot be
        # judged, review 2 of 8af6ea46de5, finding 5) and it regresses at the 2nd value outside their spread (review 1
        # of the confirm rule, finding 5; the test of 084f51bf113; review 1 of 8af6ea46de5, finding 6). No baseline
        # restarts either way.
        for baseline in ([40.0], [40.0, 40.0, 40.0]):
            state = cron.empty_state(T0)
            for i, v in enumerate(baseline):
                measure_tip(state, sha(i + 1), {"panes.close.stress.e2e": row(v)}, at(i * cron.TIP_EVERY_HOURS))
            events, value, n = [], 40.0, len(baseline)
            for i in range(n + 1, n + 8):
                value = round(value * 1.08, 2)
                events.append(measure_tip(state, sha(i), {"panes.close.stress.e2e": row(value)},
                                          at((i - 1) * cron.TIP_EVERY_HOURS)))
            self.assertEqual(state.get("baseline_restarts") or [], [])
            if len(baseline) >= cron.CONFIRM_SAMPLES:
                self.assertEqual(events.index("regressed"), 3, f"the 3rd and 4th creep runs leave the spread: {events}")
            else:
                self.assertEqual(events.index("regressed"), 4, f"the 4th and 5th creep runs leave the spread: {events}")

    def test_a_creep_under_the_rule_per_run_regresses_against_the_week_old_values_and_starts_its_range_there(self):
        # +1.5 % per run every 12 h never leaves the recent median's rule; the week-old values catch it once at least
        # CONFIRM_SAMPLES exist (at 168 h only the first value is a week old: no reference, review 2 of 8af6ea46de5,
        # finding 4; at 180 h four are, median 40.1). The 180 h and 192 h runs leave their spread: confirmed at sha 19.
        # The range starts at the newest commit still within the rule of the week-old level (sha 9), so it is short
        # enough to list and bisect, not at the newest commit of the week-old window (sha 4) nor at the newest accepted
        # creep value (sha 17) (review 1 of 8af6ea46de5, finding 2).
        state = cron.empty_state(T0)
        for i, v in enumerate((40.0, 40.2, 39.9)):
            measure_tip(state, sha(i + 1), {"panes.close.stress.e2e": row(v)}, at(i))
        events, value = [], 40.0
        for i in range(4, 30):
            value = round(value * 1.015, 2)
            events.append(measure_tip(state, sha(i), {"panes.close.stress.e2e": row(value)}, at(12 * (i - 3))))
            if events[-1] == "regressed":
                break
        self.assertIn("regressed", events, f"a +1.5 % creep for 9 days must regress, got {events}")
        reg = state["regressions"][0]
        self.assertEqual(len(events), 16, "confirmed at sha 19 (192 h); its first candidate against the week-old values was sha 18")
        self.assertEqual((reg["range"]["good"], reg["range"]["bad"]), (sha(9), sha(18)))
        self.assertIn("a creep", reg["why"])

    def test_a_confirmed_creep_is_judged_against_the_reference_it_was_confirmed_against(self):
        # Review 2 of 8af6ea46de5, finding 2: while a row is regressed its history does not move, but the week-old window
        # does, so within days its median climbs to the crept level. Judged against that, a creep that stopped just over
        # the rule (45.0 against the confirmed reference 40.2, rule 44.22) "recovered" in 2 runs unfixed (its values
        # then raised the baseline), and a bisect step called the culprit good.
        state = cron.empty_state(T0)
        name = "panes.close.stress.e2e"
        for i, v in enumerate((40.0, 40.2, 39.9)):
            measure_tip(state, sha(i + 1), {name: row(v)}, at(i))
        value, i = 40.0, 3
        while not state["regressions"]:
            i += 1
            value = round(value * 1.015, 2)
            measure_tip(state, sha(i), {name: row(value)}, at(12 * (i - 3)))
        reg = state["regressions"][0]
        self.assertEqual(reg["ref"], 40.2)
        rng, history = dict(reg["range"]), [e["p95"] for e in state["row_history"][name]]
        for k in range(1, 5):
            self.assertEqual(measure_tip(state, sha(100 + k), {name: row(45.0)}, at(12 * (i - 3 + k))), "still")
        self.assertEqual([r["name"] for r in state["regressions"]], [name])
        self.assertEqual([e["p95"] for e in state["row_history"][name]], history, "no closing value entered the baseline")
        state["current"] = cron.new_measurement(sha(12), "bisect", ["motion"], at(12 * (i + 2)), bisect_range=rng)
        state["current"]["parts"] = {"motion": {"state": "done"}}
        self.assertEqual(cron.finish_measurement(state, {name: row(45.0)}, 8.33, "bench", "u", at(12 * (i + 2)), budgets_mod),
                         "narrowed")
        self.assertEqual(state["regressions"][0]["range"]["bad"], sha(12), "45.0 is bad against the confirmed reference")

    def test_a_step_on_a_flat_row_starts_at_row_ok_even_when_the_week_old_median_is_a_little_lower(self):
        # Review 1 of 8af6ea46de5, finding 2: the week-old window was taken whenever its median was lower by any amount
        # (half the time on a flat noisy row), and its newest commit, at least 7 days old, started the range of a
        # plain step that the recent median alone flags.
        state = cron.empty_state(T0)
        name = "panes.close.stress.e2e"
        measure_tip(state, sha(1), {name: row(40.0)}, at(0))
        state["row_history"][name] = ([{"at": cron.iso(at(-24 * 9 - h)), "p95": 40.0, "sha": sha(100 + h)} for h in range(3)]
                                      + [{"at": cron.iso(at(-h)), "p95": v, "sha": sha(200 + h)}
                                         for h, v in zip(range(5, 0, -1), (40.2, 40.1, 40.3, 40.2, 40.2))])
        state["row_ok"][name] = sha(201)
        self.assertEqual(measure_tip(state, sha(2), {name: row(52.0)}, at(1)), "good")
        self.assertEqual(measure_tip(state, sha(3), {name: row(52.3)}, at(2)), "regressed")
        reg = state["regressions"][0]
        self.assertEqual((reg["range"]["good"], reg["range"]["bad"]), (sha(201), sha(2)), "not the week-old sha(100)")
        self.assertNotIn("creep", reg["why"])

    def test_one_noisy_run_does_not_move_the_reference(self):
        state = cron.empty_state(T0)
        for i, v in enumerate([20.0, 20.2, 19.9, 20.1, 20.0]):
            measure_tip(state, sha(i + 1), {"r.e2e": row(v)}, at(i))
        ref = cron.reference_rows(state, at(5))["r.e2e"]["p95"]
        self.assertAlmostEqual(ref, 20.0, places=1)
        measure_tip(state, sha(9), {"r.e2e": row(21.9)}, at(6))  # +9.5 %: within the rule, accepted as good
        self.assertLess(cron.reference_rows(state, at(7))["r.e2e"]["p95"], 20.2,
                        "one good run under the rule moves the median by at most one neighbor, not to 21.9")

    def test_the_week_old_reference_catches_a_creep_too_slow_for_the_median(self):
        aged = [{"at": cron.iso(at(-24 * 8 - h)), "p95": 20.0} for h in range(cron.CONFIRM_SAMPLES)]
        hist = aged + [{"at": cron.iso(at(-i)), "p95": 23.0} for i in range(5)]
        self.assertEqual(cron.row_reference(hist, T0), 20.0)
        self.assertIsNone(cron.row_reference([], T0))

    def test_fewer_week_old_values_than_confirm_samples_are_no_reference(self):
        # Review 2 of 8af6ea46de5, finding 4: one week-old value (the first after a rebase, or a sparse week) was the
        # reference and the baseline window, which then was never full, so 3 creep-only candidates restarted the row.
        name = "panes.close.stress.e2e"
        hist = [{"at": cron.iso(at(-24 * 8)), "p95": 20.0, "sha": sha(50)}] + \
               [{"at": cron.iso(at(-i)), "p95": 23.0, "sha": sha(60 + i)} for i in range(5)]
        self.assertEqual(cron.row_reference(hist, T0), 23.0)
        state = {"row_history": {name: hist}}
        window, aged_ref = cron.baseline_window(state, {"name": name, "p95": 24.0, "floor": 1.0}, T0, 0.10)
        self.assertEqual((len(window), aged_ref), (5, None), "the full recent window")

    def test_a_state_from_before_the_history_starts_from_its_last_good_value(self):
        state = cron.empty_state(T0)
        state["last_good"] = {"sha": sha(1), "measured_at": cron.iso(T0), "rows": {"r.e2e": row(20.0)}, "refresh_ms": 8.33}
        state["last"] = state["last_good"]
        self.assertEqual(measure_tip(state, sha(2), {"r.e2e": row(20.5)}, at(1)), "good")
        self.assertEqual([e["p95"] for e in state["row_history"]["r.e2e"]], [20.0, 20.5])


class CountFloorTests(unittest.TestCase):
    def test_one_new_dropped_frame_regresses(self):
        regs = cron.find_regressions({"panes.split.light.missed": {**row(1, "frames"), "refresh_ms": 8.33}},
                                     {"panes.split.light.missed": {**row(0, "frames"), "refresh_ms": 8.33}}, 8.33, 8.33, budgets_mod)
        self.assertEqual([r["name"] for r in regs], ["panes.split.light.missed"])


class BisectProgressTests(unittest.TestCase):
    def regressed_state(self):
        state = cron.empty_state(T0)
        state["last_good"] = state["last"] = {"sha": sha(1), "measured_at": cron.iso(T0), "rows": {}}
        state["last_tried"] = {"sha": sha(100), "at": cron.iso(T0)}
        state["regressions"] = [{"name": "panes.split.e2e", "range": {"good": sha(1), "bad": sha(100), "skip": [], "steps": 0}}]
        return state

    def test_bisect_progresses_while_a_new_tip_arrives_every_tick(self):
        state, tip_starts, bisect_steps, done_at = self.regressed_state(), 0, 0, None
        good, bad = 1, 100
        for tick in range(60):  # 20 h of 20-minute ticks, a new tip every tick
            t = at(tick / 3)
            bisect = None
            if bad - good <= 1 and done_at is None:
                done_at = tick
            if bad - good > 1:
                mid = (good + bad) // 2
                bisect = {"sha": sha(mid), "range": state["regressions"][0]["range"], "rows": ["panes.split.e2e"]}
            d = cron.decide(state, t, sha(1000 + tick), bisect, lambda s: ["motion"], None)
            cur = state["current"]
            if d["action"] != "part":
                continue
            # The measurement finishes in this tick (both parts at once) to keep the test short.
            cur["parts_todo"] = []
            if cur["kind"] == "tip":
                tip_starts += 1
                state["current"] = None
                state["last_tried"] = {"sha": cur["sha"], "at": cron.iso(t)}
                state.setdefault("history", []).append({"sha": cur["sha"], "kind": "tip", "at": cron.iso(t)})
            else:
                bisect_steps += 1
                state["current"] = None
                mid = int(cur["sha"], 16)
                rng = state["regressions"][0]["range"]
                if mid >= 37:  # the culprit is commit 37
                    bad, rng["bad"] = mid, cur["sha"]
                else:
                    good, rng["good"] = mid, cur["sha"]
        self.assertEqual((good, bad), (36, 37), "the range narrows to one commit")
        self.assertGreaterEqual(bisect_steps, 6)
        self.assertLessEqual(done_at, 10, "the bisect is not starved by the new tips: about one step a tick")
        self.assertGreaterEqual(tip_starts, 1, "tips are still measured")

    def test_with_nothing_to_bisect_every_new_tip_is_measured(self):
        state = cron.empty_state(T0)
        state["last_tried"] = {"sha": sha(1), "at": cron.iso(T0)}
        d = cron.decide(state, at(0.3), sha(2), None, lambda s: ["motion"], None)
        self.assertEqual((d["action"], state["current"]["kind"]), ("part", "tip"))


def git_in(d, *args):
    return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True, check=True).stdout.strip()


class ShallowRangeTests(unittest.TestCase):
    """range_commits on a real shallow clone: a range older than the clone's depth is deepened, then listed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        origin = os.path.join(self.tmp.name, "origin")
        os.makedirs(origin)
        git_in(origin, "init", "-q", "-b", cron.STATE_BRANCH)
        git_in(origin, "config", "user.email", "t@t")
        git_in(origin, "config", "user.name", "t")
        self.commits = []
        for i in range(40):
            with open(os.path.join(origin, "f"), "w") as f:
                f.write(str(i))
            git_in(origin, "add", "f")
            git_in(origin, "commit", "-q", "-m", f"c{i}")
            self.commits.append(git_in(origin, "rev-parse", "HEAD"))
        self.clone = os.path.join(self.tmp.name, "clone")
        subprocess.run(["git", "clone", "-q", "--depth", "5", "--branch", cron.STATE_BRANCH, f"file://{origin}", self.clone],
                       check=True, capture_output=True)

    def test_a_range_older_than_the_clone_is_deepened_and_listed(self):
        good, bad = self.commits[3], self.commits[39]
        with mock.patch.object(cron, "ROOT", self.clone), mock.patch.object(cron, "DEEPEN_STEP", 10):
            between = cron.range_commits(good, bad)
        self.assertEqual(between, self.commits[4:39])
        self.assertEqual(cron.bisect_midpoint(between, lambda c: True), self.commits[4 + len(between) // 2])

    def test_a_range_past_every_deepen_round_is_logged_not_listed_empty(self):
        good, bad = self.commits[0], self.commits[39]
        out = io.StringIO()
        with mock.patch.object(cron, "ROOT", self.clone), mock.patch.object(cron, "DEEPEN_STEP", 2), \
                mock.patch.object(cron, "DEEPEN_ROUNDS", 2), mock.patch("sys.stdout", out):
            self.assertIsNone(cron.range_commits(good, bad))
        self.assertIn("cannot list the range", out.getvalue())


class IssueOwnershipTests(unittest.TestCase):
    BOT = {"login": cron.ISSUE_AUTHOR}

    def issue(self, number, user, body, state="open"):
        return {"number": number, "title": cron.ISSUE_TITLE, "user": user, "body": body, "state": state}

    def test_a_persons_issue_with_the_same_title_is_never_taken(self):
        human = self.issue(5, {"login": "someone"}, f"{cron.ISSUE_MARK} copied")
        unmarked = self.issue(6, self.BOT, "no mark")
        own = self.issue(3, self.BOT, f"{cron.ISSUE_MARK}\nrows")

        def gh(path, *a, **k):
            if path.endswith("/issues/5"):
                return human
            if path.startswith("/search/issues"):
                return {"items": [human, unmarked, own]}
            raise AssertionError(path)
        with mock.patch.object(cron, "gh_request", gh):
            self.assertEqual(cron.find_issue("o/r", 5)["number"], 3, "the state's number names a person's issue: not taken")
        with mock.patch.object(cron, "gh_request", lambda p, *a, **k: {"items": [human, unmarked]}):
            self.assertIsNone(cron.find_issue("o/r"))


class ManageIssueTests(unittest.TestCase):
    def run_manage(self, issue, state, event, set_changed=True):
        calls = []

        def gh(path, method="GET", body=None, **k):
            calls.append((method, path, body))
            if method == "GET" and path.startswith("/search/issues"):
                return {"items": [issue] if issue else []}
            if method == "GET":
                return issue or {}
            if method == "POST" and path.endswith("/issues"):
                return {"number": 77}
            return {}
        with mock.patch.object(cron, "gh_request", gh):
            line = cron.manage_issue("o/r", state, event, at(1), "run-url", "summary", set_changed)
        return line, [(m, p, b) for m, p, b in calls if m != "GET"]

    def regressed_state(self):
        state = cron.empty_state(T0)
        state["last"] = {"sha": sha(2), "measured_at": cron.iso(at(1)), "rows": {}}
        state["regressions"] = [{"name": "r.e2e", "p95": 30.0, "base": 20.0, "range": {"good": sha(1), "bad": sha(2)}}]
        return state

    def own(self, state="open"):
        return {"number": 9, "title": cron.ISSUE_TITLE, "user": {"login": cron.ISSUE_AUTHOR},
                "body": cron.ISSUE_MARK, "state": state}

    def test_opens_a_new_issue_with_the_mark(self):
        state = self.regressed_state()
        line, writes = self.run_manage(None, state, "regressed")
        self.assertEqual(line, "opened issue #77")
        self.assertEqual(writes[0][0:2], ("POST", "/repos/o/r/issues"))
        self.assertIn(cron.ISSUE_MARK, writes[0][2]["body"])
        self.assertIn("compared only with values of the same host", writes[0][2]["body"])
        self.assertEqual(state["issue"], 77)

    def test_reopens_a_closed_own_issue_with_a_comment(self):
        line, writes = self.run_manage(self.own("closed"), self.regressed_state(), "still", set_changed=False)
        self.assertEqual(line, "reopened issue #9")
        self.assertEqual(writes[0][2].get("state"), "open")
        self.assertTrue(any(p.endswith("/comments") for _, p, _ in writes))

    def test_closes_on_recovery(self):
        state = cron.empty_state(T0)
        state["last"] = {"sha": sha(3), "measured_at": cron.iso(at(1)), "rows": {}}
        line, writes = self.run_manage(self.own(), state, "recovered")
        self.assertEqual(line, "closed issue #9")
        self.assertEqual(writes[-1][2], {"state": "closed", "state_reason": "completed"})

    def test_a_persons_issue_is_left_alone_and_the_cron_opens_its_own(self):
        human = {"number": 4, "title": cron.ISSUE_TITLE, "user": {"login": "someone"}, "body": "", "state": "open"}
        state = self.regressed_state()
        state["issue"] = 4
        line, writes = self.run_manage(human, state, "regressed")
        self.assertEqual(line, "opened issue #77")
        self.assertFalse(any("/issues/4" in p for _, p, _ in writes), "the person's issue gets no write")


class _Handler(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_GET(self):  # noqa: N802
        _Handler.seen.append((self.path, self.headers.get("Authorization")))
        if self.path == "/artifact":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/storage")
            self.end_headers()
            return
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("state.json", json.dumps({"schema": cron.SCHEMA, "marker": "trusted"}))
        body = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


class FetchStateTests(unittest.TestCase):
    def setUp(self):
        _Handler.seen = []
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.shutdown)
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def test_the_token_is_not_sent_to_storage(self):
        with mock.patch.dict(os.environ, {"GH_TOKEN": "secret"}):
            blob = cron.download_redirected(self.base + "/artifact")
        self.assertTrue(blob.startswith(b"PK"))
        self.assertEqual(_Handler.seen, [("/artifact", "Bearer secret"), ("/storage", None)])

    def test_forged_artifacts_on_page_one_do_not_hide_the_trusted_state(self):
        repo_id = 42
        forged = [{"id": i, "created_at": f"2026-10-23T12:{i % 60:02d}:00Z", "archive_download_url": self.base + "/forged",
                   "workflow_run": {"id": 1000 + i, "repository_id": repo_id, "head_repository_id": 99, "head_branch": "x"}}
                  for i in range(100)]
        trusted = {"id": 500, "created_at": "2026-10-23T10:00:00Z", "archive_download_url": self.base + "/artifact",
                   "workflow_run": {"id": 7, "repository_id": repo_id, "head_repository_id": repo_id, "head_branch": cron.STATE_BRANCH}}
        pages = []

        def gh(path, *a, **k):
            if path == "/repos/o/r":
                return {"id": repo_id}
            if "/actions/artifacts" in path:
                page = int(path.rsplit("page=", 1)[1])
                pages.append(page)
                return {"artifacts": forged if page == 1 else [trusted]}
            if path == "/repos/o/r/actions/runs/7":
                return {"path": cron.STATE_WORKFLOW, "event": "workflow_dispatch", "head_branch": cron.STATE_BRANCH,
                        "head_repository": {"id": repo_id}}
            raise AssertionError(path)
        with tempfile.TemporaryDirectory() as d, mock.patch.object(cron, "gh_request", gh), \
                mock.patch.dict(os.environ, {"GH_TOKEN": "secret"}), mock.patch("sys.stdout", io.StringIO()):
            self.assertTrue(cron.fetch_state("o/r", d))
            with open(os.path.join(d, "state.json")) as f:
                self.assertEqual(json.load(f)["marker"], "trusted")
        self.assertEqual(pages, [1, 2])
        self.assertNotIn("/forged", [p for p, _ in _Handler.seen], "an untrusted artifact is never downloaded")


class GithubBusyTests(unittest.TestCase):
    def test_a_nightly_job_waiting_for_a_mac_holds_the_parts(self):
        def gh(path, *a, **k):
            if "/workflows/nightly.yml/runs?status=queued" in path:
                return {"workflow_runs": [{"id": 1, "created_at": cron.iso(at(-1)), "name": "nightly", "status": "queued"}]}
            if "/workflows/" in path:
                return {"workflow_runs": []}
            if path.startswith("/repos/o/r/actions/runs/1/jobs"):
                return {"jobs": [{"status": "queued", "labels": ["glaeda-trusted-next-nightly"], "name": "build"},
                                 {"status": "queued", "labels": ["macos-15"], "name": "hosted"},
                                 {"status": "queued", "labels": ["ubuntu-latest"], "name": "lint"}]}
            raise AssertionError(path)
        with mock.patch.object(cron, "gh_request", gh):
            self.assertIn("1 job(s) waiting for a Mac runner, e.g. build", cron.github_busy("o/r", "queued", T0),
                          "a GitHub-hosted macos-15 job is not fleet load")

    def test_an_old_parked_run_and_a_linux_job_do_not(self):
        def gh(path, *a, **k):
            if "/workflows/nightly.yml/runs?status=queued" in path:
                return {"workflow_runs": [{"id": 1, "created_at": cron.iso(at(-48)), "status": "queued"},
                                          {"id": 2, "created_at": cron.iso(at(-1)), "status": "queued"}]}
            if "/workflows/" in path:
                return {"workflow_runs": []}
            if path.startswith("/repos/o/r/actions/runs/2/jobs"):
                return {"jobs": [{"status": "queued", "labels": ["ubuntu-latest"]}]}
            raise AssertionError(path)
        with mock.patch.object(cron, "gh_request", gh):
            self.assertIsNone(cron.github_busy("o/r", "queued", T0))


class TimeoutAndChainTests(unittest.TestCase):
    def test_every_part_fits_its_step_and_job_timeout(self):
        for p in cron.PARTS:
            if cron.is_linux_part(p["name"]):
                continue
            run = p.get("run_seconds", cron.PART_RUN_SECONDS)
            step, job = cron.part_minutes(run)
            need = run + cron.PART_QUEUE_SECONDS + cron.ARTIFACT_SECONDS + cron.FLEET_CHECK_SECONDS
            self.assertGreaterEqual(step * 60, need, p["name"])
            self.assertGreater(job, step, "the cleanup step gets minutes after the run step")

    def test_the_next_tick_starts_now_only_after_a_finished_mac_part_with_mac_work_left(self):
        state = cron.empty_state(T0)
        state["current"] = cron.new_measurement(sha(1), "tip", ["motion", "diff-viewer"], T0)
        self.assertTrue(cron.next_now(state, True))
        self.assertFalse(cron.next_now(state, False), "a yielded or failed part ends the chain")
        state["current"]["parts_todo"] = ["diff-viewer"]
        self.assertFalse(cron.next_now(state, True), "only the Linux part left: the dispatcher's slot is enough")
        state["current"] = None
        self.assertFalse(cron.next_now(state, True))
        state["regressions"] = [{"name": "x", "range": {"good": sha(1), "bad": sha(2)}}]
        self.assertTrue(cron.next_now(state, True), "an open range: the next tick bisects")


FAKE_CLIENT = """#!/bin/sh
echo "$@" >> "$FAKE_LOG"
case "$1" in
  run) echo "cmux-ci: step abcdef1234567890 queued"; sleep "${FAKE_SECONDS:-1}"; exit "${FAKE_EXIT:-0}";;
  status) echo "[]";;
  cancel) exit 0;;
  artifact) echo '{"rows": []}' > "$3";;
esac
"""


# The bench host as /v1/status lists it (run-part takes the step's labels from it).
BENCH_WORKERS = [{"name": cron.BENCH_WORKER, "labels": ["bench", "measure", "macos-27"]}]


class RunPartTests(unittest.TestCase):
    """cmd_run_part with a fake cmux-ci: step id parse, cancel on a foreground job, exit-code mapping."""

    def run_part(self, exit_code, status=None, seconds="1"):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", d]))
        client = os.path.join(d, "cmux-ci")
        with open(client, "w") as f:
            f.write(FAKE_CLIENT)
        os.chmod(client, os.stat(client).st_mode | stat.S_IEXEC)
        log = os.path.join(d, "calls.log")
        out = os.path.join(d, "out")
        env = {"FAKE_LOG": log, "FAKE_EXIT": str(exit_code), "FAKE_SECONDS": seconds}
        real_sleep = cron.time.sleep
        with mock.patch.dict(os.environ, env), mock.patch.object(cron.time, "sleep", lambda s: real_sleep(0.3)), \
                mock.patch.object(cron, "http_json", lambda url, timeout=30: {**(status or {"queue": []}), "workers": BENCH_WORKERS}), \
                mock.patch("sys.stdout", io.StringIO()):
            cron.cmd_run_part(argparse.Namespace(sha=sha(5), args='["--suite=budgets"]', artifact="a/report.json", key="k",
                                                 run_seconds=900, out=out, worker=cron.BENCH_WORKER, client=client))
        with open(os.path.join(out, "result.json")) as f:
            result = json.load(f)
        with open(log) as f:
            calls = f.read().splitlines()
        return result, calls, out

    def test_a_finished_step_is_done_and_its_artifact_fetched(self):
        result, calls, out = self.run_part(0)
        self.assertEqual((result["state"], result["step_id"]), ("done", "abcdef1234567890"))
        self.assertTrue(any(c.startswith("artifact abcdef1234567890") for c in calls))
        self.assertTrue(os.path.exists(os.path.join(out, "report.json")))
        run = next(c for c in calls if c.startswith("run "))
        for flag in ("--background", "--measurement", "--label bench --label measure", f"--target-worker {cron.BENCH_WORKER}",
                     f"--ref {sha(5)}", "--arg=--suite=budgets"):
            self.assertIn(flag, run)

    def test_fleet_exits_yield_and_a_timeout_fails(self):
        self.assertEqual(self.run_part(75)[0]["state"], "yielded")
        result = self.run_part(124)[0]
        self.assertEqual((result["state"], result["timed_out"]), ("failed", True))
        self.assertEqual(self.run_part(1)[0]["state"], "failed")

    def test_a_foreground_job_for_the_bench_host_cancels_the_step(self):
        status = {"queue": [{"id": "f" * 24, "labels": ["bench"], "kind": "ci-step"}], "workers": []}
        # A cancelled step makes the client exit non-zero (the fake does not stop its own sleep, so it says 1).
        result, calls, _ = self.run_part(1, status=status, seconds="2")
        self.assertTrue(any(c.startswith("cancel abcdef1234567890") for c in calls), calls)
        self.assertEqual((result["state"], result["yielded_to"]), ("yielded", "f" * 24))


if __name__ == "__main__":
    unittest.main()
