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
        self.assertEqual((taken, busy), ({place.static_label("cmux14-glaeda-1")}, {"cmux12-glaeda-3"}))
        self.assertEqual(place.busy_hosts(busy, []), {"cmux12"}, "a compiling runner not listed is busy")
        self.assertEqual(place.busy_hosts(busy, [runner("cmux12-glaeda-3", SIDE)]), set(), "an idle one is done")
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
    """FRESH_LABEL set: a DEV daily's compile goes to the free runner nearest its cache (dev-daily-place)."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.history = History(Path(temp.name))
        self.head = self.history.commits[-1]

    def env(self, **overrides) -> dict:
        env = {"SIDE_LABEL": SIDE, "SHA": self.head, "GITHUB_REPOSITORY_ID": REPO_ID, "GAP_REPO": self.history.path,
               "FRESH_LABEL": FRESH, "WAIT_SECONDS": "240", "POLL_SECONDS": "30"}
        env.update(overrides)
        return env

    def records(self, **gaps: int) -> dict[str, list[dict]]:
        """Holder records `gap` commits behind the landing, by host."""
        return {host: [holder(host, self.history.commits[9 - gap], "2026-10-28T10:00:00Z")] for host, gap in gaps.items()}

    def daily(self, runners, holders, compiling: set[str] = frozenset(), **overrides):
        reads = []
        now = [0.0]

        def read_runners():
            reads.append(1)
            return runners(len(reads)) if callable(runners) else runners
        result = place.place(self.env(**overrides), read_runners, lambda host: holders.get(host, []),
                             lambda: (set(), set(compiling)),
                             sleep=lambda seconds: now.__setitem__(0, now[0] + seconds), clock=lambda: now[0])
        return result, len(reads)

    def test_the_nearest_pinned_slot_wins_over_a_farther_slot_and_root(self):
        runners = [slot("cmux8s-glaeda-2"), slot("cmux11s-glaeda-2"), root_runner("cmux11s-glaeda")]
        result, reads = self.daily(runners, self.records(cmux8s=1, cmux11s=5))
        self.assertEqual(json.loads(result["runs_on"]), [FRESH, place.static_label("cmux8s-glaeda-2")])
        self.assertEqual((result["runner_label"], result["host"], result["gap"], reads), (FRESH, "cmux8s", "1", 1))

    def test_a_slot_before_a_root_at_equal_distance_and_a_nearer_root_before_a_farther_slot(self):
        runners = [root_runner("cmux8s-glaeda"), slot("cmux8s-glaeda-2")]
        result, _ = self.daily(runners, self.records(cmux8s=2))
        self.assertEqual(json.loads(result["runs_on"]), [FRESH, place.static_label("cmux8s-glaeda-2")])
        runners = [root_runner("cmux8s-glaeda"), slot("cmux11s-glaeda-2")]
        result, reads = self.daily(runners, self.records(cmux8s=1, cmux11s=2))
        self.assertEqual((json.loads(result["runs_on"]), reads), ([ROOT_LABEL, place.static_label("cmux8s-glaeda")], 1))

    def test_an_unpinned_slot_is_host_specific_only_while_it_is_the_one_free_slot(self):
        # One free slot: the label lands there, so its host's record counts.
        result, _ = self.daily([slot("cmux8s-glaeda-2", pinned=False), slot("cmux11s-glaeda-2", busy=True)],
                               self.records(cmux8s=1, cmux11s=4))
        self.assertEqual((json.loads(result["runs_on"]), result["host"]), (FRESH, "cmux8s"))
        # Two free unpinned slots: either could take the label, so a pinned root on the warm host wins.
        runners = [slot("cmux8s-glaeda-2", pinned=False), slot("cmux11s-glaeda-2", pinned=False),
                   root_runner("cmux8s-glaeda")]
        result, _ = self.daily(runners, self.records(cmux8s=1, cmux11s=4))
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, place.static_label("cmux8s-glaeda")])

    def test_it_waits_for_a_busy_warm_host_then_takes_it(self):
        def runners(read):
            return [slot("cmux8s-glaeda-2", busy=read < 4), slot("cmux11s-glaeda-2"), runner("cmux13s-glaeda-9", SIDE)]
        result, reads = self.daily(runners, self.records(cmux8s=1, cmux11s=8))
        self.assertEqual((json.loads(result["runs_on"]), reads), ([FRESH, place.static_label("cmux8s-glaeda-2")], 4))

    def test_a_host_compiling_another_dev_build_is_free_once_that_runner_is(self):
        # cmux8s-glaeda-3 holds cmux8s's host lock; its root runner is idle but not free until that compile ends.
        def runners(read):
            return [root_runner("cmux8s-glaeda"), runner("cmux8s-glaeda-3", SIDE, busy=read < 3),
                    slot("cmux11s-glaeda-2")]
        result, reads = self.daily(runners, self.records(cmux8s=1, cmux11s=9), compiling={"cmux8s-glaeda-3"})
        self.assertEqual((json.loads(result["runs_on"]), reads), ([ROOT_LABEL, place.static_label("cmux8s-glaeda")], 3))

    def test_the_wait_is_bounded_then_the_best_free_pick_or_a_cold_free_runner(self):
        busy_warm = [slot("cmux8s-glaeda-2", busy=True), slot("cmux11s-glaeda-2")]
        result, reads = self.daily(busy_warm, self.records(cmux8s=1, cmux11s=9))
        self.assertEqual((json.loads(result["runs_on"]), result["host"]), ([FRESH, place.static_label("cmux11s-glaeda-2")], "cmux11s"))
        self.assertEqual(reads, 9, "looks at t=0,30,...,240 and no later")
        self.assertIn("stayed busy", result["reason"])
        # Nothing on a host with a record is free: a free side runner, after the same bounded wait.
        result, reads = self.daily([slot("cmux8s-glaeda-2", busy=True), runner("cmux13s-glaeda-9", SIDE)],
                                   self.records(cmux8s=1))
        self.assertEqual((json.loads(result["runs_on"]), result["pool"], reads), (SIDE, "owned", 9))

    def test_a_small_gap_does_not_wait(self):
        result, reads = self.daily([slot("cmux8s-glaeda-2", busy=True), slot("cmux11s-glaeda-2")],
                                   self.records(cmux8s=1, cmux11s=3))
        self.assertEqual((result["host"], reads), ("cmux11s", 1))

    def test_with_no_owned_runner_free_or_readable_the_route_is_kept(self):
        result, reads = self.daily([slot("cmux8s-glaeda-2", busy=True)], {})
        self.assertEqual((result["runs_on"], result["pool"], reads), ("", "", 1), "no record: nothing to wait for")
        def refused(read):
            raise RuntimeError("HTTP 403")
        result, _ = self.daily(refused, self.records(cmux8s=1))
        self.assertEqual(result["runs_on"], "", "unreadable runners: never a queue nobody saw free")
        result, reads = self.daily([], {}, SIDE_LABEL="blacksmith-6vcpu-macos-26")
        self.assertEqual((result["runs_on"], reads), ("", 0))

    def test_no_record_free_slot_then_side(self):
        result, _ = self.daily([slot("cmux8s-glaeda-2"), runner("cmux13s-glaeda-9", SIDE)], {})
        self.assertEqual((json.loads(result["runs_on"]), result["host"]), (FRESH, ""))

    def test_a_queued_job_on_the_bare_slot_label_claims_every_slot(self):
        now = place.dt.datetime(2026, 10, 28, 12, tzinfo=place.dt.timezone.utc)
        runs = [{"id": 1, "created_at": "2026-10-28T11:58:00Z"}]
        jobs = {1: [{"name": place.DAILY_COMPILE_JOB, "status": "queued", "labels": [FRESH]},
                    {"name": "cmux-next Release compile (Xcode 26)", "status": "queued",
                     "labels": [ROOT_LABEL, place.static_label("cmux12s-glaeda")]}]}
        taken, _ = place.in_flight(runs, lambda run_id: jobs[run_id], "2", now)
        self.assertEqual(taken, {FRESH, place.static_label("cmux12s-glaeda")})
        self.assertEqual(place.free_slots([slot("cmux8s-glaeda-2")], FRESH, taken), [])
        # Slots are out for this placement; a free root runner on a warm host still is not.
        runners = [slot("cmux8s-glaeda-2"), root_runner("cmux8s-glaeda")]
        result = place.place(self.env(), lambda: runners, lambda host: self.records(cmux8s=1).get(host, []),
                             lambda: (taken, set()), sleep=lambda seconds: None, clock=lambda: 0.0)
        self.assertEqual(json.loads(result["runs_on"]), [ROOT_LABEL, place.static_label("cmux8s-glaeda")])

    def test_daily_compiles_count_as_in_flight(self):
        now = place.dt.datetime(2026, 10, 28, 12, tzinfo=place.dt.timezone.utc)
        runs = [{"id": 1, "created_at": "2026-10-28T11:58:00Z"}]
        jobs = {1: [{"name": place.DAILY_COMPILE_JOB, "status": "in_progress", "runner_name": "cmux8s-glaeda-2"},
                    {"name": place.DAILY_COMPILE_JOB, "status": "queued",
                     "labels": [place.static_label("cmux11s-glaeda-2")]}]}
        self.assertEqual(place.in_flight(runs, lambda run_id: jobs[run_id], "2", now),
                         ({place.static_label("cmux11s-glaeda-2")}, {"cmux8s-glaeda-2"}))


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
