#!/usr/bin/env python3
"""No runs-on waits on one machine through a variable's value (scripts/ci/runs_on_values.py).

Leo, 2026-10-24: "a CI test fails on a runs-on that can resolve to a single-host
label with no fallback". tests/test_ci_runs_on_fallback.py reads workflow text,
so `vars.CI_IOS_INTERNAL_RUNNER || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'`
passed while the variable named one mini's runner: a set variable never falls
through. This runs the value check on this tree with the runner-name variables
taken as one machine, and keeps the scheduled live check's inputs complete.
"""

from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import runs_on_values as check  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
ONE = "glaeda-runner-mini-ios-internal"


def values(**extra: str) -> dict[str, str]:
    return {name: ONE for name in check.RUNNER_NAME_VARIABLES} | extra


class Expressions(unittest.TestCase):
    def bad(self, expression: str, **extra: str) -> list[str]:
        return check.unguarded(expression, values(**extra))

    def test_a_bare_single_host_variable_fails_whatever_follows(self) -> None:
        # The 2026-10-27 archive: a set variable never reaches the later alternatives.
        self.assertEqual(self.bad("github.repository_owner != 'manaflow-ai' && 'macos-26' || "
                                  "vars.CI_IOS_INTERNAL_RUNNER || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'"),
                         ["CI_IOS_INTERNAL_RUNNER"])
        self.assertEqual(self.bad("vars.CI_IOS_INTERNAL_RUNNER || 'macos-26'"), ["CI_IOS_INTERNAL_RUNNER"])
        # A condition that is not a live pick still waits on the machine whenever it holds.
        self.assertEqual(self.bad("github.run_attempt == 1 && vars.CI_IOS_INTERNAL_RUNNER || 'x'"),
                         ["CI_IOS_INTERNAL_RUNNER"])

    def test_a_pool_value_passes(self) -> None:
        self.assertEqual(self.bad("vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404'",
                                  LINUX_RUNNER="blacksmith-4vcpu-ubuntu-2404"), [])
        self.assertEqual(self.bad("vars.CI_SIDE_LANE_RUNNER", CI_SIDE_LANE_RUNNER="glaeda-side-std-xcode-26.6"), [])
        self.assertEqual(check.unguarded("vars.CI_IOS_INTERNAL_RUNNER || 'x'", {"CI_IOS_INTERNAL_RUNNER": ""}), [])

    def test_a_live_pick_with_a_later_label_passes(self) -> None:
        # main's nightly build-nightly-app.
        self.assertEqual(self.bad(
            "github.repository_owner != 'manaflow-ai' && 'macos-26' || github.run_attempt == 1 && "
            "vars.CI_SEED_TRUSTED_POOL != '' && vars.CI_NIGHTLY_TRUSTED_RUNNER != '' && "
            "needs.pick-nightly-app-runner.outputs.trusted != 'false' && "
            "fromJSON(format('[\"{0}\", \"{1}\"]', vars.CI_SEED_TRUSTED_POOL, vars.CI_NIGHTLY_TRUSTED_RUNNER)) || "
            "needs.pick-nightly-app-runner.outputs.cloud || 'blacksmith-12vcpu-macos-26'"), [])
        # A pick with nothing that always names a runner after it is no fallback.
        self.assertEqual(self.bad("needs.p.outputs.ok == 'true' && vars.CI_IOS_INTERNAL_RUNNER || vars.MACOS_RUNNER_26"),
                         ["CI_IOS_INTERNAL_RUNNER"])
        # A pick in another alternative guards nothing; a variable used only as a condition is no label.
        self.assertEqual(self.bad("needs.p.outputs.label || vars.CI_IOS_INTERNAL_RUNNER || 'x'"),
                         ["CI_IOS_INTERNAL_RUNNER"])
        self.assertEqual(self.bad("vars.CI_IOS_INTERNAL_RUNNER != '' && 'blacksmith-6vcpu-macos-26' || 'x'"), [])
        # Only a positive test of the output, as its own term, is a pick (review round 1).
        for guard in ("!needs.p.outputs.ok", "(needs.p.outputs.ok || 'x')", "!(needs.p.outputs.ok)",
                      "contains('needs.p.outputs.ok', 'x')", "needs.p.outputs.ok != '' || true",
                      "fromJSON(needs.p.outputs.list)[0]"):
            self.assertEqual(self.bad(f"{guard} && vars.CI_IOS_INTERNAL_RUNNER || 'pool'"),
                             ["CI_IOS_INTERNAL_RUNNER"], guard)
        for guard in ("needs.p.outputs.ok", "needs.p.outputs.trusted != 'false'", "needs.p.outputs.dedicated != ''",
                      "needs.p.outputs.attempt == format('{0}', github.run_attempt)"):
            self.assertEqual(self.bad(f"{guard} && vars.CI_IOS_INTERNAL_RUNNER || 'pool'"), [], guard)
        # Nested: the group's own literal is the fallback.
        self.assertEqual(self.bad("a && (needs.p.outputs.ok && vars.CI_IOS_INTERNAL_RUNNER || 'x')"), [])

    def test_single_host_values(self) -> None:
        for value in ("glaeda-runner-cmux15-glaeda", "GLAEDA-RUNNER-cmux7s-mac-mini-nightly-next", "cmux22",
                      "cmuxs-mac-mini-6", " glaeda-runner-x "):
            self.assertTrue(check.single_host(value), value)
        for value in ("", "glaeda-trusted-next-nightly", "glaeda-std-xcode-26.6", "blacksmith-6vcpu-macos-26",
                      "1", '{"probe": ""}', "glaeda-ios-internal-next-pool"):
            self.assertFalse(check.single_host(value), value)


class Inputs(unittest.TestCase):
    def test_a_malformed_line_is_named_by_number_not_text(self) -> None:
        with self.assertRaises(ValueError) as caught:
            check.parse_values("A=1\nsecret-looking text\n")
        self.assertIn("line 2", str(caught.exception))
        self.assertNotIn("secret", str(caught.exception))
        with self.assertRaises(ValueError):
            check.parse_values("A=1\nA=2\n")


class ThisTree(unittest.TestCase):
    def test_no_runs_on_here_reads_a_runner_name_variable_bare(self) -> None:
        names = check.read_variables([("here", WORKFLOWS)])
        found = check.problems([("here", WORKFLOWS)], {name: "" for name in names} | values())
        self.assertEqual(found, [], "\n".join(found))

    def test_a_planted_bare_read_fails_and_an_unpassed_variable_is_named(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "w.yml").write_text("jobs:\n  a:\n    runs-on: ${{ vars.CI_IOS_INTERNAL_RUNNER || 'x' }}\n"
                                          "  b:\n    runs-on: ${{ vars.NEW_ONE || 'x' }}\n", encoding="utf-8")
            found = check.problems([("b", Path(tmp))], values())
        self.assertEqual(len(found), 2, found)
        self.assertIn("b:w.yml a: runs-on reads vars.CI_IOS_INTERNAL_RUNNER", found[0])
        self.assertIn("vars.NEW_ONE", found[1])


def live_step() -> dict | None:
    doc = yaml.load((WORKFLOWS / "ci-repo-variables.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    return next((s for s in doc["jobs"]["check"]["steps"] if s.get("id") == "runs-on-values"), None)


# The live check runs from the default branch's schedule; feat-cmux-next carries this test for ThisTree only.
@unittest.skipIf(live_step() is None, "this branch's ci-repo-variables.yml is not the scheduled one")
class Wiring(unittest.TestCase):
    def workflow(self) -> dict:
        return yaml.load((WORKFLOWS / "ci-repo-variables.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)

    def test_the_live_check_gets_every_runs_on_variable_by_name(self) -> None:
        step = next(s for s in self.workflow()["jobs"]["check"]["steps"] if s.get("id") == "runs-on-values")
        block = step["env"][check.RUNS_ON_VARIABLES_ENV]
        # The background lane's read carries its Blacksmith default (test_ci_self_hosted_guard.sh requires it on
        # every read); an unset value is that pool, never one machine.
        passed = re.findall(r"^([A-Za-z0-9_]+)=\$\{\{ vars\.\1(?: \|\| '[a-z0-9-]+')? \}\}$", block, re.M)
        self.assertEqual(len(passed), len(block.strip().splitlines()), "one NAME=${{ vars.NAME }} per line")
        missing = (check.read_variables([("here", WORKFLOWS)]) | set(check.RUNNER_NAME_VARIABLES)) - set(passed)
        self.assertEqual(missing, set())

    def test_the_live_check_reads_the_branches_that_run_workflows(self) -> None:
        step = next(s for s in self.workflow()["jobs"]["check"]["steps"] if s.get("id") == "runs-on-values")
        branches = step["env"]["ROUTE_BRANCHES"].split()
        self.assertTrue({"main", "feat-cmux-next", "nightly-next", "rc/cnx-ios-builder"} <= set(branches), branches)
        self.assertIn("python3 scripts/ci/runs_on_values.py", step["run"])
        self.assertIn("schedule", self.workflow()["on"])


if __name__ == "__main__":
    unittest.main()
