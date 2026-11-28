#!/usr/bin/env python3
"""scripts/ci/expected_wait.py: admission by expected wait, not by label (cmuxterm-hq#16113 step 3).

2026-11-20: a burst sent about 11,000 runner-minutes to GitHub-hosted Linux (20 jobs at once for manaflow-ai) and
its wait p50 was 19.8 h.
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts" / "ci"))
import expected_wait as ew  # noqa: E402

NOW = dt.datetime(2026, 11, 20, 18, 0, tzinfo=dt.timezone.utc)
HOSTED = "ubuntu-24.04"
STD, SIDE_STD, LIGHT = "glaeda-std-xcode-26.6", "glaeda-side-std-xcode-26.6", "glaeda-light-xcode-26.6"


def ago(minutes: float) -> str:
    return ew.iso(NOW - dt.timedelta(minutes=minutes))


def jobs(label: str, queued: int = 0, running: int = 0, *, age: float = 10) -> list[dict]:
    return ([{"status": "queued", "labels": [label], "created_at": ago(age), "received_at": ago(1)}
             for _ in range(queued)]
            + [{"status": "in_progress", "labels": [label], "created_at": ago(age), "started_at": ago(age),
                "received_at": ago(1)} for _ in range(running)])


def feed(*entries: list[dict]) -> dict:
    return {"receiver_last_delivery": ago(1), "jobs": [job for entry in entries for job in entry]}


def records(runner: str, seconds: float, *, count: int = ew.MIN_SAMPLES, queue: float | None = 2,
            finished: float = 1, first_id: int = 1) -> list[dict]:
    """COUNT finished jobs, FINISHED minutes ago; queue=None leaves `queue` out, as the controller does for 0 s."""
    found = []
    for index in range(count):
        item = {"at": ago(finished), "runner": runner, "conclusion": "success", "seconds": seconds,
                "id": first_id + index, "attempt": 1}
        if queue is not None:
            item["queue"] = queue
        found.append(item)
    return found


class ExpectedWait(unittest.TestCase):
    def test_queued_plus_running_over_slots_times_p50(self):
        self.assertEqual(ew.expected_wait(180, 20, 20, 300), 3000)
        self.assertEqual(ew.expected_wait(0, 20, 20, 60), 60)

    def test_a_free_slot_is_no_wait(self):
        self.assertEqual(ew.expected_wait(0, 19, 20, 3600), 0)
        self.assertEqual(ew.expected_wait(2, 4, 8, 3600), 0)

    def test_no_slots_is_an_endless_wait(self):
        self.assertEqual(ew.expected_wait(0, 0, 0, 10), float("inf"))


class Verdicts(unittest.TestCase):
    def test_a_hosted_burst_is_saturated_and_published_as_hosted_saturated(self):
        found = ew.verdicts(feed(jobs(HOSTED, queued=400, running=20)), records("github", 240), now=NOW)
        self.assertEqual(found[HOSTED], {"queued": 400, "running": 20, "slots": 20, "p50_s": 240, "wait_s": 5040,
                                         "queue_p50_s": 2, "saturated": True})
        keys = ew.record(found, NOW)
        self.assertIs(keys[ew.HOSTED_KEY], True)
        self.assertEqual(keys[ew.ADMISSION_KEY]["target_s"], 300)
        self.assertEqual(keys[ew.ADMISSION_KEY]["at"], ew.iso(NOW))

    def test_a_short_hosted_queue_admits(self):
        found = ew.verdicts(feed(jobs(HOSTED, queued=5, running=20)), records("github", 60), now=NOW)
        self.assertEqual(found[HOSTED]["wait_s"], 75)
        self.assertFalse(found[HOSTED]["saturated"])
        self.assertIs(ew.record(found, NOW)[ew.HOSTED_KEY], False)

    def test_hosted_with_no_jobs_in_flight_still_gets_a_verdict(self):
        found = ew.verdicts(feed(jobs("blacksmith-4vcpu-ubuntu-2404", running=3)), records("github", 60), now=NOW)
        self.assertFalse(found[HOSTED]["saturated"])

    def test_a_bloated_hosted_running_count_gives_no_hosted_verdict(self):
        # 2026-11-21 07:16Z one read said 2234 running: the account runs 20, so the feed is wrong, and slots of
        # max(20, running) would have admitted everything.
        for running in (ew.HOSTED_RUNNING_SANE + 1, 2234):
            with self.subTest(running=running):
                found = ew.verdicts(feed(jobs(HOSTED, queued=10, running=running)), records("github", 60), now=NOW)
                self.assertNotIn(HOSTED, found)
        found = ew.verdicts(feed(jobs(HOSTED, queued=10, running=ew.HOSTED_RUNNING_SANE)), records("github", 240),
                            now=NOW)
        self.assertEqual(found[HOSTED]["slots"], ew.HOSTED_SLOTS)
        self.assertTrue(found[HOSTED]["saturated"])

    def test_hosted_counts_only_hosted_only_jobs_on_github_runners(self):
        # The owned persistent pool's runners carry ubuntu-24.04 too: what they run takes none of the 20 slots, nor
        # does a job whose labels name anything else.
        on_owned = [dict(job, runner="cmux-runner-pool-hc1a-0") for job in jobs(HOSTED, running=30)]
        on_github = [dict(job, runner="GitHub Actions 1001108535") for job in jobs(HOSTED, running=5)]
        mixed = [dict(job, labels=[HOSTED, "cmux-fleet-linux-x64"]) for job in jobs(HOSTED, queued=50, running=40)]
        found = ew.verdicts(feed(on_owned, on_github, mixed, jobs(HOSTED, queued=2)), records("github", 60), now=NOW)
        self.assertEqual((found[HOSTED]["queued"], found[HOSTED]["running"], found[HOSTED]["slots"]), (2, 5, 20))
        self.assertFalse(found[HOSTED]["saturated"])

    def test_a_long_observed_wait_saturates_a_pool_whose_counts_look_free(self):
        found = ew.verdicts(feed(jobs(HOSTED, queued=1)), records("github", 60, queue=3600), now=NOW)
        self.assertEqual(found[HOSTED]["wait_s"], 0)
        self.assertTrue(found[HOSTED]["saturated"])

    def test_a_job_with_no_queue_field_started_at_once(self):
        # The controller rounds `queue` and leaves it out at 0 s: 6 immediate starts and 5 slow ones is a p50 of 0.
        burst = records("github", 60, count=6, queue=None) + records("github", 60, queue=400, first_id=100)
        found = ew.verdicts(feed(jobs(HOSTED, queued=1)), burst, now=NOW)
        self.assertEqual(found[HOSTED]["queue_p50_s"], 0)
        self.assertFalse(found[HOSTED]["saturated"])

    def test_the_observed_wait_counts_only_while_jobs_queue(self):
        found = ew.verdicts(feed(jobs(HOSTED, running=3)), records("github", 60, queue=3600), now=NOW)
        self.assertNotIn("queue_p50_s", found[HOSTED])
        self.assertFalse(found[HOSTED]["saturated"])

    def test_the_observed_wait_is_of_jobs_that_started_recently(self):
        # A long wait that ended before QUEUE_WINDOW no longer holds the pool saturated after it drained.
        window = ew.QUEUE_WINDOW.total_seconds() / 60
        old = records("github", 60, queue=3600, finished=window + 2)
        found = ew.verdicts(feed(jobs(HOSTED, queued=1)), old + records("github", 60, queue=0, first_id=100), now=NOW)
        self.assertEqual(found[HOSTED]["queue_p50_s"], 0)
        self.assertFalse(found[HOSTED]["saturated"])

    def test_hysteresis_saturates_at_the_target_and_clears_below_half_of_it(self):
        burst = feed(jobs(HOSTED, queued=1))
        def judged(queue, previous=None):
            return ew.verdicts(burst, records("github", 60, queue=queue), now=NOW, previous=previous)[HOSTED]
        self.assertFalse(judged(200)["saturated"])
        published = ew.record({HOSTED: judged(300)}, NOW - dt.timedelta(minutes=10))[ew.ADMISSION_KEY]
        self.assertTrue(published["pools"][HOSTED]["saturated"])
        self.assertTrue(judged(200, published)["saturated"])
        self.assertFalse(judged(140, published)["saturated"])
        # A previous verdict too old to trust holds nothing.
        stale = dict(published, at=ago(ew.FEED_MAX_AGE.total_seconds() / 60 + ew.REFRESH.total_seconds() / 60 + 1))
        self.assertFalse(judged(200, stale)["saturated"])

    def test_every_hosted_ubuntu_label_shares_the_20_slots(self):
        found = ew.verdicts(feed(jobs(HOSTED, running=12), jobs("ubuntu-22.04", running=8),
                                 jobs("ubuntu-latest", queued=30)), records("github", 240), now=NOW)
        for label in (HOSTED, "ubuntu-22.04", "ubuntu-latest"):
            with self.subTest(label=label):
                self.assertEqual((found[label]["queued"], found[label]["running"], found[label]["slots"]),
                                 (30, 20, 20))
                self.assertTrue(found[label]["saturated"])

    def test_owned_mac_families_share_their_runners_and_are_judged_by_counts(self):
        # The timing feed's `mini` class mixes every self-hosted pool, so no p50 of it is a family's.
        slots = json.dumps({STD: 8, LIGHT: 4})
        found = ew.verdicts(feed(jobs(SIDE_STD, queued=40, running=6), jobs(STD, running=2), jobs(LIGHT, running=1)),
                            [], now=NOW, slots_raw=slots)
        self.assertEqual(found[STD], found[SIDE_STD])
        self.assertEqual(found[STD], {"queued": 40, "running": 8, "slots": 8, "basis": "counts", "saturated": True})
        self.assertFalse(found[LIGHT]["saturated"])
        self.assertNotIn("p50_s", found[LIGHT])

    def test_an_owned_family_is_not_judged_by_another_pools_run_times(self):
        # A long `mini` run time (signing, say) does not saturate a family with a free runner, and a tiny one does
        # not admit a family whose runners are all taken while jobs queue.
        slots = json.dumps({STD: 8, LIGHT: 4})
        live = feed(jobs(STD, queued=2, running=5), jobs(LIGHT, queued=1, running=4))
        for seconds in (5, 7200):
            with self.subTest(seconds=seconds):
                found = ew.verdicts(live, records("mini", seconds), now=NOW, slots_raw=slots)
                self.assertFalse(found[STD]["saturated"])
                self.assertTrue(found[LIGHT]["saturated"])

    def test_a_saturated_owned_family_holds_until_its_queue_empties(self):
        slots = json.dumps({STD: 8})
        published = ew.record(ew.verdicts(feed(jobs(STD, queued=4, running=8)), [], now=NOW, slots_raw=slots),
                              NOW - dt.timedelta(minutes=10))[ew.ADMISSION_KEY]
        # One runner freed with jobs still queued: held.
        self.assertTrue(ew.verdicts(feed(jobs(STD, queued=3, running=7)), [], now=NOW, slots_raw=slots,
                                    previous=published)[STD]["saturated"])
        self.assertFalse(ew.verdicts(feed(jobs(STD, running=7)), [], now=NOW, slots_raw=slots,
                                     previous=published)[STD]["saturated"])

    def test_an_idle_family_with_a_ghost_queued_entry_clears(self):
        # Re-review repro: saturated last pass, now 0 of 8 running and 1 queued entry 20 h old (a lost webhook, or a
        # job pinned to one busy gui- member). It must not hold the family saturated for up to 24 h.
        slots = json.dumps({STD: 8})
        published = ew.record(ew.verdicts(feed(jobs(STD, queued=4, running=8)), [], now=NOW, slots_raw=slots),
                              NOW - dt.timedelta(minutes=10))[ew.ADMISSION_KEY]
        self.assertTrue(published["pools"][STD]["saturated"])
        ghost = feed(jobs(STD, queued=1, age=20 * 60))
        self.assertFalse(ew.verdicts(ghost, [], now=NOW, slots_raw=slots, previous=published)[STD]["saturated"])
        # A fresh queued job on a family far below full does not hold it either.
        quiet = feed(jobs(STD, queued=1, running=1))
        self.assertFalse(ew.verdicts(quiet, [], now=NOW, slots_raw=slots, previous=published)[STD]["saturated"])
        # Queued entries older than OWNED_QUEUED_MAX_AGE are not load at all.
        old = ew.OWNED_QUEUED_MAX_AGE.total_seconds() / 60 + 5
        found = ew.verdicts(feed(jobs(STD, queued=20, age=old), jobs(STD, running=8)), [], now=NOW, slots_raw=slots)
        self.assertEqual((found[STD]["queued"], found[STD]["saturated"]), (0, False))

    def test_owned_families_are_judged_without_timing_records(self):
        slots = json.dumps({STD: 8})
        found = ew.verdicts(feed(jobs(STD, queued=4, running=8), jobs(HOSTED, queued=400, running=20)), None,
                            now=NOW, slots_raw=slots)
        self.assertTrue(found[STD]["saturated"])
        self.assertNotIn(HOSTED, found)

    def test_owned_macs_need_their_runner_count(self):
        found = ew.verdicts(feed(jobs(STD, queued=40, running=6)), records("mini", 450), now=NOW)
        self.assertNotIn(STD, found)
        for raw in ("", "not json", "[]", json.dumps({STD: 0}), json.dumps({STD: True}), json.dumps({"x": 3})):
            with self.subTest(raw=raw):
                self.assertNotIn(STD, ew.verdicts(feed(jobs(STD, queued=40)), records("mini", 450), now=NOW,
                                                  slots_raw=raw))

    def test_an_unchanged_verdict_republishes_the_last_one_until_it_is_refresh_old(self):
        def burst(queued):
            return ew.verdicts(feed(jobs(HOSTED, queued=queued, running=20)), records("github", 240), now=NOW)
        published = ew.record(burst(400), NOW - dt.timedelta(minutes=10))[ew.ADMISSION_KEY]
        # Same routing, other numbers, under REFRESH old: the published value again, so nothing is written.
        self.assertEqual(ew.record(burst(380), NOW, previous=published)[ew.ADMISSION_KEY], published)
        # Routing changed: the new verdict.
        changed = ew.record(burst(0), NOW, previous=published)[ew.ADMISSION_KEY]
        self.assertEqual(changed["at"], ew.iso(NOW))
        self.assertFalse(changed["pools"][HOSTED]["saturated"])
        # REFRESH old: rewritten.
        aged = dict(published, at=ew.iso(NOW - ew.REFRESH))
        self.assertEqual(ew.record(burst(380), NOW, previous=aged)[ew.ADMISSION_KEY]["at"], ew.iso(NOW))

    def test_missing_data_gives_no_verdict(self):
        burst = feed(jobs(HOSTED, queued=400, running=20))
        self.assertEqual(ew.verdicts(None, records("github", 240), now=NOW), {})
        self.assertEqual(ew.verdicts(burst, None, now=NOW), {})
        # Too few finished jobs for a p50.
        self.assertEqual(ew.verdicts(burst, records("github", 240, count=ew.MIN_SAMPLES - 1), now=NOW), {})
        # Finished outside the window, cancelled or zero-length runs do not count.
        old = records("github", 240, finished=ew.RECORD_WINDOW.total_seconds() / 60 + 1)
        cancelled = [dict(item, conclusion="cancelled") for item in records("github", 240)]
        self.assertEqual(ew.verdicts(burst, old + cancelled + records("github", 0), now=NOW), {})
        self.assertEqual(ew.record({}, NOW), {})

    def test_a_stale_feed_gives_no_verdict(self):
        stale = {"receiver_last_delivery": ago(ew.FEED_MAX_AGE.total_seconds() / 60 + 1),
                 "jobs": [dict(job, received_at=ago(40)) for job in jobs(HOSTED, queued=400, running=20)]}
        self.assertEqual(ew.verdicts(stale, records("github", 240), now=NOW), {})
        future = {"receiver_last_delivery": ew.iso(NOW + dt.timedelta(hours=1)), "jobs": []}
        self.assertEqual(ew.verdicts(future, records("github", 240), now=NOW), {})

    def test_entries_older_than_github_keeps_are_not_load(self):
        lost = jobs(HOSTED, queued=300, age=ew.QUEUED_MAX_AGE.total_seconds() / 60 + 5)
        ended = jobs(HOSTED, running=300, age=ew.RUNNING_MAX_AGE.total_seconds() / 60 + 5)
        self.assertEqual(ew.label_load(lost + ended + jobs(HOSTED, queued=2, running=3), NOW),
                         {HOSTED: {"queued": 2, "running": 3}})


ROOT_STD, GUI_STD, ROOT_LIGHT = "glaeda-root-std-xcode-26.6", "glaeda-gui-std-xcode-26.6", "glaeda-root-light-xcode-26.6"


def runner(ident: int, *labels: str, status: str = "online") -> dict:
    """One entry of GitHub's runner listing (GET /orgs/<org>/actions/runners)."""
    return {"id": ident, "name": f"mini-{ident}-glaeda", "status": status, "busy": False,
            "labels": [{"name": "self-hosted"}, {"name": "macOS"}, *({"name": label} for label in labels)]}


# Three std minis' runners: two carry the pool and root labels, one the pool and side labels, one the gui label only;
# one more std runner is offline. Two light runners. A Linux runner carries no owned label.
LISTING = [runner(1, STD, ROOT_STD), runner(2, STD, ROOT_STD), runner(3, STD, SIDE_STD), runner(4, GUI_STD),
           runner(5, STD, SIDE_STD, status="offline"), runner(6, LIGHT, ROOT_LIGHT), runner(7, LIGHT),
           runner(8, "cmux-linux")]


class OnlineRunnerCounts(unittest.TestCase):
    """The owned slots come from the runners online, not the hand-set CI_OWNED_POOL_SLOTS (cmuxterm-hq
    docs/handbook/hand-set-concurrency-number.md)."""

    def test_each_label_counts_its_online_runners(self):
        labels, _ = ew.owned_capacity(LISTING)
        self.assertEqual(labels, {STD: 3, ROOT_STD: 2, SIDE_STD: 1, GUI_STD: 1, LIGHT: 2, ROOT_LIGHT: 1})

    def test_a_family_has_its_distinct_online_runners_not_the_max_or_sum_of_its_labels(self):
        _, families = ew.owned_capacity(LISTING)
        # std: runners 1-4 (the max over its labels is 3, the sum 7); light: runners 6 and 7.
        self.assertEqual(families, {"std-xcode-26.6": 4, "light-xcode-26.6": 2})

    def test_a_configured_route_stays_above_zero(self):
        # pr_runner_pool.gui_runner() and side_runner() skip a label at 0: a label CI_OWNED_POOL_SLOTS routes to keeps
        # 1 with no runner online, and so does its family; a label it does not name stays absent.
        xl, root_xl = "glaeda-xl-xcode-26.6", "glaeda-root-xl-xcode-26.6"
        slots = json.dumps({STD: 60, xl: 4, root_xl: 2, "glaeda-ios-sim": 11})
        labels, families = ew.owned_capacity([runner(5, STD, status="offline")], slots)
        self.assertEqual(labels, {STD: 1, xl: 1, root_xl: 1})
        self.assertEqual(families, {"std-xcode-26.6": 1, "xl-xcode-26.6": 1})
        # The variable's count never raises an online one: 60 configured, 3 online.
        labels, families = ew.owned_capacity(LISTING, slots)
        self.assertEqual((labels[STD], families["std-xcode-26.6"]), (3, 4))

    def test_the_verdict_takes_the_online_runners_over_the_variable(self):
        # The variable says 60 std slots; 4 std runners are online and 5 jobs hold them with 3 queued: saturated.
        slots = json.dumps({STD: 60, LIGHT: 23})
        live = feed(jobs(STD, queued=3, running=2), jobs(ROOT_STD, running=2), jobs(LIGHT, running=1))
        found = ew.verdicts(live, [], now=NOW, slots_raw=slots, runners=LISTING)
        self.assertEqual(found[STD], {"queued": 3, "running": 4, "slots": 4, "basis": "counts", "saturated": True,
                                      "slots_from": "runners", "runners": 3})
        self.assertEqual((found[ROOT_STD]["slots"], found[ROOT_STD]["runners"]), (4, 2))
        self.assertEqual((found[GUI_STD]["runners"], found[SIDE_STD]["runners"]), (1, 1))
        self.assertEqual((found[LIGHT]["slots"], found[LIGHT]["saturated"]), (2, False))
        # Unread (None), the variable decides as before.
        self.assertFalse(ew.verdicts(live, [], now=NOW, slots_raw=slots)[STD]["saturated"])

    def test_a_family_online_without_a_configured_label_is_judged(self):
        found = ew.verdicts(feed(jobs(LIGHT, queued=2, running=2)), [], now=NOW, slots_raw="", runners=LISTING)
        self.assertTrue(found[LIGHT]["saturated"])
        self.assertEqual(found[LIGHT]["slots"], 2)

    def test_admission_reads_the_listing_with_its_token_and_falls_back_without_it(self):
        def request(url, seconds):
            return 200, json.dumps(feed(jobs(STD, queued=3, running=4))).encode(), {}

        calls = []

        class GitHub:
            def __init__(self, token, repo):
                calls.append((token, repo))

            def runners(self):
                return LISTING

        env = {"GH_REPO": "manaflow-ai/cmux", "RUNNER_ADMISSION_CONTROLLER": "http://controller",
               "CI_OWNED_POOL_SLOTS": json.dumps({STD: 60})}
        pools = ew.admission(env, NOW, request=request, github=GitHub)[ew.ADMISSION_KEY]["pools"]
        self.assertEqual(calls, [])  # no token, no listing
        self.assertEqual((pools[STD]["slots"], pools[STD]["saturated"]), (60, False))
        pools = ew.admission({**env, "RUNNER_ADMISSION_RUNNERS_TOKEN": "t"}, NOW, request=request,
                             github=GitHub)[ew.ADMISSION_KEY]["pools"]
        self.assertEqual(calls, [("t", "manaflow-ai/cmux")])
        self.assertEqual((pools[STD]["slots"], pools[STD]["runners"], pools[STD]["saturated"]), (4, 3, True))

        class Refused(GitHub):
            def runners(self):
                raise RuntimeError("403 rate limit")

        pools = ew.admission({**env, "RUNNER_ADMISSION_RUNNERS_TOKEN": "t"}, NOW, request=request,
                             github=Refused)[ew.ADMISSION_KEY]["pools"]
        self.assertEqual((pools[STD]["slots"], pools[STD]["saturated"]), (60, False))


class WorkflowHourBudget(unittest.TestCase):
    NOW = dt.datetime(2026, 11, 26, 11, 20, tzinfo=dt.timezone.utc)

    def rec(self, at, workflow, seconds):
        return {"at": at, "workflow": workflow, "seconds": seconds, "id": 1, "attempt": 1}

    def test_unset_or_bad_budget_judges_nothing(self):
        self.assertEqual(ew.budgets(None), {})
        self.assertEqual(ew.budgets("3000"), {})
        self.assertEqual(ew.budgets('{"pr router": true, "x": -1}'), {})
        self.assertEqual(ew.workflow_budget([self.rec("2026-11-26T10:30:00Z", "pr router", 60)], self.NOW, {}), {})

    def test_the_last_whole_hour_is_judged_and_over_names_what_a_hold_would_queue(self):
        records = [self.rec("2026-11-26T10:05:00Z", "pr router", 120 * 60),
                   self.rec("2026-11-26T10:59:59Z", "pr router", 60 * 60),
                   self.rec("2026-11-26T11:10:00Z", "pr router", 900 * 60),  # this hour: not yet judged
                   self.rec("2026-11-26T09:59:00Z", "pr router", 900 * 60),  # the hour before
                   self.rec("2026-11-26T10:30:00Z", "rust workspaces", 30 * 60)]
        found = ew.workflow_budget(records, self.NOW, {"pr router": 150, "rust workspaces": 100})
        self.assertEqual(found["pr router"], {"hour": "2026-11-26T10:00:00Z", "min": 180.0, "budget": 150,
                                              "over": True, "would_hold_min": 30.0})
        self.assertFalse(found["rust workspaces"]["over"])
        self.assertEqual(found["rust workspaces"]["would_hold_min"], 0.0)

    def test_no_records_is_no_verdict(self):
        self.assertEqual(ew.workflow_budget(None, self.NOW, {"pr router": 1}), {})


class Admission(unittest.TestCase):
    def test_no_controller_reads_nothing_and_publishes_nothing(self):
        def request(url, seconds):
            raise AssertionError("read without a controller")

        self.assertEqual(ew.admission({"GH_REPO": "manaflow-ai/cmux"}, NOW, request=request), {})

    def test_an_unreachable_controller_publishes_nothing(self):
        def request(url, seconds):
            raise OSError("no route to host")

        env = {"GH_REPO": "manaflow-ai/cmux", "RUNNER_ADMISSION_CONTROLLER": "http://controller"}
        self.assertEqual(ew.admission(env, NOW, request=request), {})

    def test_reads_both_feeds_once_without_github(self):
        seen = []

        def request(url, seconds):
            seen.append(url)
            if "/v1/github/actions?" in url:
                return 200, json.dumps(feed(jobs(HOSTED, queued=400, running=20))).encode(), {}
            return 200, json.dumps({"more": False, "records": records("github", 240)}).encode(), {}

        env = {"GH_REPO": "manaflow-ai/cmux", "RUNNER_ADMISSION_CONTROLLER": "http://controller/"}
        keys = ew.admission(env, NOW, request=request)
        self.assertIs(keys[ew.HOSTED_KEY], True)
        self.assertEqual(len(seen), 2)
        self.assertTrue(all(url.startswith("http://controller/v1/github/") for url in seen))

    def test_overlapping_pages_count_each_job_once(self):
        # Each page starts at the last one's final second, so its records come again.
        first = records("github", 240, count=3) + records("github", 60, count=1, first_id=50)
        second = records("github", 60, count=1, first_id=50) + records("github", 60, count=2, first_id=60)
        pages = [{"more": True, "records": first}, {"more": False, "records": second}]

        def request(url, seconds):
            if "/v1/github/actions?" in url:
                return 200, json.dumps(feed()).encode(), {}
            return 200, json.dumps(pages.pop(0)).encode(), {}

        _, found = ew.read_feeds("http://controller", "manaflow-ai/cmux", NOW, request=request)
        self.assertEqual(sorted(item["id"] for item in found), [1, 2, 3, 50, 60, 61])


if __name__ == "__main__":
    unittest.main()
