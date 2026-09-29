#!/usr/bin/env python3
"""Late placement: the job after compile admission moves onto an idle owned runner."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/late_placement.py"
WORKFLOW = ROOT / ".github/workflows/ci-macos.yml"
XCODE = "/Applications/Xcode_26.6.app"
ROOT_STD = "glaeda-root-std-xcode-26.6"
FULL = {"MACOS": "true", "CLI": "false", "FULL_SUITE": "true", "ADMISSION_XCODE_APP": XCODE,
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
    def test_a_full_suite_off_blacksmith_takes_an_idle_root(self):
        placed, why = late.decide(FULL, roots(idle=3, busy=5))
        self.assertEqual(placed, {"cli-product": ROOT_STD})
        self.assertIn("3 idle", why)

    def test_a_cli_only_run_moves_cli_product(self):
        env = dict(FULL, MACOS="false", CLI="true", FULL_SUITE="false")
        self.assertEqual(late.decide(env, roots(idle=1))[0], {"cli-product": ROOT_STD})

    def test_a_job_the_picker_already_owned_stays_put(self):
        env = dict(FULL, OWNED_JOBS=" admission cli-product ")
        placed, why = late.decide(env, roots(idle=2))
        self.assertEqual(placed, {})
        self.assertIn("nothing to move", why)

    def test_the_gui_token_job_takes_an_idle_gui_runner(self):
        gui = "glaeda-gui-std-xcode-26.6"
        runners = [*roots(idle=3), *(runner(f"gui-{i}", "self-hosted", gui) for i in range(2)),
                   runner("gui-busy", gui, busy=True)]
        slots = '{"std": 40, "root-std": 19, "gui-std": 10}'
        # Admission ran on Blacksmith (the picker named no gui runner): the slots still route it.
        placed, why = late.decide(dict(FULL, OWNED_SLOTS=slots), runners)
        # cli-product-tests holds the gui token, so it takes a gui runner, never the root label.
        self.assertEqual(placed, {"cli-product": gui})
        self.assertIn(f"2 idle `{gui}`", why)
        # No gui count yet: it takes the root label as before.
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS='{"std": 40, "root-std": 19}'), runners)[0],
                         {"cli-product": ROOT_STD})
        self.assertEqual(late.decide(FULL, runners)[0], {"cli-product": ROOT_STD})
        # No idle gui runner: it stays where the picker put it.
        self.assertEqual(late.decide(dict(FULL, OWNED_SLOTS=slots), roots(idle=3))[0], {})

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

    def test_a_compile_only_run_has_nothing_after_admission(self):
        env = dict(FULL, FULL_SUITE="false")
        self.assertEqual(late.decide(env, roots(idle=4))[0], {})


GUI = "glaeda-gui-std-xcode-26.6"
SLOTS = '{"std": 40, "root-std": 19, "gui-std": 10}'
RETRY = "blacksmith-12vcpu-macos-26"
# An owned full suite: the picker gave admission and cli-product the minis.
OWNED = dict(FULL, OWNED_SLOTS=SLOTS, RETRY_RUNNER=RETRY, ADMISSION_RUNNER="glaeda-root-std-xcode-26.6",
             OWNED_JOBS=" admission cli-product ")


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

    def test_a_full_gui_pool_sends_the_job_past_one_round_to_blacksmith(self):
        count, calls = self.backlog(queued=12)
        placed, why = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        # Ten online gui runners and twelve jobs queued ahead: past a round, and 12vcpu is idle.
        self.assertEqual(placed, {"cli-product": RETRY})
        self.assertEqual(calls, [[GUI, RETRY]])
        self.assertIn(f"12 gui job(s) queued ahead on 10 online and 0 on `{RETRY}`", why)

    def test_a_backlog_within_a_round_keeps_the_job_on_the_minis(self):
        count, _ = self.backlog(queued=6)
        self.assertEqual(late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)[0], {})

    def test_a_longer_blacksmith_queue_keeps_the_owned_job_on_the_minis(self):
        # Twelve gui jobs ahead on ten gui runners is 1.3 rounds; fifty on 12vcpu's five machines is ten.
        count, _ = self.backlog(queued=12, retry_queued=50)
        placed, why = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], count)
        self.assertEqual(placed, {})
        self.assertIn(f"and 50 on `{RETRY}`", why)

    def test_no_gui_runner_online_moves_the_owned_job_without_a_read(self):
        count, calls = self.backlog(queued=0, retry_queued=99)
        placed, _ = late.decide(OWNED, roots(idle=2), count)
        self.assertEqual(placed, {"cli-product": RETRY})
        self.assertEqual(calls, [])

    def test_an_idle_gui_runner_looks_up_nothing_and_moves_nothing(self):
        count, calls = self.backlog(queued=99)
        self.assertEqual(late.decide(OWNED, [*roots(idle=2), *guis(idle=1, busy=9)], count)[0], {})
        self.assertEqual(calls, [])

    def test_an_unreadable_backlog_moves_nothing(self):
        def broken(labels):
            raise RuntimeError("HTTP 403")
        placed, _ = late.decide(OWNED, [*roots(idle=2), *guis(idle=0, busy=10)], broken)
        self.assertEqual(placed, {})

    def test_the_kill_switch_with_nothing_idle_moves_the_owned_job_without_a_read(self):
        count, calls = self.backlog(queued=0)
        placed, _ = late.decide(dict(OWNED, POOL_QUEUE_ROUNDS="0"), [*roots(idle=2), *guis(idle=0, busy=10)], count)
        self.assertEqual(placed, {"cli-product": RETRY})
        self.assertEqual(calls, [])

    def test_no_blacksmith_retry_pool_keeps_the_job(self):
        count, _ = self.backlog(queued=40)
        for retry in ("", "glaeda-std-xcode-26.6"):
            with self.subTest(retry=retry):
                env = dict(OWNED, RETRY_RUNNER=retry)
                self.assertEqual(late.decide(env, [*roots(idle=2), *guis(idle=0, busy=10)], count)[0], {})

    def test_no_gui_label_moves_no_owned_job(self):
        count, _ = self.backlog(queued=40)
        busy = [*roots(idle=0, busy=16), *guis(idle=0, busy=10)]
        self.assertEqual(late.decide(dict(OWNED, OWNED_SLOTS='{"std": 40, "root-std": 19}'), busy, count)[0], {})

    def test_an_unowned_job_takes_only_an_idle_gui_runner(self):
        count, _ = self.backlog(queued=0)
        env = dict(OWNED, OWNED_JOBS=" admission ")
        self.assertEqual(late.decide(env, [*roots(idle=0, busy=16), *guis(idle=1, busy=9)], count)[0],
                         {"cli-product": GUI})
        self.assertEqual(late.decide(env, [*roots(idle=0, busy=16), *guis(idle=0, busy=10)], count)[0], {})

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
        self.assertEqual(api.statuses, [("ci.yml", "queued"), ("ci.yml", "in_progress")])

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
                return runs if filters["status"] == "in_progress" else []

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
                return runs if filters["status"] == "in_progress" else []

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
                        for i in range(1, 4)] if filters["status"] == "in_progress" else []

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
        self.assertIn(f'"cli-product": "{RETRY}"', text)
        self.assertTrue(text.endswith("onto_owned=false\n"), text)


class Workflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]

    def test_the_consumers_wait_for_late_placement_and_read_it_first_on_attempt_one(self):
        keys = {"cli-product-tests": "'cli-product'"}
        prefix = "${{ github.run_attempt == 1 && fromJSON(needs.late-placement.outputs.runners || '{}')[%s] || "
        for job, key in keys.items():
            with self.subTest(job=job):
                spec = self.jobs[job]
                self.assertIn("late-placement", spec["needs"])
                late = (prefix % key).removeprefix("${{ ")
                owner = "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                # A consumer may keep the fork-owner branch and then the fork
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
