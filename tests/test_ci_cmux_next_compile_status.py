#!/usr/bin/env python3
"""cmux-next/compile: the controller's Release compile of the exact head, published fail-closed.

The status step runs here as written in cmux-next.yml, with a stand-in `curl` that serves the
compile-check reply and records each status post.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next.yml"
SHA = "a" * 40
REPO = "manaflow-ai/cmux"

# A curl that answers the compile-check read from $REPLY (exit 22, curl's --fail code, when it is
# missing: a 404) and appends every status post's body to $POSTS.
FAKE_CURL = r'''#!/usr/bin/env bash
out="" body="" url=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    --max-time) echo "max-time $2" >> "$READS.opts"; shift 2 ;;
    -X|-H|--connect-timeout|--retry|--retry-delay|--retry-max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */statuses/* ]]; then
  [[ -n "${POST_FAILS:-}" ]] && exit 22
  printf '%s\n' "$body" >> "$POSTS"; exit 0
fi
printf '%s\n' "$url" >> "$READS"
[[ -f "$REPLY" ]] || exit 22
cp "$REPLY" "$out"
'''


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["compile-status"]


def step_script() -> str:
    return next(step["run"] for step in job()["steps"] if "run" in step)


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class StatusMapping(unittest.TestCase):
    def run_step(self, reply: dict | None, **env: str) -> tuple[int, list[dict], list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            if reply is not None:
                Path(tmp, "reply.json").write_text(json.dumps(reply))
            done = subprocess.run(
                ["bash", "-c", step_script()], capture_output=True, text=True, timeout=60,
                env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp, "GH_TOKEN": "t", "SHA": SHA,
                     "REPO": REPO, "API": f"https://api.github.com/repos/{REPO}", "RUN_URL": "https://github.com/run/1",
                     "RESULTS": "https://results/v1", "REPLY": str(Path(tmp, "reply.json")),
                     "POSTS": str(Path(tmp, "posts")), "READS": str(Path(tmp, "reads")), **env})
            posts = [json.loads(line) for line in Path(tmp, "posts").read_text().splitlines()] \
                if Path(tmp, "posts").exists() else []
            reads = Path(tmp, "reads").read_text().splitlines() if Path(tmp, "reads").exists() else []
            return done.returncode, posts, reads

    def reply(self, state: str, **overrides) -> dict:
        return {"repo": REPO, "sha": SHA, "job_id": "j", "state": state, "configuration": "release-onone",
                "recipe_version": 2, "updated_at": "now", "log_url": "https://github.com/manaflow-ai/cmux/actions/runs/9",
                **overrides}

    def test_pass_is_success_and_everything_else_fails_closed(self):
        for reply, state, ok in (
            (self.reply("pass"), "success", True),
            (self.reply("fail"), "failure", False),
            (self.reply("unavailable"), "failure", False),
            (self.reply("pass", sha="b" * 40), "failure", False),
            (self.reply("pass", repo="someone/cmux"), "failure", False),
            (self.reply("pass", recipe_version=1), "failure", False),
            (self.reply("pass", configuration="debug"), "failure", False),
            (self.reply("running"), "failure", False),
            (None, "failure", False),
        ):
            with self.subTest(reply=reply):
                code, posts, _ = self.run_step(reply)
                self.assertEqual(code == 0, ok)
                self.assertEqual([(post["state"], post["context"]) for post in posts],
                                 [("pending", "cmux-next/compile"), (state, "cmux-next/compile")])

    def test_a_failure_links_the_compile_log(self):
        _, posts, _ = self.run_step(self.reply("fail"))
        self.assertEqual(posts[-1]["target_url"], "https://github.com/manaflow-ai/cmux/actions/runs/9")
        # A link elsewhere is not trusted: the run itself.
        _, posts, _ = self.run_step(self.reply("fail", log_url="https://evil.example/x"))
        self.assertEqual(posts[-1]["target_url"], "https://github.com/run/1")

    def test_the_wait_is_one_blocking_read_per_attempt_and_bounded(self):
        _, _, reads = self.run_step(self.reply("pass"))
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&wait=1800"])
        _, _, reads = self.run_step(self.reply("running"))
        self.assertLessEqual(len(reads), 3)
        # Every read asks for no more than what is left of the overall deadline.
        _, posts, reads = self.run_step(self.reply("running"), WAIT_SECONDS="400")
        self.assertTrue(all(read.endswith("&wait=340") or int(read.rsplit("=", 1)[1]) <= 340 for read in reads), reads)
        self.assertEqual(posts[-1]["state"], "failure")

    def test_the_whole_wait_fits_the_step_and_the_token_hour(self):
        step = next(step for step in job()["steps"] if "run" in step)
        self.assertIn("timeout \"$left\" curl", step["run"])
        self.assertIn("WAIT_SECONDS:-2400", step["run"])
        # The deadline starts before the pending post, and the terminal post (3 tries of 30 s, 2 waits
        # of 10 s) fits after it: 40 min + 110 s, inside the step's 50, the job's 55 and the token's 60.
        run = step["run"]
        self.assertLess(run.index("deadline=$((SECONDS"), run.index("post pending"))
        self.assertIn("timeout 110 curl -sS --fail-with-body", run)
        self.assertLessEqual(2400 + 110, step["timeout-minutes"] * 60 - 300)
        self.assertLessEqual(step["timeout-minutes"], job()["timeout-minutes"])
        self.assertLess(job()["timeout-minutes"], 60)

    def test_a_failed_post_is_a_red_job(self):
        code, _, _ = self.run_step(self.reply("pass"), POST_FAILS="1")
        self.assertNotEqual(code, 0)

    def test_the_script_never_sleeps(self):
        self.assertNotIn("sleep", step_script())


class Placement(unittest.TestCase):
    def test_same_repository_prs_and_base_pushes_only_with_no_checkout(self):
        j = job()
        for needle in ("github.event.pull_request.head.repo.full_name == github.repository",
                       "github.ref == 'refs/heads/feat-cmux-next'", "needs.path_route.outputs.native == 'true'"):
            self.assertIn(needle, j["if"])
        self.assertEqual(j["permissions"], {})
        self.assertFalse(any("actions/checkout" in str(step.get("uses", "")) for step in j["steps"]))
        mint = next(step for step in j["steps"] if "create-github-app-token" in str(step.get("uses", "")))
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        self.assertIn("secrets.CMUX_BOT_APP_KEY", mint["with"]["private-key"])
        self.assertIn("'pull_request' && 'ci-routing-agent' || ''", j["environment"])


if __name__ == "__main__":
    unittest.main()
