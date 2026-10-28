#!/usr/bin/env python3
"""Side-lane placement: trusted jobs use a live side label or the std pool.

Side-lane workflows have no picker. Their macOS jobs use the live side label
when it exists, and fall back to the owned std pool label when no online runner
carries the side label. A busy side label remains queued for the rescue budget.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/side_lane_placement.py"
WORKFLOWS = ROOT / ".github/workflows"
SIDE = "glaeda-side-std-xcode-26.6"
STD = "glaeda-std-xcode-26.6"
FALLBACK = "blacksmith-6vcpu-macos-26"
NIGHTLY_POOL = "glaeda-trusted-light-xcode-26.6"
NIGHTLY_RUNNER = "glaeda-runner-cmux22-nightly-next"
# The GUI suites take the owned pool's gui label, never the generic side label.
GUI = "glaeda-gui-std-xcode-26.6"
GUI_JOBS = ("swift-test", "daemon-test", "generated-files")
# glaeda#1530: jobs that need a logged-in session but not the console gui token. They take the
# session label while an online runner carries it, else the gui label exactly as before.
SESSION = "glaeda-session-std-xcode-26.6"
SESSION_JOBS = ("daemon-test", "generated-files")


def on(name: str, label: str) -> str:
    """The label a job takes where the compile jobs take an owned side or std label."""
    return GUI if name in GUI_JOBS and label in (SIDE, STD) else label
JOBS = ("cmux-scheme-compile", "release-compile", "swift-test", "daemon-test", "generated-files", "swift-canary")
# The fast tier reads the placement runner too, but runs only on feat-cmux-next PRs and pushes
# and has its own fast-lane route, so the side-lane runs-on cases below cover JOBS only.
PLACED_JOBS = (*JOBS, "fast-tier")
# The jobs whose bot overflow (attempt 2+) reads the placement's free retry label. With no free
# Blacksmith slot (an empty label) they take the owned side label: waiting behind the fleet is
# acceptable, a Blacksmith queue is not (2026-10-20: 5+ hour waits on 12 vCPU). The GUI jobs keep
# the Blacksmith fallback; the fleet's gui label is what they overflow from.
RETRY_JOBS = ("cmux-scheme-compile", "release-compile", "swift-canary")


def overflow(name: str, placed: bool = True) -> str:
    """The label a bot attempt 2+ takes with no free Blacksmith slot.

    A GUI job whose placement ran keeps the 6 vCPU escape from its gui label (it also covers a gui
    label with no online runner); with no placement result it waits on the fleet's gui label, never
    vars.MACOS_RUNNER_26 (12 vCPU, 5+ hour waits on 2026-10-20).
    """
    if name in RETRY_JOBS:
        return SIDE
    return FALLBACK if placed else GUI

sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402


def load():
    spec = importlib.util.spec_from_file_location("side_lane_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["side_lane_placement"] = module
    spec.loader.exec_module(module)
    return module


placement = load() if SCRIPT.exists() else None


def runner(name: str, *, busy: bool = False, status: str = "online", labels=(STD, SIDE)) -> dict:
    return {"name": name, "status": status, "busy": busy,
            "labels": [{"name": label} for label in ("self-hosted", *labels)]}


def env(**overrides: str) -> dict:
    return {"SIDE_LABEL": SIDE, "JOBS": " ".join(JOBS), "GITHUB_RUN_ATTEMPT": "1", **overrides}


# The rescue's re-runs come from GITHUB_TOKEN's actor or the cmux-bot App (pr_runner_pool.RESCUE_ACTORS).
RESCUE_BOTS = ("github-actions[bot]", "cmux-bot[bot]")


def placed_in(attempt: str, actor: str) -> str:
    """The attempt macos-placement last ran in: it runs on attempt 1 and on the rescue's attempt 2
    (RESCUE_BOTS); any other attempt carries an earlier attempt's job, outputs and all."""
    return attempt if attempt == "1" or attempt == "2" and actor in RESCUE_BOTS else "1"


class Decide(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(placement, "scripts/ci/side_lane_placement.py is missing")

    def test_a_busy_pool_stays_on_the_owned_label(self):
        # No idle owned runner: every job remains queued for the long rescue budget.
        busy = [runner("mini-a-glaeda-3", busy=True), runner("mini-b-glaeda-3", busy=True),
                runner("mini-c-glaeda-3", status="offline")]
        owned, fallback, why = placement.decide(env(), busy)
        self.assertEqual((owned, fallback), ((), ()))
        self.assertIn("no idle", why)

    def test_an_idle_owned_runner_takes_a_job(self):
        runners = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3", busy=True)]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], ()))
        idle = [runner(f"mini-{host}-glaeda-3") for host in "abcd"]
        self.assertEqual(placement.decide(env(), idle)[:2], (JOBS[:4], ()))

    def test_only_runners_carrying_the_side_label_count(self):
        # A root runner of the same mini (std label, no side label) is not a side runner.
        runners = [runner("mini-a-glaeda", labels=(STD, "glaeda-root-std-xcode-26.6")), runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], ()))

    def test_route_falls_back_to_the_owned_pool_when_side_label_is_absent(self):
        runners = [runner("mini-a-glaeda", labels=(STD,)),
                   runner("mini-b-glaeda", labels=(STD,), busy=True)]
        self.assertEqual(placement.route_label(SIDE, runners), STD)

    def test_route_keeps_side_label_when_any_online_runner_carries_it(self):
        self.assertEqual(placement.route_label(SIDE, [runner("mini-a-glaeda")]), SIDE)

    def test_gui_route_requires_an_online_runner_with_the_gui_label(self):
        self.assertEqual(placement.gui_route_label(SIDE, []), "")
        self.assertEqual(placement.gui_route_label(SIDE, None), "")
        self.assertEqual(placement.gui_route_label(SIDE, [runner("mini-a-glaeda")]), "")
        self.assertEqual(
            placement.gui_route_label(SIDE, [runner("mini-a-glaeda", labels=(STD, SIDE, GUI))]),
            GUI,
        )

    def test_a_light_side_lane_borrows_the_std_gui_runners(self):
        # The light minis run no GUI runner, so a light side lane's GUI suites take the std minis'
        # live GUI label instead of the Blacksmith fallback; a live light GUI label still wins.
        light_side, light_gui = "glaeda-side-light-xcode-26.6", "glaeda-gui-light-xcode-26.6"
        light = runner("light-a-glaeda-1", labels=("glaeda-light-xcode-26.6", light_side))
        std_gui = runner("mini-a-glaeda-4", labels=(STD, GUI))
        self.assertEqual(placement.gui_route_label(light_side, [light, std_gui]), GUI)
        self.assertEqual(placement.gui_route_label(light_side, [light]), "")
        self.assertEqual(placement.gui_route_label(light_side, [light, runner("mini-a-glaeda-4", labels=(STD, GUI),
                                                                              status="offline")]), "")
        live_light = runner("light-b-glaeda-4", labels=("glaeda-light-xcode-26.6", light_gui))
        self.assertEqual(placement.gui_route_label(light_side, [light, live_light, std_gui]), light_gui)

    def test_session_route_requires_an_online_runner_with_the_session_label(self):
        gui = runner("mini-a-glaeda-4", labels=(STD, GUI, SESSION))
        gui_only = runner("mini-a-glaeda-4", labels=(STD, GUI))
        session = runner("mini-b-glaeda-5", labels=(SESSION,))
        self.assertEqual(placement.session_route_label(SIDE, None), "")
        self.assertEqual(placement.session_route_label(SIDE, []), "")
        self.assertEqual(placement.session_route_label(SIDE, [runner("mini-a-glaeda")]), "")
        # Before the fleet rollout no runner carries the session label: the gui route, as today.
        self.assertEqual(placement.session_route_label(SIDE, [gui_only]), GUI)
        self.assertEqual(placement.session_route_label(
            SIDE, [gui_only, runner("mini-b-glaeda-5", labels=(SESSION,), status="offline")]), GUI)
        # Once one online runner carries it, the session jobs take it.
        self.assertEqual(placement.session_route_label(SIDE, [gui]), SESSION)
        self.assertEqual(placement.session_route_label(SIDE, [gui_only, session]), SESSION)
        # A session runner can run them while the console gui runner is offline.
        self.assertEqual(placement.session_route_label(SIDE, [session]), SESSION)
        # Light side lanes borrow the std minis' session runners, as they do the gui runners.
        light_side = "glaeda-side-light-xcode-26.6"
        light = runner("light-a-glaeda-1", labels=("glaeda-light-xcode-26.6", light_side))
        self.assertEqual(placement.session_route_label(light_side, [light, gui]), SESSION)
        self.assertEqual(placement.session_route_label(light_side, [light, gui_only]), GUI)
        # Not an owned side label, or an AWS one: no session route.
        for label in ("", FALLBACK, STD, "glaeda-aws-side-std-xcode-26.6"):
            self.assertEqual(placement.session_route_label(label, [gui, session]), "", label)

    def test_free_gui_and_session_routes_skip_busy_owned_runners(self):
        busy = runner("mini-a-glaeda-4", busy=True, labels=(STD, GUI, SESSION))
        idle = runner("mini-b-glaeda-4", labels=(STD, GUI, SESSION))
        self.assertEqual(placement.free_gui_route_label(SIDE, [busy]), "")
        self.assertEqual(placement.free_session_route_label(SIDE, [busy]), "")
        self.assertEqual(placement.free_gui_route_label(SIDE, [busy, idle]), GUI)
        self.assertEqual(placement.free_session_route_label(SIDE, [busy, idle]), SESSION)

    def test_attempt_2_and_later_are_unchanged(self):
        # Attempt 2+ keeps its own route (the workflow's expression sends it to the fallback): no decision.
        idle = [runner(f"mini-{host}-glaeda-3") for host in "abc"]
        for attempt in ("2", "3"):
            self.assertEqual(placement.decide(env(GITHUB_RUN_ATTEMPT=attempt), idle)[:2], ((), ()))

    def test_uncertainty_keeps_todays_route(self):
        # Unreadable runners, or a route that is not an owned side label (a fork, owned pools off), decide
        # nothing: the jobs keep attempt 1's owned label and the rescue watches them, as before.
        idle = [runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), None)[:2], ((), ()))
        for label in ("", FALLBACK, "macos-26", STD, "glaeda-root-std-xcode-26.6"):
            self.assertEqual(placement.decide(env(SIDE_LABEL=label), idle)[:2], ((), ()), label)

    def test_dedicated_nightly_runner_requires_online_idle_exact_labels(self):
        dedicated = runner("cmux22", labels=(NIGHTLY_POOL, NIGHTLY_RUNNER, "glaeda-trusted-next-nightly"))
        route = {"NIGHTLY_POOL": NIGHTLY_POOL, "NIGHTLY_RUNNER": NIGHTLY_RUNNER}
        self.assertTrue(placement.nightly_runner_ready(route, [dedicated]))
        self.assertFalse(placement.nightly_runner_ready(route, [{**dedicated, "busy": True}]))
        self.assertFalse(placement.nightly_runner_ready(
            route, [runner("cmux22", labels=(NIGHTLY_POOL, "other-runner"))]))

    def test_it_reuses_the_main_pickers_idle_placement(self):
        # One rule for both callers: pr_runner_pool.idle_placement().
        runners = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3")]
        self.assertEqual(placement.pool.idle_placement(runners, SIDE, JOBS), JOBS[:2])
        with mock.patch.object(placement.pool, "idle_placement", return_value=()) as shared:
            self.assertEqual(placement.decide(env(), runners)[:2], ((), ()))
        shared.assert_called_once()

    def test_a_refused_runner_read_retries_with_cmux_bot(self):
        # 2026-10-26 22:47Z: the routing App's runner read returned 403; cmux-bot reads again.
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            output = Path(tmp) / "out"
            refused, bot = mock.Mock(), mock.Mock()
            refused.runners.side_effect = OSError("HTTP Error 403: Forbidden")
            bot.runners.return_value = [runner("mini-a-glaeda-3")]
            clients = {"t": refused, "bot": bot}
            with mock.patch.object(placement.pool, "GitHub", side_effect=lambda token, repo, **_: clients[token]):
                placement.main(env(ROUTE_TOKEN="t", ROUTE_TOKEN_FALLBACK="bot", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                   GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(lines["owned_jobs"], " cmux-scheme-compile ")
            bot.runners.assert_called_once_with()

    def test_main_writes_the_outputs(self):
        # The script's ::warning:: lines stay out of the guard job's log.
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.runners.return_value = [runner("mini-a-glaeda-3")]
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(lines["owned_jobs"], " cmux-scheme-compile ")
            self.assertEqual(lines["fallback_jobs"], "")
            self.assertEqual(lines["runner"], SIDE)
            self.assertEqual(lines["gui_runner"], "")
            self.assertEqual(lines["session_runner"], "")
            self.assertEqual(lines["watch"], "true")
            # Every job on the fallback: no owned job for the rescue to watch.
            output.write_text("")
            fake.runners.return_value = []
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["owned_jobs"], lines["fallback_jobs"], lines["runner"], lines["watch"]),
                             ("", "", STD, "true"))
            # Unreadable: no decision, today's route, watched.
            output.write_text("")
            fake.runners.side_effect = RuntimeError("HTTP 403")
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["fallback_jobs"], lines["runner"], lines["watch"]), ("", "", "true"))
            self.assertEqual((lines["gui_runner"], lines["session_runner"]), ("", ""))
            # A live gui runner without the session label: session_runner is the gui label.
            output.write_text("")
            fake.runners.side_effect = None
            fake.runners.return_value = [runner("mini-a-glaeda-4", labels=(STD, SIDE, GUI))]
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["gui_runner"], lines["session_runner"]), (GUI, GUI))
            output.write_text("")
            fake.runners.return_value = [runner("mini-a-glaeda-4", labels=(STD, SIDE, GUI, SESSION))]
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["gui_runner"], lines["session_runner"]), (GUI, SESSION))
            self.assertEqual((lines["free_gui_runner"], lines["free_session_runner"]), (GUI, SESSION))


LIGHT_SIDE = "glaeda-side-light-xcode-26.6"
LIGHT = "glaeda-light-xcode-26.6"
# The fleet dashboard at 2026-10-20 22:22Z: 133 jobs queued on the light side label's 3 online (all
# busy) runners, while 51 of the std side label's 60 online runners sat idle.
SNAPSHOT = ROOT / "tests/fixtures/side-lane-placement/fleet-2026-10-20T2222Z.json"


FAST = "glaeda-fast-light-xcode-26.6"


class NightlyRunnerStaysOffTheRoutes(unittest.TestCase):
    """The workflow takes the placement's runner outputs as they are (cmux-next.yml's release-compile and the
    other Mac jobs), so no output names the dedicated nightly-next runner or its pool, whether that runner is
    idle, busy or the only one online (test_ci_next_macos_cascade's guard on release-compile's runs-on)."""

    ROUTES = ("runner", "gui_runner", "session_runner", "free_gui_runner", "free_session_runner", "fast_runner",
              "gateway_runner", "retry_runner", "free_retry_runner")

    def place_step(self) -> tuple[dict, dict]:
        workflow = yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text())
        step = next(step for step in workflow["jobs"]["macos-placement"]["steps"] if step.get("id") == "place")
        return workflow, step

    def place_step_env(self, workflow: dict, step: dict, side: str, attempt: str, token: str) -> dict:
        """The step's `env:` as the workflow evaluates it on a feat push, from repository variables shaped like
        the real ones, so a workflow edit to SIDE_LABEL, NIGHTLY_POOL or any input reaches the guard."""
        context = github_context("push", ref="refs/heads/feat-cmux-next", CI_PR_POOL_OWNED="1", CI_SIDE_LANE_RUNNER=side,
                                 MACOS_RUNNER_26="blacksmith-12vcpu-macos-26", CI_NIGHTLY_NEXT_TRUSTED_POOL=NIGHTLY_POOL,
                                 CI_NIGHTLY_NEXT_TRUSTED_RUNNER=NIGHTLY_RUNNER,
                                 CI_NEXT_PROMOTE_POOL="glaeda-promote-side-trusted-std-xcode-26.6",
                                 CI_FAST_LANE_RUNNER="glaeda-fast-light-xcode-26.6",
                                 CI_COMPILE_CHECK_GATEWAY="glaeda-side-light-xcode-26.6")
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, event={}, token="g")
        context["inputs"] = {}
        context["needs"] = {"path_route": {"outputs": {"native": "true", "swift_canary": "true", "scheme": "true"}}}
        context["steps"] = {"route-token": {"outputs": {"token": token}},
                            "snapshot-read-token": {"outputs": {"token": token}}}
        context["env"] = dict(context["env"], **{key: evaluate(value, context) if "${{" in str(value) else value
                                                 for key, value in workflow["env"].items()})
        values = {key: evaluate(value, context) if "${{" in str(value) else value for key, value in step["env"].items()}
        values = {key: "" if value is None else str(value) for key, value in values.items()}
        self.assertEqual(values["SIDE_LABEL"], context["env"]["CMUX_NEXT_SIDE_ROUTE"])
        return values

    def test_no_route_output_names_the_nightly_runner(self):
        workflow, step = self.place_step()
        # The step's `run:` with the script call stubbed: the shell after it can still add routes.
        call = "python3 scripts/ci/side_lane_placement.py\n"
        self.assertEqual(step["run"].count(call), 1)
        shell = step["run"].replace(call, ":\n")
        dedicated = runner("cmux22", labels=(NIGHTLY_POOL, NIGHTLY_RUNNER, "glaeda-trusted-next-nightly"))
        fleets = {"idle nightly and side": [dedicated, runner("mini-a-glaeda-3")],
                  "only the nightly runner online": [dedicated, runner("mini-a-glaeda-3", status="offline")],
                  "nightly runner busy": [{**dedicated, "busy": True}, runner("mini-a-glaeda-3", busy=True)],
                  # Fail-open states: no runner listed, the listing refused, no routing token.
                  "empty fleet": [], "unreadable fleet": RuntimeError("HTTP 403"), "no token": None}
        ready_with = {"idle nightly and side", "only the nightly runner online"}
        for why, runners in fleets.items():
            for side in (SIDE, "glaeda-side-light-xcode-26.6"):
                for attempt in ("1", "2"):
                    with self.subTest(why=why, side=side, attempt=attempt), tempfile.TemporaryDirectory() as tmp:
                        output = Path(tmp) / "out"
                        values = self.place_step_env(workflow, step, side, attempt, "" if runners is None else "t")
                        values.update(GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY="manaflow-ai/cmux",
                                      GITHUB_RUN_ATTEMPT=attempt)
                        free = {placement.cascade.LARGE: 0, placement.cascade.SMALL: 0}
                        with mock.patch.object(placement.pool, "GitHub") as github, \
                                mock.patch.object(placement.cascade, "read", return_value=(free, dict(free), None)), \
                                contextlib.redirect_stdout(io.StringIO()):
                            if isinstance(runners, Exception):
                                github.return_value.runners.side_effect = runners
                            else:
                                github.return_value.runners.return_value = runners
                            placement.main(values)
                        # Then the rest of the step, as the runner runs it; a later line wins, as in GITHUB_OUTPUT.
                        subprocess.run(["bash", "-e", "-c", shell], check=True,
                                       env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **values})
                        lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
                        for key in self.ROUTES:
                            value = lines.get(key, "")
                            self.assertNotIn(NIGHTLY_POOL, value, key)
                            self.assertNotIn(NIGHTLY_RUNNER, value, key)
                            self.assertNotIn("nightly", value, key)
                        # The step only knows the nightly runner on attempt 1 (NIGHTLY_POOL, NIGHTLY_RUNNER).
                        ready = attempt == "1" and why in ready_with
                        self.assertEqual(lines.get("nightly_runner_ready", ""), "true" if ready else "")


class FastRoute(unittest.TestCase):
    """The fast tier takes its reserved label only while a runner carrying it is idle (2026-10-25:
    15 runs' fast tiers queued an hour behind the two runners left on the light fast label)."""

    def test_an_idle_fast_runner_takes_the_fast_tier(self):
        runners = [runner("mini-a-glaeda-3", labels=(FAST,)), runner("mini-b-glaeda-3", busy=True, labels=(FAST,))]
        self.assertEqual(placement.fast_route({"FAST_LABEL": FAST}, runners), FAST)

    def test_a_busy_offline_or_unread_fast_pool_routes_nothing(self):
        busy = [runner("mini-a-glaeda-3", busy=True, labels=(FAST,)),
                runner("mini-b-glaeda-3", status="offline", labels=(FAST,))]
        self.assertEqual(placement.fast_route({"FAST_LABEL": FAST}, busy), "")
        self.assertEqual(placement.fast_route({"FAST_LABEL": FAST}, []), "")
        self.assertEqual(placement.fast_route({"FAST_LABEL": FAST}, None), "")
        self.assertEqual(placement.fast_route({}, [runner("mini-a-glaeda-3", labels=(FAST,))]), "")

    def test_the_fast_tier_leaves_jobs_and_the_cascade_only_when_routed(self):
        trimmed = placement.without_fast({"JOBS": "fast-tier swift-canary", "CASCADE_RUNS": " fast-tier swift-canary  "})
        self.assertEqual(trimmed["JOBS"], "swift-canary")
        self.assertEqual(trimmed["CASCADE_RUNS"], " swift-canary ")
        self.assertEqual(placement.without_fast({"CASCADE_RUNS": " fast-tier "})["CASCADE_RUNS"], "")

    def test_main_writes_fast_runner(self):
        idle = [runner("mini-a-glaeda-3", labels=(FAST,)), runner("mini-b-glaeda-1", busy=True)]
        for runners, expected in ((idle, FAST), (idle[1:], "")):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                values = env(JOBS="fast-tier " + " ".join(JOBS), FAST_LABEL=FAST, CASCADE_RUNS=" fast-tier ",
                             GITHUB_OUTPUT=str(output), ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux")
                with mock.patch.object(placement.pool, "GitHub") as github, \
                        mock.patch.object(placement.cascade, "read", return_value=(None, None, None)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    github.return_value.runners.return_value = runners
                    placement.main(values)
                self.assertIn(f"fast_runner={expected}\n", output.read_text())


FRESH = "glaeda-dev-std-xcode-26.6"


class FreshRoute(unittest.TestCase):
    """A feed's compile takes the freshness slot (one extra runner per owned std mini) while it is idle, then
    the side route and the cascade (2026-10-26: no DEV publish from 21:01Z, every DEV Release compile queued
    behind PR compiles on the 22 busy side runners)."""

    def test_idle_fresh_runners_take_the_feeds_compiles_only(self):
        idle = [runner("mini-a-glaeda-12", labels=(FRESH,)), runner("mini-b-glaeda-12", busy=True, labels=(FRESH,))]
        values = {"FRESH_LABEL": FRESH, "FRESH_JOBS": "cmux-scheme-compile", "FRESH_SLOT_JOBS": "cmux-scheme-compile",
                  "JOBS": " ".join(JOBS)}
        self.assertEqual(placement.fresh_route(values, idle), (FRESH, ("cmux-scheme-compile",)))
        # A feed's compile the slot's hook does not admit (a push's Release compile) never takes it.
        self.assertEqual(placement.fresh_route({**values, "FRESH_JOBS": "release-compile"}, idle), ("", ()))
        self.assertEqual(placement.fresh_route({**values, "FRESH_SLOT_JOBS": ""}, idle), ("", ()))
        # No FRESH_JOBS (a PR run), a job this run does not have, or no label: nothing takes the slot.
        self.assertEqual(placement.fresh_route({**values, "FRESH_JOBS": ""}, idle), ("", ()))
        self.assertEqual(placement.fresh_route({**values, "FRESH_JOBS": "not-a-job"}, idle), ("", ()))
        self.assertEqual(placement.fresh_route({**values, "FRESH_LABEL": ""}, idle), ("", ()))

    def test_a_busy_offline_or_unread_slot_routes_nothing(self):
        values = {"FRESH_LABEL": FRESH, "FRESH_JOBS": "cmux-scheme-compile", "FRESH_SLOT_JOBS": "cmux-scheme-compile",
                  "JOBS": " ".join(JOBS)}
        busy = [runner("mini-a-glaeda-12", busy=True, labels=(FRESH,)),
                runner("mini-b-glaeda-12", status="offline", labels=(FRESH,))]
        for runners in (busy, [], None, [runner("mini-c-glaeda-1")]):
            with self.subTest(runners=runners):
                self.assertEqual(placement.fresh_route(values, runners), ("", ()))

    def test_the_summary_names_why_the_slot_took_nothing(self):
        runners = [runner("mini-a-glaeda-2", busy=True, labels=(FRESH,)),
                   runner("mini-b-glaeda-2", status="offline", labels=(FRESH,)),
                   runner("mini-c-glaeda-2", status="offline", labels=(FRESH,)), runner("mini-d-glaeda-1")]
        self.assertEqual(placement.fresh_slot_state(FRESH, runners),
                         "busy: mini-a-glaeda-2; offline: mini-b-glaeda-2, mini-c-glaeda-2")
        self.assertEqual(placement.fresh_slot_state(FRESH, runners[1:]), "offline: mini-b-glaeda-2, mini-c-glaeda-2")
        self.assertEqual(placement.fresh_slot_state(FRESH, runners[3:]), "no runner carries it")
        self.assertEqual(placement.fresh_slot_state(FRESH, None), "runners unread")

    def test_routed_jobs_leave_the_side_route_and_the_cascade(self):
        trimmed = placement.without_jobs({"JOBS": "fast-tier release-compile", "CASCADE_RUNS": " release-compile ",
                                          "FIRST_JOBS": "release-compile", "FRESH_JOBS": "release-compile"},
                                         ("release-compile",))
        self.assertEqual(trimmed, {"JOBS": "fast-tier", "CASCADE_RUNS": "", "FIRST_JOBS": "", "FRESH_JOBS": ""})

    def test_main_writes_the_fresh_route(self):
        idle = [runner("mini-a-glaeda-12", labels=(FRESH,)), runner("mini-b-glaeda-1", busy=True)]
        for runners, label, jobs in ((idle, FRESH, " cmux-scheme-compile "), (idle[1:], "", "")):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                values = env(FRESH_LABEL=FRESH, FRESH_JOBS="cmux-scheme-compile", FRESH_SLOT_JOBS="cmux-scheme-compile",
                             CASCADE_RUNS=" cmux-scheme-compile ",
                             GITHUB_OUTPUT=str(output), ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux")
                with mock.patch.object(placement.pool, "GitHub") as github, \
                        mock.patch.object(placement.cascade, "read", return_value=(None, None, None)), \
                        mock.patch.object(placement.cascade, "place", wraps=placement.cascade.place) as place, \
                        contextlib.redirect_stdout(io.StringIO()):
                    github.return_value.runners.return_value = runners
                    placement.main(values)
                text = output.read_text()
                self.assertIn(f"fresh_runner={label}\n", text)
                self.assertIn(f"fresh_jobs={jobs}\n", text)
                # A routed compile is no longer the cascade's: it takes no Blacksmith slot as well.
                cascade_env = place.call_args.args[0]
                self.assertEqual("cmux-scheme-compile" in cascade_env["CASCADE_RUNS"].split(), not label)


class FreshSlotJobs(unittest.TestCase):
    """cmux-next.yml's FRESH_SLOT_JOBS names exactly the jobs the slot's glaeda hook admits
    (dev_compile_refusal, glaeda#1636): a job it refuses would fail in setup instead of falling back."""

    def test_the_workflow_routes_only_what_the_slot_admits(self):
        workflow = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next.yml"
        text = workflow.read_text()
        match = re.search(r"^\s*FRESH_SLOT_JOBS:\s*(.+)$", text, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(set(match.group(1).split()), {"cmux-scheme-compile", "release-compile"})
        # Every slot job reads the slot in its runs-on (a slot job that never reads it would still be dropped
        # from the cascade by fresh_route() and lose its Blacksmith overflow).
        for job in match.group(1).split():
            self.assertIn(f"contains(needs.macos-placement.outputs.fresh_jobs, ' {job} ')", text)

    def test_a_pushs_release_compile_takes_an_idle_slot(self):
        idle = [runner("mini-a-glaeda-2", labels=(FRESH,)), runner("mini-b-glaeda-2", labels=(FRESH,))]
        values = {"FRESH_LABEL": FRESH, "FRESH_JOBS": "release-compile",
                  "FRESH_SLOT_JOBS": "cmux-scheme-compile release-compile", "JOBS": " ".join(JOBS)}
        self.assertEqual(placement.fresh_route(values, idle), (FRESH, ("release-compile",)))
        busy = [runner("mini-a-glaeda-2", busy=True, labels=(FRESH,))]
        self.assertEqual(placement.fresh_route(values, busy), ("", ()), "busy: the side route and the cascade")


class GatewayRoute(unittest.TestCase):
    """The build-fleet compiles take vars.CI_COMPILE_CHECK_GATEWAY, or a wider class of it, only while a
    runner is idle there. At 06:00Z on 2026-10-26 the light side label had 5 jobs running and 44 queued,
    the oldest 58 minutes, and PR #24155's app compile (build fleet) queued there three times."""

    def light(self, *busy: bool) -> list[dict]:
        return [runner(f"light-{index}-glaeda-1", busy=flag, labels=(LIGHT, LIGHT_SIDE))
                for index, flag in enumerate(busy)]

    def std(self, *busy: bool) -> list[dict]:
        return [runner(f"mini-{index}-glaeda-3", busy=flag) for index, flag in enumerate(busy)]

    def test_an_idle_gateway_runner_takes_the_compiles(self):
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE}, self.light(True, False)), LIGHT_SIDE)

    def test_a_busy_light_gateway_spills_to_an_idle_std_side_runner(self):
        self.assertEqual(placement.compatible_labels(LIGHT_SIDE), (LIGHT_SIDE, SIDE))
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE},
                                                 self.light(True, True) + self.std(True, False)), SIDE)

    def test_no_idle_runner_anywhere_routes_nothing(self):
        busy = self.light(True, True) + self.std(True) + [runner("mini-x-glaeda-3", status="offline")]
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE}, busy), "")
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE}, []), "")

    def test_unread_runners_and_an_unset_variable_route_nothing(self):
        # Nobody saw a runner free, so the gateway jobs skip and their Mac fallbacks run.
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE}, None), "")
        self.assertEqual(placement.gateway_route({}, self.light(False)), "")

    def test_each_gateway_job_needs_its_own_idle_runner_beyond_the_runs_own_jobs(self):
        runners = self.light(False) + self.std(False, False)
        both = {"GATEWAY_LABEL": LIGHT_SIDE, "GATEWAY_JOBS": " app-compile-fleet swift-canary-fleet"}
        self.assertEqual(placement.gateway_route(both, runners), SIDE)
        self.assertEqual(placement.gateway_route(both, runners, {SIDE: 1}), "")
        self.assertEqual(placement.gateway_route({"GATEWAY_LABEL": LIGHT_SIDE}, runners, {LIGHT_SIDE: 1}), SIDE)

    def test_the_cascade_gains_the_mac_fallback_only_once(self):
        self.assertEqual(placement.with_gateway_cascade({"CASCADE_RUNS": " fast-tier ", "GATEWAY_CASCADE": "release-compile"})
                         ["CASCADE_RUNS"], " fast-tier release-compile ")
        self.assertEqual(placement.with_gateway_cascade({"CASCADE_RUNS": " release-compile ",
                                                         "GATEWAY_CASCADE": "release-compile"})["CASCADE_RUNS"],
                         " release-compile ")
        self.assertEqual(placement.with_gateway_cascade({"CASCADE_RUNS": ""}), {"CASCADE_RUNS": ""})

    def run_main(self, runners: list[dict], **overrides: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            values = env(SIDE_LABEL=LIGHT_SIDE, GITHUB_OUTPUT=str(output), ROUTE_TOKEN="t",
                         GITHUB_REPOSITORY="manaflow-ai/cmux", **overrides)
            free = {placement.cascade.LARGE: 0, placement.cascade.SMALL: 0}
            with mock.patch.object(placement.pool, "GitHub") as github, \
                    mock.patch.object(placement.cascade, "read", return_value=(free, dict(free), None)), \
                    contextlib.redirect_stdout(io.StringIO()):
                github.return_value.runners.return_value = runners
                placement.main(values)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_with_no_idle_gateway_the_compiles_skip_and_the_release_compile_takes_blacksmith(self):
        gateway = {"GATEWAY_LABEL": LIGHT_SIDE, "GATEWAY_JOBS": "app-compile-fleet", "GATEWAY_CASCADE": "release-compile",
                   "CASCADE_RUNS": " cmux-scheme-compile "}
        lines = self.run_main(self.light(True, True) + self.std(True, True), **gateway)
        self.assertEqual((lines["gateway_runner"], lines["gateway_attempt"]), ("", "1"))
        self.assertIn(" release-compile ", lines["blacksmith_12_jobs"])
        # The one idle std side runner is the run's scheme compile's, which races for it, not the gateway's.
        lines = self.run_main(self.light(True, True) + self.std(True, False), **gateway)
        self.assertEqual(lines["gateway_runner"], "")
        # A second idle runner takes the compile; the Mac fallback stays out of the cascade.
        lines = self.run_main(self.light(True, True) + self.std(True, False, False), **gateway)
        self.assertEqual((lines["gateway_runner"], lines["gateway_attempt"]), (SIDE, "1"))
        self.assertNotIn("release-compile", lines["blacksmith_12_jobs"])
        self.assertEqual(self.run_main(self.light(False), GITHUB_RUN_ATTEMPT="2", **gateway)["gateway_attempt"], "2")

    def test_only_the_side_jobs_that_run_count_against_the_gateway(self):
        runners = self.light(True) + self.std(False, False)
        values = env(SIDE_LABEL=LIGHT_SIDE, GATEWAY_JOBS="app-compile-fleet swift-canary-fleet",
                     CASCADE_RUNS=" swift-canary release-compile cmux-scheme-compile ")
        # GUI suites take another label; swift-canary and release-compile stand in for the gateway jobs.
        self.assertEqual(placement.gateway_taken(values, runners), {SIDE: 1})
        self.assertEqual(placement.gateway_taken({**values, "CASCADE_RUNS": " swift-canary "}, runners), {})
        self.assertEqual(placement.gateway_taken({**values, "CASCADE_RUNS": ""}, runners, FAST), {FAST: 1})

    def test_a_running_fleet_fast_check_keeps_its_mac_fallback_out_of_the_cascade(self):
        values = {"CASCADE_RUNS": " fast-tier release-compile ", "FIRST_JOBS": "release-compile"}
        trimmed = placement.without_cascade(values, "release-compile")
        self.assertEqual((trimmed["CASCADE_RUNS"], trimmed["FIRST_JOBS"]), (" fast-tier ", ""))
        push = {"GATEWAY_LABEL": LIGHT_SIDE, "GATEWAY_JOBS": "release-compile-fast",
                "CASCADE_RUNS": " release-compile ", "FIRST_JOBS": "release-compile"}
        free = {placement.cascade.LARGE: 0, placement.cascade.SMALL: 0}
        for runners, cascaded in ((self.light(False, False), False), (self.light(True, True), True)):
            with self.subTest(idle=not cascaded), tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                values = env(SIDE_LABEL=LIGHT_SIDE, GITHUB_OUTPUT=str(output), ROUTE_TOKEN="t",
                             GITHUB_REPOSITORY="manaflow-ai/cmux", **push)
                with mock.patch.object(placement.pool, "GitHub") as github, \
                        mock.patch.object(placement.cascade, "read", return_value=(free, dict(free), None)), \
                        contextlib.redirect_stdout(io.StringIO()):
                    github.return_value.runners.return_value = runners + self.std(True)
                    placement.main(values)
                lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual("release-compile" in lines["blacksmith_12_jobs"], cascaded)

    def test_without_the_variable_nothing_is_judged(self):
        lines = self.run_main(self.light(False))
        self.assertEqual((lines["gateway_runner"], lines["gateway_attempt"]), ("", ""))


class SpillToCompatiblePool(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(placement, "scripts/ci/side_lane_placement.py is missing")

    def test_the_starved_light_snapshot_spills_to_the_idle_std_side_runners(self):
        fleet = json.loads(SNAPSHOT.read_text())
        runners = fleet["runners"]
        self.assertEqual(fleet["pools"][LIGHT_SIDE]["queued"], 133)
        self.assertEqual(placement.route_label(LIGHT_SIDE, runners), SIDE)
        self.assertEqual(placement._online(LIGHT_SIDE, runners), 3)
        self.assertEqual(placement.pool.live_owned_free(runners, [LIGHT_SIDE, SIDE]), {LIGHT_SIDE: 0, SIDE: 51})
        owned, _, why = placement.decide(env(SIDE_LABEL=LIGHT_SIDE), runners)
        self.assertEqual(owned, JOBS)
        self.assertIn(SIDE, why)
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", return_value=fake), \
                    mock.patch.object(placement.cascade, "read", return_value=(None, None, None)):
                placement.main(env(SIDE_LABEL=LIGHT_SIDE, ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                   GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(lines["runner"], SIDE)

    def test_the_own_class_keeps_its_jobs_while_it_has_as_much_room(self):
        light = [runner(f"light-{host}-glaeda-1", labels=(LIGHT, LIGHT_SIDE)) for host in "ab"]
        std = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3", busy=True)]
        self.assertEqual(placement.route_label(LIGHT_SIDE, light + std), LIGHT_SIDE)
        # All busy everywhere: the larger online pool drains the queue faster.
        busy = [{**item, "busy": True} for item in light + std + [runner("mini-c-glaeda-3")]]
        self.assertEqual(placement.route_label(LIGHT_SIDE, busy), SIDE)
        # Light offline and std offline: the owned pool label, as before.
        self.assertEqual(placement.route_label(LIGHT_SIDE, [runner("light-a-glaeda", labels=(LIGHT,))]), LIGHT)

    def test_the_own_class_keeps_the_run_while_its_idle_runners_cover_every_job(self):
        light = [runner(f"light-{host}-glaeda-1", labels=(LIGHT, LIGHT_SIDE)) for host in "abc"]
        std = [runner(f"mini-{host}-glaeda-3") for host in "abcdefgh"]
        self.assertEqual(placement.side_route(LIGHT_SIDE, light + std, want=3), LIGHT_SIDE)
        self.assertEqual(placement.side_route(LIGHT_SIDE, light + std, want=4), SIDE)
        owned, _, why = placement.decide(env(SIDE_LABEL=LIGHT_SIDE, JOBS="a b c"), light + std)
        self.assertEqual(owned, ("a", "b", "c"))
        self.assertIn(LIGHT_SIDE, why)

    def test_a_std_job_never_takes_a_light_runner(self):
        light = [runner(f"light-{host}-glaeda-1", labels=(LIGHT, LIGHT_SIDE)) for host in "abcd"]
        std = [runner("mini-a-glaeda-3", busy=True)]
        self.assertEqual(placement.compatible_labels(SIDE), (SIDE,))
        self.assertEqual(placement.route_label(SIDE, light + std), SIDE)
        self.assertEqual(placement.decide(env(), light + std)[0], ())

    def test_compatibility_changes_only_the_class(self):
        # Role, trust and fleet namespace never mix: only the class token widens.
        cases = {
            LIGHT_SIDE: (LIGHT_SIDE, SIDE),
            "glaeda-aws-side-light-xcode-26.6": ("glaeda-aws-side-light-xcode-26.6", "glaeda-aws-side-std-xcode-26.6"),
            # Trusted and promote pools are not ordinary owned pools: they never widen.
            "glaeda-trusted-light-xcode-26.6": ("glaeda-trusted-light-xcode-26.6",),
            "glaeda-promote-side-trusted-std-xcode-26.6": ("glaeda-promote-side-trusted-std-xcode-26.6",),
            "glaeda-root-light-xcode-26.6": ("glaeda-root-light-xcode-26.6", "glaeda-root-std-xcode-26.6"),
            SIDE: (SIDE,),
            FALLBACK: (FALLBACK,),
            "": (),
        }
        for label, expected in cases.items():
            self.assertEqual(placement.compatible_labels(label), expected, label)
            for wider in expected[1:]:
                self.assertEqual(placement.pool._role_name(wider), placement.pool._role_name(label), wider)
                self.assertEqual(wider.replace("-std-", "-light-"), label, wider)

    def test_the_classes_are_the_pickers_classes_and_the_fleet_labels_classes(self):
        # One class list: every class an owned label names (OWNED_LABEL, the label manifest the fleet
        # registers) that the picker routes is in RUN_CLASSES, and the snapshot's live pools use no other.
        fleet = json.loads(SNAPSHOT.read_text())
        classes = {placement.pool.owned_class(label) for label in fleet["pools"] if placement.pool.persistent(label)}
        self.assertEqual(classes, set(placement.pool.RUN_CLASSES))
        self.assertEqual(placement.pool.RUN_CLASSES[-1], placement.pool.LIGHT_CLASS)

    def test_a_side_route_is_only_a_side_label(self):
        root = [runner("mini-a-glaeda", labels=(STD, "glaeda-root-std-xcode-26.6"))]
        self.assertEqual(placement.side_route(LIGHT_SIDE, root), "")
        self.assertEqual(placement.side_route(LIGHT, [runner("mini-a-glaeda-3")]), "")
        self.assertEqual(placement.side_route(LIGHT_SIDE, None), "")


class CmuxNextWiring(unittest.TestCase):
    PLACEMENT = "macos-placement"

    def workflow(self) -> dict:
        return yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8"))

    def context(self, attempt: str = "1", fallback_jobs: str | None = "", runner: str = "",
                fork: bool = False,
                triggering_actor: str = "teamleaderleo") -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE)
        context["vars"].pop("MACOS_RUNNER_PR")
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        # PR Mac jobs run only with the full-ci label (the batch integration PR).
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt,
                                 triggering_actor=triggering_actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}},
                                                         "labels": [{"name": "full-ci"}]}})
        outputs = {} if fallback_jobs is None else {"fallback_jobs": fallback_jobs, "runner": runner,
                                                    "gui_runner": GUI if runner else "",
                                                    "session_runner": GUI if runner else "",
                                                    "placed_attempt": placed_in(attempt, triggering_actor)}
        # path_route (#17164) gates every Mac job; these cases are native changes.
        context["needs"] = {"path_route": {"outputs": {"native": "true", "macos": "true", "scheme": "true",
                                                            "swift": "true", "swift_canary": "true", "daemon": "true", "generated": "true",
                                                            "tree_state": "ready"}},
                            "push-head-preflight": {"outputs": {"current": "true"}},
                            "release-compile-fast": {"result": "skipped", "outputs": {"verdict": ""}},
                            # The GUI jobs wait for the shared web bundles (#21189).
                            "web-bundles": {"result": "success"},
                            self.PLACEMENT: {"outputs": outputs}}
        return context

    def test_every_mac_job_reads_the_placement(self):
        jobs = self.workflow()["jobs"]
        placement_job = jobs[self.PLACEMENT]
        place = next(step for step in placement_job["steps"] if step.get("id") == "place")
        self.assertIn("python3 scripts/ci/side_lane_placement.py", place["run"])
        placed = tuple(place["env"]["JOBS"].split())
        self.assertEqual(set(placed), set(PLACED_JOBS))
        for name in placed:
            job = jobs[name]
            with self.subTest(job=name):
                self.assertIn(self.PLACEMENT, job["needs"] if isinstance(job["needs"], list) else [job["needs"]])
                # A failed placement job must not skip the Mac jobs: they keep today's route.
                self.assertIn("!cancelled() && ", job["if"])
                self.assertIn("needs.macos-placement.outputs." + ("gui_runner" if name in GUI_JOBS else "runner"),
                              job["runs-on"])
                if name not in JOBS:
                    # The fast tier picks its mini-only steps by runner.name and keeps no label copy.
                    self.assertNotIn("CMUX_NEXT_RUNNER", job.get("env", {}))
                    continue
                # The job's own copy of its label (mini-only steps) agrees with runs-on.
                if name != "release-compile":
                    self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], job["runs-on"])

    def test_trusted_attempts_use_the_live_route_until_overflow(self):
        jobs = self.workflow()["jobs"]
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                # A live side label remains preferred; no live side label routes to the std pool.
                self.assertEqual(evaluate(runs_on, self.context(runner=SIDE)), on(name, SIDE))
                self.assertEqual(evaluate(runs_on, self.context(runner=STD)), on(name, STD))
                # Skipped or unreadable placement keeps today's configured route.
                self.assertEqual(evaluate(runs_on, self.context(fallback_jobs=None)), on(name, SIDE))
                self.assertEqual(evaluate(runs_on, self.context("2")), on(name, SIDE))
                # The rescue's first re-run overflows (test_the_rescues_first_rerun_overflows_to_blacksmith).
                self.assertEqual(evaluate(runs_on, self.context("2", triggering_actor="github-actions[bot]")),
                                 overflow(name, placed=False))
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="teamleaderleo")), on(name, SIDE))
                # The rescue's third attempt: a free Blacksmith slot, else the owned side label.
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="github-actions[bot]")),
                                 overflow(name, placed=False))
                self.assertEqual(evaluate(runs_on, self.context("3", fallback_jobs=f" {name} ",
                                                                 triggering_actor="github-actions[bot]")),
                                 overflow(name, placed=False))
                self.assertEqual(evaluate(runs_on, self.context(fork=True)), FALLBACK)

    def test_missing_gui_label_uses_blacksmith_instead_of_a_dead_gui_queue(self):
        jobs = self.workflow()["jobs"]
        context = self.context(runner=STD)
        # With no online gui or session runner, placement writes both empty.
        context["needs"][self.PLACEMENT]["outputs"].update(gui_runner="", session_runner="")
        for name in GUI_JOBS:
            self.assertEqual(evaluate(jobs[name]["runs-on"], context), FALLBACK, name)

    def test_bot_retry_uses_a_newly_free_owned_session_runner(self):
        job_spec = self.workflow()["jobs"]["generated-files"]
        context = self.context("2", triggering_actor="github-actions[bot]")
        context["needs"][self.PLACEMENT]["outputs"]["free_session_runner"] = SESSION
        self.assertEqual(evaluate(job_spec["runs-on"], context), SESSION)

    def test_session_jobs_take_a_live_session_label_and_otherwise_keep_the_gui_label(self):
        jobs = self.workflow()["jobs"]
        bot = "github-actions[bot]"
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                # No online session runner (placement wrote the gui label), or a trusted base whose
                # placement predates the output: every job keeps today's label.
                context = self.context(runner=STD)
                self.assertEqual(evaluate(runs_on, context), on(name, STD))
                del context["needs"][self.PLACEMENT]["outputs"]["session_runner"]
                self.assertEqual(evaluate(runs_on, context), on(name, STD))
                # A live session label moves only the session jobs.
                live = self.context(runner=STD)
                live["needs"][self.PLACEMENT]["outputs"]["session_runner"] = SESSION
                self.assertEqual(evaluate(runs_on, live), SESSION if name in SESSION_JOBS else on(name, STD))
                # The rescue's attempt 3 still drops the placement's label.
                live["github"].update(run_attempt="3", triggering_actor=bot)
                self.assertEqual(evaluate(runs_on, live), overflow(name))
                # No placement (a person's re-run): the session label only once CI_SESSION_LABEL is 1.
                rerun = self.context("2")
                rerun["needs"][self.PLACEMENT] = {"outputs": {}}
                self.assertEqual(evaluate(runs_on, rerun), on(name, SIDE))
                rerun["vars"]["CI_SESSION_LABEL"] = "1"
                self.assertEqual(evaluate(runs_on, rerun), SESSION if name in SESSION_JOBS else on(name, SIDE))
                if name != "release-compile":
                    self.assertEqual(jobs[name]["env"]["CMUX_NEXT_RUNNER"], runs_on)

    def test_a_bot_attempt_3_leaves_the_placement_label_for_blacksmith(self):
        # A rescue attempt 3 must drop the stale placement output and use the
        # hosted fallback; later bot attempts remain hosted as well.
        jobs = self.workflow()["jobs"]
        bot = "github-actions[bot]"
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(evaluate(runs_on, self.context("3", runner=STD, triggering_actor=bot)), overflow(name))
                # A bot attempt 4+ follows a refusal on attempt 3 (owned_pool_rescue
                # REFUSAL_RESCUE_ATTEMPT): it leaves the fleet, which may have lost that runner.
                self.assertEqual(evaluate(runs_on, self.context("4", runner=STD, triggering_actor=bot)), FALLBACK)
                self.assertEqual(evaluate(runs_on, self.context("5", runner=SIDE, triggering_actor=bot)), FALLBACK)
                for attempt in ("4", "5"):
                    unplaced = self.context(attempt, triggering_actor=bot)
                    unplaced["needs"] = {}
                    self.assertFalse(str(evaluate(runs_on, unplaced)).startswith("glaeda-"), (name, attempt))
                # The placement never runs on attempt 3, so a retry label there was read in an earlier
                # attempt (a re-run of failed jobs carries it): stale, so the owned fallback, never it
                # (run 40398277457, 2026-10-26: a 39-minute-old slot, then 55 minutes with no runner).
                stale = self.context("3", runner=STD, triggering_actor=bot)
                stale["needs"][self.PLACEMENT]["outputs"]["retry_runner"] = FALLBACK
                self.assertEqual(evaluate(runs_on, stale), overflow(name))
                # A person's re-run stays minis-first at any attempt.
                self.assertEqual(evaluate(runs_on, self.context("4", runner=STD)), on(name, STD))

    def test_a_cmux_bot_rerun_routes_like_the_github_actions_bot(self):
        """The rescue re-runs with the cmux-bot App's token, so its re-runs' triggering actor is
        cmux-bot[bot]. Counted as a person's, every one went back to the side label: DEV daily run
        40444295785 took 10 attempts, each refused by another mini, and never reached Blacksmith."""
        jobs = self.workflow()["jobs"]
        github_actions, cmux_bot = RESCUE_BOTS
        for name in PLACED_JOBS:
            job = jobs[name]
            labels = {"runs-on": job["runs-on"]}
            if "CMUX_NEXT_RUNNER" in job.get("env", {}):
                labels["CMUX_NEXT_RUNNER"] = job["env"]["CMUX_NEXT_RUNNER"]
            for key, expression in labels.items():
                for attempt in ("2", "3", "4", "5"):
                    for runner, retry in ((STD, ""), (STD, FALLBACK), (SIDE, FALLBACK)):
                        with self.subTest(job=name, key=key, attempt=attempt, runner=runner, retry=retry):
                            routed = []
                            for actor in RESCUE_BOTS:
                                context = self.context(attempt, runner=runner, triggering_actor=actor)
                                context["needs"][self.PLACEMENT]["outputs"]["retry_runner"] = retry
                                routed.append(evaluate(expression, context))
                            self.assertEqual(routed[1], routed[0], (github_actions, cmux_bot))
                if key != "runs-on" or name not in JOBS:
                    continue
                # A bot attempt 4 leaves the minis for Blacksmith; a person's stays on them.
                self.assertEqual(evaluate(expression, self.context("4", runner=STD, triggering_actor=cmux_bot)),
                                 FALLBACK, (name, key))
                self.assertNotEqual(evaluate(expression, self.context("4", runner=STD)), FALLBACK, (name, key))

    def test_the_rescues_first_rerun_overflows_to_blacksmith(self):
        """claude-sr2, 2026-10-21: the bot's first re-run (attempt 2) may go to Blacksmith macOS as
        overflow capacity. It used to queue on the minis again, so under saturation a pull request lost a
        second rescue window (about 10 minutes) and its running jobs before attempt 3 overflowed."""
        jobs = self.workflow()["jobs"]
        bot = "github-actions[bot]"
        for name in PLACED_JOBS:
            job = jobs[name]
            labels = {"runs-on": job["runs-on"]}
            if "CMUX_NEXT_RUNNER" in job.get("env", {}):
                labels["CMUX_NEXT_RUNNER"] = job["env"]["CMUX_NEXT_RUNNER"]
            for key, expression in labels.items():
                with self.subTest(job=name, key=key):
                    # Minis first: attempt 1 and a person's re-run at any attempt.
                    self.assertEqual(evaluate(expression, self.context(runner=STD)), on(name, STD))
                    self.assertEqual(evaluate(expression, self.context("2", runner=STD)), on(name, STD))
                    # The rescue's attempt 2 takes the free Blacksmith slot the placement found.
                    free = self.context("2", runner=STD, triggering_actor=bot)
                    free["needs"][self.PLACEMENT]["outputs"]["retry_runner"] = FALLBACK
                    self.assertEqual(evaluate(expression, free), FALLBACK)
                    # The fast tier's own fast-lane mini is left the same way.
                    free["needs"][self.PLACEMENT]["outputs"]["fast_runner"] = "glaeda-fast-std-xcode-26.6"
                    self.assertEqual(evaluate(expression, free), FALLBACK)
                    # With no free slot it waits behind the fleet, never in a Blacksmith queue, as attempt 3 does.
                    full = self.context("2", runner=STD, triggering_actor=bot)
                    self.assertEqual(evaluate(expression, full), SIDE if name == "fast-tier" else overflow(name))
                    # A dispatch run's attempt 2 overflows the same way.
                    free["github"].update(event_name="workflow_dispatch", ref="refs/heads/topic")
                    self.assertEqual(evaluate(expression, free), FALLBACK)

    def test_placement_starts_only_where_attempt_1_may_take_the_side_label(self):
        # A fork, another owner, owned pools off or a re-run starts no Linux runner before the Mac jobs.
        jobs = self.workflow()["jobs"]
        # !cancelled(): a same-tree mode run (path routing skipped) still places its tree jobs.
        self.assertTrue(jobs[self.PLACEMENT]["if"].startswith("${{ !cancelled() && "))
        gate = jobs[self.PLACEMENT]["if"].replace("!cancelled() && ", "")
        self.assertTrue(evaluate(gate, self.context()))
        same_tree = self.context()
        same_tree["github"].update(event_name="workflow_dispatch", ref="refs/heads/feat-cmux-next")
        same_tree["inputs"] = {"same_tree_sha": "a" * 40, "same_tree_state": "ready"}
        same_tree["needs"] = {}
        self.assertTrue(evaluate(gate, same_tree))
        same_tree["inputs"]["same_tree_state"] = "failed"
        self.assertFalse(evaluate(gate, same_tree))
        push = self.context()
        push["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertTrue(evaluate(gate, push))
        # A dispatch on a working branch runs every tier, so its Mac jobs are placed too (#22303).
        dispatch_on_a_branch = self.context()
        dispatch_on_a_branch["github"].update(event_name="workflow_dispatch", ref="refs/heads/issue-22303-next-pr-ci")
        dispatch_on_a_branch["inputs"] = {"same_tree_sha": ""}
        self.assertTrue(evaluate(gate, dispatch_on_a_branch))
        other_owner = self.context()
        other_owner["github"]["repository_owner"] = "someone"
        owned_off = self.context()
        owned_off["vars"]["CI_PR_POOL_OWNED"] = "0"
        no_mac_work = self.context()
        no_mac_work["needs"]["path_route"]["outputs"].update(native="false", macos="false")
        for why, context in {"fork": self.context(fork=True), "attempt 2": self.context("2"),
                             "attempt 3": self.context("3"), "another owner": other_owner,
                             "owned pools off": owned_off,
                             "no Mac work on the path route": no_mac_work}.items():
            self.assertFalse(evaluate(gate, context), why)
        # Wherever a Mac job may take an owned label the placement runs, so its marker can upload:
        # every context above that skips it routes every Mac job to the fallback.
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            # A bot attempt 3 with no free Blacksmith slot (or, for a GUI job, no placement result)
            # does wait on an owned label, unwatched: the rescue's watch ends at attempt 2.
            for why, context in {"fork": self.context(fork=True),
                                 "another owner": other_owner, "owned pools off": owned_off}.items():
                context["needs"] = {}  # the skipped placement has no outputs
                self.assertFalse(str(evaluate(runs_on, context)).startswith("glaeda-"), (name, why))
            # A skipped placement leaves the Mac jobs running (!cancelled()) and its empty output keeps the label.
            gate = jobs[name]["if"].replace("always() && ", "").replace("!cancelled() && ", "")
            self.assertTrue(evaluate(gate, self.context()))
            self.assertEqual(evaluate(runs_on, dict(self.context(), needs={})), on(name, SIDE))

    def test_the_watch_marker_follows_the_placement(self):
        steps = self.workflow()["jobs"][self.PLACEMENT]["steps"]
        names = [step.get("name") for step in steps]
        mark = next(step for step in steps if step.get("id") == "marker")
        # The marker comes after the placement and skips a run with every job on the fallback.
        self.assertLess(names.index(next(step["name"] for step in steps if step.get("id") == "place")),
                        names.index(mark["name"]))
        self.assertIn("steps.place.outputs.watch != 'false'", mark["if"])
        upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact"))
        # With no free overflow slot a bot re-run rejoins the same side label (retry_runner is
        # empty), so the sweeper on main watches it for refusals only and leaves a long queue
        # alone (run 39615562861 was cancelled and re-queued twice, 2026-10-21).
        name = upload["with"]["name"]
        for free, marker in (("blacksmith-6vcpu-macos-26", "owned-pool-watch"), ("", "owned-pool-watch-refusals"),
                             (None, "owned-pool-watch-refusals")):
            outputs = {} if free is None else {"free_retry_runner": free}
            self.assertEqual(evaluate(name, {"steps": {"place": {"outputs": outputs}}}), marker, free)
        checks = self.workflow()["jobs"]["checks"]["steps"]
        self.assertFalse(any(step.get("with", {}).get("name") == "owned-pool-watch" for step in checks))


    def push(self, run_id: str, event_name: str = "push") -> dict:
        context = self.context()
        context["github"].update(event_name=event_name, ref="refs/heads/feat-cmux-next", run_id=run_id, event={})
        return context

    def test_a_newer_push_replaces_only_a_pending_mac_job(self):
        # 2026-10-07 00:20Z to 01:05Z: pushes about once a minute, and in none of 12
        # tip runs did "cmux-next swift test" complete. The owned-pool rescue cancelled
        # each push run whose Mac jobs waited 30 s for a mini while a newer push run
        # existed, so the newest run was always the next one cancelled. Each Mac job of
        # a push now holds one group per branch: one runs, one waits, and a newer push
        # replaces only the waiting job (cancel-in-progress false). Pull request and
        # dispatch runs keep a group per run.
        jobs = self.workflow()["jobs"]
        push_groups = {}
        for name in JOBS:
            with self.subTest(job=name):
                concurrency = jobs[name].get("concurrency")
                self.assertIsInstance(concurrency, dict, f"{name} has no job-level concurrency")
                # A push never cancels a running Mac job; a newer PR head may.
                cancel = concurrency["cancel-in-progress"]
                self.assertFalse(evaluate(cancel, self.push("101")) if isinstance(cancel, str) else cancel)
                group = concurrency["group"]
                first, second = evaluate(group, self.push("101")), evaluate(group, self.push("102"))
                if name == "release-compile":
                    # A started Release compile is never evicted: its group is
                    # per run, while superseded push jobs skip before queueing.
                    self.assertNotEqual(first, second)
                else:
                    self.assertEqual(first, second)
                push_groups[name] = first
                # Dispatch runs keep a group per run. Pull request runs are kept
                # apart per run or, for jobs that coalesce stale heads, per pull
                # request; either way two pull requests never share a group.
                one, other = (evaluate(group, self.push(run_id, "workflow_dispatch")) for run_id in ("101", "102"))
                self.assertNotEqual(one, other, "workflow_dispatch")
                if name != "release-compile":
                    self.assertNotEqual(one, first, "workflow_dispatch")
                pulls = []
                for run_id, number in (("101", 1), ("102", 2)):
                    context = self.push(run_id, "pull_request")
                    context["github"]["event"] = {"pull_request": {"number": number}}
                    pulls.append(evaluate(group, context))
                self.assertNotEqual(pulls[0], pulls[1], "pull_request")
                if name != "release-compile":
                    self.assertNotEqual(pulls[0], first, "pull_request")
        self.assertEqual(len(set(push_groups.values())), len(JOBS))

    def test_push_runs_upload_no_rescue_watch_marker(self):
        # The rescue sweeper adopts a run by its owned-pool-watch marker and cancels a
        # push run with a newer push run behind it, even while its swift test runs.
        # The per-branch job groups above bound the push queue instead.
        steps = self.workflow()["jobs"][self.PLACEMENT]["steps"]
        mark = next(step for step in steps if step.get("id") == "marker")

        def marked(context: dict) -> bool:
            context["env"]["CMUX_NEXT_SIDE_ROUTE"] = SIDE
            context["steps"] = {"place": {"outputs": {"watch": "true"}}}
            return bool(evaluate(mark["if"], context))

        self.assertTrue(marked(self.context()))
        self.assertTrue(marked(self.push("101", "workflow_dispatch")))
        self.assertFalse(marked(self.push("101")))


class FeedReplyFullText(unittest.TestCase):
    """The feed workflow's package tests need no secrets, so they take the owned side lane
    on attempt 1 like the cmux-tui legs, instead of always queuing on Blacksmith."""

    def runs_on(self, job: str) -> str:
        workflow = yaml.safe_load((WORKFLOWS / "test-feed-reply-providers.yml").read_text(encoding="utf-8"))
        return workflow["jobs"][job]["runs-on"]

    def context(self, attempt: str = "1", owned: str = "1", owner: str = "manaflow-ai") -> dict:
        context = github_context("workflow_dispatch", CI_PR_POOL_OWNED=owned, CI_SIDE_LANE_RUNNER=SIDE)
        context["vars"].pop("MACOS_RUNNER_PR")
        context["github"].update(run_attempt=attempt, repository_owner=owner)
        return context

    def test_full_text_takes_the_side_lane_on_attempt_1(self):
        runs_on = self.runs_on("full-text")
        self.assertEqual(evaluate(runs_on, self.context()), SIDE)
        # A re-run, owned pools off, or another owner keeps a hosted runner.
        self.assertEqual(evaluate(runs_on, self.context(attempt="2")), FALLBACK)
        self.assertEqual(evaluate(runs_on, self.context(owned="0")), FALLBACK)
        self.assertEqual(evaluate(runs_on, self.context(owner="someone")), "macos-26")

    def test_verify_stays_hosted(self):
        # verify waits up to 30 min on another run and drives a GUI app; it keeps Blacksmith.
        self.assertEqual(evaluate(self.runs_on("verify"), self.context()), FALLBACK)


if __name__ == "__main__":
    unittest.main()
