#!/usr/bin/env python3
"""Every feat-cmux-next landing compiles the DEV Release app at once, on the owned Mac whose cache is nearest.

scripts/ci/dev_landing_place.py picks the runner for cmux-next.yml's dev-landing-compile: a free
owned root runner on the host whose holder record (cmux-next-dev-cas-holder-<host>) names the
nearest commit, else any free owned runner, else Blacksmith after about two minutes. These pin
the picker's rules against fake runner listings and a real git history, and the holder
record script (dev-cas-holder.sh). tests/test_cmux_next_dev_landing_workflow.py pins the
workflow's wiring.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import dev_landing_place as place  # noqa: E402

SIDE = "glaeda-side-std-xcode-26.6"
ROOT_LABEL = "glaeda-root-std-xcode-26.6"
REPO_ID = "42"


def runner(name: str, *labels: str, busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "busy": busy, "status": status, "labels": [{"name": label} for label in labels]}


def root_runner(name: str, **kwargs) -> dict:
    return runner(name, ROOT_LABEL, place.static_label(name), **kwargs)


def holder(host: str, sha: str, created: str, *, branch: str = "feat-cmux-next", repo: str = REPO_ID,
           expired: bool = False) -> dict:
    return {"name": place.HOLDER_PREFIX + host, "expired": expired, "created_at": created,
            "workflow_run": {"id": 1, "repository_id": repo, "head_repository_id": repo,
                             "head_branch": branch, "head_sha": sha}}


class History:
    """A linear history c0..c9 in a scratch repository."""

    def __init__(self, directory: Path):
        self.path = str(directory)
        git = ["git", "-C", self.path, "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", "init", "-q", self.path], check=True)
        self.commits = []
        for index in range(10):
            subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", f"c{index}"], check=True)
            self.commits.append(subprocess.run(["git", "-C", self.path, "rev-parse", "HEAD"],
                                               capture_output=True, text=True, check=True).stdout.strip())


class PickerTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.history = History(Path(temp.name))
        self.head = self.history.commits[-1]

    def env(self, **overrides) -> dict:
        env = {"SIDE_LABEL": SIDE, "SHA": self.head, "GITHUB_REPOSITORY_ID": REPO_ID,
               "GAP_REPO": self.history.path, "WAIT_SECONDS": "120", "POLL_SECONDS": "30"}
        env.update(overrides)
        return env

    def run_place(self, runners, holders: dict[str, list[dict]] | None = None, **overrides):
        reads = []

        def read_runners():
            reads.append(1)
            if isinstance(runners, Exception):
                raise runners
            return runners(len(reads)) if callable(runners) else runners

        now = [0.0]
        result = place.place(self.env(**overrides), read_runners, lambda host: (holders or {}).get(host, []),
                             sleep=lambda seconds: now.__setitem__(0, now[0] + seconds), clock=lambda: now[0])
        return result, len(reads)

    def test_host_and_static_label_match_glaeda(self):
        self.assertEqual(place.host_of("cmux14-glaeda-2"), "cmux14")
        self.assertEqual(place.host_of("cmuxs-mac-mini-5-glaeda-3"), "cmuxs-mac-mini-5")
        self.assertEqual(place.host_of("cmux15-glaeda"), "cmux15")
        self.assertEqual(place.static_label("CMUX14-glaeda-1"), "glaeda-runner-cmux14-glaeda-1")

    def test_the_nearest_free_host_is_pinned(self):
        runners = [root_runner("cmux14-glaeda-1"), root_runner("cmux12s-mac-mini-glaeda-1"),
                   runner("cmux13-glaeda-4", SIDE)]
        holders = {"cmux14": [holder("cmux14", self.history.commits[2], "2026-10-26T10:00:00Z")],
                   "cmux12s-mac-mini": [holder("cmux12s-mac-mini", self.history.commits[8], "2026-10-26T09:00:00Z")]}
        result, _ = self.run_place(runners, holders)
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, "glaeda-runner-cmux12s-mac-mini-glaeda-1"])
        self.assertEqual((result["pool"], result["host"], result["gap"]), ("owned", "cmux12s-mac-mini", "1"))
        self.assertEqual(result["runner_label"], ROOT_LABEL)

    def test_only_trusted_feat_cmux_next_records_count_and_the_newest_wins(self):
        commits = self.history.commits
        records = [holder("cmux14", commits[9], "2026-10-26T12:00:00Z", branch="attacker-branch"),
                   holder("cmux14", commits[9], "2026-10-26T12:00:00Z", repo="999"),
                   holder("cmux14", commits[9], "2026-10-26T12:00:00Z", expired=True),
                   holder("cmux14", commits[3], "2026-10-26T11:00:00Z"),
                   holder("cmux14", commits[1], "2026-10-26T10:00:00Z")]
        self.assertEqual(place.holder_sha(records, "cmux14", REPO_ID), commits[3])
        self.assertEqual(place.holder_sha(records, "cmux12", REPO_ID), "")

    def test_a_newer_holder_counts_its_distance_too(self):
        self.assertEqual(place.git_distance(self.history.path, self.history.commits[9], self.history.commits[7]), 2)
        self.assertEqual(place.git_distance(self.history.path, "f" * 40, self.head), None)

    def test_without_a_near_cache_a_free_side_runner_then_a_free_root_runner(self):
        result, _ = self.run_place([root_runner("cmux14-glaeda-1"), runner("cmux13-glaeda-4", SIDE)])
        self.assertEqual((json.loads(result["runs_on"]), result["pool"]), (SIDE, "owned"))
        result, _ = self.run_place([root_runner("cmux14-glaeda-1"), runner("cmux13-glaeda-4", SIDE, busy=True)])
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, "glaeda-runner-cmux14-glaeda-1"])

    def test_busy_offline_and_unpinnable_runners_are_not_free(self):
        roots, sides = place.free_runners([
            root_runner("a-glaeda-1", busy=True), root_runner("b-glaeda-1", status="offline"),
            runner("c-glaeda-1", ROOT_LABEL), runner("d-glaeda-2", "glaeda-side-light-xcode-26.6")], SIDE)
        self.assertEqual((roots, sides), ([], []))

    def test_no_free_owned_mac_for_two_minutes_overflows_to_blacksmith(self):
        result, reads = self.run_place([root_runner("cmux14-glaeda-1", busy=True)])
        self.assertEqual((json.loads(result["runs_on"]), result["pool"]), ("blacksmith-12vcpu-macos-26", "blacksmith"))
        self.assertEqual(reads, 5, "looks at t=0,30,60,90,120 and no later")

    def test_the_overflow_skips_a_stalled_blacksmith_label(self):
        # 2026-10-28: blacksmith-12vcpu-macos-26 started nothing from about 02:11Z; landings kept overflowing onto it.
        now = place.dt.datetime(2026, 10, 28, 15, 40, tzinfo=place.dt.timezone.utc)

        def snap(waits):
            return {"generated_at": "2026-10-28T15:39:00Z",
                    "pools": {label: {"queued": 1 if wait else 0, "oldest_queued_minutes": wait}
                              for label, wait in waits.items()}}

        large, small = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
        cases = ((snap({large: 926}), small), (snap({large: 2}), large), (None, large))
        for snapshot, expected in cases:
            with self.subTest(snapshot=snapshot):
                now_reads = [0.0]
                result = place.place(self.env(), lambda: [], lambda host: [], sleep=lambda s: now_reads.__setitem__(0, now_reads[0] + s),
                                     clock=lambda: now_reads[0], read_snapshot=lambda: snapshot, now=now)
                self.assertEqual((json.loads(result["runs_on"]), result["pool"]), (expected, "blacksmith"))
        # An unreadable snapshot keeps the configured label; a non-Blacksmith label is never re-picked.
        def broken():
            raise OSError("rate limit")
        self.assertEqual(place.overflow_label(large, broken, now)[0], large)
        self.assertEqual(place.overflow_label("macos-26", lambda: snap({}), now), ("macos-26", ""))

    def test_the_overflow_skips_a_dead_label_a_stale_snapshot_shows(self):
        # 2026-10-30: blacksmith-12vcpu-macos-26 started nothing for about a day; the janitor's snapshot is
        # often older than the stall rule's 15 minutes, and the overflow then took OVERFLOW_LABEL unchecked.
        now = place.dt.datetime(2026, 10, 30, 19, 0, tzinfo=place.dt.timezone.utc)
        large, small = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
        stale = {"generated_at": "2026-10-30T18:22:00Z",
                 "pools": {large: {"queued": 0, "running": 0}, small: {"queued": 0, "running": 5}},
                 "label_started": {small: "2026-10-30T18:21:00Z"}}
        self.assertEqual(place.overflow_label(large, lambda: stale, now)[0], small)
        older = {key: value for key, value in stale.items() if key != "label_started"}
        self.assertEqual(place.overflow_label(large, lambda: older, now)[0], large)

    def test_a_mac_freed_during_the_wait_is_taken(self):
        def runners(read):
            return [runner("cmux13-glaeda-4", SIDE, busy=read < 3)]
        result, reads = self.run_place(runners)
        self.assertEqual((json.loads(result["runs_on"]), reads), (SIDE, 3))

    def test_unreadable_runners_and_owned_off_overflow_at_once(self):
        result, reads = self.run_place(RuntimeError("HTTP 403"))
        self.assertEqual((json.loads(result["runs_on"]), result["pool"], reads),
                         ("blacksmith-12vcpu-macos-26", "blacksmith", 1))
        result, reads = self.run_place([], SIDE_LABEL="blacksmith-6vcpu-macos-26")
        self.assertEqual((result["pool"], reads), ("blacksmith", 0))

    def test_other_landings_in_flight_are_not_placed_on_again(self):
        now = place.dt.datetime(2026, 10, 26, 12, tzinfo=place.dt.timezone.utc)
        runs = [{"id": 7, "created_at": "2026-10-26T11:58:00Z"}, {"id": 8, "created_at": "2026-10-26T11:59:00Z"},
                {"id": 9, "created_at": "2026-10-26T10:00:00Z"}, {"id": 10, "created_at": "2026-10-26T11:59:30Z"}]
        jobs = {7: [{"name": place.COMPILE_JOB, "status": "queued",
                     "labels": [ROOT_LABEL, place.static_label("cmux14-glaeda-1")]}],
                8: [{"name": place.COMPILE_JOB, "status": "in_progress", "runner_name": "cmux12-glaeda-3"},
                    {"name": "cmux-scheme-compile", "status": "in_progress", "runner_name": "cmux15-glaeda-1"}],
                9: [{"name": place.COMPILE_JOB, "status": "queued", "labels": [place.static_label("old-glaeda-1")]}],
                10: [{"name": place.COMPILE_JOB, "status": "queued", "labels": [place.static_label("self-glaeda-1")]}]}
        taken, busy = place.in_flight(runs, lambda run_id: jobs[run_id], "10", now)
        self.assertEqual((taken, busy), ({place.static_label("cmux14-glaeda-1")}, {"cmux12"}))
        runners = [root_runner("cmux14-glaeda-1"), root_runner("cmux12-glaeda-1"), root_runner("cmux11-glaeda-1")]
        holders = {host: [holder(host, self.history.commits[8], "2026-10-26T10:00:00Z")] for host in ("cmux14", "cmux12")}
        result = place.place(self.env(), lambda: runners, lambda host: holders.get(host, []), lambda: (taken, busy),
                             sleep=lambda seconds: None, clock=lambda: 0.0)
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, place.static_label("cmux11-glaeda-1")])

    def test_a_holder_missing_from_the_history_is_fetched(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        bare = str(Path(temp.name) / "bare.git")
        subprocess.run(["git", "init", "-q", "--bare", bare], check=True)
        subprocess.run(["git", "-C", bare, "fetch", "-q", self.history.path, self.history.commits[5]], check=True)
        # c9 is newer than the landing's c5: not in its history until the holder is fetched.
        self.assertIsNone(place.git_distance(bare, self.history.commits[9], self.history.commits[5]))
        self.assertEqual(place.git_distance(bare, self.history.commits[9], self.history.commits[5],
                                            self.history.path), 4)

    def test_gap_prints_the_distance_or_nothing(self):
        def gap(*args):
            return subprocess.run([sys.executable, "-I", str(ROOT / "scripts/ci/dev_landing_place.py"), "gap", *args],
                                  capture_output=True, text=True, check=True,
                                  env={"GAP_REMOTE": self.history.path, "PATH": "/usr/bin:/bin"}).stdout.strip()
        commits = self.history.commits
        self.assertEqual(gap(commits[6], commits[9]), "3")
        self.assertEqual(gap(commits[9], commits[9]), "0")
        self.assertEqual(gap("", commits[9]), "")
        self.assertEqual(gap("f" * 40, commits[9]), "")


FRESH = "glaeda-dev-std-xcode-26.6"


def slot(name: str, *, pinned: bool = True, **kwargs) -> dict:
    return runner(name, FRESH, *([place.static_label(name)] if pinned else []), **kwargs)


class DailyPickerTests(unittest.TestCase):
    """FRESH_LABEL set: a DEV daily's compile goes to the idle runner nearest its cache (dev-daily-place)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.history = History(Path(temp.name))
        self.head = self.history.commits[-1]

    def env(self, **overrides) -> dict:
        env = {"SIDE_LABEL": SIDE, "SHA": self.head, "GITHUB_REPOSITORY_ID": REPO_ID, "GAP_REPO": self.history.path,
               "FRESH_LABEL": FRESH}
        env.update(overrides)
        return env

    def records(self, **gaps: int) -> dict[str, list[dict]]:
        """Holder records `gap` commits behind the head, by host."""
        return {host: [holder(host, self.history.commits[9 - gap], "2026-10-28T10:00:00Z")] for host, gap in gaps.items()}

    def daily(self, runners, holders, **overrides) -> dict:
        """One placement. It never sleeps and never reads job lists: both raise here."""
        def read_runners():
            if callable(runners):
                return runners()
            return runners

        def never(*_):
            raise AssertionError("a DEV daily placement reads one runner listing and never waits")
        return place.place(self.env(**overrides), read_runners, lambda host: holders.get(host, []),
                           read_in_flight=never, sleep=never, clock=lambda: 0.0)

    def test_the_nearest_pinned_slot_wins_over_a_farther_slot_and_root(self):
        runners = [slot("cmux8s-glaeda-2"), slot("cmux11s-glaeda-2"), root_runner("cmux11s-glaeda")]
        result = self.daily(runners, self.records(cmux8s=1, cmux11s=5))
        self.assertEqual(json.loads(result["runs_on"]), [FRESH, place.static_label("cmux8s-glaeda-2")])
        self.assertEqual((result["runner_label"], result["host"], result["gap"]), (FRESH, "cmux8s", "1"))

    def test_a_slot_before_a_root_at_equal_distance_and_a_nearer_root_before_a_farther_slot(self):
        result = self.daily([root_runner("cmux8s-glaeda"), slot("cmux8s-glaeda-2")], self.records(cmux8s=2))
        self.assertEqual(json.loads(result["runs_on"]), [FRESH, place.static_label("cmux8s-glaeda-2")])
        result = self.daily([root_runner("cmux8s-glaeda"), slot("cmux11s-glaeda-2")], self.records(cmux8s=1, cmux11s=2))
        self.assertEqual((json.loads(result["runs_on"]), result["runner_label"]),
                         ([ROOT_LABEL, place.static_label("cmux8s-glaeda")], ROOT_LABEL))

    def test_an_unpinned_slot_claims_its_host_only_as_the_one_idle_slot(self):
        # The other slot is busy, so the shared label resolves to this one runner.
        result = self.daily([slot("cmux8s-glaeda-2", pinned=False), slot("cmux11s-glaeda-2", busy=True)],
                            self.records(cmux8s=1))
        self.assertEqual((json.loads(result["runs_on"]), result["host"]), (FRESH, "cmux8s"))
        # Two idle unpinned slots: the label could land on either, so no host is claimed and nothing waits.
        idle_two = [slot("cmux8s-glaeda-2", pinned=False), slot("cmux11s-glaeda-2", pinned=False)]
        result = self.daily(idle_two, self.records(cmux8s=1, cmux11s=9))
        self.assertEqual((json.loads(result["runs_on"]), result["host"], result["gap"]), (FRESH, "", ""))
        # A pinned root on the warm host does claim it.
        result = self.daily(idle_two + [root_runner("cmux8s-glaeda")], self.records(cmux8s=1, cmux11s=9))
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, place.static_label("cmux8s-glaeda")])

    def test_an_occupied_host_counts_its_idle_slots_against_uniqueness(self):
        # cmux11s is occupied, but its idle unpinned slot can still take the shared label: no host is claimed
        # for cmux8s's slot, and the pinned root there wins.
        runners = [slot("cmux8s-glaeda-2", pinned=False), slot("cmux11s-glaeda-2", pinned=False),
                   runner("cmux11s-glaeda-3", SIDE, busy=True), root_runner("cmux8s-glaeda")]
        result = self.daily(runners, self.records(cmux8s=1, cmux11s=1))
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, place.static_label("cmux8s-glaeda")])

    def test_a_host_with_any_busy_runner_is_not_picked(self):
        # Whatever holds cmux8s's host lock (a push's compile, a landing's, a daily's) runs on one of its
        # runners; the busy flag is enough, whatever the job is called.
        runners = [root_runner("cmux8s-glaeda"), slot("cmux8s-glaeda-2"), runner("cmux8s-glaeda-3", SIDE, busy=True),
                   slot("cmux11s-glaeda-2")]
        result = self.daily(runners, self.records(cmux8s=0, cmux11s=6))
        self.assertEqual((json.loads(result["runs_on"]), result["host"]),
                         ([FRESH, place.static_label("cmux11s-glaeda-2")], "cmux11s"))

    def test_it_never_waits_for_a_busy_warm_host(self):
        result = self.daily([slot("cmux8s-glaeda-2", busy=True), slot("cmux11s-glaeda-2")], self.records(cmux8s=0, cmux11s=9))
        self.assertEqual(result["host"], "cmux11s")

    def test_without_a_claimable_warm_host_the_shared_slot_label_then_side_then_the_route_is_kept(self):
        result = self.daily([slot("cmux8s-glaeda-2"), runner("cmux13s-glaeda-9", SIDE)], {})
        self.assertEqual((json.loads(result["runs_on"]), result["pool"], result["host"]), (FRESH, "owned", ""))
        result = self.daily([slot("cmux8s-glaeda-2", busy=True), runner("cmux13s-glaeda-9", SIDE)], self.records(cmux8s=1))
        self.assertEqual((json.loads(result["runs_on"]), result["pool"]), (SIDE, "owned"))
        result = self.daily([slot("cmux8s-glaeda-2", status="offline"), runner("cmux13s-glaeda-9", SIDE, busy=True)],
                            self.records(cmux8s=1))
        self.assertEqual((result["runs_on"], result["runner_label"], result["pool"]), ("", "", ""))

    def test_with_nothing_idle_it_waits_on_a_busy_dev_slot_not_behind_the_side_queue(self):
        # 2026-10-30: five DEV daily compiles queued on glaeda-side-std-xcode-26.6 from 13:55Z behind about 184 PR
        # and side jobs (GitHub hands a label's queue out oldest first), while the DEV slots, which admit only feed
        # work, ran DEV compiles. Waiting on the slot label puts it behind DEV work only.
        result = self.daily([slot("cmux8s-glaeda-2", busy=True), slot("cmux9s-glaeda-2", status="offline"),
                             runner("cmux13s-glaeda-9", SIDE, busy=True)], self.records(cmux8s=1, cmux9s=0))
        self.assertEqual((json.loads(result["runs_on"]), result["runner_label"], result["pool"], result["host"]),
                         (FRESH, FRESH, "owned", ""))
        self.assertIn("DEV slot", result["reason"])

    def test_unreadable_runners_or_owned_pools_off_keep_the_route(self):
        def refused():
            raise RuntimeError("HTTP 403")
        self.assertEqual(self.daily(refused, self.records(cmux8s=1))["runs_on"], "")
        self.assertEqual(self.daily([slot("cmux8s-glaeda-2")], {}, SIDE_LABEL="blacksmith-6vcpu-macos-26")["runs_on"], "")


class HolderScriptTests(unittest.TestCase):
    def test_the_holder_record_is_written_only_for_a_host_build(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        report, out = Path(temp.name) / "report.txt", Path(temp.name) / "out"
        script = str(ROOT / "scripts/cmux-next/dev-cas-holder.sh")
        env = {"RUNNER_NAME": "CMUX14-glaeda-2", "GITHUB_SHA": "a" * 40, "PATH": "/usr/bin:/bin"}
        report.write_text("mode=instance\nderived_data=/x\nprevious_sha=\n")
        printed = subprocess.run([script, str(report), str(out)], capture_output=True, text=True, check=True, env=env)
        self.assertEqual((printed.stdout, out.exists()), ("", False))
        report.write_text("mode=host\nderived_data=/x\nprevious_sha=\n")
        printed = subprocess.run([script, str(report), str(out)], capture_output=True, text=True, check=True, env=env)
        self.assertEqual(printed.stdout, "holder=cmux14\n")
        self.assertEqual(json.loads((out / "holder.json").read_text())["host"], "cmux14")


if __name__ == "__main__":
    unittest.main()
