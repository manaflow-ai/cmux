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
import shlex
import shutil
import subprocess
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
FAKE_CURL = r'''#!/usr/bin/env bash
out="" body="" url="" fmt=""
while (($#)); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -w) fmt="$2"; shift 2 ;;
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
GAPS = {"PROBE_GAP": "0", "READ_GAP": "0"}
# autoland's and base_red_excuse.py's no-verdict line (NO_VERDICT): a red that names no compile failure.
NO_VERDICT_LINE = re.compile(r"cmux-next/compile is not a pass for \S+ \((?!fail\))")


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["compile-status"]


def step_script() -> str:
    return next(step["run"] for step in job()["steps"] if "run" in step)


@unittest.skipUnless(shutil.which("jq"), "jq is not installed")
class StatusMapping(unittest.TestCase):
    def run_step(self, reply: dict | None, **env: str) -> tuple[int, list[dict], list[str]]:
        if reply is None:
            env = {"WAIT_SECONDS": "63", "READ_GAP": "1", **env}  # 404 until the deadline: keep it short
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
        # A pull request's read names it, so the controller can queue a head it never saw (cmuxterm-hq#5571).
        _, _, reads = self.run_step(self.reply("pass"), PR="28059")
        self.assertEqual(reads, [f"https://results/v1/{SHA}?repo=manaflow-ai%2Fcmux&pr=28059&wait=1800"])
        _, _, reads = self.run_step(self.reply("pass"), PR="1;x")
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

    def test_it_sleeps_only_between_probes_and_re_reads(self):
        sleeps = re.findall(r"sleep[^;\n]*", step_script())
        self.assertEqual(sorted(sleeps), ['sleep "${PROBE_GAP:-30}"', 'sleep "${READ_GAP:-30}"'])
        self.assertIn("${BAD_BOUND:-300}", step_script())

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
        self.assertRegex(self.stdout, NO_VERDICT_LINE)
        self.assertEqual(self.output, "")

    def test_a_service_that_answers_nothing_usable_is_down_after_the_bound(self):
        # Probes see a 404 (the service up), then every read is a 503 or a 530: handed off after BAD_BOUND.
        for bad in ("503", "530", "000", "403"):
            with self.subTest(code=bad):
                started = time.monotonic()
                code, posts, reads = self.run_step(None, CODES=bad, BAD_BOUND="2", READ_GAP="1", FALLBACK="true",
                                                   WAIT_SECONDS="2400")
                self.assertLess(time.monotonic() - started, 20)
                self.assertEqual(code, 0)
                self.assertTrue(self.output.startswith(f"handoff=HTTP {bad} for "), self.output)
                self.assertGreaterEqual(len(reads), 2)
        # A 404 (no result yet) is the service up: read again, and the pass that follows is the verdict.
        code, posts, reads = self.run_step(self.reply("pass"), CODES="404 404 200", BAD_BOUND="0")
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
        if reply is None:
            env = {**env, "WAIT_SECONDS": "63", "READ_GAP": "1"}  # 404 until the deadline: keep it short
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
        code, verdict, reads = self.run_step(self.reply("pass"), CODES="530", BAD_BOUND="2", READ_GAP="1")
        self.assertLess(time.monotonic() - started, 20)
        self.assertEqual((code, verdict), (0, "unavailable"))
        self.assertGreaterEqual(len(reads), 2)
        code, verdict, reads = self.run_step(self.reply("pass"), PROBE_CODE="530")
        self.assertEqual((code, verdict, reads), (0, "unavailable", []))

    def test_the_wait_fits_the_job(self):
        job = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["release-compile-fast"]
        run = next(step["run"] for step in job["steps"] if step.get("id") == "compile")
        self.assertIn("WAIT_SECONDS:-1200", run)
        self.assertLessEqual(1200 + 120, job["timeout-minutes"] * 60 - 300)


def handoff_job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["compile-status-handoff"]


class ResultsServer(http.server.ThreadingHTTPServer):
    """The results service and the statuses API on 127.0.0.1: every results read answers `code` (a 530 is the proxy
    saying the origin is down), every status post is kept."""

    def __init__(self, code: int):
        self.code, self.posts, self.reads = code, [], []
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                server.reads.append(self.path)
                self.send_response(server.code)
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

    def test_a_pull_request_with_no_fallback_says_no_verdict(self):
        code, stdout, output = self.compile_status(FALLBACK="false")
        self.assertEqual((code, output), (1, ""))
        self.assertEqual([p["state"] for p in self.server.posts], ["pending", "error"])
        self.assertIn("no fallback compile runs here; re-run this job", self.server.posts[-1]["description"])
        self.assertRegex(stdout, NO_VERDICT_LINE)

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


SHELL_SEPARATORS = {";", "&&", "||", "|", "&", ";;", "|&"}


def shell_tokens(text: str) -> list[str]:
    """One shell line's words, as a shell splits them: any run of spaces or tabs, quotes removed, `;`, `&&`, `|` apart,
    a `#` comment to the end of the line. Command substitutions are taken out first (split_substitutions)."""
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=";&|")
        lex.whitespace_split = True
        return list(lex)
    except ValueError:  # an unbalanced quote (a `"$(` that the next line closes): words without quotes still serve
        return shell_tokens(re.sub(r"""["']""", " ", text))


SUBSTITUTION = "__substitution__"


def split_substitutions(text: str) -> tuple[str, list[str]]:
    """The line with each outermost command substitution (`$(...)`, a backquoted command) replaced by one plain word,
    and the commands they hold. A substitution is its own command: its curl keeps its own arguments, and the command
    around it keeps its words (`curl -H "$(printf x)" --retry 3` is one curl with --retry; Codex on #40717). One that
    the line does not close runs to the end of the line."""
    outer, bodies, i, quote = [], [], 0, ""
    while i < len(text):
        c = text[i]
        if quote == "'":
            quote = "" if c == "'" else quote
        elif c == "\\" and i + 1 < len(text):
            outer.append(text[i:i + 2])
            i += 2
            continue
        elif c == "'" and not quote:
            quote = "'"
        elif c == '"':
            quote = "" if quote == '"' else '"'
        elif text.startswith("$(", i) and not text.startswith("$((", i) or c == "`":
            end = matching_close(text, i)
            bodies.append(text[i + (1 if c == "`" else 2):end])
            outer.append(SUBSTITUTION)
            i = end + 1
            continue
        outer.append(c)
        i += 1
    return "".join(outer), bodies


def matching_close(text: str, start: int) -> int:
    """Where the substitution opening at `start` ends (its `)` or closing backquote), or the end of the line."""
    if text[start] == "`":
        close = text.find("`", start + 1)
        return close if close >= 0 else len(text)
    depth, i, quote = 1, start + 2, ""
    while i < len(text):
        c = text[i]
        if quote == "'":
            quote = "" if c == "'" else quote
        elif c == "\\":
            i += 1
        elif text.startswith("$(", i) and not text.startswith("$((", i):  # a nested one: its own quoting
            i = matching_close(text, i) + 1
            continue
        elif c == '"':
            quote = "" if quote else '"'
        elif c == "'" and not quote:
            quote = "'"
        elif c == "(" and not quote:
            depth += 1
        elif c == ")" and not quote:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(text)


def logical_lines(text: str) -> list[tuple[int, str]]:
    """(first line number, text) per shell line, each backslash continuation joined to its line. Lines are lexed one by
    one, so a `#` comment ends at its own line (shlex reads one to the end of its input: LW#4170)."""
    lines, out, i = text.splitlines(), [], 0
    while i < len(lines):
        start, line = i + 1, lines[i]
        while re.search(r"(?<!\\)\\$", line) and i + 1 < len(lines):
            i += 1
            line = line[:-1] + " " + lines[i]
        out.append((start, line))
        i += 1
    return out


def curl_calls(text: str) -> list[tuple[int, list[str], list[str]]]:
    """(line, the words before curl in its command, curl's own arguments) for each curl the shell text runs."""
    calls = []
    for line, logical in logical_lines(text):
        commands, pending = [], [logical]
        while pending:  # the line, then each substitution in it, nested ones included
            outer, bodies = split_substitutions(pending.pop())
            commands.append(outer)
            pending += bodies
        command: list[str] = []
        for word in [w for outer in commands for w in [*shell_tokens(outer), ";"]]:
            if word not in SHELL_SEPARATORS:
                command.append(word)
                continue
            for k, w in enumerate(command):
                if w == "curl" or w.endswith("/curl"):
                    calls.append((line, command[:k], command[k + 1:]))
                    break
            command = []
    return calls


# curl's options that take a value, short and long, so the words after them are values and not options (a subset: the
# ones these scripts use, and every one that bounds time or retries).
CURL_SHORT_VALUE = set("AbcCdDeEFhHKmoPQrTuUwxXyYz")
CURL_LONG = {"-m": "--max-time"}


def curl_options(args: list[str]) -> dict[str, list[str]]:
    """Each long option curl is given, with its values: `--retry 5`, `--retry=5`, `-m 30`, `-m30` and a combined
    `-fsSm 30` all read as the option and its value. A short option that takes a value ends a combined group."""
    options: dict[str, list[str]] = {}
    i = 0
    while i < len(args):
        word = args[i]
        if word.startswith("--") and len(word) > 2:
            name, eq, value = word.partition("=")
            if not eq and i + 1 < len(args) and not args[i + 1].startswith("-"):
                value, i = args[i + 1], i + 1
            options.setdefault(name, []).append(value)
        elif word.startswith("-") and len(word) > 1:
            for j, letter in enumerate(word[1:], 1):
                if letter in CURL_SHORT_VALUE:
                    rest = word[j + 1:]
                    if not rest and i + 1 < len(args):
                        rest, i = args[i + 1], i + 1
                    options.setdefault(CURL_LONG.get(f"-{letter}", f"-{letter}"), []).append(rest)
                    break
        i += 1
    return options


def literal(values: list[str] | None) -> int | None:
    """The option's last value when it is a literal whole number of seconds (curl reads the last one), else None."""
    return int(values[-1]) if values and re.fullmatch(r"\d+", values[-1]) else None


def outer_bound(prefix: list[str]) -> int | None:
    """N when the words before curl run it under a fixed total bound: `timeout [options] N curl` or perl's alarm,
    `perl -e 'alarm shift; exec @ARGV' N curl` (macOS ships perl, not `timeout`)."""
    if len(prefix) >= 2 and re.fullmatch(r"\d+s?", prefix[-1]):
        seconds = int(prefix[-1].rstrip("s"))
        if prefix[-4:-1] == ["perl", "-e", "alarm shift; exec @ARGV"]:
            return seconds
        if "timeout" in prefix:
            k = len(prefix) - 1 - prefix[::-1].index("timeout")
            between = prefix[k + 1:-1]
            j = 0
            while j < len(between) and between[j].startswith("-"):  # timeout's own options
                j += 2 if between[j] in ("-k", "-s") else 1
            if j == len(between):
                return seconds
    return None


def call_retries(args: list[str]) -> bool:
    """Whether a curl retries: its last --retry (the one curl uses) is anything but a literal 0 (a variable count may
    be anything)."""
    counts = curl_options(args).get("--retry", [])
    return bool(counts) and counts[-1] != "0"


def call_bound(prefix: list[str], args: list[str]) -> int | None:
    """The most seconds a retrying curl can take, from literal values only; None when nothing fixes the total.

    Only two shapes hold with Retry-After, which overrides --retry-delay (curl 8: a 503 with `Retry-After: 8` kept
    `--retry 2 --retry-delay 1 --max-time 1` busy 16 s, not the 3 s that count times delay gives): an outer bound on
    the whole command (`timeout N`, perl's alarm), or --retry-max-time N with --max-time M, since curl sleeps for no
    retry that would pass N and each attempt stops at M, so the total is at most N + M. RetryAfterBound checks both
    against real curl."""
    outer = outer_bound(prefix)
    if outer is not None:
        return outer
    options = curl_options(args)
    retry_max, max_time = literal(options.get("--retry-max-time")), literal(options.get("--max-time"))
    return retry_max + max_time if retry_max is not None and max_time is not None else None


def retrying(command: str) -> bool:
    return any(call_retries(args) for _, _, args in curl_calls(command))


def retry_bound(command: str) -> int | None:
    """call_bound of the first curl in a shell command."""
    _, prefix, args = curl_calls(command)[0]
    return call_bound(prefix, args)


def unbounded_retries(workflow: Path = WORKFLOW) -> list[str]:
    """Each retrying curl in cmux-next.yml, or in a scripts/cmux-next script it names, that nothing bounds in total, or
    that reads our own service and may outlast OWN_BOUND (cmux#40600: a 530 retried for the whole 40 minutes)."""
    text = workflow.read_text(encoding="utf-8")
    own_vars = {m.group(1) for m in re.finditer(r"^\s*([A-Za-z_]\w*):\s*\S*https?://[\w.-]*cmux\.com", text, re.M)}
    sources = [(workflow, text)] + [(ROOT / rel, (ROOT / rel).read_text(encoding="utf-8"))
                                    for rel in sorted(set(re.findall(r"scripts/cmux-next/[\w./-]+\.sh", text)))
                                    if (ROOT / rel).is_file()]
    found = []
    for path, body in sources:
        for line, prefix, args in curl_calls(body):
            if not call_retries(args):
                continue
            command = " ".join(args)
            own = bool(OWN_HOST.search(command)) or any(re.search(rf"\$\{{?{name}\b", command) for name in own_vars)
            bound = call_bound(prefix, args)
            if bound is None or own and bound > OWN_BOUND:
                where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
                found.append(f"{where}:{line}: a retrying curl "
                             + ("with no total bound (--retry-max-time N with --max-time M, or an outer `timeout N`; "
                                "Retry-After overrides --retry-delay, so a retry count bounds nothing)" if bound is None else
                                f"against our own service may retry for {bound} s, over {OWN_BOUND} s")
                             + (" against our own service: probe it and hand off on 000/52x/530 instead" if own else ""))
    return found


class UnboundedRetryDetector(unittest.TestCase):
    """The class of cmux#40600: a `curl --retry-all-errors` against our own endpoint retries a proxy's 530 until its
    caller's deadline. Any retrying curl has the same hole: a Retry-After header overrides --retry-delay, so only a total
    bound holds (RetryAfterBound). Run it against another copy with CMUX_NEXT_WORKFLOW=PATH."""

    def test_every_retrying_curl_is_bounded(self):
        self.assertEqual(unbounded_retries(), [])

    def test_the_detector_catches_the_shapes_it_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "w.yml")
            for text, bad in (
                ('RESULTS: https://gh-events.cmux.com/x\n  timeout "$left" curl -sS --retry 60 --retry-all-errors \\\n'
                 '    --retry-max-time "$left" "$RESULTS/a"\n', True),
                ('curl -fsSL --retry 5 --retry-all-errors https://ci-cache.cmux.com/a\n', True),
                ('timeout 900 curl --retry 3 --retry-all-errors https://gh-events.cmux.com/a\n', True),
                ('timeout 110 curl --max-time 30 --retry 2 --retry-delay 10 --retry-all-errors "$API/x"\n', False),
                # A retry count, a delay and a per-attempt --max-time bound nothing: Retry-After overrides the delay.
                ('curl --max-time 60 --retry 5 --retry-delay 3 --retry-all-errors "$@"\n', True),
                ('curl --max-time 20 --retry 3 --retry-delay 5 --retry-all-errors https://gh-events.cmux.com/a\n', True),
                ('curl -fL --retry 5 -o "$archive" "$url"\n', True),  # any --retry, not only --retry-all-errors
                ('curl --retry "${2:-0}" --max-time 3 "$u"\n', True),  # a count that is not a literal 0
                ('curl --max-time 60 --retry 5 --retry-max-time 300 --retry-all-errors "$@"\n', False),
                ('curl --max-time 20 --retry 3 --retry-max-time 200 https://gh-events.cmux.com/a\n', False),
                ('curl --max-time 20 --retry 3 --retry-max-time 600 https://gh-events.cmux.com/a\n', True),  # over 5 min
                ('curl --retry 3 --retry-max-time 300 "$u"\n', True),  # one attempt may hang: no --max-time
                ("perl -e 'alarm shift; exec @ARGV' 120 curl --retry 3 \"$u\"\n", False),
                ('curl --retry 0 "$u"\n', False),
                ('curl -sS --retry-all-errors "$url"\n', False),  # no --retry: curl retries nothing
                ('# curl --retry 5 in a comment\n', False),
                # Spacing and lines as a shell reads them (Codex on #40701): each was missed by a one-space regex.
                ('curl --max-time 20  --retry  5 "$u"\n', True),  # two spaces
                ('curl --max-time 20\t--retry\t5 "$u"\n', True),  # tabs
                ('curl --max-time 20 --retry \\\n    5 "$u"\n', True),  # a backslash continuation between flag and value
                ('curl --max-time 20 \\\n  --retry 5 \\\n  --retry-max-time 200 "$u"\n', False),
                # The forms curl accepts: --flag=value, -m for --max-time, a combined short group ending in -m.
                ('curl --retry=5 --max-time 20 "$u"\n', True),
                ('curl --retry=5 --max-time=20 --retry-max-time=200 "$u"\n', False),
                ('curl -fsS -m 20 --retry 5 --retry-max-time 200 "$u"\n', False),
                ('curl -fsSm20 --retry 5 --retry-max-time 200 "$u"\n', False),
                ('curl -fsSm 20 --retry 5 --retry-max-time 200 "$u"\n', False),
                ('curl --retry-delay 5 --retry-max-time 200 -m 20 "$u"\n', False),  # --retry-delay is no --retry
                ('curl -m "$t" --retry 5 --retry-max-time 200 "$u"\n', True),  # not a literal
                ('curl --retry 5 --max-time 20 "$u"  # --retry-max-time 200\n', True),  # a bound in a comment is none
                ('code="$(curl --retry 3 --max-time 5 "$u")"\n', True),  # inside a command substitution
                ('code="$(timeout 30 curl --retry 3 "$u")"\n', False),
                ('timeout -k 5 110 curl --retry 3 "$u"\n', False),
                ('timeout "$left" curl --retry 3 --max-time 5 "$u"\n', True),
                ('echo start; curl --retry 3 "$u" && echo done\n', True),  # one command among others
                # Command substitutions are commands of their own (Codex on #40717): neither the curl in one nor the
                # curl around one loses its arguments, at any depth, in $(...) or backquotes.
                ('code=$(curl --retry 3 --max-time 5 "$u")\n', True),
                ('code=$(timeout 30 curl --retry 3 "$u")\n', False),
                ('code=$(curl --retry 3 --max-time 5 --retry-max-time 60 "$u")\n', False),
                ('x=$(echo $(curl --retry 3 "$u"))\n', True),
                ('x="$(echo "$(curl --retry 3 "$u")")"\n', True),
                ('x=`curl --retry 3 "$u"`\n', True),
                ('curl -H "$(printf x)" --retry 3 "$u"\n', True),
                ("curl -H \"$(printf '%s' \"$(date)\")\" --retry 3 \"$u\"\n", True),
                ('curl -H "$(printf x)" --retry 3 --max-time 5 --retry-max-time 60 "$u"\n', False),
                ('curl -H `printf x` --retry 3 "$u"\n', True),
                ('curl -H "$(printf ")")" --retry 3 "$u"\n', True),  # a quoted paren inside closes nothing
                ('echo $((1 + 2)); curl --retry 3 "$u"\n', True),  # arithmetic is no substitution
                # curl uses the last --retry.
                ('curl --retry 5 --retry 0 "$u"\n', False),
                ('curl --retry 5 --retry=0 "$u"\n', False),
                ('curl --retry 0 --retry 5 "$u"\n', True),
            ):
                with self.subTest(text=text):
                    path.write_text(text)
                    self.assertEqual(bool(unbounded_retries(path)), bad, unbounded_retries(path))


@unittest.skipUnless(shutil.which("curl") and shutil.which("timeout") and shutil.which("perl"), "curl, timeout or perl missing")
class SubstitutionsAreCommands(unittest.TestCase):
    """Each curl keeps exactly its own arguments, whether it sits in a substitution or holds one (Codex on #40717)."""

    def test_each_curl_keeps_its_own_arguments(self):
        for text, args in (
            ('code=$(curl --retry 3 --max-time 5 "$u")', ["--retry", "3", "--max-time", "5", "$u"]),
            ('x="$(echo "$(curl --retry 3 "$u")")"', ["--retry", "3", "$u"]),
            ('x=`curl --retry 3 "$u"`', ["--retry", "3", "$u"]),
            ('curl -H "$(printf x)" --retry 3 "$u"', ["-H", SUBSTITUTION, "--retry", "3", "$u"]),
            ('curl -H "$(printf ")")" --retry 3 "$u"', ["-H", SUBSTITUTION, "--retry", "3", "$u"]),
            ("curl -H \"$(printf '%s' \"$(date)\")\" --retry 3 \"$u\"", ["-H", SUBSTITUTION, "--retry", "3", "$u"]),
        ):
            with self.subTest(text=text):
                self.assertEqual([found for _, _, found in curl_calls(text)], [args])


class RetryAfterBound(unittest.TestCase):
    """The detector's rule, checked against real curl and a local service that answers 503 with Retry-After: a retry
    count and delay bound nothing, while --retry-max-time with --max-time, `timeout N` and perl's alarm each hold."""

    def setUp(self):
        self.retry_after, self.stall = "4", False
        test = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                if test.stall:
                    time.sleep(30)
                    return
                self.send_response(503)
                self.send_header("Retry-After", test.retry_after)
                self.send_header("Content-Length", "0")
                self.end_headers()

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.url = f"http://127.0.0.1:{server.server_address[1]}/x"

    def took(self, *argv: str) -> float:
        started = time.monotonic()
        subprocess.run([*argv, self.url], capture_output=True, timeout=60)
        return time.monotonic() - started

    def curl(self, *flags: str) -> list[str]:
        return ["curl", "-sS", "-o", "/dev/null", *flags]

    def test_a_retry_count_and_delay_bound_nothing(self):
        # 2 attempts of at most 1 s and one 1 s delay "bound" 3 s; Retry-After makes curl sleep 4 s instead.
        took = self.took(*self.curl("--max-time", "1", "--retry", "1", "--retry-delay", "1", "--retry-all-errors"))
        self.assertGreaterEqual(took, 4)
        self.assertEqual(retry_bound("curl --max-time 1 --retry 1 --retry-delay 1 --retry-all-errors"), None)

    def test_retry_max_time_with_max_time_holds_with_retry_after(self):
        for retry_after, stall in (("2", False), ("4", False), ("100", False), ("1", True)):
            with self.subTest(retry_after=retry_after, stall=stall):
                self.retry_after, self.stall = retry_after, stall
                flags = ("--max-time", "1", "--retry", "10", "--retry-delay", "1", "--retry-max-time", "3",
                         "--retry-all-errors")
                bound = retry_bound("curl " + " ".join(flags))
                self.assertEqual(bound, 4)
                self.assertLess(self.took(*self.curl(*flags)), bound + 1)

    def test_an_outer_bound_holds_with_retry_after(self):
        flags = ("--max-time", "1", "--retry", "5", "--retry-delay", "1", "--retry-all-errors")
        for outer in (["timeout", "3"], ["perl", "-e", "alarm shift; exec @ARGV", "3"]):
            with self.subTest(outer=outer[0]):
                self.assertEqual(retry_bound(" ".join(outer[:2] + [f"'{outer[2]}'"] + outer[3:]
                                                      if outer[0] == "perl" else outer) + " curl " + " ".join(flags)), 3)
                self.assertLess(self.took(*outer, *self.curl(*flags)), 3.5)


if __name__ == "__main__":
    unittest.main()
