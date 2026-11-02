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

import contextlib
import io
import json
import re
import subprocess
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


def runner(name: str, *labels: str) -> dict:
    return {"name": name, "status": "online", "labels": [{"name": label} for label in labels]}


POOL, PAIR_RUNNER = "glaeda-trusted-std-xcode-26.6", "glaeda-runner-cmux15-glaeda"
PAIR = ("needs.pick-nightly-app-runner.outputs.trusted != 'false' && "
        "fromJSON(format('[\"{0}\", \"{1}\"]', vars.CI_SEED_TRUSTED_POOL, vars.CI_NIGHTLY_TRUSTED_RUNNER)) || "
        "needs.pick-nightly-app-runner.outputs.cloud || 'blacksmith-12vcpu-macos-26'")
TRUSTED = {"CI_SEED_TRUSTED_POOL": POOL, "CI_NIGHTLY_TRUSTED_RUNNER": PAIR_RUNNER}
ONE_HOST = [runner("cmux15-glaeda", POOL, PAIR_RUNNER), runner("cmux15-glaeda-1", POOL, "glaeda-runner-cmux15-glaeda-1"),
            runner("cmux3-glaeda", "glaeda-std-xcode-26.6")]


def counted(runs_on: str, runners: list[dict], **extra: str) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        Path(tmp, "w.yml").write_text(f"jobs:\n  build:\n    runs-on: ${{{{ {runs_on} }}}}\n", encoding="utf-8")
        return check.single_host_sets([("b", Path(tmp))], TRUSTED | extra, runners)


class Hosts(unittest.TestCase):
    """The live half counts the hosts that serve each variable-derived label set."""

    def test_runner_hosts(self) -> None:
        for name, host in (("cmux15-glaeda", "cmux15"), ("cmux15-glaeda-1", "cmux15"),
                           ("cmux7s-mac-mini-glaeda-nightly-next", "cmux7s-mac-mini"),
                           ("cmuxs-mac-mini-6-glaeda-2", "cmuxs-mac-mini-6"),
                           ("cmux7s-mac-mini-nightly-ops-1", "cmux7s-mac-mini"), ("CMUX15-Glaeda", "cmux15"),
                           ("some-runner", "some-runner")):
            self.assertEqual(check.runner_host(name), host, name)

    def test_a_pool_one_host_serves_fails_and_two_hosts_pass(self) -> None:
        found = counted("vars.CI_SEED_TRUSTED_POOL || 'blacksmith-6vcpu-macos-26'", ONE_HOST)
        self.assertEqual(len(found), 1, found)
        self.assertIn("vars.CI_SEED_TRUSTED_POOL asks for ['glaeda-trusted-std-xcode-26.6'], which only host cmux15",
                      found[0])
        self.assertIn("cmux15-glaeda, cmux15-glaeda-1", found[0])
        self.assertIn("b:w.yml build", found[0])
        two = ONE_HOST + [runner("cmux7s-mac-mini-glaeda", POOL)]
        self.assertEqual(counted("vars.CI_SEED_TRUSTED_POOL || 'blacksmith-6vcpu-macos-26'", two), [])

    def test_the_pair_needs_both_labels_on_one_runner(self) -> None:
        # One host carries both: fails even behind the picker and its fallback.
        found = counted(PAIR, ONE_HOST)
        self.assertEqual(len(found), 1, found)
        self.assertIn("vars.CI_SEED_TRUSTED_POOL + vars.CI_NIGHTLY_TRUSTED_RUNNER asks for "
                      "['glaeda-runner-cmux15-glaeda', 'glaeda-trusted-std-xcode-26.6'], which only host cmux15", found[0])
        # A second host with only the pool label (or only the runner label) does not serve the pair.
        split = ONE_HOST + [runner("cmux7s-mac-mini-glaeda", POOL), runner("cmux9-glaeda", PAIR_RUNNER)]
        self.assertEqual(len(counted(PAIR, split)), 1)
        # The second mini's runner given both labels (labels match case-insensitively): two hosts.
        both = ONE_HOST + [runner("cmux7s-mac-mini-glaeda-nightly-next", POOL.upper(), PAIR_RUNNER)]
        self.assertEqual(counted(PAIR, both), [])

    def test_sets_no_self_hosted_runner_serves_and_unset_variables_are_not_counted(self) -> None:
        self.assertEqual(counted("vars.MACOS_RUNNER_26 || 'x'", ONE_HOST, MACOS_RUNNER_26="blacksmith-6vcpu-macos-26"), [])
        self.assertEqual(counted(PAIR, ONE_HOST, CI_NIGHTLY_TRUSTED_RUNNER=""), [])
        self.assertEqual(counted("vars.CI_SEED_TRUSTED_POOL || 'x'", ONE_HOST, CI_SEED_TRUSTED_POOL=""), [])

    def test_a_json_field_and_a_nested_group_resolve(self) -> None:
        pools = '{"linux": "glaeda-trusted-std-xcode-26.6"}'
        self.assertEqual(len(counted("fromJSON(vars.RUNNER_POOLS || '{}').linux || 'x'", ONE_HOST, RUNNER_POOLS=pools)), 1)
        self.assertEqual(counted("fromJSON(vars.RUNNER_POOLS).linux || 'x'", ONE_HOST, RUNNER_POOLS='{"linux": "b"}'), [])
        self.assertEqual(len(counted("a && (needs.p.outputs.ok && vars.CI_SEED_TRUSTED_POOL || 'x')", ONE_HOST)), 1)

    def test_an_unknown_form_is_named_not_skipped(self) -> None:
        found = counted("format('{0}-x', vars.CI_SEED_TRUSTED_POOL) || 'x'", ONE_HOST)
        self.assertEqual(len(found), 1, found)
        self.assertIn("vars.CI_SEED_TRUSTED_POOL in a form this check cannot turn into labels", found[0])


class LiveMain(unittest.TestCase):
    def run_main(self, env: dict, argv: list[str] | None = None, read=None) -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "w.yml").write_text(f"jobs:\n  build:\n    runs-on: ${{{{ {PAIR} }}}}\n", encoding="utf-8")
            raw = "".join(f"{name}={value}\n" for name, value in TRUSTED.items())
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = check.main([f"b={tmp}"] if argv is None else argv, {check.RUNS_ON_VARIABLES_ENV: raw} | env,
                                  read or self.never)
        return code, out.getvalue()

    @staticmethod
    def never(token: str, repo: str) -> list:
        raise AssertionError("only --list-runners reads runners")

    @staticmethod
    def counting(runners) -> dict:
        return {check.COUNT_HOSTS_ENV: "1", check.RUNNER_LIST_ENV: runners if isinstance(runners, str)
                else json.dumps(runners)}

    def test_the_count_runs_only_when_asked(self) -> None:
        self.assertEqual(self.run_main({check.RUNNER_LIST_ENV: json.dumps(ONE_HOST)}),
                         (0, "runs-on values: ok (1 branch(es))\n"))

    def test_one_host_fails_and_two_hosts_pass(self) -> None:
        code, out = self.run_main(self.counting(ONE_HOST))
        self.assertEqual(code, 1, out)
        self.assertIn("which only host cmux15 serves", out)
        both = ONE_HOST + [runner("cmux7s-mac-mini-glaeda-nightly-next", POOL, PAIR_RUNNER)]
        self.assertEqual(self.run_main(self.counting(both)), (0, "runs-on values: ok (1 branch(es))\n"))

    def test_an_unreadable_list_fails_closed(self) -> None:
        for raw, says in (("", "the runners job gave no self-hosted runner list"),
                          ("[]", "the self-hosted runner list is empty"),
                          ("not json", "is not a JSON list of runners"), ('{"a": 1}', "is not a JSON list of runners"),
                          # A record with no name or no labels would count no host and pass (review round 2).
                          ("[{}]", "is not a JSON list of runners"), ('[{"name": "r"}]', "is not a JSON list of runners"),
                          ('[{"name": "r", "labels": []}]', "is not a JSON list of runners"),
                          ('[{"name": "r", "labels": [{}]}]', "is not a JSON list of runners"),
                          ('[{"name": "", "labels": [{"name": "x"}]}]', "is not a JSON list of runners")):
            code, out = self.run_main(self.counting(raw))
            self.assertEqual(code, 1, (raw, out))
            self.assertIn(says, out)
            self.assertIn("no label set's hosts were counted", out)

    def test_list_runners_needs_no_pyyaml(self) -> None:
        # The runners job runs on a bare Python (review round 2): the module imports without PyYAML.
        code = ("import sys; sys.modules['yaml'] = None; sys.path.insert(0, sys.argv[1]); "
                "import runs_on_values as r; sys.exit(r.main(['--list-runners'], {}, lambda t, p: []))")
        done = subprocess.run([sys.executable, "-c", code, str(ROOT / "scripts" / "ci")],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertIn("no ROUTE_TOKEN", done.stdout)
        self.assertNotIn("Traceback", done.stderr)

    def test_list_runners_prints_names_and_labels_or_fails(self) -> None:
        seen = []

        def read(token: str, repo: str) -> list:
            seen.append((token, repo))
            return [ONE_HOST[0] | {"id": 7, "busy": False}]
        code, out = self.run_main({"ROUTE_TOKEN": "t", "GITHUB_REPOSITORY": "o/r"}, ["--list-runners"], read)
        self.assertEqual((code, seen), (0, [("t", "o/r")]))
        self.assertTrue(out.startswith("list=") and out.count("\n") == 1, out)
        listed = json.loads(out[len("list="):])
        self.assertEqual(listed, [{"name": "cmux15-glaeda", "labels": [{"name": POOL}, {"name": PAIR_RUNNER}]}])
        # What it prints is what the check reads.
        self.assertEqual(check.runner_list(self.counting(out[len("list="):].strip())), (listed, ""))

        def broken(token: str, repo: str) -> list:
            raise RuntimeError("org runner group glaeda-minis unreadable (HTTP 403)")
        code, out = self.run_main({"ROUTE_TOKEN": "t"}, ["--list-runners"], broken)
        self.assertEqual(code, 1)
        self.assertIn("unreadable (org runner group glaeda-minis unreadable (HTTP 403))", out)
        self.assertNotIn("list=", out)
        code, out = self.run_main({}, ["--list-runners"], broken)
        self.assertEqual(code, 1)
        self.assertIn("no ROUTE_TOKEN", out)


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
        passed = re.findall(r"^([A-Za-z0-9_]+)=\$\{\{ vars\.\1 \}\}$", block, re.M)
        self.assertEqual(len(passed), len(block.strip().splitlines()), "one NAME=${{ vars.NAME }} per line")
        missing = (check.read_variables([("here", WORKFLOWS)]) | set(check.RUNNER_NAME_VARIABLES)) - set(passed)
        self.assertEqual(missing, set())

    def test_the_live_check_reads_the_branches_that_run_workflows(self) -> None:
        step = next(s for s in self.workflow()["jobs"]["check"]["steps"] if s.get("id") == "runs-on-values")
        branches = step["env"]["ROUTE_BRANCHES"].split()
        self.assertTrue({"main", "feat-cmux-next", "nightly-next", "rc/cnx-ios-builder"} <= set(branches), branches)
        self.assertIn("python3 scripts/ci/runs_on_values.py", step["run"])
        self.assertIn("schedule", self.workflow()["on"])

    def test_the_live_check_counts_hosts_from_the_runners_job(self) -> None:
        jobs = self.workflow()["jobs"]
        step = next(s for s in jobs["check"]["steps"] if s.get("id") == "runs-on-values")
        self.assertEqual(step["env"].get(check.COUNT_HOSTS_ENV), "1")
        self.assertEqual(step["env"].get(check.RUNNER_LIST_ENV), "${{ needs.runners.outputs.list }}")
        self.assertEqual(jobs["check"].get("needs"), "runners")
        # A failed runner read still runs the check, which then fails closed.
        self.assertIn("!cancelled()", jobs["check"]["if"])
        self.assertEqual(jobs["runners"]["outputs"]["list"], "${{ steps.read.outputs.list }}")
        steps = jobs["runners"]["steps"]
        mint = next(s for s in steps if s.get("id") == "route-token")
        read = next(s for s in steps if s.get("id") == "read")
        self.assertLess(steps.index(mint), steps.index(read))
        self.assertIn("runs_on_values.py --list-runners", read["run"])
        self.assertEqual(read["env"]["ROUTE_TOKEN"], "${{ steps.route-token.outputs.token }}")
        # The org's glaeda group is where the minis register (pr_runner_pool.GitHub.runners()).
        self.assertEqual(mint["with"].get("permission-organization-self-hosted-runners"), "read")
        # The App key stays out of the check job, whose runs-on a variable can move.
        self.assertNotIn("secrets.", yaml.safe_dump(jobs["check"]))

if __name__ == "__main__":
    unittest.main()
