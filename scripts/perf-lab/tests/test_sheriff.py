#!/usr/bin/env python3
"""sheriff.py: legal and refused state moves, recovery before fixed, takes, the SLO report and the CLI.

  python3 -m unittest scripts/perf-lab/tests/test_sheriff.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def _load(name: str, filename: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", "store.py")
sheriff = _load("perf_lab_sheriff", "sheriff.py")

LIVE = datetime(2026, 10, 25, 0, 0, tzinfo=timezone.utc)
LEAD = "cmux-perf-lead"
HOST = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-1")
STORY = "terminal.key-frame.light"
ALERTS_ACTOR = "perf-lab-alerts"
CREATED = (None, "new")


class Clock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **delta: float) -> None:
        self.now += timedelta(**delta)


class SheriffTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "lab.sqlite"
        self.clock = Clock(LIVE)
        self.lab = store.Store(self.path, clock=self.clock)
        self.lab.migrate()
        self.sheriff = self.as_session("sheriff-1")
        self._runs = 0

    def tearDown(self) -> None:
        self.lab.close()
        self._tmp.cleanup()

    def as_session(self, session: str | None, *, lead: str | None = LEAD) -> "sheriff.Sheriff":
        return sheriff.Sheriff(self.lab, clock=self.clock, session=session, lead_session=lead)

    def query(self, sql: str, *args) -> list[tuple]:
        db = sqlite3.connect(self.path)
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def execute(self, sql: str, *args) -> int:
        db = sqlite3.connect(self.path)
        try:
            with db:
                return db.execute(sql, args).lastrowid
        finally:
            db.close()

    def point(self, pos: int, samples: list[float], *, metric: str = "key_to_frame_ms",
              better: str = "lower") -> str:
        """One waterfall run at commit position `pos`; returns the series key."""
        self._runs += 1
        run = store.Run(run_uuid=f"run-{self._runs}", kind="waterfall", measure_version="m1", story=STORY,
                        engine="webkit", macos_major=26, macos_build="26.1 (25B78)", features_hash="f0",
                        safe_mode="off", started_at=self.clock())
        self.lab.insert_run(run, build=store.Build(sha=f"{pos:040x}", config="bench", commit_pos=pos), host=HOST,
                            metrics=[store.Metric(name=metric, unit="ms", better=better, samples=samples)])
        return store.series_key(story=STORY, metric=metric, engine="webkit", host_class=HOST.host_class,
                                macos_major=26, build_config="bench")

    def group(self, *, created: datetime | None = None, start: int = 10, end: int = 12) -> int:
        """A new group with its creation row, the rows alerts._group_for writes."""
        stamp = sheriff._stamp(created or self.clock())
        db = sqlite3.connect(self.path)
        try:
            with db:
                gid = db.execute("INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) "
                                 "VALUES ('new', ?, ?, ?, ?)", (start, end, stamp, stamp)).lastrowid
                db.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                           "VALUES (?, NULL, 'new', ?, ?, ?)", (gid, ALERTS_ACTOR, f"alert on {STORY}", stamp))
            return gid
        finally:
            db.close()

    def alert(self, group_id: int, key: str, *, before: float | None = 4.0, after: float | None = 8.0,
              rule: str = "edivisive", end: int = 12, improvement: bool = False) -> int:
        (series_id,), = self.query("SELECT id FROM series WHERE series_key = ?", key)
        return self.execute(
            "INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after, "
            "is_improvement, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            series_id, group_id, rule, end - 2, end, before, after, int(improvement), sheriff._stamp(self.clock()))

    def walk(self, group_id: int, *states: str) -> None:
        for state in states:
            self.sheriff.set_state(group_id, state, reason=f"to {state}",
                                   culprit_sha="abc1234" if state == "culprit" else None)

    def state(self, group_id: int) -> str:
        return self.query("SELECT state FROM alert_groups WHERE id = ?", group_id)[0][0]


class TransitionTests(SheriffTestCase):
    def test_the_full_path_records_timestamped_history(self) -> None:
        gid = self.group()
        for state in ("triaged", "bisecting", "culprit", "assigned"):
            self.clock.advance(minutes=10)
            self.walk(gid, state)
        history = self.sheriff.history(gid)
        self.assertEqual([(h.from_state, h.to_state) for h in history],
                         [CREATED, ("new", "triaged"), ("triaged", "bisecting"), ("bisecting", "culprit"),
                          ("culprit", "assigned")])
        self.assertEqual([h.at for h in history],
                         [sheriff._stamp(LIVE + timedelta(minutes=10 * i)) for i in range(0, 5)])
        self.assertEqual([h.describe() for h in history[:2]], ["created", "new -> triaged"])
        self.assertEqual(self.query("SELECT state, culprit_sha, updated_at FROM alert_groups WHERE id = ?", gid),
                         [("assigned", "abc1234", sheriff._stamp(LIVE + timedelta(minutes=40)))])

    def test_illegal_transitions_are_refused_and_leave_no_trace(self) -> None:
        gid = self.group()
        for target in ("culprit", "assigned", "fixed", "flag-off", "accepted", "bisecting"):
            with self.subTest(target=target), self.assertRaises(sheriff.IllegalTransition):
                self.as_session(LEAD).set_state(gid, target, reason="r", culprit_sha="abc1234")
        self.walk(gid, "triaged")
        with self.assertRaises(sheriff.IllegalTransition):
            self.sheriff.set_state(gid, "assigned", reason="r")
        with self.assertRaises(sheriff.IllegalTransition):
            self.sheriff.set_state(gid, "triaged")
        with self.assertRaisesRegex(sheriff.IllegalTransition, "unknown state"):
            self.sheriff.set_state(gid, "closed")
        self.walk(gid, "invalid")
        for target in ("new", "triaged", "fixed"):
            with self.subTest(closed=target), self.assertRaisesRegex(sheriff.IllegalTransition, "closed"):
                self.as_session(LEAD).set_state(gid, target, reason="r")
        self.assertEqual(self.state(gid), "invalid")
        self.assertEqual(len(self.sheriff.history(gid)), 3)

    def test_every_listed_transition_is_between_known_states(self) -> None:
        self.assertEqual(set(sheriff.TRANSITIONS) | sheriff.TERMINAL, set(store.ALERT_GROUP_STATES))
        for source, targets in sheriff.TRANSITIONS.items():
            self.assertLessEqual(targets, set(store.ALERT_GROUP_STATES), source)
        self.assertEqual(sheriff.TERMINAL & set(sheriff.TRANSITIONS), set())

    def test_reasons_are_required_for_closing_assigning_and_steps_back(self) -> None:
        gid = self.group()
        with self.assertRaises(sheriff.MissingReason):
            self.sheriff.set_state(gid, "invalid", reason="  ")
        self.sheriff.set_state(gid, "triaged")
        self.sheriff.set_state(gid, "bisecting")
        with self.assertRaises(sheriff.MissingReason):
            self.sheriff.set_state(gid, "triaged")
        self.sheriff.set_state(gid, "triaged", reason="bisect found no culprit")
        self.assertEqual(self.state(gid), "triaged")

    def test_culprit_needs_a_commit_and_only_culprit_takes_one(self) -> None:
        gid = self.group()
        self.walk(gid, "triaged", "bisecting")
        for bad in (None, "", "not-a-sha", "abc"):
            with self.subTest(sha=bad), self.assertRaisesRegex(sheriff.SheriffError, "--culprit"):
                self.sheriff.set_state(gid, "culprit", culprit_sha=bad)
        with self.assertRaisesRegex(sheriff.SheriffError, "only with the culprit state"):
            self.sheriff.set_state(gid, "invalid", reason="r", culprit_sha="abc1234")
        self.sheriff.set_state(gid, "culprit", culprit_sha="ABCDEF0123")
        self.assertEqual(self.query("SELECT culprit_sha FROM alert_groups WHERE id = ?", gid), [("abcdef0123",)])

    def verify(self, gid: int) -> None:
        """What verify.py (017) writes for a verified culprit."""
        self.execute("UPDATE alert_groups SET culprit_verified = 1 WHERE id = ?", gid)

    def culprit(self, gid: int) -> tuple:
        return self.query("SELECT state, culprit_sha, culprit_verified FROM alert_groups WHERE id = ?", gid)[0]

    def test_a_culprit_that_did_not_hold_loses_its_verification(self) -> None:
        gid = self.group()
        self.walk(gid, "triaged", "bisecting")
        self.sheriff.set_state(gid, "culprit", culprit_sha="aaaaaaa")
        self.verify(gid)
        self.assertEqual(self.culprit(gid), ("culprit", "aaaaaaa", 1))
        self.sheriff.set_state(gid, "bisecting", reason="culprit did not reproduce")
        self.assertEqual(self.culprit(gid), ("bisecting", None, 0))
        self.sheriff.set_state(gid, "culprit", culprit_sha="bbbbbbb")
        self.assertEqual(self.culprit(gid), ("culprit", "bbbbbbb", 0))

    def test_only_the_verified_commit_keeps_its_verification(self) -> None:
        full = "abc1234" + "0" * 33
        for named, expected in (("abc1234", (full, 1)), ("def5678", ("def5678", 0))):
            with self.subTest(named=named):
                gid = self.group()
                self.walk(gid, "triaged")
                # verify.py (017) finished before the sheriff moved the group on.
                self.execute("UPDATE alert_groups SET culprit_sha = ?, culprit_verified = 1 WHERE id = ?", full, gid)
                self.walk(gid, "bisecting")
                self.sheriff.set_state(gid, "culprit", culprit_sha=named)
                self.assertEqual(self.culprit(gid), ("culprit", *expected))
                self.sheriff.set_state(gid, "assigned", reason="owner")
                self.assertEqual(self.culprit(gid), ("assigned", *expected))

    def test_accepted_needs_a_reason_and_the_performance_lead(self) -> None:
        gid = self.group()
        self.walk(gid, "triaged", "bisecting", "culprit")
        with self.assertRaises(sheriff.NotPerformanceLead):
            self.sheriff.set_state(gid, "accepted", reason="trade-off")
        with self.assertRaises(sheriff.MissingReason):
            self.as_session(LEAD).set_state(gid, "accepted")
        with self.assertRaisesRegex(sheriff.NotPerformanceLead, "none configured"):
            self.as_session(LEAD, lead=None).set_state(gid, "accepted", reason="trade-off")
        self.assertEqual(self.state(gid), "culprit")
        self.as_session(LEAD).set_state(gid, "accepted", reason="memory for latency, issue #1")
        self.assertEqual(self.query("SELECT state, reason FROM alert_groups WHERE id = ?", gid),
                         [("accepted", "memory for latency, issue #1")])
        self.assertEqual(self.sheriff.history(gid)[-1].actor, LEAD)

    def test_a_second_handle_sees_the_move_and_cannot_repeat_it(self) -> None:
        gid = self.group()
        other_lab = store.Store(self.path, clock=self.clock)
        try:
            other = sheriff.Sheriff(other_lab, clock=self.clock, session="sheriff-2", lead_session=LEAD)
            self.sheriff.set_state(gid, "triaged")
            with self.assertRaisesRegex(sheriff.IllegalTransition, "triaged -> triaged"):
                other.set_state(gid, "triaged")
        finally:
            other_lab.close()
        self.assertEqual(len(self.sheriff.history(gid)), 2)

    def test_unknown_group(self) -> None:
        with self.assertRaises(sheriff.NoSuchGroup):
            self.sheriff.set_state(99, "triaged")
        with self.assertRaises(sheriff.NoSuchGroup):
            self.sheriff.history(99)


class RecoveryTests(SheriffTestCase):
    def assigned_group(self, key: str, **alert) -> int:
        gid = self.group()
        self.alert(gid, key, **alert)
        self.walk(gid, "triaged", "bisecting", "culprit", "assigned")
        return gid

    def test_manual_fixed_without_recovery_stays_assigned(self) -> None:
        key = self.point(5, [4.0, 4.1])
        gid = self.assigned_group(key)
        with self.assertRaisesRegex(sheriff.NotRecovered, "0 of 2 judged batches"):
            self.sheriff.set_state(gid, "fixed", reason="fix landed")
        self.point(13, [8.0, 8.2])
        self.point(14, [7.9, 8.1])
        with self.assertRaisesRegex(sheriff.NotRecovered, "nearer 8 \\(after\\)"):
            self.sheriff.set_state(gid, "fixed")
        self.point(15, [4.1, 4.0])
        with self.assertRaisesRegex(sheriff.NotRecovered, "at 14"):
            self.sheriff.set_state(gid, "fixed")
        self.assertEqual(self.state(gid), "assigned")
        self.assertEqual(self.sheriff.history(gid)[-1].to_state, "assigned")

    def test_fixed_after_two_recovered_batches(self) -> None:
        key = self.point(5, [4.0])
        gid = self.assigned_group(key)
        self.point(13, [8.0])
        self.point(15, [4.2, 4.4])
        self.point(15, [9.0, 3.9])  # a second shard of the same batch: the batch median is over both points
        self.point(16, [5.9])
        recovery = self.sheriff.recovery(gid)
        self.assertTrue(recovery.recovered, recovery.explain())
        self.assertEqual(recovery.alerts[0].batches, ((15, 5.375), (16, 5.9)))
        self.sheriff.set_state(gid, "fixed", reason="fix #123")
        self.assertEqual(self.query("SELECT state, reason FROM alert_groups WHERE id = ?", gid),
                         [("fixed", "fix #123")])

    def test_points_at_or_before_the_alert_end_and_empty_points_are_not_judged(self) -> None:
        key = self.point(11, [4.0])
        self.point(12, [4.0])
        self.point(13, [])
        gid = self.assigned_group(key)
        self.assertEqual(self.sheriff.recovery(gid).alerts[0].batches, ())

    def test_higher_is_better_series_recovers_upward(self) -> None:
        key = self.point(5, [60.0], metric="fps", better="higher")
        gid = self.assigned_group(key, before=120.0, after=60.0)
        self.point(13, [80.0], metric="fps", better="higher")
        self.point(14, [100.0], metric="fps", better="higher")
        self.assertFalse(self.sheriff.recovery(gid).recovered)
        self.point(15, [118.0], metric="fps", better="higher")
        self.assertTrue(self.sheriff.recovery(gid).recovered)

    def test_every_regression_alert_of_the_group_must_recover(self) -> None:
        key = self.point(5, [4.0])
        other = self.point(5, [10.0], metric="commit_ms")
        gid = self.group()
        self.alert(gid, key)
        self.alert(gid, other, before=10.0, after=20.0)
        self.alert(gid, other, before=20.0, after=10.0, end=11, improvement=True)
        self.walk(gid, "triaged", "bisecting", "culprit", "assigned")
        for pos in (13, 14):
            self.point(pos, [4.0])
            self.point(pos, [19.0], metric="commit_ms")
        recovery = self.sheriff.recovery(gid)
        self.assertEqual([a.recovered for a in recovery.alerts], [True, False])
        with self.assertRaisesRegex(sheriff.NotRecovered, "commit_ms"):
            self.sheriff.set_state(gid, "fixed")

    def test_a_group_without_a_judgeable_alert_cannot_be_fixed(self) -> None:
        key = self.point(5, [4.0])
        bare = self.group()
        self.walk(bare, "triaged", "bisecting", "culprit", "assigned")
        with self.assertRaisesRegex(sheriff.NotRecovered, "no regression alert"):
            self.sheriff.set_state(bare, "fixed")
        no_medians = self.assigned_group(key, before=None, after=None)
        self.point(13, [4.0])
        self.point(14, [4.0])
        with self.assertRaisesRegex(sheriff.NotRecovered, "no median"):
            self.sheriff.set_state(no_medians, "fixed")

    def test_a_broken_harness_recovers_when_the_story_runs_again(self) -> None:
        key = self.point(5, [4.0])
        gid = self.assigned_group(key, rule="harness_broken", before=None, after=None)
        self.point(13, [4.0])
        self.assertFalse(self.sheriff.recovery(gid).recovered)
        self.point(14, [40.0])
        self.assertTrue(self.sheriff.recovery(gid).recovered)

    def test_flag_off_does_not_wait_for_recovery(self) -> None:
        key = self.point(5, [4.0])
        gid = self.assigned_group(key)
        self.sheriff.set_state(gid, "flag-off", reason="perfPath default off, PR #9")
        self.assertEqual(self.state(gid), "flag-off")


class TakeTests(SheriffTestCase):
    def test_one_session_holds_a_group_until_its_lease_lapses(self) -> None:
        gid = self.group()
        claim = self.sheriff.take(gid)
        self.assertEqual((claim.group_id, claim.holder), (gid, "sheriff-1"))
        self.assertEqual(self.state(gid), "new")
        with self.assertRaisesRegex(sheriff.Claimed, "held by sheriff-1"):
            self.as_session("sheriff-2").take(gid)
        self.clock.advance(hours=1)
        self.walk(gid, "triaged")  # the holder's own move renews the lease
        self.clock.advance(hours=1, minutes=59)
        with self.assertRaises(sheriff.Claimed):
            self.as_session("sheriff-2").take(gid)
        self.assertEqual(self.sheriff.groups()[0].holder, "sheriff-1")
        self.clock.advance(minutes=2)
        self.assertIsNone(self.sheriff.groups()[0].holder)
        self.as_session("sheriff-2").take(gid)
        self.assertEqual(self.sheriff.groups()[0].holder, "sheriff-2")

    def test_only_the_holder_or_the_lead_moves_a_held_group(self) -> None:
        gid = self.group()
        self.sheriff.take(gid)
        with self.assertRaisesRegex(sheriff.Claimed, "held by sheriff-1"):
            self.as_session("sheriff-2").set_state(gid, "triaged")
        self.assertEqual(self.state(gid), "new")
        self.as_session(LEAD).set_state(gid, "triaged")
        self.assertEqual(self.state(gid), "triaged")

    def test_a_take_adds_no_history_row(self) -> None:
        gid = self.group()
        self.sheriff.take(gid)
        self.clock.advance(minutes=30)
        self.sheriff.take(gid)  # a lease renewal
        self.assertEqual([(h.from_state, h.to_state) for h in self.sheriff.history(gid)], [CREATED])
        self.assertEqual(self.query("SELECT holder, held_at FROM alert_groups WHERE id = ?", gid),
                         [("sheriff-1", sheriff._stamp(LIVE + timedelta(minutes=30)))])

    def test_a_closing_move_releases_the_claim(self) -> None:
        gid = self.group()
        self.sheriff.take(gid)
        self.walk(gid, "invalid")
        self.assertEqual(self.query("SELECT holder, held_at FROM alert_groups WHERE id = ?", gid), [(None, None)])

    def test_a_lead_move_keeps_the_holder_claim_unrenewed(self) -> None:
        gid = self.group()
        self.sheriff.take(gid)
        self.clock.advance(hours=1)
        self.as_session(LEAD).set_state(gid, "triaged")
        self.assertEqual(self.query("SELECT holder, held_at FROM alert_groups WHERE id = ?", gid),
                         [("sheriff-1", sheriff._stamp(LIVE))])

    def test_no_session_reads_but_cannot_act(self) -> None:
        gid = self.group()
        anonymous = self.as_session(None)
        self.assertEqual([g.id for g in anonymous.groups()], [gid])
        with self.assertRaises(sheriff.NoSession):
            anonymous.take(gid)
        with self.assertRaises(sheriff.NoSession):
            anonymous.set_state(gid, "triaged")

    def test_closed_groups_cannot_be_taken(self) -> None:
        gid = self.group()
        self.walk(gid, "lab-drift")
        with self.assertRaises(sheriff.IllegalTransition):
            self.sheriff.take(gid)

    def test_takes_do_not_count_as_triage(self) -> None:
        gid = self.group()
        self.sheriff.take(gid)
        self.clock.advance(hours=2)
        self.assertEqual(self.sheriff.slo(LIVE)["triage"]["missed"], [gid])


class SloTests(SheriffTestCase):
    """A fixture of groups with known times, read at LIVE + 30 h."""

    def at(self, hours: float) -> datetime:
        return LIVE + timedelta(hours=hours)

    def move(self, gid: int, hours: float, state: str, **kwargs) -> None:
        self.clock.now = self.at(hours)
        self.as_session(kwargs.pop("session", "sheriff-1")).set_state(
            gid, state, reason=kwargs.pop("reason", f"to {state}"), **kwargs)

    def fixture(self) -> dict[str, int]:
        key = self.point(5, [4.0])
        groups = {}
        # Fast: triaged at 0.5 h, culprit at 3 h, flag-off at 6 h.
        groups["fast"] = g = self.group(created=self.at(0))
        self.move(g, 0.5, "triaged"); self.move(g, 0.6, "bisecting")
        self.move(g, 3, "culprit", culprit_sha="abc1234"); self.move(g, 6, "flag-off")
        # Slow: triaged at 2 h (missed), culprit at 7 h (from 1 h), fixed at 20 h (missed).
        groups["slow"] = g = self.group(created=self.at(1))
        self.alert(g, key)
        self.move(g, 3, "triaged"); self.move(g, 3.5, "bisecting")
        self.move(g, 8, "culprit", culprit_sha="def5678"); self.move(g, 9, "assigned")
        self.clock.now = self.at(19)
        self.point(13, [4.0]); self.point(14, [4.0])
        self.move(g, 21, "fixed")
        # Invalid within the hour: triage met, no culprit or fix judged.
        groups["invalid"] = g = self.group(created=self.at(2))
        self.move(g, 2.5, "invalid")
        # Stuck bisecting since 4.5 h, created at 4 h: 26 h old at 30 h, culprit overdue, stale.
        groups["stuck"] = g = self.group(created=self.at(4))
        self.move(g, 4.5, "triaged"); self.move(g, 4.6, "bisecting")
        # Young and untriaged: pending everywhere.
        groups["young"] = self.group(created=self.at(29.5))
        # Created before the window.
        groups["old"] = self.group(created=LIVE - timedelta(hours=1))
        self.clock.now = self.at(30)
        return groups

    def test_report_on_the_fixture(self) -> None:
        g = self.fixture()
        report = self.sheriff.slo(LIVE)
        self.assertEqual(report["groups"], 5)
        self.assertEqual(report["triage"]["met"], [g["fast"], g["invalid"], g["stuck"]])
        self.assertEqual(report["triage"]["missed"], [g["slow"]])
        self.assertEqual(report["triage"]["pending"], [g["young"]])
        self.assertEqual(report["triage"]["pct"], 75.0)
        self.assertEqual(report["culprit"]["reached"], [g["fast"], g["slow"]])
        self.assertEqual(report["culprit"]["overdue"], [g["stuck"]])
        self.assertEqual(report["culprit"]["pending"], [g["young"]])
        self.assertEqual(report["culprit"]["median_hours"], 7.0)  # median of 3, 7 and 26 (censored)
        self.assertEqual(report["fix"]["met"], [g["fast"]])
        self.assertEqual(report["fix"]["missed"], [g["slow"]])
        self.assertEqual(report["stale"], [{"group": g["stuck"], "state": "bisecting", "age_hours": 26.0}])
        self.assertEqual({k: report[k]["ok"] for k in ("triage", "culprit", "fix")},
                         {"triage": False, "culprit": False, "fix": False})
        self.assertFalse(report["pass"])

    def test_a_clean_window_passes(self) -> None:
        g = self.fixture()
        report = self.sheriff.slo(self.at(29))
        self.assertEqual(report["groups"], 1)
        self.assertTrue(report["pass"])
        self.assertIsNone(report["culprit"]["median_hours"])
        self.assertIsNone(report["triage"]["pct"])
        self.assertEqual(report["triage"]["pending"], [g["young"]])

    def test_an_open_group_past_its_fix_slo_is_missed(self) -> None:
        gid = self.group(created=self.at(0))
        self.move(gid, 0.2, "triaged"); self.move(gid, 0.3, "bisecting")
        self.move(gid, 1, "culprit", culprit_sha="abc1234"); self.move(gid, 2, "assigned")
        self.clock.now = self.at(11)
        report = self.sheriff.slo(LIVE)
        self.assertEqual((report["fix"]["pending"], report["fix"]["missed"]), ([gid], []))
        self.assertTrue(report["pass"])
        self.clock.now = self.at(13)
        report = self.sheriff.slo(LIVE)
        self.assertEqual(report["fix"]["missed"], [gid])
        self.assertEqual(report["stale"], [])  # assigned is the fix SLO's, not stale
        self.assertFalse(report["pass"])

    def test_live_time_is_the_first_migration(self) -> None:
        self.assertEqual(self.sheriff.live_at(), LIVE)


class CliTests(SheriffTestCase):
    def cli(self, *argv: str, session: str | None = "sheriff-1", lead: str | None = LEAD,
            db: Path | None = None) -> tuple[int, str, str]:
        lead_file = self.path.parent / sheriff.LEAD_FILE
        if lead is None:
            lead_file.unlink(missing_ok=True)
        else:
            lead_file.write_text(lead + "\n", encoding="utf-8")
        parser = sheriff.argparse.ArgumentParser(prog="lab.py sheriff")
        sheriff.add_arguments(parser)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = sheriff.run(parser.parse_args(["--db", str(db or self.path), *argv]), clock=self.clock,
                               environ={} if session is None else {"CMUX_AGENT_SESSION": session})
        return code, out.getvalue(), err.getvalue()

    def test_list_take_set_and_history(self) -> None:
        first, second = self.group(), self.group()
        self.assertEqual(self.cli("take", str(first))[0], 0)
        self.assertEqual(self.cli("set", str(first), "triaged")[0], 0)
        code, out, _ = self.cli("list", "--state", "new,triaged", "--json")
        self.assertEqual(code, 0)
        listed = json.loads(out)
        self.assertEqual([(g["id"], g["state"], g["holder"]) for g in listed],
                         [(first, "triaged", "sheriff-1"), (second, "new", None)])
        code, out, _ = self.cli("history", str(first), "--json")
        self.assertEqual([(h["from_state"], h["to_state"]) for h in json.loads(out)], [CREATED, ("new", "triaged")])
        code, out, _ = self.cli("history", str(first))
        self.assertEqual([line.split()[1] for line in out.splitlines()], ["created", "new"])
        self.assertIn(f"created{' ' * 16}{ALERTS_ACTOR}", out)
        self.assertNotIn("None", out)
        code, out, _ = self.cli("list")
        self.assertIn(f"#{first} triaged", out)

    def test_the_acting_session_comes_from_the_environment(self) -> None:
        gid = self.group()
        self.walk(gid, "triaged", "bisecting", "culprit")
        parser = sheriff.argparse.ArgumentParser()
        sheriff.add_arguments(parser)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["set", str(gid), "accepted", "--session", LEAD, "--reason", "ok"])
        code, _, err = self.cli("set", str(gid), "accepted", "--reason", "ok", session="sheriff-1")
        self.assertEqual(code, 2)
        self.assertIn("sheriff-1 is not cmux-perf-lead", err)
        code, _, err = self.cli("set", str(gid), "accepted", "--reason", "ok", session=None)
        self.assertEqual(code, 2)
        self.assertIn("no agent session", err)
        self.assertEqual(self.state(gid), "culprit")
        self.assertEqual(self.cli("set", str(gid), "accepted", "--reason", "ok", session=LEAD)[0], 0)
        self.assertEqual(self.sheriff.history(gid)[-1].actor, LEAD)
        self.assertEqual(sheriff.caller_session({"CLAUDE_CODE_SESSION_ID": " c1 ", "CODEX_THREAD_ID": "x"}), "c1")
        self.assertIsNone(sheriff.caller_session({"CMUX_AGENT_SESSION": "  "}))

    def test_refusals_exit_2_with_the_reason(self) -> None:
        gid = self.group()
        code, _, err = self.cli("set", str(gid), "fixed")
        self.assertEqual(code, 2)
        self.assertIn("new -> fixed is not allowed", err)
        self.walk(gid, "triaged")
        code, _, err = self.cli("set", str(gid), "accepted", "--reason", "ok", session=LEAD, lead=None)
        self.assertEqual(code, 2)
        self.assertIn("Performance Lead", err)
        self.assertEqual(self.cli("list", "--state", "bogus")[0], 2)
        code, _, err = self.cli("--since", "24h", "list")
        self.assertEqual(code, 2)
        self.assertIn("go with --slo", err)
        code, _, err = self.cli("--slo", "history", str(gid))
        self.assertEqual(code, 2)
        self.assertIn("drop the subcommand", err)

    def test_a_missing_store_is_refused_and_not_created(self) -> None:
        missing = self.path.parent / "typo.sqlite"
        code, out, err = self.cli("--slo", "--since-live", db=missing)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("no lab store there", err)
        self.assertFalse(missing.exists())

    def test_a_store_at_another_schema_is_refused_with_exit_2(self) -> None:
        self.execute("INSERT INTO schema_version VALUES (?, 'from the future', 'x', ?)",
                     len(store.MIGRATIONS) + 1, sheriff._stamp(LIVE))
        code, _, err = self.cli("--slo", "--since-live")
        self.assertEqual(code, 2)
        self.assertIn("newer than this checkout", err)
        self.execute("DELETE FROM schema_version WHERE version >= ?", len(store.MIGRATIONS))
        code, _, err = self.cli("list")
        self.assertEqual(code, 2)
        self.assertIn("older than this checkout", err)

    def test_a_sqlite_failure_exits_2_not_1(self) -> None:
        broken = self.path.parent / "broken.sqlite"
        broken.write_bytes(b"not a database, " * 64)
        code, out, err = self.cli("--slo", "--since-live", db=broken)
        self.assertEqual((code, out), (2, ""))
        self.assertIn("sheriff: ", err)
        self.assertNotIn("Traceback", err)

    def test_slo_since_live_exits_1_when_missed_and_0_when_met(self) -> None:
        gid = self.group()
        self.clock.advance(minutes=30)
        code, out, _ = self.cli("--slo", "--since-live", "--json")
        self.assertEqual((code, json.loads(out)["triage"]["pending"]), (0, [gid]))
        self.clock.advance(hours=1)
        code, out, _ = self.cli("--slo", "--since-live")
        self.assertEqual(code, 1)
        self.assertIn("triage <= 1 h: MISSED", out)
        code, out, _ = self.cli("--slo", "--since", "10m")
        self.assertEqual(code, 2)
        code, out, _ = self.cli("--slo", "--since", (self.clock() - timedelta(minutes=10)).isoformat(), "--json")
        self.assertEqual((code, json.loads(out)["groups"]), (0, 0))

    def test_parse_since(self) -> None:
        now = LIVE
        self.assertEqual(sheriff.parse_since("24h", now), now - timedelta(hours=24))
        self.assertEqual(sheriff.parse_since("7d", now), now - timedelta(days=7))
        with self.assertRaisesRegex(sheriff.SheriffError, "timezone"):
            sheriff.parse_since("2026-10-25T00:00:00", now)


if __name__ == "__main__":
    unittest.main()
