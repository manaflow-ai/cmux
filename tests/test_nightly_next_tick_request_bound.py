#!/usr/bin/env python3
"""The nightly-next tick's promotion request is bounded in time.

On 2026-11-26 ticks sat 30+ minutes in "Request nightly-next promotion on main": the walk
asked 35 refused feat-cmux-next commits one by one, single commits taking up to 5 minutes in
rate-limit waits, and every later tick queued behind it in the one 'nightly-next-tick' group.
The feed stood still from 23:41Z (11-25) until a promotion by hand at 02:45Z.

These tests run the step's real script in a scratch repository whose commits carry a fake
request-nightly-next.sh, and check that a commit that never answers costs at most
TICK_COMMIT_SECONDS and the walk at most TICK_WALK_BUDGET_SECONDS.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TICK = ROOT / ".github" / "workflows" / "nightly-next-tick.yml"
STEP = "Request nightly-next promotion on main"

# One script in every commit; what each commit does comes from $BEHAVIOR/<sha>.
FAKE_REQUEST = """#!/usr/bin/env bash
sha="$2"
case "$(cat "$BEHAVIOR/$sha" 2>/dev/null)" in
  hang) sleep 60 ;;
  slow) sleep 1.2; echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet" ;;
  request) echo "requested nightly-next promotion of ${sha:0:12}" ;;
  broken) echo "boom" >&2; exit 3 ;;
  *) echo "not promoting ${sha:0:12}: the nightly cannot resolve a published cmux-tui tree for it yet" ;;
esac
"""


def request_step() -> dict:
    steps = yaml.safe_load(TICK.read_text(encoding="utf-8"))["jobs"]["request"]["steps"]
    return next(step for step in steps if step.get("name") == STEP)


@unittest.skipUnless(shutil.which("timeout") and shutil.which("git"), "needs coreutils timeout and git")
class RequestWalkBoundTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="tick-bound-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = self.tmp / "repo"
        self.behavior = self.tmp / "behavior"
        self.bin = self.tmp / "bin"
        self.runner_temp = self.tmp / "runner"
        for d in (self.repo, self.behavior, self.bin, self.runner_temp):
            d.mkdir()
        gh = self.bin / "gh"
        gh.write_text("#!/usr/bin/env bash\nexit 0\n")
        gh.chmod(0o755)
        git = ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q", "-b", "main"], check=True)
        script = self.repo / "scripts/cmux-next/request-nightly-next.sh"
        script.parent.mkdir(parents=True)
        script.write_text(FAKE_REQUEST)
        script.chmod(0o755)
        self.shas: list[str] = []
        for i in range(4):
            (self.repo / "n.txt").write_text(str(i))
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-q", "-m", f"c{i}"], check=True)
            self.shas.append(subprocess.run([*git, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip())
        self.shas.reverse()  # newest first, as the walk goes
        self.script = self.tmp / "step.sh"
        self.script.write_text(request_step()["run"])

    def behave(self, *kinds: str) -> None:
        for sha, kind in zip(self.shas, kinds):
            (self.behavior / sha).write_text(kind)

    def run_step(self, **env: str) -> tuple[subprocess.CompletedProcess, float]:
        full = {k: str(v) for k, v in request_step().get("env", {}).items()}
        full.update(os.environ)
        full.update(
            PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            RUNNER_TEMP=str(self.runner_temp),
            GITHUB_REPOSITORY="example/repo",
            BEHAVIOR=str(self.behavior),
            GIT_TERMINAL_PROMPT="0",
        )
        full.update(env)
        started = time.monotonic()
        result = subprocess.run(["bash", str(self.script)], cwd=self.repo, env=full, capture_output=True, text=True, timeout=40)
        return result, time.monotonic() - started

    def test_a_commit_that_never_answers_is_a_refusal_and_the_walk_goes_on(self) -> None:
        self.behave("hang", "request")
        result, took = self.run_step(TICK_COMMIT_SECONDS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"not promoting {self.shas[0][:12]}: its request did not answer within 1s", result.stdout)
        self.assertIn(f"requested nightly-next promotion of {self.shas[1][:12]}", result.stdout)
        self.assertLess(took, 25)

    def test_the_walk_stops_at_its_budget_and_still_tallies_the_refusals(self) -> None:
        self.behave("slow", "slow", "slow", "slow")
        result, _ = self.run_step(TICK_WALK_BUDGET_SECONDS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::notice title=nightly-next tick::walk budget of 1s spent", result.stdout)
        asked = result.stdout.count("answered in")
        self.assertGreaterEqual(asked, 1)
        self.assertLess(asked, len(self.shas))
        self.assertIn("::warning title=nightly-next tick::no newer feat-cmux-next commit is promotable", result.stdout)

    def test_each_commit_logs_how_long_it_took(self) -> None:
        self.behave("refuse", "request")
        result, _ = self.run_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"({self.shas[0][:12]} answered in ", result.stdout)

    def test_a_request_that_fails_still_fails_the_step(self) -> None:
        self.behave("broken", "request")
        result, _ = self.run_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("boom", result.stdout)
        self.assertNotIn("requested nightly-next promotion", result.stdout)


class RequestStepBoundsTests(unittest.TestCase):
    def test_the_step_and_its_waits_are_bounded(self) -> None:
        job = yaml.safe_load(TICK.read_text(encoding="utf-8"))["jobs"]["request"]
        step = request_step()
        minutes = int(step["timeout-minutes"])
        self.assertLessEqual(minutes, 30)
        env = step["env"]
        walk = int(env["TICK_WALK_BUDGET_SECONDS"])
        commit = int(env["TICK_COMMIT_SECONDS"])
        # The last commit may start just before the walk budget runs out.
        self.assertLess(walk + commit, minutes * 60)
        # A commit outlasts the step's rate-limit waits, so a promotion waiting out a limit is not cut off.
        self.assertLess(int(env["GH_BUDGET_WAIT_MAX_SECONDS"]), commit)
        self.assertGreaterEqual(int(job["timeout-minutes"]), minutes + 10)
        self.assertNotIn("cancel-in-progress: true", TICK.read_text(encoding="utf-8"))

    def test_the_tooling_checkouts_are_shallow_and_not_promisor_clones(self) -> None:
        # actions/checkout turns sparse-checkout into --filter=blob:none, and the blobs then come
        # over a lazy fetch at checkout: on 2026-11-26 it stalled ("Operation too slow", "could not
        # fetch ... from promisor remote") and the tick died before it asked for anything.
        doc = yaml.safe_load(TICK.read_text(encoding="utf-8"))
        found = 0
        for name, job in doc["jobs"].items():
            for step in job["steps"]:
                if str(step.get("uses", "")).startswith("actions/checkout@") and step.get("with", {}).get("path") == ".tick-tooling":
                    found += 1
                    self.assertNotIn("sparse-checkout", step["with"], name)
                    self.assertNotIn("filter", step["with"], name)
                    self.assertEqual(step["with"].get("fetch-depth"), 1, name)
        self.assertEqual(found, 4)  # a try and its retry in each of request and unstick (#58127)


if __name__ == "__main__":
    unittest.main()
