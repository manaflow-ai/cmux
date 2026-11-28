#!/usr/bin/env python3
"""The rollback drill's Mac half in a Tart guest (scripts/fuzz/macos-matrix/rollback/drill.py, vm.sh --suite
rollback-drill): which publish it accepts, how it reads the app's answers, and the steps it records, with the guest
and files-next.cmux.com faked. No network, no VM."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    # One module object per file (tests/test_script_module_loads.py): reuse what another test registered.
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


drill = load("macos_matrix_rollback_drill", ROOT / "scripts/fuzz/macos-matrix/rollback/drill.py")
BASE = "https://files-next.cmux.com/nightly-next/"
COMMIT = "a" * 40
NOW = drill.epoch("2026-11-16T09:30:00Z")


def item(build: str, commit: bool = True) -> str:
    source = f'<cmux:sourceCommit xmlns:cmux="x">{COMMIT}</cmux:sourceCommit>' if commit else ""
    return (f"<item><title>{build}</title><sparkle:version>{build}</sparkle:version>{source}"
            f'<enclosure url="{BASE}cmux-NEXT-{build}.dmg" length="1" type="application/octet-stream"/></item>\n')


def appcast(run: str = "42000000001", attempt: str = "1", builds=(("200", True), ("100", False))) -> str:
    tag = f'<cmux:drillRun xmlns:cmux="x" attempt="{attempt}">{run}</cmux:drillRun>\n' if run else ""
    return "<rss><channel>\n" + tag + "".join(item(b, c) for b, c in builds) + "</channel></rss>\n"


def receipt(**over) -> dict:
    value = {"schema": drill.RECEIPT_SCHEMA, "bad_build": "200", "kept_build": "100",
             "published_at": "2026-11-16T09:15:00Z", "publish": {"run_id": "42000000001", "run_attempt": "1"},
             "outcome": "published", "pull_ordered_at": None}
    value.update(over)
    return value


class PublishTests(unittest.TestCase):
    def test_this_weeks_publish_is_accepted(self):
        picked = drill.this_weeks_publish(receipt(), appcast(), NOW)
        self.assertEqual((picked["bad"]["build"], picked["kept"]["build"]), ("200", "100"))
        self.assertEqual(picked["kept"]["url"], f"{BASE}cmux-NEXT-100.dmg")

    def test_already_pulled_says_so(self):
        with self.assertRaisesRegex(RuntimeError, "already pulled"):
            drill.this_weeks_publish(receipt(pull_ordered_at="2026-11-16T10:15:00Z"), appcast(), NOW)
        with self.assertRaisesRegex(RuntimeError, "already pulled"):
            drill.this_weeks_publish(receipt(outcome="pulled"), appcast(), NOW)

    def test_last_weeks_pulled_receipt_is_stale_not_pulled(self):
        with self.assertRaisesRegex(RuntimeError, "stale receipt: published"):
            drill.this_weeks_publish(receipt(outcome="pulled", published_at="2026-11-09T09:15:00Z"), appcast(), NOW)

    def test_older_than_an_hour_is_stale(self):
        with self.assertRaisesRegex(RuntimeError, "stale receipt: published 4500 s"):
            drill.this_weeks_publish(receipt(published_at="2026-11-16T08:15:00Z"), appcast(), NOW)

    def test_schema_run_and_builds_must_match(self):
        with self.assertRaisesRegex(RuntimeError, "schema"):
            drill.this_weeks_publish(receipt(schema="v0"), appcast(), NOW)
        with self.assertRaisesRegex(RuntimeError, "publish run 42000000001/1 is not the drill feed's 42000000001/2"):
            drill.this_weeks_publish(receipt(), appcast(attempt="2"), NOW)
        with self.assertRaisesRegex(RuntimeError, "drill feed's none"):
            drill.this_weeks_publish(receipt(), appcast(run=""), NOW)
        with self.assertRaisesRegex(RuntimeError, "builds 300/100"):
            drill.this_weeks_publish(receipt(bad_build="300"), appcast(), NOW)

    def test_not_an_object(self):
        with self.assertRaisesRegex(RuntimeError, "not a JSON object"):
            drill.this_weeks_publish([], appcast(), NOW)

    def test_kept_prefers_a_commit_then_any_own_item(self):
        text = appcast(builds=(("300", True), ("250", False), ("200", True)))
        self.assertEqual(drill.pick(text)["kept"]["build"], "200")
        text = appcast(builds=(("300", True), ("250", False)))
        self.assertEqual(drill.pick(text)["kept"]["build"], "250")
        with self.assertRaisesRegex(RuntimeError, "no item before 300"):
            drill.pick(appcast(builds=(("300", True),)))

    def test_a_dmg_off_the_feed_host_is_no_item(self):
        text = appcast().replace(f"{BASE}cmux-NEXT-100.dmg", "https://example.com/x.dmg")
        with self.assertRaisesRegex(RuntimeError, "no item before 200"):
            drill.pick(text)

    def test_drill_run_unclosed_tags(self):
        self.assertEqual(drill.drill_run("<cmux:drillRun " * 3), "")
        self.assertEqual(drill.drill_run('<cmux:drillRun><cmux:drillRun attempt="3"> 7 </cmux:drillRun>'), "7/3")


class AnswerTests(unittest.TestCase):
    def test_ok_result(self):
        self.assertEqual(drill.answer("m", '{"id":1,"ok":true,"result":{"a":1}}\n'), {"a": 1})

    def test_refused(self):
        with self.assertRaises(drill.Refused) as caught:
            drill.answer("m", '{"id":1,"ok":false,"error":{"code":"invalid_params","message":"no"}}')
        self.assertEqual(caught.exception.code, "invalid_params")
        with self.assertRaises(drill.Refused):
            drill.answer("m", '{"id":1,"error":"boom"}')

    def test_envelope_without_ok(self):
        self.assertEqual(drill.answer("m", '{"id":1,"result":3}'), 3)

    def test_no_answer_and_garbage(self):
        with self.assertRaisesRegex(RuntimeError, "socket closed"):
            drill.answer("m", "")
        with self.assertRaisesRegex(RuntimeError, "not JSON"):
            drill.answer("m", "{nope")
        with self.assertRaisesRegex(RuntimeError, "not an app answer"):
            drill.answer("m", '{"id":1}')

    def test_identify_either_shape(self):
        self.assertEqual(drill.result_of(drill.parsed('noise\n{"ok":true,"result":{"build":"1"}}')), {"build": "1"})
        self.assertEqual(drill.result_of(drill.parsed('{"build":"1"}')), {"build": "1"})
        self.assertEqual(drill.parsed("not json"), {})


class FakeGuest(drill.Capped):
    """The guest: the bundled CLI and the socket, as a NIGHTLY that updates to N and rolls back to K answers. Its
    commands go through drill.Capped.sh, the budget cut the real Guest has."""

    def __init__(self, build="100", install_exit=1, offer=True):
        self.build, self.install_exit, self.offer, self.calls = build, install_exit, offer, []

    def run(self, cmd, timeout):
        self.calls.append(cmd)
        if cmd.startswith("/bin/sh -c"):
            return 0, ("BUILD 100\nBUNDLE com.cmuxterm.app.nightly.cmux-next\n"
                       "APP /Applications/cmux NEXT.app\n"), ""
        if cmd.startswith("/usr/bin/open"):
            return 0, "", ""
        if "app identify" in cmd:
            return 0, json.dumps({"ok": True, "result": {"build": self.build, "socket_path": "/tmp/s"}}), ""
        if "/usr/bin/perl" in cmd:
            if "updates.test_feed" in cmd:
                return 0, json.dumps({"ok": True, "result": {"test_feed": drill.DRILL_URL}}) + "\n", ""
            return 0, json.dumps({"ok": True, "result": {"phase": "update_available" if self.offer else "idle"}}) + "\n", ""
        if "install-available-update" in cmd:
            self.build = "200"
            return self.install_exit, "", "the app quit"
        if "rollback-update" in cmd:
            self.build = "100"
            return 0, "{}", ""
        if cmd.startswith("test -d"):
            return 0, "", ""
        return 0, "{}", ""

    def close(self):
        pass


class SlowGuest(FakeGuest):
    """Every guest command takes its whole timeout (the worst case each call allows), then answers."""

    def __init__(self, clock, never_build=False, **kw):
        super().__init__(**kw)
        self.clock, self.never_build = clock, never_build

    def run(self, cmd, timeout):
        self.clock.t += timeout
        code, out, err = super().run(cmd, timeout)
        if self.never_build and "app identify" in cmd:
            return 0, json.dumps({"ok": True, "result": {"build": "999", "socket_path": "/tmp/s"}}), ""
        return code, out, err


class Clock:
    def __init__(self):
        self.t = 0.0

    def __call__(self):
        return self.t

    def pause(self, s):
        self.t += s


def run(guest, rec=None, cast=None, budget=1380):
    clock = Clock()
    reads = {drill.DRILL_URL: cast or appcast(), drill.RECEIPT_URL: json.dumps(rec or receipt())}
    d = drill.Drill(guest, drill.Budget(budget, clock), read=lambda url, _t: reads[url.split("?", 1)[0]],
                    wall=lambda: NOW + clock.t, clock=clock, pause=clock.pause)
    return d.run(drill.Walk(clock, echo=False))


class WalkTests(unittest.TestCase):
    def test_the_whole_drill(self):
        result = run(FakeGuest())
        self.assertTrue(result["ok"], result)
        self.assertEqual([f"{s['flow']}/{s['step']}" for s in result["steps"]],
                         ["feed/pick", "app/install-kept", "drill/serve", "app/sees-bad", "app/install-bad", "app/restore"])
        for key in ("ok", "bad_build", "kept_build", "receipt_run", "published_at", "mac_feed", "seen_at", "seen_s",
                    "restore_s", "restored_by", "kept_copy", "failed_steps", "steps"):
            self.assertIn(key, result)
        self.assertEqual((result["bad_build"], result["kept_build"], result["receipt_run"]), ("200", "100", "42000000001/1"))
        self.assertEqual((result["seen_at"], result["seen_s"]), ("2026-11-16T09:30:00Z", 900.0))
        self.assertEqual(result["restored_by"], "settings rollback-update")
        self.assertTrue(result["kept_copy"])
        self.assertEqual(result["mac_feed"], "live")

    def test_already_pulled_stops_with_a_failure(self):
        guest = FakeGuest()
        result = run(guest, rec=receipt(outcome="pulled", pull_ordered_at="2026-11-16T09:20:00Z"))
        self.assertFalse(result["ok"])
        self.assertIn("already pulled", result["failure"])
        self.assertEqual([s["outcome"] for s in result["steps"]], ["fail"] + ["skip"] * 5)
        self.assertEqual(result["steps"][1]["note"], "needs feed/pick, which did not pass")
        self.assertEqual(guest.calls, [])

    def test_no_offer_fails_sees_bad_within_its_bound(self):
        result = run(FakeGuest(offer=False))
        self.assertEqual([s["outcome"] for s in result["steps"]], ["ok", "ok", "ok", "fail", "skip", "skip"])
        self.assertIn("not within 120 s", result["failure"])

    def test_up_to_date_is_no_install(self):
        guest = FakeGuest()
        real = guest.sh

        def sh(cmd, timeout):
            if "install-available-update" in cmd:
                return 1, "", "cmux Is Up to Date"
            return real(cmd, timeout)
        guest.sh = sh
        result = run(guest)
        self.assertEqual(result["failed_steps"], ["app/install-bad", "app/restore"])
        self.assertIn("Up to Date", result["failure"])

    def test_already_back_on_k_is_the_watch(self):
        guest = FakeGuest()
        real = guest.sh

        def sh(cmd, timeout):
            out = real(cmd, timeout)
            if cmd.startswith("test -d"):
                guest.build = "100"  # PulledBuildWatch followed the pull before the restore step
            return out
        guest.sh = sh
        result = run(guest)
        self.assertTrue(result["ok"], result)
        self.assertEqual((result["restored_by"], result["restore_s"]), ("pulled-build-watch", 0.0))

    def test_the_budget_cuts_every_step(self):
        result = run(FakeGuest(offer=False), budget=60)
        self.assertIn("not within", result["failure"])
        self.assertLessEqual(sum(s["ms"] or 0 for s in result["steps"]), 61_000)

    def test_install_checks_the_team_by_requirement(self):
        guest = FakeGuest()
        run(guest)
        install = next(c for c in guest.calls if c.startswith("/bin/sh -c"))
        self.assertIn("--globoff", install)
        self.assertIn('-R="$3"', install)
        self.assertIn("'anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\"'", install)

    def test_every_call_at_its_limit_ends_within_the_budget(self):
        """vm.sh's DRILL_BUDGET_S (1380 s) and smaller ones: each guest command and read takes its whole timeout, the
        walk, the OS read and all, ends by the budget."""
        for budget in (drill.BUDGET_S, 600, 300, 61):
            for kw in ({}, {"offer": False}, {"never_build": True}):
                with self.subTest(budget=budget, **kw), tempfile.TemporaryDirectory() as out:
                    clock = Clock()
                    guest = SlowGuest(clock, **kw)
                    reads = {drill.DRILL_URL: appcast(), drill.RECEIPT_URL: json.dumps(receipt())}

                    def read(url, timeout):
                        clock.t += timeout
                        return reads[url.split("?", 1)[0]]
                    b = drill.Budget(budget, clock, reserve=drill.RESERVE_S)
                    result = drill.drive(guest, b, out, echo=False, read=read, wall=lambda: NOW + clock.t,
                                         clock=clock, pause=clock.pause)
                    self.assertLessEqual(clock.t, budget, result["failure"])
                    with open(os.path.join(out, "result.json")) as f:
                        self.assertEqual(json.load(f)["steps"], result["steps"])

    def test_result_json_after_every_step(self):
        class Killed(BaseException):
            pass  # a hard kill: nothing in the walk catches it

        guest = FakeGuest()
        real = guest.sh

        def sh(cmd, timeout):
            if "install-available-update" in cmd:
                raise Killed()
            return real(cmd, timeout)
        guest.sh = sh
        clock = Clock()
        reads = {drill.DRILL_URL: appcast(), drill.RECEIPT_URL: json.dumps(receipt())}
        with tempfile.TemporaryDirectory() as out:
            with self.assertRaises(Killed):
                drill.drive(guest, drill.Budget(1380, clock), out, echo=False,
                            read=lambda url, _t: reads[url.split("?", 1)[0]], wall=lambda: NOW + clock.t,
                            clock=clock, pause=clock.pause)
            with open(os.path.join(out, "result.json")) as f:
                left = json.load(f)
        self.assertFalse(left["ok"])
        self.assertEqual([s["outcome"] for s in left["steps"]], ["ok"] * 4)
        self.assertEqual(left["seen_at"], "2026-11-16T09:30:00Z")

    def test_limits_sum_under_the_worker_bound(self):
        caps = (2 * drill.PICK_READ_S + drill.INSTALL_KEPT_S + drill.LAUNCH_S + drill.RPC_S + drill.CHECK_S
                + drill.OFFER_S + drill.INSTALL_S + drill.RELAUNCH_S + drill.ROLLBACK_S + drill.RESTORE_S + drill.WRAP_S)
        self.assertEqual(caps, 1420)
        self.assertLess(drill.BUDGET_S, 25 * 60)


if __name__ == "__main__":
    unittest.main()
