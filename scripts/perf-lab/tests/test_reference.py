#!/usr/bin/env python3
"""reference.py: the weekly pin, the .ref series and lab-drift, on a temp lab store with the real catapult
detector (anomaly.py), alerts.detect, the sheriff and pinpoint_exec's bisect start.

  python3 -m unittest scripts/perf-lab/tests/test_reference.py
"""
from __future__ import annotations

import importlib.util
import io
import json
import random
import sys
import tempfile
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


reference = _load("perf_lab_reference", LAB / "reference.py")
exe = _load("perf_lab_pinpoint_exec", LAB / "pinpoint_exec.py")
dashboard = _load("perf_lab_dashboard", LAB / "dashboard.py")
alerts, store_mod, builds = reference.alerts, reference.store_mod, exe.builds

NOW = datetime(2026, 10, 26, 0, 0, tzinfo=timezone.utc)
STORY, METRIC = "terminal-key-to-frame.light", "key_to_frame_ms"
HOST = store_mod.Host(name="cmux15", chip="Apple M6", memory_gb=24, display_hz=120, fingerprint="fp-1")
REF_SHA = "f" * 40
REPIN_SHA = "e" * 40
SHAS = [f"{i:040x}" for i in range(200)]  # first-parent commits; commit position = index
STEP = 42  # the tip index of the first slow point
SUBSCRIPTIONS_DOC = {
    "build_configs": ["bench"],
    "subscriptions": [
        {"name": "key", "kind": "target", "owner": "PL-typing", "match": {"story": "terminal-key-to-frame*"}},
    ],
}
SUBSCRIPTIONS = alerts.Subscriptions.parse(SUBSCRIPTIONS_DOC)
PIN = {"sha": REF_SHA, "config": "bench", "digest": "sha256:" + "a" * 64, "week_of": "2026-10-26",
       "pinned_by": "operator"}


def noisy(value: float, seed: str) -> list[float]:
    rng = random.Random(seed)
    return [value * (1 + rng.gauss(0, 0.01)) for _ in range(10)]


class Controller:
    def find(self, key):
        return None

    def status(self, controller_id):
        raise AssertionError("no story job runs in these tests")

    def cancel(self, controller_id):
        pass


class Lab(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.store = store_mod.Store(self.root / "lab.sqlite", clock=lambda: NOW)
        self.store.migrate()
        self.ledger = builds.BuildLedger(self.root / "ledger", clock=lambda: NOW)
        self.tips = 0
        self.refs = 0

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    # ----- the waterfall: one T0 every 10 minutes, the pin beside every 6th -----

    def insert(self, kind: str, sha: str, pos: int, value: float, at: datetime, *, story: str = STORY,
               macos_build: str = "25A1", host: store_mod.Host = HOST) -> None:
        uuid = f"{kind}-{story}-{at.isoformat()}"
        run = store_mod.Run(run_uuid=uuid, kind=kind, measure_version="1", story=story, engine="native",
                            macos_major=26, macos_build=macos_build, features_hash="f0", safe_mode="off", started_at=at)
        self.store.insert_run(run, build=store_mod.Build(sha, "bench", pos), host=host,
                              metrics=[store_mod.Metric(METRIC, "ms", "lower", noisy(value, uuid))])

    def waterfall(self, count: int, tip, ref, *, story: str = STORY, ref_sha=lambda i: REF_SHA,
                  macos_build=lambda i: "25A1", host=lambda i: HOST) -> None:
        """T0 points `self.tips`..+count at positions 1.., value tip(i); every 6th T0 also runs the pin, ref(i)."""
        for i in range(self.tips, self.tips + count):
            at = NOW + timedelta(minutes=10 * i)
            self.insert("waterfall", SHAS[i + 1], i + 1, tip(i), at, story=story, macos_build=macos_build(i),
                        host=host(i))
            self.ledger.record(builds.BuildRecord(SHAS[i + 1], "bench", "ok", 30, digest="e" * 64,
                                                  app="cmux DEV perf-lab.app"))
            if (i + 1) % 6 == 0:
                sha = ref_sha(i)
                self.insert("reference", sha, 0 if sha == REF_SHA else 1000, ref(i), at + timedelta(minutes=1),
                            story=story, macos_build=macos_build(i), host=host(i))
        self.tips += count

    # ----- the pipeline: detect, classify, start bisects -----

    def detect(self):
        return alerts.detect(self.store, SUBSCRIPTIONS, alerts.CatapultDetector(), lambda target: None)

    def classify(self):
        return reference.classify(self.store, SUBSCRIPTIONS, alerts.CatapultDetector(), lab_owner="PL-perf-lab")

    def start_bisects(self) -> list[int]:
        executor = exe.Executor(self.root / "lab.sqlite", self.root / "state", controller=Controller(),
                                ledger=self.ledger, first_parent=lambda good, bad: SHAS[SHAS.index(good) + 1:
                                                                                        SHAS.index(bad) + 1],
                                commit_positions=lambda sha: None, clock=lambda: NOW)
        try:
            return executor.start_bisects()
        finally:
            executor.close()

    def states(self) -> list[str]:
        return [row[0] for row in self.store._db.execute("SELECT state FROM alert_groups ORDER BY id")]

    def annotations(self, kind: str) -> list[str]:
        return [row[0] for row in self.store._db.execute(
            "SELECT text FROM annotations WHERE kind = ? ORDER BY id", (kind,))]


def step(at: int, low: float = 10.0, high: float = 11.5):
    return lambda i: high if i >= at else low


def flat(value: float = 20.0):
    return lambda i: value


class LabDriftTests(Lab):
    def test_step_on_tip_and_ref_is_lab_drift_and_never_bisected(self) -> None:
        self.waterfall(84, step(STEP), step(STEP, 20.0, 23.0))
        report = self.detect()
        self.assertEqual(report.alerts, 1)
        drift = self.classify()
        self.assertEqual(drift.lab_drift, [1])
        self.assertEqual(self.start_bisects(), [])
        self.assertEqual(self.states(), ["lab-drift"])
        reason = self.store._db.execute(
            "SELECT reason FROM sheriff_history WHERE to_state = 'lab-drift'").fetchone()[0]
        self.assertIn("routed to PL-perf-lab", reason)
        self.assertEqual(len(self.annotations("reference_drift")), 1)

    def test_step_on_tip_only_is_bisected(self) -> None:
        self.waterfall(84, step(STEP), flat())
        self.assertEqual(self.detect().alerts, 1)
        self.assertEqual(self.classify().lab_drift, [])
        self.assertEqual(len(self.start_bisects()), 1)
        self.assertEqual(self.states(), ["bisecting"])

    def test_ref_step_found_later_moves_the_bisecting_group_to_lab_drift(self) -> None:
        # The tip alert needs 6 T0 points after the step, the .ref series 6 reference runs (36 T0s): the bisect
        # starts first and the lab-drift move cancels it (pinpoint_exec cancels a bisect whose group left bisecting).
        tip, ref = step(STEP), step(STEP, 20.0, 23.0)
        self.waterfall(STEP + 8, tip, ref)
        self.assertEqual(self.detect().alerts, 1)
        self.assertEqual(self.classify().lab_drift, [])
        self.assertEqual(len(self.start_bisects()), 1)
        self.waterfall(84 - self.tips, tip, ref)
        self.assertEqual(self.classify().lab_drift, [1])
        self.assertEqual(self.states(), ["lab-drift"])

    def test_ref_step_in_another_window_is_not_drift(self) -> None:
        self.waterfall(120, step(78), step(36, 20.0, 23.0))
        self.assertEqual(self.detect().alerts, 1)
        self.assertEqual(self.classify().lab_drift, [])
        self.assertEqual(len(self.start_bisects()), 1)

    def test_ref_improvement_is_not_drift(self) -> None:
        self.waterfall(84, step(STEP), step(STEP, 20.0, 17.0))
        self.detect()
        self.assertEqual(self.classify().lab_drift, [])

    def test_a_repin_is_not_drift(self) -> None:
        # The new pin is slower than the old one; each pin alone is flat.
        self.waterfall(84, step(STEP), step(STEP, 20.0, 23.0), ref_sha=lambda i: REPIN_SHA if i >= STEP else REF_SHA)
        self.detect()
        self.assertEqual(self.classify().lab_drift, [])

    def test_a_group_with_an_unexplained_alert_is_bisected(self) -> None:
        self.waterfall(84, step(STEP), step(STEP, 20.0, 23.0))
        self.tips = 0
        self.waterfall(84, step(STEP), flat(), story="terminal-key-to-frame.stress")
        self.detect()
        self.assertEqual(self.store._db.execute("SELECT COUNT(*) FROM alert_groups").fetchone()[0], 1)
        self.assertEqual(self.classify().lab_drift, [])
        self.assertEqual(len(self.start_bisects()), 1)

    def test_a_claimed_group_is_reported_and_left(self) -> None:
        self.waterfall(84, step(STEP), step(STEP, 20.0, 23.0))
        self.detect()
        self.store._db.execute("UPDATE alert_groups SET holder = 'cmux-sheriff', held_at = ?",
                               (NOW.isoformat(timespec="microseconds"),))
        report = self.classify()
        self.assertEqual(report.lab_drift, [])
        self.assertIn("held by cmux-sheriff", report.problems[0])
        self.assertEqual(self.states(), ["new"])

    def test_classify_cli_dry_run_writes_nothing(self) -> None:
        self.waterfall(84, step(STEP), step(STEP, 20.0, 23.0))
        self.detect()
        config = self.root / "reference.json"
        config.write_text(json.dumps({"schema": reference.SCHEMA, "lab_owner": "PL-perf-lab", "pin": PIN}))
        subscriptions = self.root / "subscriptions.json"
        subscriptions.write_text(json.dumps(SUBSCRIPTIONS_DOC))
        out = io.StringIO()
        code = reference.main(["--file", str(config), "--subscriptions", str(subscriptions), "classify", "--db", str(self.root / "lab.sqlite"), "--dry-run"],
                              floors=lambda series: None, out=out)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["lab_drift"], [1])
        self.assertEqual(self.states(), ["new"])


class HostChangeTests(Lab):
    def test_host_changes_are_marked_once_on_the_first_tip_point_after_them(self) -> None:
        # macOS changes at i=12 (tip position 13), the fingerprint at i=24 (position 25); the reference runs
        # beside them are at positions 18 and 30.
        moved = store_mod.Host(name="cmux15", chip="Apple M6", memory_gb=24, display_hz=120, fingerprint="fp-2")
        self.waterfall(36, flat(10.0), flat(), macos_build=lambda i: "25A1" if i < 12 else "25B78",
                       host=lambda i: HOST if i < 24 else moved)
        self.assertEqual(reference.annotate_host_changes(self.store), 1)
        self.assertEqual(reference.annotate_host_changes(self.store), 0)
        key = self.store._db.execute("SELECT series_key FROM series WHERE story = ?", (STORY,)).fetchone()[0]
        source = dashboard.StoreSource(self.root / "lab.sqlite")
        try:
            view = source.series(key, 100)
        finally:
            source.close()
        marks = sorted((note.start_pos, note.kind, note.text)
                       for note in [*view.annotations, *dashboard.derived_annotations(view.points)])
        self.assertEqual(marks, [(13, "macos_build", "25A1 → 25B78"),
                                 (25, "note", "reference on cmux15: host fingerprint fp-1 -> fp-2")])


class PinTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "reference.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def write(self, pin) -> None:
        self.path.write_text(json.dumps({"schema": reference.SCHEMA, "lab_owner": "PL-perf-lab", "pin": pin}))

    def cli(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        code = reference.main(["--file", str(self.path), *argv], out=out, err=err)
        return code, out.getvalue(), err.getvalue()

    def test_the_checked_in_file_parses(self) -> None:
        config = reference.load(reference.REFERENCE_PATH)
        self.assertEqual(config.lab_owner, "PL-perf-lab")

    def test_scheduler_gets_the_digest_and_a_stale_pin_keeps_running(self) -> None:
        self.write(PIN)
        fresh = reference.scheduler_reference(self.path, datetime(2026, 10, 28, tzinfo=timezone.utc))
        self.assertEqual((fresh.digest, fresh.problems), (PIN["digest"], ()))
        stale = reference.scheduler_reference(self.path, datetime(2026, 11, 2, 9, tzinfo=timezone.utc))
        self.assertEqual(stale.digest, PIN["digest"])
        self.assertIn("stale", stale.problems[0])
        self.assertEqual(self.cli("check", "--today", "2026-11-02")[0], 1)
        self.assertEqual(self.cli("check", "--today", "2026-10-30")[0], 0)

    def test_no_pin_or_a_bad_file_runs_no_reference(self) -> None:
        self.write(None)
        self.assertIsNone(reference.scheduler_reference(self.path, NOW).digest)
        self.path.write_text("{")
        broken = reference.scheduler_reference(self.path, NOW)
        self.assertIsNone(broken.digest)
        self.assertTrue(broken.problems)

    def test_malformed_pins_are_refused(self) -> None:
        for bad in ({**PIN, "week_of": "2026-10-27"}, {**PIN, "digest": "a" * 64}, {**PIN, "sha": "abc"},
                    {**PIN, "config": "debug"}, {**PIN, "pinned_by": " "}, {k: v for k, v in PIN.items() if k != "sha"}):
            self.write(bad)
            with self.assertRaises(reference.PinError, msg=bad):
                reference.load(self.path)

    def test_pin_cli_pins_this_monday_and_only_moves_forward(self) -> None:
        self.write(None)
        code, out, _ = self.cli("pin", "--sha", REF_SHA, "--digest", PIN["digest"], "--by", "operator",
                                "--today", "2026-10-28")
        self.assertEqual(code, 0, out)
        self.assertEqual(reference.load(self.path).pin.week_of, date(2026, 10, 26))
        self.assertEqual(self.cli("current", "--today", "2026-10-28")[1].strip(), PIN["digest"])
        code, _, err = self.cli("pin", "--sha", REPIN_SHA, "--digest", PIN["digest"], "--by", "operator",
                                "--week-of", "2026-10-19", "--today", "2026-10-28")
        self.assertEqual(code, 1)
        self.assertIn("before the current pin", err)
        code, _, err = self.cli("pin", "--sha", REPIN_SHA, "--digest", PIN["digest"], "--by", "operator",
                                "--week-of", "2026-11-02", "--today", "2026-10-28")
        self.assertEqual(code, 1)
        self.assertIn("after this week", err)
        self.assertEqual(reference.load(self.path).pin.sha, REF_SHA)


if __name__ == "__main__":
    unittest.main()
