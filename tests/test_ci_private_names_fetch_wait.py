#!/usr/bin/env python3
"""private-names.yml waits once for a refused budget before failing the checker fetch, and gives the checker room.

cmux runs 45960905805 and 45960538227 (2026-11-27 07:44-07:47Z) were refused on every token and went red with
"rerun this check"; the rerun after the hour's reset is green, a false red. The step now fetches the checker on
both App tokens, and when each was refused for budget (403/429 with x-ratelimit-remaining 0 or Retry-After) it
sleeps to the soonest reset, at most FETCH_WAIT_S, and fetches once more. A further reset, a second refusal or a
permission refusal still fails the step. PRIVATE_NAMES_READ_BOUND_S lets the checker's own reads wait the same way
(cmuxterm-hq tools/agent-guards/private_names.py), and the job's timeout holds both waits.

The checker is read over git first (cmuxterm-hq main, a shallow blobless fetch and one blob), which spends no
REST quota: the contents API read cost cmux-bot (installation 175618676) one call per run, about 630 runs an hour,
in an installation that reaches 12,500 used about 30 minutes after each reset (hq reconciler-state/app-spend
hourly.txt, 11-28 09:51-13:51Z). The REST rounds above run only when the git read fails on every token.

Run: python3 tests/test_ci_private_names_fetch_wait.py
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "private-names.yml"
STEP = "Check the pull request for private names"

# Each call takes the next answer from $PLAN (comma separated): `200`, `403spent:SECONDS` (quota, resets SECONDS
# from now), `403perm` (a permission refusal) or `429after:SECONDS` (Retry-After).
FAKE_CURL = r"""#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
log = os.environ["CURL_LOG"]
calls = open(log).read().split() if os.path.exists(log) else []
open(log, "a").write("call\n")
answer = os.environ["PLAN"].split(",")[len(calls)]
headers = args[args.index("-D") + 1]
out = args[args.index("-o") + 1]
code, _, arg = answer.partition(":")
lines = []
if code == "200":
    open(out, "w").write("import sys\nsys.exit(0)\n")
elif code == "403spent":
    lines = ["x-ratelimit-remaining: 0", f"x-ratelimit-reset: {int(time.time()) + int(arg)}"]
elif code == "429after":
    lines = [f"Retry-After: {arg}"]
open(headers, "w").write("HTTP/2 " + code[:3] + "\r\n" + "".join(l + "\r\n" for l in lines) + "\r\n")
sys.stdout.write(code[:3])
"""


# Each `fetch` takes the next answer from $GIT_PLAN (comma separated): `ok` or `fail`. The tokens each fetch was
# sent with are logged to $GIT_LOG. init, remote add and cat-file always work; cat-file writes a checker that exits 0.
FAKE_GIT = r"""#!/usr/bin/env python3
import base64, os, sys
args = sys.argv[1:]
sub = next((a for a in args if a in ("init", "remote", "fetch", "cat-file")), "")
if sub == "fetch":
    log = os.environ["GIT_LOG"]
    calls = open(log).read().split() if os.path.exists(log) else []
    header = next(a for a in args if a.startswith("http.https://github.com/.extraheader="))
    token = base64.b64decode(header.split("basic ", 1)[1]).decode().split(":", 1)[1]
    open(log, "a").write(token + "\n")
    plan = os.environ["GIT_PLAN"].split(",")
    sys.exit(0 if plan[len(calls)] == "ok" else 128)
if sub == "cat-file":
    sys.stdout.write("import sys\nsys.exit(0)\n")
sys.exit(0)
"""


def step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["check"]["steps"]
    return next(s for s in steps if s.get("name") == STEP)


class FetchWait(unittest.TestCase):
    def run_step(self, plan: str, *, route: str = "route-token", git_plan: str = "fail,fail") -> tuple[int, int, list[str], str]:
        root = Path(tempfile.mkdtemp(prefix="private-names-fetch-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        slept = root / "slept"
        for name, text in (("curl", FAKE_CURL), ("git", FAKE_GIT), ("sleep", f'#!/bin/sh\necho "$1" >> "{slept}"\n')):
            path = bin_dir / name
            path.write_text(text)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        temp = root / "runner-temp"
        temp.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
        env.update({k: str(v) for k, v in step()["env"].items() if not str(v).startswith("${{")})
        env.update(BOT_TOKEN="bot-token", ROUTE_TOKEN=route, GH_TOKEN="job", PR_READ_TOKENS="bot-token", PR_NUMBER="7",
                   GITHUB_REPOSITORY_OWNER="o", GITHUB_REPOSITORY="o/r", RUNNER_TEMP=str(temp), PLAN=plan,
                   CURL_LOG=str(root / "curl.log"), GIT_PLAN=git_plan, GIT_LOG=str(root / "git.log"), PATH=f"{bin_dir}:{env.get('PATH', '/usr/bin:/bin')}")
        done = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", step()["run"]],
                              cwd=root, env=env, capture_output=True, text=True, timeout=60)
        calls = len((root / "curl.log").read_text().split()) if (root / "curl.log").exists() else 0
        sleeps = slept.read_text().split() if slept.exists() else []
        self.git_tokens = (root / "git.log").read_text().split() if (root / "git.log").exists() else []
        return done.returncode, calls, sleeps, done.stdout + done.stderr

    def test_a_git_read_spends_no_rest_call(self) -> None:
        rc, calls, sleeps, out = self.run_step("", git_plan="ok")
        self.assertEqual((rc, calls, sleeps), (0, 0, []), out)
        self.assertEqual(self.git_tokens, ["bot-token"])
        self.assertIn("checker read over git with BOT_TOKEN (no REST call)", out)

    def test_a_failed_git_read_on_one_token_tries_the_other_over_git(self) -> None:
        rc, calls, _, out = self.run_step("", git_plan="fail,ok")
        self.assertEqual((rc, calls), (0, 0), out)
        self.assertEqual(self.git_tokens, ["bot-token", "route-token"])

    def test_a_failed_git_read_on_every_token_falls_back_to_the_contents_api(self) -> None:
        rc, calls, sleeps, out = self.run_step("200")
        self.assertEqual((rc, calls, sleeps), (0, 1, []), out)
        self.assertEqual(self.git_tokens, ["bot-token", "route-token"])

    def test_the_git_read_is_of_hq_main_on_a_remote_not_named_origin(self) -> None:
        run = step()["run"]
        self.assertIn('remote add hq "https://github.com/${GITHUB_REPOSITORY_OWNER}/cmuxterm-hq.git"', run)
        self.assertIn("fetch --quiet --no-tags --depth=1 --filter=blob:none hq main", run)
        self.assertIn("FETCH_HEAD:tools/agent-guards/private_names.py", run)
        self.assertLess(run.index("if git_fetch; then"), run.index("elif ! fetch_round"))

    def test_the_waits_fit_the_job_timeout(self) -> None:
        env = step()["env"]
        timeout = yaml.safe_load(WORKFLOW.read_text())["jobs"]["check"]["timeout-minutes"]
        self.assertLessEqual(timeout, 10)
        self.assertGreaterEqual(timeout * 60, int(env["FETCH_WAIT_S"]) + int(env["PRIVATE_NAMES_READ_BOUND_S"]) + 30)

    def test_a_first_fetch_is_untouched(self) -> None:
        rc, calls, sleeps, out = self.run_step("200")
        self.assertEqual((rc, calls, sleeps), (0, 1, []), out)

    def test_both_spent_waits_for_the_soonest_reset_and_fetches_again(self) -> None:
        rc, calls, sleeps, out = self.run_step("403spent:200,403spent:90,403spent:200,200")
        self.assertEqual(rc, 0, out)
        self.assertEqual(calls, 4)
        self.assertEqual(len(sleeps), 1)
        self.assertTrue(90 <= int(sleeps[0]) <= 100, sleeps)

    def test_retry_after_is_honored(self) -> None:
        rc, _, sleeps, out = self.run_step("429after:30,200", route="")
        self.assertEqual(rc, 0, out)
        self.assertTrue(30 <= int(sleeps[0]) <= 40, sleeps)

    def test_a_reset_past_the_bound_fails_without_waiting(self) -> None:
        rc, calls, sleeps, out = self.run_step("403spent:3000,403spent:3000")
        self.assertEqual((rc, calls, sleeps), (1, 2, []), out)
        self.assertIn("rerun this check", out)

    def test_a_second_refusal_fails(self) -> None:
        rc, calls, sleeps, _ = self.run_step("403spent:30,403spent:30,403spent:3000,403spent:3000")
        self.assertEqual((rc, calls, len(sleeps)), (1, 4, 1))

    def test_a_permission_refusal_is_not_waited_on(self) -> None:
        rc, _, sleeps, _ = self.run_step("403perm,403perm")
        self.assertEqual((rc, sleeps), (1, []))


if __name__ == "__main__":
    unittest.main()
