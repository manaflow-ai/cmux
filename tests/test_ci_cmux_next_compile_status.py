#!/usr/bin/env python3
"""cmux-next/compile: the controller's Release compile of the exact head, published fail-closed.

The status step runs here as written in cmux-next.yml, with a stand-in `curl` that serves the
compile-check reply and records each status post.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
# CMUX_NEXT_WORKFLOW: run the checks against another copy (the detector against an older workflow).
WORKFLOW = Path(os.environ.get("CMUX_NEXT_WORKFLOW") or ROOT / ".github" / "workflows" / "cmux-next.yml")
SHA = "a" * 40
REPO = "manaflow-ai/cmux"

# A curl that answers the compile-check read from $REPLY (HTTP 404 when it is missing) and appends every status
# post's body to $POSTS. $CODES (space-separated) overrides the HTTP code of each result read in turn, the last one
# repeating; a probe (-o /dev/null) answers $PROBE_CODE (404 by default) and is logged to $READS.probe.
# A status post answers $POST_REFUSALS (space-separated HTTP codes) to its first tries, with GitHub's rate-limit
# body unless $REFUSAL_BODY says otherwise and $REFUSAL_HEADERS as its headers; every try is logged to $POSTS.tries.
FAKE_CURL = r'''#!/usr/bin/env bash
out="" body="" url="" fmt="" hdr=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
    --max-time) echo "max-time $2" >> "$READS.opts"; shift 2 ;;
    -X|-H|--connect-timeout|--retry|--retry-delay|--retry-max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == */statuses/* ]]; then
  printf '%s\n' "$body" >> "$POSTS.tries"
  [[ -n "${POST_FAILS:-}" ]] && exit 22
  n=$(wc -l < "$POSTS.tries"); refusals=(${POST_REFUSALS:-})
  if (( n <= ${#refusals[@]} )); then
    [[ -z "$out" ]] || printf '%s' "${REFUSAL_BODY:-{\"message\":\"You have exceeded a secondary rate limit.\"}}" > "$out"
    [[ -z "$hdr" ]] || printf '%b' "${REFUSAL_HEADERS:-}" > "$hdr"
    [[ -n "$fmt" ]] && printf '%s' "${refusals[$((n - 1))]}"
    exit 0
  fi
  printf '%s\n' "$body" >> "$POSTS"; [[ -n "$fmt" ]] && printf 201; exit 0
fi
if [[ "$out" == /dev/null ]]; then
  printf '%s\n' "$url" >> "$READS.probe"; code="${PROBE_CODE:-404}"
else
  printf '%s\n' "$url" >> "$READS"
  n=$(wc -l < "$READS"); codes=(${CODES:-}); code=""
  (( ${#codes[@]} )) && code="${codes[$(( n <= ${#codes[@]} ? n - 1 : ${#codes[@]} - 1 ))]}"
  [[ -n "$code" ]] || { [[ -f "$REPLY" ]] && code=200 || code=404; }
  [[ "$code" == 200 ]] && cp "$REPLY" "$out"
fi
[[ -n "$fmt" ]] && printf '%s' "$code"
[[ "$code" == 000 ]] && exit 7
exit 0
'''
# Fast gaps for the fake: the step's probe, re-read and bad-answer bounds are 30 s, 30 s and 300 s.
GAPS = {"PROBE_GAP": "0", "READ_GAP": "0", "POST_GAP": "0", "LIMIT_GAP": "0"}
# autoland's and base_red_excuse.py's no-verdict line (NO_VERDICT): a red that names no compile failure.
NO_VERDICT_LINE = re.compile(r"cmux-next/compile is not a pass for \S+ \((?!fail\))")


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["compile-status"]


def step_script() -> str:
    return next(step["run"] for step in job()["steps"] if "run" in step)


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class StatusMapping(unittest.TestCase):
    def run_step(self, reply: dict | None, **env: str) -> tuple[int, list[dict], list[str]]:
        if reply is None or reply.get("state") == "running":
            env = {"WAIT_SECONDS": "5", "READ_GAP": "1", **env}  # no terminal answer until the deadline: keep it short
        env = {**GAPS, "FALLBACK": "false", **env}
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            if reply is not None:
                Path(tmp, "reply.json").write_text(json.dumps(reply))
            done = subprocess.run(
                ["bash", "-e", "-c", step_script()], capture_output=True, text=True, timeout=60,
                env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp, "GH_TOKEN": "t", "SHA": SHA,
                     "REPO": REPO, "API": f"https://api.github.com/repos/{REPO}", "RUN_URL": "https://github.com/run/1",
                     "RESULTS": "https://results/v1", "REPLY": str(Path(tmp, "reply.json")),
                     "POSTS": str(Path(tmp, "posts")), "READS": str(Path(tmp, "reads")),
                     "GITHUB_OUTPUT": str(Path(tmp, "output")), **env})
            self.stdout, self.output = done.stdout, (Path(tmp, "output").read_text()
                                                     if Path(tmp, "output").exists() else "")
            self.tries = [json.loads(line)["state"] for line in Path(tmp, "posts.tries").read_text().splitlines()] \
                if Path(tmp, "posts.tries").exists() else []
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
        # The shared deadline: a read waits at most what is left of the bound for a usable answer (300 s) less 30 s.
        _, _, reads = self.run_step(self.reply("pass"))
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&wait=270"])
        # A pull request's read names it, so the controller can queue a head it never saw (cmuxterm-hq#5571).
        _, _, reads = self.run_step(self.reply("pass"), PR="28059")
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&pr=28059&wait=270"])
        _, _, reads = self.run_step(self.reply("pass"), PR="1;x")
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&wait=270"])
        _, _, reads = self.run_step(self.reply("pass"), BAD_BOUND="3000")
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&wait=1800"])
        # Every read asks for no more than what is left of the overall deadline, and gets --max-time of it.
        _, posts, reads = self.run_step(self.reply("running"), WAIT_SECONDS="12")
        self.assertTrue(reads and all(int(read.rsplit("=", 1)[1]) <= 6 for read in reads), reads)
        self.assertEqual(posts[-1]["state"], "failure")
        self.assertTrue(posts[-1]["description"].startswith("[no-verdict] No compile result for this head"))

    def test_the_whole_wait_fits_the_step_and_the_token_hour(self):
        step = next(step for step in job()["steps"] if "run" in step)
        self.assertIn("timeout \"$left\" curl", step["run"])
        self.assertIn("WAIT_SECONDS:-2400", step["run"])
        # The deadline starts before the pending post, and the terminal post (waits of at most POST_BUDGET, then
        # one try of at most 40 s) fits after it: 40 min + 640 s, inside the step's 56, the job's 58 and the token's 60.
        run = step["run"]
        self.assertLess(run.index("deadline=$((SECONDS"), run.index("post pending"))
        self.assertIn("timeout 40 curl -sS", run)
        self.assertIn("${POST_BUDGET:-600}", run)
        self.assertLessEqual(2400 + 600 + 40, step["timeout-minutes"] * 60 - 300)
        self.assertLessEqual(step["timeout-minutes"], job()["timeout-minutes"])
        self.assertLess(job()["timeout-minutes"], 60)

    def test_a_failed_post_is_a_red_job(self):
        code, _, _ = self.run_step(self.reply("pass"), POST_FAILS="1")
        self.assertNotEqual(code, 0)

    def test_a_rate_limited_pending_post_is_a_warning_and_the_verdict_still_posts(self):
        """2026-11-11 02:38Z: cmux-bot's status posts got GitHub's 403 rate limit for about ten minutes, and the pending
        post's three tries 10 s apart failed the job on #40351, #40942, #41007 and the base push before any compile
        was read. The pending status only shows the wait: it gives up at once, and the verdict decides."""
        code, posts, _ = self.run_step(self.reply("pass"), POST_REFUSALS="403", LIMIT_GAP="60")
        self.assertEqual((code, [p["state"] for p in posts]), (0, ["success"]))
        self.assertEqual(self.tries, ["pending", "success"])  # a rate limit waits a minute: over the pending budget
        self.assertIn("GitHub refused the pending status for cmux-next/compile after 1 tries: HTTP 403: "
                      "You have exceeded a secondary rate limit", self.stdout.replace('{"message":"', ""))
        self.assertIn("(rate limited)", self.stdout)

    def test_a_rate_limited_verdict_waits_and_posts(self):
        # PENDING_BUDGET=-1: the pending post takes the first refusal and gives up; the verdict meets the rest.
        code, posts, _ = self.run_step(self.reply("fail"), POST_REFUSALS="403 429 403", PENDING_BUDGET="-1")
        self.assertEqual((code, [p["state"] for p in posts]), (1, ["failure"]))
        self.assertEqual(self.tries, ["pending", "failure", "failure", "failure"])
        self.assertIn("posting again in 0 s", self.stdout)
        code, posts, _ = self.run_step(self.reply("pass"), POST_REFUSALS="000 403 503 403", PENDING_BUDGET="-1")
        self.assertEqual((code, [p["state"] for p in posts]), (0, ["success"]))
        # A Retry-After or an exhausted primary limit is waited out in full; past POST_BUDGET it is a red, said why.
        code, posts, _ = self.run_step(self.reply("pass"), POST_REFUSALS="403 403", POST_BUDGET="5", PENDING_BUDGET="-1",
                                       REFUSAL_HEADERS="retry-after: 30\r\n")
        self.assertEqual((code, posts), (1, []))
        self.assertIn("GitHub refused the success status for cmux-next/compile after 1 tries: HTTP 403", self.stdout)
        self.assertRegex(self.stdout, NO_VERDICT_LINE)  # "(pass)": no verdict, never a compile red

    def run_handoff(self, fast: str, mac: str, **env: str) -> tuple[int, list[dict], str]:
        """compile-status-handoff's publish step, as written, against the fake curl."""
        script = next(step["run"] for step in handoff_job()["steps"] if "run" in step)
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            done = subprocess.run(
                ["bash", "-e", "-c", script], capture_output=True, text=True, timeout=60,
                env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp, "GH_TOKEN": "t", "SHA": SHA,
                     "API": f"https://api.github.com/repos/{REPO}", "RUN_URL": "https://github.com/run/1",
                     "DOWN": "HTTP 530", "FAST": fast, "MAC": mac, "POSTS": str(Path(tmp, "posts")),
                     "READS": str(Path(tmp, "reads")), **GAPS, **env})
            self.tries = [json.loads(line)["state"] for line in Path(tmp, "posts.tries").read_text().splitlines()] \
                if Path(tmp, "posts.tries").exists() else []
            posts = [json.loads(line) for line in Path(tmp, "posts").read_text().splitlines()] \
                if Path(tmp, "posts").exists() else []
            return done.returncode, posts, done.stdout

    def test_the_handoff_waits_out_a_rate_limit_and_posts_the_fallbacks_verdict(self):
        code, posts, _ = self.run_handoff("skipped/", "success", POST_REFUSALS="403 429")
        self.assertEqual((code, [p["state"] for p in posts], self.tries), (0, ["success"], ["success"] * 3))
        code, posts, _ = self.run_handoff("failure/fail", "skipped", POST_REFUSALS="403")
        self.assertEqual((code, [p["state"] for p in posts]), (1, ["failure"]))
        # Past its budget it is a red that names the refused post, never a pass.
        code, posts, out = self.run_handoff("skipped/", "success", POST_REFUSALS="403 403", POST_BUDGET="5",
                                            REFUSAL_HEADERS="retry-after: 30\r\n")
        self.assertEqual((code, posts), (1, []))
        self.assertIn("could not post the fallback's verdict", out)

    def test_a_refused_terminal_post_still_prints_the_no_verdict_line(self):
        """A rate limit past POST_BUDGET on a failure post: the job's own ::error line still says why, so
        base_red_excuse.py reads it (NO_VERDICT for every state but fail)."""
        code, posts, _ = self.run_step(self.reply("unavailable"), POST_REFUSALS="403 403 403", POST_BUDGET="5",
                                       PENDING_BUDGET="-1", REFUSAL_HEADERS="retry-after: 30\r\n")
        self.assertEqual((code, posts), (1, []))
        self.assertRegex(self.stdout, NO_VERDICT_LINE)
        code, _, _ = self.run_step(self.reply("fail"), POST_REFUSALS="403 403 403", POST_BUDGET="5",
                                   PENDING_BUDGET="-1", REFUSAL_HEADERS="retry-after: 30\r\n")
        self.assertEqual(code, 1)
        self.assertIn("cmux-next/compile is not a pass for " + SHA + " (fail)", self.stdout)

    def test_a_refusal_that_is_no_rate_limit_is_final(self):
        for code_, body in (("403", '{"message":"Resource not accessible by integration"}'),
                            ("401", '{"message":"Bad credentials"}'), ("422", '{"message":"No commit found"}')):
            with self.subTest(code=code_):
                code, posts, _ = self.run_step(self.reply("pass"), POST_REFUSALS=f"{code_} {code_} {code_}",
                                               REFUSAL_BODY=body)
                self.assertEqual((code, posts), (1, []))
                self.assertEqual(self.tries, ["pending", "success"])  # one try each, no waiting on a bad token
                self.assertIn(f"HTTP {code_}: {body}", self.stdout)

    def test_every_cmux_next_compile_post_waits_out_a_rate_limit(self):
        """The detector of this class: every step that posts cmux-next/compile uses the one post(), which reads the
        answer, names it, and waits out a GitHub rate limit; no bare curl to the statuses API sits beside it."""
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        posters = {name: step["run"] for name, j in workflow.items() for step in j.get("steps", [])
                   if '"cmux-next/compile"' in step.get("run", "")}
        self.assertEqual(sorted(posters), ["compile-status", "compile-status-handoff"])
        body = lambda run: run[run.index("post() {"):run.index("\n}\n", run.index("post() {"))]
        canon = body(posters["compile-status"])
        for name, run in posters.items():
            with self.subTest(job=name):
                self.assertEqual(body(run), canon)
                self.assertEqual(len(re.findall(r"statuses/", run)), 1)
                self.assertNotIn("--retry-all-errors", run)
        for needle in ("(403|429)", "rate limit", "retry-after", "x-ratelimit-reset", "LIMIT_GAP:-60} << (tries - 1)",
                       '-o "$out"', 'said="HTTP $code: '):
            self.assertIn(needle, canon)

    def test_it_sleeps_only_between_probes_and_re_reads(self):
        sleeps = re.findall(r"sleep[^;\n]*", step_script())
        self.assertEqual(sorted(sleeps), ['sleep "$gap"', 'sleep "$pause"', 'sleep "${PROBE_GAP:-30}"'])
        self.assertIn("${READ_GAP:-30}", step_script())
        self.assertIn("${BAD_BOUND:-300}", step_script())
        # The shared deadline: each read's --max-time and timeout are what is left, never a fixed wait plus 30 s.
        self.assertIn('timeout "$left" curl', step_script())
        self.assertIn('--max-time "$left"', step_script())

    def test_a_530_hands_off_to_the_fallback_or_says_no_verdict(self):
        """The results service down (two 530 probes) is no verdict, never a compile failure or a pass."""
        code, posts, reads = self.run_step(self.reply("pass"), PROBE_CODE="530", FALLBACK="true")
        self.assertEqual((code, reads), (0, []))
        self.assertEqual([p["state"] for p in posts], ["pending", "pending"])
        self.assertIn("the Mac Release compile decides this head", posts[-1]["description"])
        self.assertEqual(self.output.strip(), "handoff=HTTP 530")
        code, posts, _ = self.run_step(self.reply("pass"), PROBE_CODE="530", FALLBACK="false")
        self.assertEqual(code, 1)
        self.assertEqual([p["state"] for p in posts], ["pending", "error"])
        self.assertIn("re-run this job", posts[-1]["description"])
        self.assertTrue(posts[-1]["description"].startswith("[no-verdict] "))
        self.assertRegex(self.stdout, NO_VERDICT_LINE)
        self.assertEqual(self.output, "")

    def test_a_service_that_answers_nothing_usable_is_down_after_the_bound(self):
        # Probes see a 404 (the service up), then every read is a 503 or a 530: handed off after BAD_BOUND.
        for bad in ("503", "530", "000", "403"):
            with self.subTest(code=bad):
                started = time.monotonic()
                code, posts, reads = self.run_step(None, CODES=bad, BAD_BOUND="3", READ_GAP="1", FALLBACK="true",
                                                   WAIT_SECONDS="2400")
                self.assertLess(time.monotonic() - started, 20)
                self.assertEqual(code, 0)
                self.assertTrue(self.output.startswith(f"handoff=HTTP {bad} for "), self.output)
                self.assertGreaterEqual(len(reads), 1)
        # A deadline shorter than the bound still hands a bad last answer off, never "no compile result".
        code, posts, _ = self.run_step(None, CODES="530", WAIT_SECONDS="3", READ_GAP="1", FALLBACK="true")
        self.assertEqual((code, [p["state"] for p in posts]), (0, ["pending", "pending"]))
        self.assertTrue(self.output.startswith("handoff=HTTP 530 for "), self.output)
        # A 404 (no result yet) is the service up: read again, and the pass that follows is the verdict.
        code, posts, reads = self.run_step(self.reply("pass"), CODES="404 404 200")
        self.assertEqual((code, len(reads), posts[-1]["state"]), (0, 3, "success"))
        # A bad answer between good ones restarts nothing: a 530 then the result is still the result.
        code, posts, _ = self.run_step(self.reply("fail"), CODES="530 200", BAD_BOUND="60")
        self.assertEqual((code, posts[-1]["state"]), (1, "failure"))


class Placement(unittest.TestCase):
    def test_the_fallback_is_named_where_one_runs(self):
        fallback = next(step for step in job()["steps"] if "run" in step)["env"]["FALLBACK"]
        for needle in ("needs.push-head-preflight.outputs.current == 'true'", "github.event_name == 'push'",
                       "contains(github.event.pull_request.labels.*.name, 'full-ci')",
                       "needs.path_route.outputs.mac_release == 'true'"):
            self.assertIn(needle, fallback)
        self.assertEqual(job()["needs"], ["path_route", "push-head-preflight"])
        self.assertEqual(job()["outputs"]["handoff"], "${{ steps.wait.outputs.handoff }}")
        # The fallback's own conditions: release-compile runs for a push (when release-compile-fast has no verdict)
        # and for a full-ci or mac_release same-repository pull request.
        release = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile"]["if"]
        for needle in ("github.event_name != 'pull_request'", "contains(github.event.pull_request.labels.*.name, 'full-ci')",
                       "needs.path_route.outputs.mac_release == 'true'", "needs.push-head-preflight.outputs.current == 'true'"):
            self.assertIn(needle, release)

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



@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class FastCheckLinuxRoute(unittest.TestCase):
    """release-compile-fast with no idle gateway runner reads the same fleet result on Linux instead of
    skipping into the Mac queue (2026-11-02: pushes 622a6b75 and 0fa148c5 queued their Mac Release compile over
    two hours while this result had passed both). Pass and fail are verdicts; anything else is unavailable, and
    the Mac fallback runs. A fail keeps the step red, as the gateway path's does."""

    def run_step(self, reply: dict | None, gateway: str = "", **env: str) -> tuple[int, str, list[str]]:
        if reply is None or reply.get("state") == "running":
            env = {**env, "WAIT_SECONDS": "5", "READ_GAP": "1"}  # no terminal answer until the deadline: keep it short
        env = {**GAPS, **env}
        step = next(step for step in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
                    ["release-compile-fast"]["steps"] if step.get("id") == "compile")
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            curl = bin_dir / "curl"
            curl.write_text(FAKE_CURL)
            curl.chmod(0o755)
            if reply is not None:
                Path(tmp, "reply.json").write_text(json.dumps(reply))
            output = Path(tmp, "output")
            done = subprocess.run(
                ["bash", "-e", "-c", step["run"]], capture_output=True, text=True, timeout=60,
                env={"PATH": f"{bin_dir}:{os.environ['PATH']}", "RUNNER_TEMP": tmp, "REF": SHA, "REPO": REPO,
                     "GATEWAY": gateway, "RESULTS": "https://results/v1", "GITHUB_OUTPUT": str(output),
                     "HOME": tmp, "RUNNER_NAME": "r", "REPLY": str(Path(tmp, "reply.json")),
                     "POSTS": str(Path(tmp, "posts")), "READS": str(Path(tmp, "reads")), **env})
            verdict = dict(line.split("=", 1) for line in output.read_text().splitlines()).get("verdict", "") \
                if output.exists() else ""
            reads = Path(tmp, "reads").read_text().splitlines() if Path(tmp, "reads").exists() else []
            return done.returncode, verdict, reads

    def reply(self, state: str, **overrides) -> dict:
        return {"repo": REPO, "sha": SHA, "state": state, "configuration": "release-onone", "recipe_version": 2,
                **overrides}

    def test_the_fleet_result_is_the_verdict_fail_closed(self):
        for reply, verdict, ok in (
            (self.reply("pass"), "pass", True),
            (self.reply("fail"), "fail", False),
            (self.reply("unavailable"), "unavailable", True),
            (self.reply("pass", sha="b" * 40), "unavailable", True),
            (self.reply("pass", repo="someone/cmux"), "unavailable", True),
            (self.reply("pass", recipe_version=1), "unavailable", True),
            (self.reply("pass", configuration="debug"), "unavailable", True),
            (self.reply("running"), "unavailable", True),
            (None, "unavailable", True),
        ):
            with self.subTest(reply=reply):
                code, got, reads = self.run_step(reply, WAIT_SECONDS="400")
                self.assertEqual((got, code == 0), (verdict, ok))
                self.assertTrue(reads and all(read.startswith(f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&wait=")
                                              for read in reads), reads)

    def test_a_gateway_runner_submits_its_own_check_and_never_reads_the_result(self):
        # No client on this stand-in gateway: the existing path's unavailable, with no result read.
        code, verdict, reads = self.run_step(self.reply("pass"), gateway="glaeda-gateway-xcode-26.6")
        self.assertEqual((code, verdict, reads), (0, "unavailable", []))

    def test_a_service_down_after_the_probes_hands_off_after_the_bound(self):
        started = time.monotonic()
        code, verdict, reads = self.run_step(self.reply("pass"), CODES="530", BAD_BOUND="3", READ_GAP="1")
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual((code, verdict), (0, "unavailable"))
        self.assertGreaterEqual(len(reads), 1)
        code, verdict, reads = self.run_step(self.reply("pass"), PROBE_CODE="530")
        self.assertEqual((code, verdict, reads), (0, "unavailable", []))

    def test_the_wait_fits_the_job(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile-fast"]
        run = next(step["run"] for step in job["steps"] if step.get("id") == "compile")
        self.assertIn("WAIT_SECONDS:-1200", run)
        self.assertLessEqual(1200 + 120, job["timeout-minutes"] * 60 - 300)


def base_red_excuse():
    """scripts/ci/base_red_excuse.py, the consumer of the no-verdict descriptions."""
    sys.path.insert(0, str(ROOT / "scripts/ci"))
    import base_red_excuse as module  # noqa: PLC0415
    return module


def handoff_job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["compile-status-handoff"]


class ResultsServer(http.server.ThreadingHTTPServer):
    """The results service and the statuses API on 127.0.0.1: every results read answers `code` (a 530 is the proxy
    saying the origin is down), every status post is kept."""

    def __init__(self, code: int):
        # probe_code: what the first two reads (the probes) answer, else `code`; stall: a later read never answers.
        self.code, self.probe_code, self.stall, self.posts, self.reads = code, None, False, [], []
        self.release = threading.Event()
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                server.reads.append(self.path)
                probe = len(server.reads) <= 2  # the step's two probes come first
                if server.stall and not probe:
                    server.release.wait(60)  # a stalled response: the connection open, no answer
                    return
                self.send_response(server.probe_code if probe and server.probe_code else server.code)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(b"<html>error code: 1033</html>")

            def do_POST(self):
                server.posts.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(201)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b"{}")

        super().__init__(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server_address[1]}"


@unittest.skipUnless(shutil.which("jq") and shutil.which("curl"), "jq or curl is not installed")
class ResultsServiceDown(unittest.TestCase):
    """The stop condition of the change, end to end with the real curl: a head whose results service answers 530
    gets a verdict from the fallback Release compile, not "No compile result for this head in 40 minutes"."""

    def setUp(self):
        self.server = ResultsServer(530)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.release.set)

    def bash(self, script: str, **env: str) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp, "output")
            done = subprocess.run(
                ["bash", "-e", "-c", script], capture_output=True, text=True, timeout=120,
                env={"PATH": os.environ["PATH"], "RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(output), "GH_TOKEN": "t",
                     "SHA": SHA, "REPO": REPO, "API": f"{self.server.url}/repos/{REPO}",
                     "RUN_URL": "https://github.com/run/1", "RESULTS": f"{self.server.url}/v1", **env})
            return done.returncode, done.stdout, output.read_text() if output.exists() else ""

    def compile_status(self, **env: str) -> tuple[int, str, str]:
        return self.bash(step_script(), PROBE_GAP="1", READ_GAP="1", **env)

    def handoff(self, down: str, fast: str, mac: str) -> tuple[int, str, str]:
        script = next(step["run"] for step in handoff_job()["steps"] if "run" in step)
        return self.bash(script, DOWN=down, FAST=fast, MAC=mac)

    def test_a_pull_request_with_a_fallback_gets_the_fallbacks_verdict(self):
        started = time.monotonic()
        code, _, output = self.compile_status(FALLBACK="true", PR="40600")
        self.assertLess(time.monotonic() - started, 15)  # two probes 1 s apart, not 40 minutes
        self.assertEqual(code, 0)
        self.assertEqual(output.strip(), "handoff=HTTP 530")
        self.assertEqual(len(self.server.reads), 2)
        self.assertTrue(all(read.endswith("&pr=40600&wait=1") for read in self.server.reads), self.server.reads)
        self.assertEqual([p["state"] for p in self.server.posts], ["pending", "pending"])
        down = output.strip().split("=", 1)[1]
        # A fallback's red is a red (exit 1); with no fallback run it is the needs_verdict rule's no verdict (exit 3),
        # never the PR's own red.
        for fast, mac, state, exit_code in (("skipped/", "success", "success", 0),
                                            ("skipped/", "failure", "failure", 1),
                                            ("success/unavailable", "success", "success", 0),
                                            ("success/pass", "skipped", "success", 0),
                                            ("failure/fail", "skipped", "failure", 1),
                                            ("skipped/", "skipped", "error", 3),
                                            ("skipped/", "cancelled", "error", 3)):
            with self.subTest(fast=fast, mac=mac):
                code, stdout, _ = self.handoff(down, fast, mac)
                post = self.server.posts[-1]
                self.assertEqual((post["state"], post["context"], code), (state, "cmux-next/compile", exit_code))
                self.assertEqual("::error::no verdict: " in stdout, state == "error")
                self.assertNotIn("did not compile", post["description"])
                self.assertLessEqual(len(post["description"]), 140)
                if state == "error":
                    self.assertIn("re-run all jobs", post["description"])
                    self.assertTrue(base_red_excuse().COMPILE_STATUS_NO_VERDICT.match(post["description"]))

    def test_a_pull_request_with_no_fallback_hands_off_to_the_overflow_compile(self):
        """2026-11-10 19:51Z: this failed the job on every pull request while the controller was down. The overflow
        compile posts the head's verdict; until then cmux-next/compile is pending (never a pass) and the job is green."""
        code, stdout, output = self.compile_status(FALLBACK="false", PR="40742")
        self.assertEqual((code, output), (0, ""))
        self.assertEqual([p["state"] for p in self.server.posts], ["pending", "pending"])
        said = self.server.posts[-1]["description"]
        self.assertTrue(said.startswith("[overflow] Results service down (HTTP 530); "), said)
        self.assertLessEqual(len(said), 140)
        self.assertFalse(base_red_excuse().COMPILE_STATUS_NO_VERDICT.match(said))
        self.assertIn("the overflow compile posts cmux-next/compile", stdout)

    def test_a_push_with_no_fallback_says_no_verdict(self):
        """The overflow compile takes only pull request heads: a superseded push still says no verdict."""
        code, stdout, output = self.compile_status(FALLBACK="false")
        self.assertEqual((code, output), (1, ""))
        self.assertEqual([p["state"] for p in self.server.posts], ["pending", "error"])
        self.assertIn("no fallback compile runs here, re-run this job", self.server.posts[-1]["description"])
        self.assertRegex(stdout, NO_VERDICT_LINE)
        # base_red_excuse.py judges it no verdict (another compile's pass at the head may stand in), not a compile red.
        self.assertTrue(base_red_excuse().COMPILE_STATUS_NO_VERDICT.match(self.server.posts[-1]["description"]))

    def test_a_stalled_response_hands_off_at_the_bound(self):
        """A service that takes the connection and never answers: the read gets --max-time of what is left of the
        bound, not a 30-minute long poll, and the step hands off when it expires."""
        self.server.stall, self.server.probe_code = True, 404
        started = time.monotonic()
        code, _, output = self.compile_status(FALLBACK="true", BAD_BOUND="4")
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual(code, 0)
        self.assertRegex(output.strip(), r"^handoff=HTTP 000 for [3-9] s$")
        self.assertEqual([p["state"] for p in self.server.posts], ["pending", "pending"])
        step = next(step for step in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
                    ["release-compile-fast"]["steps"] if step.get("id") == "compile")
        self.server.reads.clear()
        started = time.monotonic()
        code, _, output = self.bash(step["run"], REF=SHA, GATEWAY="", PROBE_GAP="1", BAD_BOUND="4")
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual((code, output.strip()), (0, "verdict=unavailable"))

    def test_the_fast_checks_route_hands_the_push_to_the_mac(self):
        step = next(step for step in yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
                    ["release-compile-fast"]["steps"] if step.get("id") == "compile")
        code, _, output = self.bash(step["run"], REF=SHA, GATEWAY="", PROBE_GAP="1")
        self.assertEqual((code, output.strip()), (0, "verdict=unavailable"))

    def test_the_handoff_job_waits_on_the_fallback_and_checks_nothing_out(self):
        j = handoff_job()
        self.assertEqual(j["needs"], ["compile-status", "release-compile-fast", "release-compile"])
        self.assertIn("needs.compile-status.outputs.handoff != ''", j["if"])
        self.assertIn("always()", j["if"])
        self.assertEqual(j["permissions"], {})
        self.assertFalse(any("actions/checkout" in str(step.get("uses", "")) for step in j["steps"]))
        self.assertNotEqual(j["name"], job()["name"])  # one check run per name: the gate's red stays compile-status's


# Our own endpoints: a cmux.com host, named in the curl or through a variable this workflow sets to one.
OWN_HOST = re.compile(r"https?://[\w.-]*cmux\.com\b")
OWN_BOUND = 300  # seconds: a read of our own service hands off after this, as compile-status does


def curl_commands(text: str) -> list[tuple[int, str]]:
    """(line, command) for each shell line that runs curl, its backslash continuations joined."""
    lines, out, i = text.splitlines(), [], 0
    while i < len(lines):
        start, command = i + 1, lines[i]
        while command.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            command = command.rstrip()[:-1] + " " + lines[i].strip()
        if re.search(r"\bcurl\b", command) and not command.lstrip().startswith("#"):
            out.append((start, command))
        i += 1
    return out


def retry_bound(command: str) -> int | None:
    """The most seconds a --retry-all-errors curl can take, from literal flags only; None when nothing fixes it."""
    flag = lambda name: (m := re.search(rf"(?<![\w-])--{name}[ =](\d+)\b", command)) and int(m.group(1))
    outer = re.search(r"\btimeout\s+(?:-\S+\s+)*(\d+)s?\s+curl\b", command)
    if outer:
        return int(outer.group(1))
    if flag("retry-max-time") is not None and flag("max-time") is not None:
        return flag("retry-max-time") + flag("max-time")
    if flag("retry") is not None and flag("max-time") is not None and flag("retry-delay") is not None:
        return (flag("retry") + 1) * flag("max-time") + flag("retry") * flag("retry-delay")
    return None


def unbounded_retries(workflow: Path = WORKFLOW) -> list[str]:
    """Each `curl --retry-all-errors` in cmux-next.yml, or in a scripts/cmux-next script it runs, that nothing bounds,
    or that reads our own service and may outlast OWN_BOUND (cmux#40600: a 530 retried for the whole 40 minutes)."""
    text = workflow.read_text(encoding="utf-8")
    own_vars = {m.group(1) for m in re.finditer(r"^\s*([A-Za-z_]\w*):\s*\S*https?://[\w.-]*cmux\.com", text, re.M)}
    sources = [(workflow, text)] + [(ROOT / rel, (ROOT / rel).read_text(encoding="utf-8"))
                                    for rel in sorted(set(re.findall(r"scripts/cmux-next/[\w./-]+\.sh", text)))
                                    if (ROOT / rel).is_file()]
    found = []
    for path, body in sources:
        for line, command in curl_commands(body):
            if "--retry-all-errors" not in command:
                continue
            own = bool(OWN_HOST.search(command)) or any(re.search(rf"\$\{{?{name}\b", command) for name in own_vars)
            bound = retry_bound(command)
            if bound is None or own and bound > OWN_BOUND:
                where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
                found.append(f"{where}:{line}: curl --retry-all-errors "
                             + ("with no fixed bound (an outer `timeout N`, --retry-max-time N, or --retry, "
                                "--max-time and --retry-delay N)" if bound is None else
                                f"against our own service may retry for {bound} s, over {OWN_BOUND} s")
                             + (" against our own service: probe it and hand off on 000/52x/530 instead" if own else ""))
    return found


class UnboundedRetryDetector(unittest.TestCase):
    """The class of cmux#40600: a `curl --retry-all-errors` against our own endpoint retries a proxy's 530 until its
    caller's deadline. Run it against another copy with CMUX_NEXT_WORKFLOW=PATH (the tip before this fix fails)."""

    def test_every_retry_all_errors_curl_is_bounded(self):
        self.assertEqual(unbounded_retries(), [])

    def test_the_detector_catches_the_shapes_it_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "w.yml")
            for text, bad in (
                ('RESULTS: https://gh-events.cmux.com/x\n  timeout "$left" curl -sS --retry 60 --retry-all-errors \\\n'
                 '    --retry-max-time "$left" "$RESULTS/a"\n', True),
                ('curl -fsSL --retry 5 --retry-all-errors https://ci-cache.cmux.com/a\n', True),
                ('timeout 900 curl --retry-all-errors https://gh-events.cmux.com/a\n', True),
                ('timeout 110 curl --max-time 30 --retry 2 --retry-delay 10 --retry-all-errors "$API/x"\n', False),
                ('curl --max-time 60 --retry 5 --retry-delay 3 --retry-all-errors "$@"\n', False),
                ('curl --max-time 20 --retry 3 --retry-delay 5 --retry-all-errors https://gh-events.cmux.com/a\n', False),
                ('curl -sS --retry-all-errors "$url"\n', True),
                ('# curl --retry-all-errors in a comment\n', False),
            ):
                with self.subTest(text=text):
                    path.write_text(text)
                    self.assertEqual(bool(unbounded_retries(path)), bad, unbounded_retries(path))


if __name__ == "__main__":
    unittest.main()
