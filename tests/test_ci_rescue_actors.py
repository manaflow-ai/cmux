#!/usr/bin/env python3
"""The owned-pool rescue's re-runs route the same whichever bot identity started them.

The rescue (owned_pool_rescue.py) re-runs with the cmux-bot App's token, so a re-run's
triggering actor is cmux-bot[bot], not github-actions[bot]. Every runs-on that asked for
github-actions[bot] alone counted those re-runs as a person's and sent them back to the owned
label on every attempt: DEV daily run 40444295785 went through 10 attempts, each refused by
another mini, and never reached Blacksmith.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOWS = ROOT / ".github/workflows"
BOTS = frozenset({"github-actions[bot]", "cmux-bot[bot]"})
# A comparison of the triggering actor to one literal login, in either order.
SINGLE_ACTOR = re.compile(
    r"github\.triggering_actor\s*[!=]=\s*'[^']*'|'[^']*'\s*[!=]=\s*github\.triggering_actor")

sys.path.insert(0, str(SCRIPTS))


def load(name: str):
    spec = importlib.util.spec_from_file_location(f"rescue_actors_{name}", SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    # dataclasses look the module up by name while the class is built.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class WorkflowsAcceptBothBots(unittest.TestCase):
    def test_no_workflow_compares_the_triggering_actor_to_one_login(self):
        offenders = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.lstrip().startswith("#") and SINGLE_ACTOR.search(line):
                    offenders.append(f"{path.name}:{number}")
        self.assertEqual(offenders, [], "use contains(fromJSON('[\"github-actions[bot]\",\"cmux-bot[bot]\"]'), "
                                        "github.triggering_actor) so both rescue bots route alike")

    def test_every_actor_list_names_both_bots(self):
        lists = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\), github\.triggering_actor\)")
        seen = 0
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            for found in lists.finditer(path.read_text(encoding="utf-8")):
                seen += 1
                self.assertEqual(frozenset(json.loads(found.group(1))), BOTS, path.name)
        self.assertGreater(seen, 0)


class ScriptsAcceptBothBots(unittest.TestCase):
    def test_the_scripts_share_one_actor_set(self):
        for name in ("pr_runner_pool", "next_macos_cascade", "queue_janitor"):
            with self.subTest(script=name):
                self.assertEqual(load(name).RESCUE_ACTORS, BOTS)

    def test_a_cmux_bot_attempt_3_is_a_host_fault_retry(self):
        pool = load("pr_runner_pool")
        for actor in BOTS:
            self.assertFalse(pool.host_fault_retry(2, actor))
            self.assertTrue(pool.host_fault_retry(3, actor))
        self.assertFalse(pool.host_fault_retry(3, "teamleaderleo"))

    def test_a_cmux_bot_attempt_2_is_placed_afresh(self):
        cascade = load("next_macos_cascade")
        for actor in BOTS:
            self.assertTrue(cascade.bot_rerun({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": actor}))
        self.assertFalse(cascade.bot_rerun({"GITHUB_RUN_ATTEMPT": "2", "GITHUB_TRIGGERING_ACTOR": "teamleaderleo"}))

    def test_a_cmux_bot_attempt_3_is_not_re_run_again(self):
        # classify_failures re-runs a machine failure once; the bot's attempt 3 is already on Blacksmith.
        classify = load("classify_failures")
        report = {"run_id": 42, "attempt": 3, "head_sha": "a" * 40, "conclusion": "failure",
                  "jobs": [{"name": "job 0", "verdict": classify.MACHINE}]}
        for actor in BOTS:
            latest = {"run_attempt": 3, "status": "completed", "triggering_actor": {"login": actor}}
            self.assertFalse(classify.rerun_decision(report, latest)[0], actor)
        # A person's attempt 3 that a mini failed is still re-run, by the bot, onto Blacksmith.
        person = {"run_attempt": 3, "status": "completed", "triggering_actor": {"login": "teamleaderleo"}}
        self.assertTrue(classify.rerun_decision(report, person)[0])


if __name__ == "__main__":
    unittest.main()
