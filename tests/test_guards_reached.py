#!/usr/bin/env python3
"""scripts/ci/guards_reached.sh runs the base pass beside the head's, under one deadline, so its verdict prints.

ci/steps.toml's guard-steps-reached step re-ran the head's red guard steps on the base only after the head finished.
On cmux#61530 (run 46142803587) the head took 597 s and the base re-run ran past the step's 900 s: no
`guard red step (KIND)` line printed, so its 15 base reds went to the merge gate as the change's, with no
feat-cmux-next run to compare with. These tests run the script in a scratch repository whose guard runner is a stub.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/guards_reached.sh"
NEW_REDS = ROOT / "scripts/ci/guards_new_reds.py"

# The plan guard_step_inputs.py would print: every stub step is reached.
PLAN_STUB = """#!/usr/bin/env python3
import json, os
steps = os.environ["STUB_STEPS"].split(",")
print(json.dumps({"run": {step: "reached by stub.txt" for step in steps}}))
"""

# guards-local.sh: STUB_HEAD / STUB_BASE ({step: passed}) per side, STUB_SLEEP seconds before it writes, and one
# `start SIDE DEADLINE TIME` / `end SIDE TIME` line per run in STUB_LOG.
RUNNER_STUB = """#!/usr/bin/env python3
import json, os, sys, time
args = sys.argv[1:]
if "--list" in args:
    sys.exit(0)
side = "base" if "--root" in args else "head"
results = args[args.index("--results") + 1]
deadline = args[args.index("--deadline") + 1] if "--deadline" in args else "none"
steps = [args[n + 1] for n, arg in enumerate(args) if arg == "--step"]
log = os.environ["STUB_LOG"]
with open(log, "a") as out:
    out.write(f"start {side} {deadline} {time.time()} {','.join(steps)}\\n")
time.sleep(float(os.environ.get("STUB_SLEEP_" + side.upper(), "0")))
found = json.loads(os.environ["STUB_" + side.upper()])
body = {"_cmux_complete": os.environ.get("STUB_CUT_" + side.upper()) != "1"}
body.update({step: found[step] for step in steps if step in found})
with open(results, "w") as out:
    json.dump(body, out)
with open(log, "a") as out:
    out.write(f"end {side} {time.time()}\\n")
print(f"cmux guards: stub {side}")
sys.exit(0 if all(body[step] for step in steps if step in body) else 1)
"""


class GuardsReached(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        repo = self.repo = self.tmp / "repo"
        (repo / "scripts/ci").mkdir(parents=True)
        shutil.copy(SCRIPT, repo / "scripts/ci/guards_reached.sh")
        shutil.copy(NEW_REDS, repo / "scripts/ci/guards_new_reds.py")
        (repo / "scripts/ci/guard_step_inputs.py").write_text(PLAN_STUB)
        runner = repo / "scripts/ci/guards-local.sh"
        runner.write_text(RUNNER_STUB)
        runner.chmod(0o755)
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "stub.txt").write_text("base\n")
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run([*git, "commit", "-qm", "base"], check=True)
        (repo / "stub.txt").write_text("head\n")
        subprocess.run([*git, "commit", "-qam", "head"], check=True)
        self.log = self.tmp / "runs.log"

    def run_it(self, head, base, *, sleep_head=0.0, sleep_base=0.0, budget=None, cut_head=False):
        env = {key: value for key, value in os.environ.items() if not key.startswith(("STUB_", "GUARDS_REACHED"))}
        env.update(STUB_STEPS=",".join(sorted(head)), STUB_HEAD=json.dumps(head), STUB_BASE=json.dumps(base),
                   STUB_SLEEP_HEAD=str(sleep_head), STUB_SLEEP_BASE=str(sleep_base), STUB_LOG=str(self.log))
        if cut_head:
            env["STUB_CUT_HEAD"] = "1"
        if budget is not None:
            env["GUARDS_REACHED_BUDGET"] = budget
        started = time.monotonic()
        done = subprocess.run(["bash", str(self.repo / "scripts/ci/guards_reached.sh")], cwd=self.repo, env=env,
                              capture_output=True, text=True, timeout=120)
        return done, time.monotonic() - started

    def runs(self):
        found = {}
        for line in self.log.read_text().splitlines():
            word, side, *rest = line.split()
            found.setdefault(side, {})[word] = rest
        return found

    def test_the_base_pass_runs_beside_the_head_and_judges_its_reds(self):
        done, seconds = self.run_it({"old": False, "mine": False, "fine": True},
                                    {"old": False, "mine": True, "fine": True}, sleep_head=3, sleep_base=3)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertIn("guard red step (base): old", done.stdout)
        self.assertIn("guard red step (new): mine", done.stdout)
        self.assertNotIn("fine", "".join(line for line in done.stdout.splitlines() if "red step" in line))
        runs = self.runs()
        # The base started before the head finished: the two 3 s passes overlap, not one after the other.
        self.assertLess(float(runs["base"]["start"][1]), float(runs["head"]["end"][0]))
        self.assertLess(seconds, 5.8, done.stdout)
        # Both passes cover every reached step.
        self.assertEqual(runs["base"]["start"][2], runs["head"]["start"][2])

    def test_only_base_reds_still_fail_nothing(self):
        done, _ = self.run_it({"old": False, "fine": True}, {"old": False, "fine": True})
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("guard red step (base): old", done.stdout)
        self.assertIn("0 guard steps red on this change, 1 red on the base too", done.stdout)

    def test_a_green_head_stops_the_base_pass(self):
        done, seconds = self.run_it({"fine": True}, {"fine": True}, sleep_base=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("every reached step passed", done.stdout)
        self.assertLess(seconds, 30, done.stdout)
        self.assertNotIn("end", self.runs()["base"])

    def test_a_cut_short_green_head_is_not_a_pass(self):
        done, _ = self.run_it({"fine": True}, {"fine": True}, cut_head=True)
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertNotIn("every reached step passed", done.stdout)
        self.assertIn("::error title=Guard run timed out::", done.stdout)

    def test_both_passes_get_the_one_budget(self):
        self.run_it({"fine": True}, {"fine": True}, budget="300")
        runs = self.runs()
        self.assertEqual((runs["head"]["start"][0], runs["base"]["start"][0]), ("300", "300"))

    def test_a_budget_that_is_not_a_number_of_seconds_falls_back(self):
        for budget in ("0", "abc", "5", "$(true)"):
            with self.subTest(budget=budget):
                self.log.unlink(missing_ok=True)
                self.run_it({"fine": True}, {"fine": True}, budget=budget)
                self.assertEqual(self.runs()["head"]["start"][0], "840")

    def test_the_default_budget_fits_inside_the_steps_timeout(self):
        steps = (ROOT / "ci/steps.toml").read_text(encoding="utf-8")
        block = steps[steps.index("[step.guard-steps-reached]"):]
        timeout = int(block.split("timeout = ", 1)[1].split("\n", 1)[0])
        self.assertGreaterEqual(timeout - 840, 45, "the default budget leaves the plan and the compare no time")


if __name__ == "__main__":
    unittest.main()
