#!/usr/bin/env python3
"""Late placement: jobs after compile admission move onto idle root runners."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from unittest import mock
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/late_placement.py"
WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"
XCODE = "/Applications/Xcode_26.6.app"
ROOT_STD = "glaeda-root-std-xcode-26.6"
FULL = {"MACOS": "true", "CLI": "false", "FULL_SUITE": "true", "UNIT_SUITE": "false",
        "UNIT_IN_ADMISSION": "false", "UNIT_SELECTORS": "", "ADMISSION_XCODE_APP": XCODE,
        "ADMISSION_RUNNER": "blacksmith-12vcpu-macos-26", "OWNED_JOBS": ""}


def load():
    spec = importlib.util.spec_from_file_location("late_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["late_placement"] = module
    spec.loader.exec_module(module)
    return module


late = load()


def runner(name: str, *labels: str, busy: bool = False, status: str = "online") -> dict:
    return {"name": name, "status": status, "busy": busy, "labels": [{"name": label} for label in labels]}


def roots(idle: int, busy: int = 0) -> list[dict]:
    return ([runner(f"idle-{i}", "self-hosted", ROOT_STD) for i in range(idle)]
            + [runner(f"busy-{i}", ROOT_STD, busy=True) for i in range(busy)])


class Decide(unittest.TestCase):
    def test_a_full_suite_off_blacksmith_takes_the_idle_roots_shards_first(self):
        placed, why = late.decide(FULL, roots(idle=3, busy=5))
        self.assertEqual(placed, {"shard-1": ROOT_STD, "shard-2": ROOT_STD, "shard-3": ROOT_STD})
        self.assertIn("3 idle", why)

    def test_enough_idle_roots_move_every_job_after_admission(self):
        placed, _ = late.decide(FULL, roots(idle=16))
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"})

    def test_jobs_the_picker_already_owned_stay_put(self):
        env = dict(FULL, OWNED_JOBS=" admission shard-1 shard-2 ")
        placed, _ = late.decide(env, roots(idle=2))
        self.assertEqual(placed, {"shard-3": ROOT_STD, "shard-4": ROOT_STD})

    def test_gui_jobs_take_idle_gui_runners_and_the_rest_idle_roots(self):
        gui = "glaeda-gui-std-xcode-26.6"
        runners = [*roots(idle=3), *(runner(f"gui-{i}", "self-hosted", gui) for i in range(2)),
                   runner("gui-busy", gui, busy=True)]
        slots = '{"std": 40, "root-std": 19, "gui-std": 10}'
        # Admission ran on Blacksmith (the picker named no gui runner): the slots still route GUI jobs.
        placed, why = late.decide(dict(FULL, OWNED_SLOTS=slots), runners)
        # cli-product-tests holds the gui token too, so it queues behind the shards for a gui runner.
        self.assertEqual(placed, {"shard-1": gui, "shard-2": gui})
        self.assertIn(f"2 idle `{gui}`", why)
        # The runners decide, not CI_OWNED_POOL_SLOTS: without a gui count the gui runners still route.
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS='{"std": 40, "root-std": 19}'), runners)[0],
                         {"shard-1": gui, "shard-2": gui})
        self.assertEqual(late.decide(FULL, runners)[0], {"shard-1": gui, "shard-2": gui})
        # No runner carries the gui label: the GUI jobs take the root label as before, whatever the slots.
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS=slots), roots(idle=3))[0],
                         {"shard-1": ROOT_STD, "shard-2": ROOT_STD, "shard-3": ROOT_STD})
        # No idle gui runner: the gui-token jobs stay where the picker put them.
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS=slots),
                                     [*roots(idle=3), runner("gui-busy", gui, busy=True)])[0], {})
        # An offline gui runner (a drained mini) still keeps them off the root label.
        self.assertEqual(late.decide(FULL, [*roots(idle=3), runner("gui-off", gui, status="offline")])[0], {})
        # Enough gui runners: cli-product-tests takes one, never the root label.
        many = [*roots(idle=3), *(runner(f"gui-{i}", "self-hosted", gui) for i in range(10))]
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS=slots), many)[0]["cli-product"], gui)

    def test_no_idle_root_changes_nothing(self):
        self.assertEqual(late.decide(FULL, roots(idle=0, busy=16))[0], {})

    def test_offline_runners_do_not_count(self):
        self.assertEqual(late.decide(FULL, [runner("off", ROOT_STD, status="offline")])[0], {})

    def test_another_xcode_has_no_owned_pool(self):
        env = dict(FULL, ADMISSION_XCODE_APP="/Applications/Xcode_26.3.app")
        placed, why = late.decide(env, roots(idle=8))
        self.assertEqual(placed, {})

    def test_unreadable_runners_change_nothing(self):
        placed, why = late.decide(FULL, None)
        self.assertEqual(placed, {})
        self.assertIn("could not be read", why)

    def test_gui_off_moves_only_cli_product(self):
        env = dict(FULL, POOL_OWNED_GUI="0")
        self.assertEqual(late.decide(env, roots(idle=8))[0], {"cli-product": ROOT_STD})

    def test_a_changed_suites_run_moves_its_one_worker(self):
        env = dict(FULL, FULL_SUITE="false", UNIT_SUITE="true", UNIT_SELECTORS="cmuxTests/FooTests")
        self.assertEqual(late.decide(env, roots(idle=4))[0], {"shard-8": ROOT_STD})

    def test_a_compile_only_run_has_nothing_after_admission(self):
        env = dict(FULL, FULL_SUITE="false")
        self.assertEqual(late.decide(env, roots(idle=4))[0], {})


GUI = "glaeda-gui-std-xcode-26.6"
SLOTS = '{"std": 40, "root-std": 19, "gui-std": 10}'
RETRY = "blacksmith-12vcpu-macos-26"
# An owned full suite: the picker gave admission, the shards, lag and cli-product the minis.
OWNED = dict(FULL, OWNED_SLOTS=SLOTS, RETRY_RUNNER=RETRY, ADMISSION_RUNNER="glaeda-root-std-xcode-26.6",
             OWNED_JOBS=" admission " + " ".join(f"shard-{i}" for i in range(1, 8)) + " lag cli-product ")


def guis(idle: int, busy: int) -> list[dict]:
    return ([runner(f"gui-{i}", "self-hosted", GUI) for i in range(idle)]
            + [runner(f"gui-busy-{i}", GUI, busy=True) for i in range(busy)])


class GuiOverflow(unittest.TestCase):
    def backlog(self, queued: int, retry_queued: int = 0):
        calls = []

        def count(labels):
            calls.append(list(labels))
            return {label: queued if label == GUI else retry_queued for label in labels}
        return count, calls

    def test_a_full_gui_pool_sends_every_queued_job_to_an_idle_blacksmith_pool(self):
        count, calls = self.backlog(queued=6)
        placed, why = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        # Six queued ahead on ten busy gui runners: the first job would start in 7/10 x 407 s = 285 s there,
        # against 15 s on an idle 12vcpu pool, and the ninth 15 s + 4/5 x 295 s = 251 s. No round of queue
        # is kept on the minis while Blacksmith would start the job sooner.
        self.assertEqual(placed, {key: RETRY for key in (*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product")})
        self.assertEqual(calls, [[GUI, RETRY]])
        self.assertIn(f"6 gui job(s) queued ahead on 10 online and 0 on `{RETRY}`", why)

    def test_a_longer_blacksmith_queue_keeps_the_owned_gui_jobs_on_the_minis(self):
        # Six gui jobs ahead on ten gui runners is under two rounds; fifty on 12vcpu's five machines is ten.
        count, _ = self.backlog(queued=6, retry_queued=50)
        placed, why = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        self.assertEqual(placed, {})
        self.assertIn(f"and 50 on `{RETRY}`", why)

    def test_jobs_move_only_while_blacksmith_would_start_them_sooner(self):
        # The shared account has 15 queued jobs and 17 measured slots, so the
        # retry pool starts this run before the GUI backlog for every job.
        count, _ = self.backlog(queued=25, retry_queued=15)
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        mine = sorted({*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"}, key=late.pool.priority)
        self.assertEqual(placed, {key: RETRY for key in mine})

    def test_an_empty_blacksmith_pool_takes_its_machines_at_once(self):
        # Twenty gui runners, twenty jobs ahead: each job waits over a round there, none on an idle 12vcpu.
        count, _ = self.backlog(queued=20, retry_queued=0)
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=20)], count)
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"})

    def test_no_gui_runner_online_moves_every_owned_gui_job_without_a_read(self):
        count, calls = self.backlog(queued=0, retry_queued=99)
        offline = [runner(f"gui-off-{i}", GUI, status="offline") for i in range(10)]
        placed, _ = late.decide(OWNED, [*roots(idle=2), *offline], count)
        self.assertEqual(set(placed.values()), {RETRY})
        self.assertEqual(len(placed), 9)
        self.assertEqual(calls, [])

    def test_the_kill_switch_reads_only_the_gui_backlog(self):
        count, calls = self.backlog(queued=1, retry_queued=99)
        placed, _ = late.decide(dict(OWNED, POOL_QUEUE_ROUNDS="0"), [*roots(idle=2), *guis(idle=3, busy=7)], count)
        self.assertEqual(calls, [[GUI]])
        # The one queued ahead takes an idle runner: two of the nine stay, whatever Blacksmith's queue.
        self.assertEqual(len(placed), 7)

    def test_a_backlog_past_a_round_moves_every_owned_gui_job(self):
        count, _ = self.backlog(queued=25)
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"})
        self.assertEqual(set(placed.values()), {RETRY})

    def test_enough_idle_gui_runners_look_up_nothing_and_move_nothing(self):
        count, calls = self.backlog(queued=99)
        self.assertEqual(late.decide(OWNED, [*roots(idle=2), *guis(idle=9, busy=1)], count)[0], {})
        self.assertEqual(calls, [])

    def test_the_idle_gui_runners_keep_the_first_jobs_and_an_idle_blacksmith_takes_the_rest(self):
        count, _ = self.backlog(queued=0)
        # Minis first: three idle GUI runners take the three highest priority
        # jobs. The shared Blacksmith account takes the remaining six.
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=3, busy=7)], count)
        mine = sorted({*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"}, key=late.pool.priority)
        self.assertEqual(placed, {key: RETRY for key in mine[3:]})

    def test_a_tie_keeps_the_job_on_the_minis(self):
        # Nothing ahead on one gui runner of 20 s jobs, against an idle retry pool's 20 s start: minis first.
        with mock.patch.object(late, "GUI_JOB_SECONDS", late.DEFAULT_BLACKSMITH_START_SECONDS):
            self.assertEqual(late.overflow(("shard-1",), owned_jobs="shard-1", gui_idle=0, gui_online=1, backlog=0,
                                           retry_queued=0, retry_capacity=1, retry="unknown"), ())
            self.assertEqual(late.overflow(("shard-1",), owned_jobs="shard-1", gui_idle=0, gui_online=1, backlog=1,
                                           retry_queued=0, retry_capacity=1, retry="unknown"), ("shard-1",))

    def test_an_unreadable_backlog_moves_nothing(self):
        def broken(labels):
            raise RuntimeError("HTTP 403")
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], broken)
        self.assertEqual(placed, {})

    def test_the_kill_switch_queues_nothing_on_purpose(self):
        count, _ = self.backlog(queued=0)
        placed, _ = late.decide(dict(OWNED, POOL_QUEUE_ROUNDS="0"), [*roots(idle=2), *guis(idle=2, busy=8)], count)
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(3, 8)), "lag", "cli-product"})

    def test_no_blacksmith_retry_pool_keeps_the_jobs(self):
        count, _ = self.backlog(queued=40)
        for retry in ("", "glaeda-std-xcode-26.6"):
            with self.subTest(retry=retry):
                env = dict(OWNED, RETRY_RUNNER=retry)
                self.assertEqual(late.decide(env, [*roots(idle=2), *guis(idle=0, busy=10)], count)[0], {})

    def test_gui_off_or_no_gui_label_moves_no_owned_job(self):
        count, _ = self.backlog(queued=40)
        busy = [*roots(idle=0, busy=16), *guis(idle=0, busy=10)]
        self.assertEqual(late.decide(dict(OWNED, POOL_OWNED_GUI="0"), busy, count)[0], {})
        self.assertEqual(late.decide(OWNED, roots(idle=0, busy=16), count)[0], {})

    def test_owned_jobs_that_stay_take_the_idle_gui_runners_before_unowned_ones(self):
        count, _ = self.backlog(queued=0)
        env = dict(OWNED, OWNED_JOBS=" admission shard-1 shard-2 shard-3 ")
        # Three owned shards and two idle gui runners: the owned ones keep both, so none is free
        # for shard-4 and up, which stay on Blacksmith where the picker put them; the third owned
        # shard would queue on the gui label and starts sooner on the idle retry pool.
        self.assertEqual(late.decide(env, [*roots(idle=0, busy=16), *guis(idle=2, busy=8)], count)[0],
                         {"shard-3": RETRY})

    def test_the_backlog_takes_the_idle_runners_first(self):
        count, _ = self.backlog(queued=12)
        # Two idle, ten online, twelve queued before this run: nothing of it starts within a round.
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=2, busy=8)], count)
        self.assertEqual(set(placed), {*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"})
        count, calls = self.backlog(queued=1)
        # One queued ahead takes one of the two idle runners; the highest
        # priority job takes the other. The shared account has enough measured
        # capacity for the remaining jobs, so they move to Blacksmith.
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=2, busy=8)], count)
        mine = sorted({*(f"shard-{i}" for i in range(1, 8)), "lag", "cli-product"}, key=late.pool.priority)
        self.assertEqual(placed, {key: RETRY for key in mine[1:]})
        self.assertEqual(calls, [[GUI, RETRY]])

    def test_the_kill_switch_with_nothing_idle_moves_every_owned_gui_job_without_a_read(self):
        count, calls = self.backlog(queued=0)
        placed, _ = late.decide(dict(OWNED, POOL_QUEUE_ROUNDS="0"), [*roots(idle=2), *guis(idle=0, busy=10)], count)
        self.assertEqual(len(placed), 9)
        self.assertEqual(calls, [])

    def test_unowned_gui_jobs_still_take_only_idle_runners_the_owned_ones_left(self):
        count, _ = self.backlog(queued=0)
        env = dict(OWNED, OWNED_JOBS=" admission shard-1 shard-2 ")
        placed, _ = late.decide(env, [*roots(idle=0, busy=16), *guis(idle=4, busy=6)], count)
        # shard-1 and shard-2 keep two idle runners; the other two take shard-3 and shard-4 off Blacksmith.
        self.assertEqual(placed, {"shard-3": GUI, "shard-4": GUI})

    def test_backlog_reads_queued_and_running_runs_and_counts_each_label(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)

        def at(minutes_ago: int) -> str:
            return (now - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")

        class API:
            def __init__(self):
                self.jobs_read, self.statuses = [], []

            def runs_since(self, workflow, since, **filters):
                self.statuses.append((workflow, filters["status"]))
                # GitHub lists a run with a queued job as queued even while others run.
                if workflow != "ci.yml":
                    return []
                if filters["status"] == "queued":
                    return [{"id": 5, "created_at": at(30)}, {"id": 4, "created_at": at(2)}]
                return [{"id": 9, "created_at": at(10)}, {"id": 8, "created_at": at(50)},
                        {"id": 7, "created_at": at(20)}, {"id": 6, "created_at": at(40)}]

            def get(self, path):
                self.jobs_read.append(int(path.split("/")[3]))
                return {"jobs": [{"status": "queued", "labels": [GUI]}, {"status": "queued", "labels": [ROOT_STD]},
                                 {"status": "in_progress", "labels": [GUI]}, {"status": "queued", "labels": [GUI]}]}
        api = API()
        # Run 4 is too young to have gui jobs and 7 is this run.
        self.assertEqual(late.gui_backlog(api, [GUI, ROOT_STD], exclude_run_id=7, now=now), {GUI: 8, ROOT_STD: 4})
        self.assertEqual(sorted(api.jobs_read), [5, 6, 8, 9])
        self.assertEqual(sorted(api.statuses), [("ci.yml", "in_progress"), ("ci.yml", "queued"),
                                                ("test-e2e.yml", "in_progress"), ("test-e2e.yml", "queued")])

    def test_backlog_counts_queued_e2e_gui_jobs(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)
        e2e = {"id": 21, "created_at": "2026-09-28T00:00:00Z"}

        class API:
            def runs_since(self, workflow, since, **filters):
                return [e2e] if workflow == "test-e2e.yml" and filters["status"] == "in_progress" else []

            def get(self, path):
                return {"jobs": [{"status": "queued", "labels": [ROOT_STD]}]}

        # E2E runs request the root/pool label but consume the GUI token inside the job.
        self.assertEqual(late.gui_backlog(API(), [GUI, RETRY], exclude_run_id=None, now=now),
                         {GUI: 1, RETRY: 0})

    def test_e2e_fallback_rejects_unrelated_or_unowned_jobs(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)
        runs = [
            ({"id": 22, "created_at": "2026-09-28T00:00:00Z"}, "test-e2e.yml", ["glaeda-other-xcode-26.6"]),
            ({"id": 23, "created_at": "2026-09-28T00:00:00Z"}, "test-e2e.yml", ["ubuntu-latest"]),
            ({"id": 24, "created_at": "2026-09-28T00:00:00Z"}, "ci.yml", ["glaeda-other-xcode-26.6"]),
        ]

        class API:
            def runs_since(self, workflow, since, **filters):
                return [run for run, run_workflow, _ in runs
                        if workflow == run_workflow and filters["status"] == "in_progress"]

            def get(self, path):
                run_id = int(path.split("/")[3])
                labels = next(labels for run, _, labels in runs if run["id"] == run_id)
                return {"jobs": [{"status": "queued", "labels": labels}]}

        self.assertEqual(late.gui_backlog(API(), [GUI, RETRY], exclude_run_id=None, now=now),
                         {GUI: 0, RETRY: 0})

    def test_backlog_reads_runs_concurrently(self):
        import datetime as dt
        import threading
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)
        runs = [{"id": i, "created_at": (now - dt.timedelta(minutes=100 - i)).strftime("%Y-%m-%dT%H:%M:%SZ")}
                for i in range(1, 2 * late.BACKLOG_READERS + 1)]
        # Every read of a batch must be in flight at once, or the barrier breaks and the read raises.
        together = threading.Barrier(late.BACKLOG_READERS, timeout=30)

        class API:
            def __init__(self):
                self.jobs_read, self.lock = [], threading.Lock()

            def runs_since(self, workflow, since, **filters):
                return runs if workflow == "ci.yml" and filters["status"] == "in_progress" else []

            def get(self, path):
                together.wait()
                with self.lock:
                    self.jobs_read.append(int(path.split("/")[3]))
                return {"jobs": [{"status": "queued", "labels": [GUI]}]}
        api = API()
        self.assertEqual(late.gui_backlog(api, [GUI], exclude_run_id=None, now=now), {GUI: len(runs)})
        self.assertEqual(sorted(api.jobs_read), [run["id"] for run in runs])

    def test_backlog_reads_at_most_the_oldest_lookups(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)
        runs = [{"id": i, "created_at": (now - dt.timedelta(minutes=100 - i)).strftime("%Y-%m-%dT%H:%M:%SZ")}
                for i in range(1, late.BACKLOG_LOOKUPS + 11)]

        class API:
            def __init__(self):
                self.jobs_read = []

            def runs_since(self, workflow, since, **filters):
                return runs if workflow == "ci.yml" and filters["status"] == "in_progress" else []

            def get(self, path):
                self.jobs_read.append(int(path.split("/")[3]))
                return {"jobs": [{"status": "queued", "labels": [RETRY]}]}
        api = API()
        self.assertEqual(late.gui_backlog(api, [GUI, RETRY], exclude_run_id=None, now=now),
                         {GUI: 0, RETRY: late.BACKLOG_LOOKUPS})
        self.assertEqual(sorted(api.jobs_read), list(range(1, late.BACKLOG_LOOKUPS + 1)))

    def test_a_failed_backlog_read_raises_so_nothing_moves(self):
        import datetime as dt
        now = dt.datetime(2026, 9, 28, 1, 0, tzinfo=dt.timezone.utc)

        class API:
            def runs_since(self, workflow, since, **filters):
                return [{"id": i, "created_at": (now - dt.timedelta(minutes=30 + i)).strftime("%Y-%m-%dT%H:%M:%SZ")}
                        for i in range(1, 4)] if workflow == "ci.yml" and filters["status"] == "in_progress" else []

            def get(self, path):
                if path.split("/")[3] == "2":
                    raise RuntimeError("HTTP 502")
                return {"jobs": []}
        with self.assertRaises(RuntimeError):
            late.gui_backlog(API(), [GUI], exclude_run_id=None, now=now)


class Output(unittest.TestCase):
    def test_main_writes_an_empty_object_without_a_token(self):
        import tempfile
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out:
            self.assertEqual(late.main(dict(FULL, GITHUB_OUTPUT=out.name)), 0)
            self.assertEqual(Path(out.name).read_text(), "runners={}\nonto_owned=false\n")

    def test_main_counts_the_backlog_without_this_run_and_says_where_jobs_went(self):
        import tempfile
        from unittest import mock
        seen = {}

        class API:
            def __init__(self, token, repo):
                pass

            def runners(self):
                return [*roots(idle=2), *guis(idle=0, busy=10)]

        def backlog(github, labels, *, exclude_run_id, now):
            seen["exclude"] = exclude_run_id
            return {label: 40 if label == GUI else 0 for label in labels}
        with tempfile.NamedTemporaryFile("r+", suffix=".out") as out, \
                mock.patch.object(late.pool, "GitHub", API), mock.patch.object(late, "gui_backlog", backlog):
            env = dict(OWNED, GITHUB_OUTPUT=out.name, ROUTE_TOKEN="t", GITHUB_REPOSITORY="o/r", GITHUB_RUN_ID="77")
            self.assertEqual(late.main(env), 0)
            text = Path(out.name).read_text()
        self.assertEqual(seen["exclude"], 77)
        self.assertIn(f'"shard-1": "{RETRY}"', text)
        self.assertTrue(text.endswith("onto_owned=false\n"), text)


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_the_consumers_wait_for_late_placement_and_read_it_first_on_attempt_one(self):
        keys = {"app-host-unit-tests": "format('shard-{0}', matrix.shard)",
                "tests-build-and-lag": "'lag'", "cli-product-tests": "'cli-product'"}
        prefix = "${{ github.run_attempt == 1 && fromJSON(needs.late-placement.outputs.runners || '{}')[%s] || "
        for job, key in keys.items():
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertIn("late-placement", spec["needs"])
                late = (prefix % key).removeprefix("${{ ")
                owner = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                # tests-build-and-lag keeps the fork-owner branch and then the fork
                # pull-request branch first (test_ci_fork_runner_routing). Late
                # placement skips fork heads, so its output is {} there anyway.
                fork_pr = (
                    "(github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name"
                    " != github.repository && (startsWith(inputs.pr_runner, 'blacksmith-') && inputs.pr_runner"
                    " || 'blacksmith-6vcpu-macos-15') || "
                )
                self.assertTrue(spec["runs-on"].startswith("${{ " + late)
                                or spec["runs-on"].startswith(owner + late)
                                or spec["runs-on"].startswith(owner + fork_pr + late),
                                spec["runs-on"][:200])
                # The job-level if never requires late-placement, so a skipped or failed one
                # leaves the consumer running where the picker put it.
                self.assertNotIn("late-placement", spec["if"])
                requested = [step["env"]["REQUESTED_RUNNER"] for step in spec["steps"]
                             if "REQUESTED_RUNNER" in (step.get("env") or {})]
                self.assertEqual(requested, [spec["runs-on"]])

    def test_late_placement_runs_only_where_the_picker_may_use_owned_runners(self):
        spec = self.jobs["late-placement"]
        for clause in ("github.run_attempt == 1", "vars.CI_PR_POOL_OWNED == '1'",
                       "github.event.pull_request.head.repo.full_name == github.repository",
                       "needs.macos-compile-admission.result == 'success'"):
            self.assertIn(clause, spec["if"])
        self.assertTrue(all(step.get("continue-on-error") for step in spec["steps"]))
        # Jobs move only once both markers the rescue watch reads uploaded.
        # A move to Blacksmith alone (the gui overflow) needs neither.
        self.assertEqual(spec["outputs"]["runners"],
                         "${{ (steps.place.outputs.onto_owned == 'false' || steps.late-marker.outcome == 'success'"
                         " && steps.late-watch-marker.outcome == 'success') && steps.place.outputs.runners || '{}' }}")
        steps = {step.get("id"): step for step in spec["steps"]}
        for marker in ("late-marker", "late-watch-marker"):
            self.assertEqual(steps[marker]["with"]["if-no-files-found"], "error", marker)

    def test_late_placement_runs_after_an_owned_admission_to_overflow_the_gui_jobs(self):
        spec = self.jobs["late-placement"]
        self.assertNotIn("startsWith(needs.macos-compile-admission.outputs.runner, 'glaeda-')", spec["if"])
        steps = {step.get("id"): step for step in spec["steps"]}
        self.assertEqual(steps["place"]["env"]["RETRY_RUNNER"], "${{ inputs.pr_retry_runner }}")
        self.assertEqual(steps["place"]["env"]["POOL_QUEUE_ROUNDS"], "${{ vars.CI_PR_POOL_QUEUE_ROUNDS }}")
        for mint in ("route-token", "route-token-repo"):
            self.assertEqual(steps[mint]["with"]["permission-actions"], "read", mint)

    def test_moved_jobs_leave_the_marker_the_rescue_watch_looks_for(self):
        steps = {step["name"]: step for step in self.jobs["late-placement"]["steps"]}
        marker = steps["Upload the late placement marker"]
        self.assertIn("steps.place.outputs.runners != '{}'", marker["if"])
        rescue = (ROOT / "scripts/ci/owned_pool_rescue.py").read_text()
        # owned_pool_rescue.late_marker_name() and LATE_JOB: the names the watch reads.
        self.assertIn('LATE_MARKER_PREFIX = "macos-pool-late"', rescue)
        self.assertEqual(marker["with"]["name"], "macos-pool-late-${{ github.run_id }}-${{ github.run_attempt }}")
        self.assertIn('LATE_JOB = "macos / late-placement"', rescue)
        # It starts nothing itself: the rescue sweeper finds the run by its marker.
        self.assertEqual(self.jobs["late-placement"]["permissions"], {"contents": "read"})


if __name__ == "__main__":
    unittest.main(buffer=True)
