#!/usr/bin/env python3
"""cmux-next fast gates: the PR merged with its base, five gates in fail mode, one commit status.

Four base reds landed on 2026-10-21 through checks that only warn on a pull request or run only
on push: webviews lint/format and switch-fetches (ci-web's react-apps-check is warn-only on a PR;
cmux-next-web.yml's `web lint (fast)` fails only on push), a self-merge past its own red
`defaults-snapshot`, and direct pushes that tripped the crash ratchet. feat-cmux-next has no
required checks. cmux-next-fast-gates.yml runs those gates on BASE..merge for every pull request
into feat-cmux-next (and on dispatch, against the current tip) and posts `cmux-next/fast-gates`
with `base <sha>` on the PR head, so autoland and the merge hook can tell whether the result is
fresh for the tip they merge into.

Two halves:
- the workflow's shape (triggers, runner, permissions, the status it posts), from the YAML;
- scripts/ci/cmux_next_fast_gates.py's behavior on temporary git repositories: `prepare` finds or
  makes the merge and names BASE and the head, `run` runs every gate against BASE and fails when
  any one fails.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-fast-gates.yml"
GUARDS = ROOT / ".github/workflows/cmux-next-guards.yml"
SCRIPT = ROOT / "scripts/ci/cmux_next_fast_gates.py"
GATE_SCRIPTS = {
    "web lint": "scripts/web_lint_prepush.py",
    "crash ratchet": "scripts/ci/crash_ratchet_compare.py",
    "prepush gate": "scripts/cmux-next/prepush-gate.py",
    "crash-class rules": "scripts/ci/crash_class_fast_gate.py",
    "webviews checks": "scripts/ci/fast_gate_webviews_checks.py",
}
CI_WEB = ROOT / ".github/workflows/ci-web.yml"
WEBVIEWS_CHECKS = ROOT / "scripts/ci/fast_gate_webviews_checks.py"


def load(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def triggers(doc: dict) -> dict:
    # PyYAML reads the bare key `on` as the boolean True.
    return doc.get("on", doc.get(True))


def job(doc: dict, key: str = "fast-gates") -> dict:
    return doc["jobs"][key]


def step_named(steps: list[dict], fragment: str) -> dict:
    found = [s for s in steps if fragment in s.get("name", "")]
    if len(found) != 1:
        raise AssertionError(f"expected one step named like {fragment!r}, found {[s.get('name') for s in found]}")
    return found[0]


class WorkflowShape(unittest.TestCase):
    def test_name_job_and_runner(self):
        doc = workflow()
        self.assertEqual(doc["name"], "cmux-next fast gates")
        self.assertEqual(list(doc["jobs"]), ["resolve", "fast-gates", "panic-ratchet", "post"])
        self.assertEqual(job(doc)["name"], "fast gates")
        # Fleet Linux is first for every trusted job; fork pull requests retain
        # their ephemeral Blacksmith branch, and reruns accept bounded overflow.
        guards_runner = yaml.safe_load(GUARDS.read_text(encoding="utf-8"))["jobs"]["crash-ratchet"]["runs-on"]
        self.assertNotEqual(doc["jobs"]["resolve"]["runs-on"], guards_runner)
        self.assertNotEqual(doc["jobs"]["post"]["runs-on"], guards_runner)
        fast_runner = doc["jobs"]["fast-gates"]["runs-on"]
        self.assertIn("cmux-fleet-linux-x64", fast_runner)
        self.assertIn("inputs.runner", fast_runner)
        self.assertNotIn("macos", fast_runner.lower())
        for key, each in doc["jobs"].items():
            with self.subTest(runner=key):
                self.assertIn("cmux-fleet-linux-x64", str(each["runs-on"]))
                if key != "panic-ratchet":  # its optional fork route is unchanged in this resolver fix
                    self.assertTrue(str(each["runs-on"]).endswith("|| fromJSON(vars.RUNNER_POOLS).linux }}"),
                                    "a stalled literal fleet label must not bypass the reconciled live pool")
                self.assertNotIn("vars.LINUX_RUNNER", str(each["runs-on"]))
        for key, each in doc["jobs"].items():
            with self.subTest(job=key):
                # The panic ratchet builds cmux-tui twice, as cmux-tui-spec.yml's clippy job (40) does once.
                self.assertLessEqual(int(each["timeout-minutes"]), 40 if key == "panic-ratchet" else 15)
                self.assertNotIn("macos", str(each["runs-on"]).lower())

    def test_triggers_have_no_paths_filter(self):
        on = triggers(workflow())
        self.assertEqual(set(on), {"pull_request", "workflow_dispatch"})
        self.assertEqual(on["pull_request"]["branches"], ["feat-cmux-next"])
        for event in on.values():
            for key in ("paths", "paths-ignore"):
                self.assertNotIn(key, event or {}, "a paths filter leaves PRs with no status")
        self.assertNotIn("pull_request_target", on)
        self.assertNotIn("workflow_run", on)

    def test_dispatch_input_is_validated_as_digits(self):
        doc = workflow()
        self.assertIn("pr", triggers(doc)["workflow_dispatch"]["inputs"])
        resolve = step_named(job(doc, "resolve")["steps"], "Resolve")
        self.assertIn("inputs.pr", resolve["env"]["PR"])
        self.assertRegex(resolve["run"], r"\^\[0-9\]")
        # PR-controlled values reach shell through env only, never ${{ }} inside run.
        for key, each in doc["jobs"].items():
            for step in each["steps"]:
                self.assertNotRegex(step.get("run", ""), r"\$\{\{",
                                    f"{key} step {step.get('name')!r} interpolates an expression into shell")

    def test_dispatch_refuses_a_fork_or_another_base_before_pr_code_runs(self):
        doc = workflow()
        resolve = job(doc, "resolve")
        # resolve runs no checked-out code: on dispatch it checks nothing out at all.
        for step in resolve["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                self.assertEqual(step["if"].replace(" ", ""), "${{github.event_name=='pull_request'}}")
            self.assertNotIn("scripts/", step.get("run", ""), step.get("name"))
        body = step_named(resolve["steps"], "Resolve")["run"]
        self.assertIn('"$head_repo" != "$GITHUB_REPOSITORY"', body)
        self.assertIn('"$base_ref" != "$BRANCH"', body)
        self.assertIn('"$state" != open', body)
        self.assertEqual(step_named(resolve["steps"], "Resolve")["env"]["BRANCH"], "feat-cmux-next")
        # The gates job, which runs the PR's code, starts only after resolve passed.
        self.assertEqual(job(doc)["needs"], "resolve")
        prepare = step_named(job(doc)["steps"], "Merge with the base")
        self.assertIn("needs.resolve.outputs.head_sha", prepare["env"]["HEAD_SHA"])
        self.assertIn("needs.resolve.outputs.base", prepare["env"]["BASE"])
        self.assertIn('--head "$HEAD_SHA" --base "$BASE"', prepare["run"])

    def resolve_dispatch(self, *, fields=None, error=None, failures=0, graphql_fields=None):
        """Execute the real resolver with bounded API and sleep stubs."""
        body = step_named(job(workflow(), "resolve")["steps"], "Resolve")["run"]
        with tempfile.TemporaryDirectory(prefix="fast-gates-resolve-") as tmp:
            root = Path(tmp)
            gh = root / "gh"
            gh.write_text("#!/usr/bin/env python3\n" + textwrap.dedent("""\
                import json, os, pathlib, sys
                calls = pathlib.Path(os.environ["CALLS"])
                previous = calls.read_text().splitlines() if calls.exists() else []
                with calls.open("a") as stream:
                    stream.write(json.dumps(sys.argv[1:]) + "\\n")
                if len(previous) < int(os.environ["FAILURES"]):
                    print(os.environ["API_ERROR"], file=sys.stderr)
                    sys.exit(17)
                if sys.argv[2] == "graphql":
                    print(os.environ["GRAPHQL_FIELDS"])
                elif "/pulls/" in sys.argv[2]:
                    print(os.environ["PR_FIELDS"])
                else:
                    print("b" * 40)
                """))
            gh.chmod(0o755)
            sleep = root / "sleep"
            sleep.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$WAITS"\n')
            sleep.chmod(0o755)
            output, calls, waits = (root / name for name in ("output", "calls", "waits"))
            env = {
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "EVENT_NAME": "workflow_dispatch", "PR": "28116", "BRANCH": "feat-cmux-next",
                "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_OUTPUT": str(output),
                "CALLS": str(calls), "WAITS": str(waits), "FAILURES": str(failures),
                "API_ERROR": error or "",
                "GRAPHQL_FIELDS": (graphql_fields or "open|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|" + "c" * 40)
                .replace("|", "\t"),
                "PR_FIELDS": fields.replace("|", "\t") if fields is not None else "open\tmanaflow-ai/cmux\tfeat-cmux-next\t" + "a" * 40,
            }
            result = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, timeout=10)
            return (result, calls.read_text().splitlines(),
                    waits.read_text().splitlines() if waits.exists() else [],
                    output.read_text() if output.exists() else "")

    def test_dispatch_api_failure_surfaces_the_github_error(self):
        result, calls, waits, output = self.resolve_dispatch(
            error="gh: API rate limit exceeded for installation (HTTP 403)", failures=100)
        self.assertEqual(result.returncode, 17)
        self.assertIn("rate limit exceeded", result.stderr)
        self.assertNotIn("comes from", result.stdout + result.stderr)
        # The resolve step makes one REST read and, only after a REST rate-limit
        # refusal, one GraphQL read (its own budget).  A shell retry loop here is
        # indistinguishable from token polling to the CI guard and spends the
        # shared GitHub-token budget; transient failures are surfaced for the
        # workflow retry machinery instead.
        self.assertEqual(len(calls), 2)
        self.assertEqual(json.loads(calls[1])[:2], ["api", "graphql"])
        self.assertEqual(waits, [])
        self.assertEqual(output, "")

    def test_dispatch_rest_rate_limit_reads_over_graphql(self):
        """2026-10-31: 13 of 34 next-autoland dispatches died in resolve on the spent REST budget,
        posted no status, and each PR waited 45 minutes for the next dispatch (#29724)."""
        result, calls, waits, output = self.resolve_dispatch(
            error="gh: API rate limit exceeded for installation (HTTP 403)", failures=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertEqual(json.loads(calls[1])[:2], ["api", "graphql"])
        self.assertEqual(waits, [])
        self.assertIn("head_sha=" + "a" * 40, output)
        self.assertIn("base=" + "c" * 40, output)
        self.assertIn("post=true", output)

    def test_dispatch_graphql_fallback_still_refuses_a_fork_or_a_closed_pr(self):
        limited = "gh: API rate limit exceeded for installation (HTTP 403)"
        for fields, words in (("open|fork/cmux|feat-cmux-next|" + "a" * 40 + "|" + "c" * 40, "comes from fork/cmux"),
                              ("merged|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|" + "c" * 40, "is merged"),
                              ("open|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|", "incomplete")):
            result, calls, waits, output = self.resolve_dispatch(error=limited, failures=1, graphql_fields=fields)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(words, result.stdout + result.stderr)
            self.assertEqual(output, "")

    def test_dispatch_empty_owner_is_not_reported_as_a_fork(self):
        result, calls, waits, output = self.resolve_dispatch(fields="open||feat-cmux-next|" + "a" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete", result.stdout + result.stderr)
        self.assertNotIn("comes from", result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(output, "")

    def test_dispatch_transient_server_error_surfaces_without_retry(self):
        result, calls, waits, output = self.resolve_dispatch(error="gh: Bad Gateway (HTTP 502)", failures=1)
        self.assertEqual(result.returncode, 17)
        self.assertIn("Bad Gateway", result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])
        self.assertEqual(output, "")

    def test_dispatch_permission_failure_is_not_retried(self):
        result, calls, waits, output = self.resolve_dispatch(
            error="gh: Resource not accessible by integration (HTTP 403)", failures=100)
        self.assertEqual(result.returncode, 17)
        self.assertIn("Resource not accessible", result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(waits, [])
        self.assertEqual(output, "")

    def test_dispatch_valid_fork_is_still_refused(self):
        result, calls, waits, output = self.resolve_dispatch(fields="open|fork/cmux|feat-cmux-next|" + "a" * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("comes from fork/cmux", result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(output, "")

    def test_concurrency_per_pull_request(self):
        concurrency = workflow()["concurrency"]
        self.assertEqual(concurrency["group"], "fast-gates-${{ github.event.pull_request.number || inputs.pr }}")
        self.assertIs(concurrency["cancel-in-progress"], True)

    def test_permissions_are_minimal(self):
        doc = workflow()
        self.assertEqual(doc["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "resolve")["permissions"], {"contents": "read", "pull-requests": "read"})
        # The jobs that run pull request code can write nothing; only post can write a status.
        self.assertEqual(job(doc)["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "panic-ratchet")["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "post")["permissions"], {"statuses": "write"})

    def test_every_gate_fails_the_job(self):
        doc = workflow()
        self.assertNotIn("CMUX_NEXT_STYLE_GUARDS", json.dumps(doc))
        gates = job(doc)
        self.assertNotIn("continue-on-error", gates)
        for step in gates["steps"]:
            self.assertNotIn("continue-on-error", step, step.get("name"))
        run = step_named(gates["steps"], "Fast gates")
        self.assertIn("scripts/ci/cmux_next_fast_gates.py run", run["run"])
        source = SCRIPT.read_text(encoding="utf-8")
        for path in GATE_SCRIPTS.values():
            self.assertIn(path, source)
        self.assertNotRegex(source, r"\bwarn(-only)?\b mode")

    def test_checkout_keeps_no_credentials(self):
        checkout = next(s for s in job(workflow())["steps"] if s.get("uses", "").startswith("actions/checkout@"))
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertEqual(int(checkout["with"]["fetch-depth"]), 2)

    def test_status_context_and_description(self):
        doc = workflow()
        poster = job(doc, "post")
        self.assertEqual(poster["needs"], ["resolve", "fast-gates", "panic-ratchet"])
        self.assertIn("!cancelled()", poster["if"])
        self.assertIn("needs.resolve.result == 'success'", poster["if"])
        # Fork pull requests have no write token: resolve says post=false, the gates still pass or fail.
        self.assertIn("needs.resolve.outputs.post == 'true'", poster["if"])
        self.assertIn('"$PR_REPO" == "$GITHUB_REPOSITORY"', step_named(job(doc, "resolve")["steps"], "Resolve")["run"])
        self.assertEqual(len(poster["steps"]), 1, "post checks nothing out and runs no repository code")
        post = poster["steps"][0]
        self.assertNotIn("uses", post)
        self.assertEqual(post["env"]["CONTEXT"], "cmux-next/fast-gates")
        # Head and base come from resolve, never from anything the gates job wrote.
        self.assertIn("needs.resolve.outputs.head_sha", post["env"]["HEAD_SHA"])
        self.assertIn("needs.resolve.outputs.base", post["env"]["BASE"])
        self.assertEqual(post["env"]["GATES"].replace(" ", ""), "${{needs.fast-gates.result}}")
        self.assertEqual(post["env"]["RATCHET"].replace(" ", ""), "${{needs.panic-ratchet.result}}")
        # The gates job hands post nothing but its result; its one output only says whether the ratchet runs,
        # and comes from prepare, before any pull request code ran.
        self.assertEqual(job(doc)["outputs"], {"ratchet": "${{ steps.prepare.outputs.ratchet }}"})
        self.assertNotIn("outputs.", json.dumps(post["env"]).replace("needs.resolve.outputs.", ""))
        self.assertIn("github.run_id", post["env"]["TARGET_URL"])
        self.assertIn("github.token", post["env"]["GH_TOKEN"])
        body = post["run"]
        self.assertIn('"base $BASE"', body)
        self.assertIn("statuses/$HEAD_SHA", body)
        self.assertRegex(body, r"\[0-9a-f\]\{40\}")
        self.assertIn("state=success", body)
        self.assertIn("state=failure", body)
        # A skipped panic ratchet (nothing to rejudge) passes; a failed or cancelled one fails the status.
        for gates, ratchet, state in (("success", "skipped", "success"), ("success", "success", "success"),
                                      ("success", "failure", "failure"), ("success", "cancelled", "failure"),
                                      ("failure", "skipped", "failure")):
            with self.subTest(gates=gates, ratchet=ratchet):
                self.assertEqual(self.posted_state(body, gates, ratchet), state)

    def posted_state(self, body: str, gates: str, ratchet: str) -> str:
        with tempfile.TemporaryDirectory(prefix="fast-gates-state-") as tmp:
            root = Path(tmp)
            fake = root / "gh"
            fake.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {root}/args\n")
            fake.chmod(0o755)
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "HEAD_SHA": "a" * 40, "BASE": "b" * 40,
                   "GATES": gates, "RATCHET": ratchet, "CONTEXT": "cmux-next/fast-gates",
                   "TARGET_URL": "https://example.invalid/run", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "GITHUB_STEP_SUMMARY": str(root / "summary")}
            done = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            args = (root / "args").read_text().splitlines()
            return next(arg.split("=", 1)[1] for arg in args if arg.startswith("state="))

    def test_the_panic_ratchet_job_reruns_the_ratchet_on_the_merge_against_the_tip(self):
        doc = workflow()
        ratchet = job(doc, "panic-ratchet")
        self.assertEqual(ratchet["needs"], ["resolve", "fast-gates"])
        self.assertIn("!cancelled()", ratchet["if"])
        self.assertIn("needs.fast-gates.outputs.ratchet == 'true'", ratchet["if"])
        steps = ratchet["steps"]
        checkout = next(s for s in steps if s.get("uses", "").startswith("actions/checkout@"))
        self.assertIs(checkout["with"]["persist-credentials"], False)
        merge = step_named(steps, "Merge with the base")
        self.assertIn("prepare --event workflow_dispatch", merge["run"])
        run = step_named(steps, "Rust panic ratchet")
        self.assertIn(".github/scripts/cmux-tui-clippy-changed.py", run["run"])
        self.assertIn('--base "$BASE"', run["run"])
        self.assertIn("--panic-ratchet", run["run"])
        self.assertIn("--compare-base", run["run"])
        self.assertEqual(run["env"]["BASE"], "${{ needs.resolve.outputs.base }}")
        # The same build setup as cmux-tui-spec.yml's clippy job, whose cache it reads and never saves.
        spec = yaml.safe_load((ROOT / ".github/workflows/cmux-tui-spec.yml").read_text(encoding="utf-8"))
        spec_cache = next(s for s in spec["jobs"]["clippy"]["steps"] if s.get("uses", "").startswith("Swatinem/"))
        cache = next(s for s in steps if s.get("uses", "").startswith("Swatinem/"))
        self.assertEqual(cache["uses"], spec_cache["uses"])
        self.assertEqual(cache["with"]["shared-key"], spec_cache["with"]["shared-key"])
        self.assertIs(cache["with"]["save-if"], False)
        self.assertEqual(ratchet["env"]["GHOSTTY_ZIG_SOURCE"], "ghostty-next")

    def test_status_api_rate_limit_is_advisory_instead_of_a_second_red(self):
        """A GitHub installation-limit refusal is infrastructure, not a gate verdict."""
        post = step_named(job(workflow(), "post")["steps"], "Post the cmux-next/fast-gates status")
        body = post["run"]
        self.assertRegex(body, r"rate limit exceeded|secondary rate limit|too many requests|HTTP 429")
        self.assertIn("::warning title=GitHub API budget::", body)
        self.assertIn("status could not be posted", body)
        self.assertIn("exit 0", body)
        self.assertNotIn("sleep ", body, "status posting must not burn more quota with in-job retries")

        def run_post(message: str) -> subprocess.CompletedProcess[str]:
            with tempfile.TemporaryDirectory(prefix="fast-gates-status-") as tmp:
                root = Path(tmp)
                fake = root / "gh"
                fake.write_text(f"#!/bin/sh\nprintf '%s\\n' {message!r} >&2\nexit 1\n")
                fake.chmod(0o755)
                summary = root / "summary"
                env = {
                    **os.environ,
                    "PATH": f"{root}:{os.environ['PATH']}",
                    "HEAD_SHA": "a" * 40,
                    "BASE": "b" * 40,
                    "GATES": "success",
                    "RATCHET": "skipped",
                    "CONTEXT": "cmux-next/fast-gates",
                    "TARGET_URL": "https://example.invalid/run",
                    "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                    "GITHUB_STEP_SUMMARY": str(summary),
                }
                return subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True)

        limited = run_post("gh: API rate limit exceeded for installation")
        self.assertEqual(limited.returncode, 0, limited.stderr)
        self.assertIn("installation API budget is exhausted", limited.stdout)

        other = run_post("gh: HTTP 404 Not Found")
        self.assertEqual(other.returncode, 1)
        self.assertIn("HTTP 404", other.stderr)

    def test_web_tools_install_only_for_web_changes_or_the_webviews_checks(self):
        steps = job(workflow())["steps"]
        bun = next(s for s in steps if s.get("uses", "").startswith("oven-sh/setup-bun@"))
        self.assertIn("steps.prepare.outputs.web == 'true'", bun["if"])
        self.assertIn("steps.prepare.outputs.checks == 'true'", bun["if"])
        package = json.loads((ROOT / "webviews" / "package.json").read_text(encoding="utf-8"))
        self.assertEqual(bun["with"]["bun-version"], package["devEngines"]["packageManager"]["version"])
        run = step_named(steps, "Fast gates")
        self.assertIn('--checks "$CHECKS"', run["run"])
        self.assertEqual(run["env"]["CHECKS"], "${{ steps.prepare.outputs.checks }}")

    def test_a_dispatch_never_saves_a_cache(self):
        # A dispatch runs on feat-cmux-next's ref after pull request code ran: a cache it saved would be the base's.
        steps = job(workflow())["steps"]
        for step in steps:
            if step.get("uses", "").startswith("actions/cache@"):
                self.assertIn("github.event_name == 'pull_request'", step["if"], step.get("name"))
        for name in ("Restore the Bun package cache", "Restore the pinned lint tools"):
            restore = step_named(steps, name)
            self.assertTrue(restore["uses"].startswith("actions/cache/restore@"), name)
            self.assertIn("github.event_name == 'workflow_dispatch'", restore["if"], name)

    def test_the_webviews_checks_are_ci_webs_fail_mode_checks(self):
        # The gate reruns what a pull request's ci-web fails on, so a check that landed after the PR's CI
        # (2026-10-21: check:fixed-waits, past which #22967, #22975 and #23094 merged) runs before the merge.
        # ci-web runs the same script, with the merge parent as the base, so both compare per error.
        doc = yaml.safe_load(CI_WEB.read_text(encoding="utf-8"))
        steps = [s for j in doc["jobs"].values() for s in j.get("steps", []) if s.get("id") == "webviews-check"]
        self.assertEqual(len(steps), 1)
        self.assertIn("scripts/ci/fast_gate_webviews_checks.py", steps[0]["run"])
        self.assertIn('--base "$BASE_REF"', steps[0]["run"])
        self.assertEqual(steps[0]["env"]["BASE_REF"], "${{ github.event_name == 'pull_request' && 'HEAD^1' || '' }}")
        self.assertNotRegex(steps[0]["run"], r"bun run \S+ \|\| status=1")
        module = load(WEBVIEWS_CHECKS)
        self.assertIn("check:fixed-waits", module.CHECKS)
        self.assertIn("check:effect-cleanup", module.CHECKS)
        self.assertIn("typecheck", module.CHECKS)  # #23763's TS2339 hid behind a red base

    def test_no_web_check_waits_on_an_earlier_red(self):
        # #23763 (2026-10-21): the bundle build was red on the base, so `Build the web bundles` failed and every
        # check after it, the type check and the tests included, was skipped; the PR's own TS2339 in
        # test/composer-row-layout.test.ts merged unseen. Every step between the setup and the tests keeps going
        # on a red, and the last step fails the job on any of them.
        doc = yaml.safe_load(CI_WEB.read_text(encoding="utf-8"))
        steps = doc["jobs"]["react-apps-check-shard"]["steps"]
        names = [s.get("name", "") for s in steps]
        first, last = names.index("Setup Node") + 1, names.index("Test webviews")
        gate = steps[names.index("Fail on the gate checks")]
        self.assertEqual(gate["if"], "${{ !cancelled() }}")
        gated = list(gate["env"].values())
        for step in steps[first:last]:
            with self.subTest(step=step["name"]):
                self.assertIs(step.get("continue-on-error"), True)
        # A red that keeps going must still fail the job: every continue-on-error step, an action's too, has an id
        # whose outcome the last step reads.
        for step in steps:
            if step.get("continue-on-error") is True:
                with self.subTest(gated=step["name"]):
                    self.assertIn("id", step)
                    self.assertIn(f"${{{{ steps.{step['id']}.outcome }}}}", gated)

    def test_format_never_hides_lint_or_type_errors(self):
        # `vp check` stops at its first red: one unformatted file on the base hid every lint and type error
        # (#23763's fast gates log shows only "Formatting issues found"). Format and lint are separate pieces.
        for package in ("webviews", "cmux-tui/frontends/web"):
            path = ROOT / package / "package.json"
            if not path.is_file():
                continue
            scripts = json.loads(path.read_text())["scripts"]
            pieces = [p.strip() for p in scripts.get("check:pieces", scripts["check"]).split("&&")]
            with self.subTest(package=package):
                self.assertNotIn("vp check", pieces)
                self.assertIn("vp fmt --check", pieces)
                self.assertIn("vp lint", pieces)
                # Every caller of `check` (the hook, the fast gates, ci-web off feat-cmux-next) gets the type check.
                self.assertIn("vp check --no-fmt --no-lint", pieces)

    def test_the_type_check_covers_every_webviews_test_file(self):
        tsconfig = json.loads((ROOT / "webviews/tsconfig.json").read_text())
        roots = tuple(f"{root.rstrip('/')}/" for root in tsconfig["include"])
        tracked = subprocess.run(["git", "-C", str(ROOT), "ls-files", "--", "webviews"], capture_output=True,
                                 text=True, check=True).stdout.split()
        tests = [t[len("webviews/"):] for t in tracked if re.search(r"\.(test|spec)\.[cm]?tsx?$", t)]
        self.assertGreater(len(tests), 100)
        self.assertEqual([t for t in tests if not t.startswith(roots)], [])

    def test_wired_into_the_guards_tooling_tests(self):
        guards = yaml.safe_load(GUARDS.read_text(encoding="utf-8"))
        runs = " ".join(s.get("run", "") for s in guards["jobs"]["tooling-tests"]["steps"])
        self.assertIn("tests/test_cmux_next_fast_gates.py", runs)


def git(repo: Path, *args: str) -> str:
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def commit(repo: Path, files: dict[str, str], message: str) -> str:
    for rel, text in files.items():
        path = repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        git(repo, "add", rel)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


# A stand-in for each gate script: records its argv (and, for the crash ratchet, the base tree it
# was given), and fails when its gate name is in $FAKE_FAIL.
FAKE = textwrap.dedent("""\
    import json, os, sys
    from pathlib import Path
    name = {name!r}
    entry = {{"gate": name, "argv": sys.argv[1:], "cwd": os.getcwd()}}
    if "--base" in sys.argv and Path(sys.argv[sys.argv.index("--base") + 1]).is_dir():
        base = Path(sys.argv[sys.argv.index("--base") + 1])
        entry["base_marker"] = (base / "scripts/cmux-next/marker.txt").read_text()
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(json.dumps(entry) + "\\n")
    sys.exit(1 if name in os.environ.get("FAKE_FAIL", "").split(",") else 0)
""")


class ScriptBehavior(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="fast-gates-test-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.remote = self.tmp / "remote.git"
        seed = self.tmp / "seed"
        seed.mkdir()
        git(seed, "init", "-q", "-b", "feat-cmux-next")
        files = {path: FAKE.format(name=name) for name, path in GATE_SCRIPTS.items()}
        files["scripts/cmux-next/crash_ratchet.py"] = "print('crash-ratchet: ok')\n"
        files["scripts/cmux-next/marker.txt"] = "base\n"
        files["shared.txt"] = "one\n"
        self.root = commit(seed, files, "root")
        git(seed, "checkout", "-q", "-b", "pr")
        self.pr_head = commit(seed, {"scripts/cmux-next/marker.txt": "head\n", "pr.txt": "pr\n"}, "pr change")
        git(seed, "checkout", "-q", "feat-cmux-next")
        self.tip = commit(seed, {"tip.txt": "tip\n"}, "another merge on the base")
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next", f"pr:refs/pull/7/head")
        self.seed = seed
        self.log = self.tmp / "gates.jsonl"

    def script(self, repo: Path, *args: str, fail: str = "") -> subprocess.CompletedProcess:
        env = {**os.environ, "FAKE_LOG": str(self.log), "FAKE_FAIL": fail,
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        return subprocess.run([sys.executable, str(SCRIPT), *args, "--repo", str(repo)],
                              capture_output=True, text=True, env=env)

    def clone(self, shallow: bool = True) -> Path:
        # Shallow like actions/checkout: a dispatch must deepen until the PR head and the tip meet.
        work = self.tmp / "work"
        depth = ["--depth=1"] if shallow else []
        subprocess.run(["git", "clone", "-q", *depth, "-b", "feat-cmux-next",
                        f"file://{self.remote}", str(work)], check=True)
        return work

    def dispatch(self, work: Path, pr: str = "7", head: str | None = None, base: str | None = None):
        # The workflow's resolve job names the head and base from the API before this runs.
        return self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", pr,
                           "--head", head or git(self.remote, "rev-parse", "refs/pull/7/head"),
                           "--base", base or git(self.remote, "rev-parse", "refs/heads/feat-cmux-next"),
                           "--output", str(self.tmp / "out.txt"))

    def outputs(self) -> dict[str, str]:
        out = self.tmp / "out.txt"
        return dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)

    def gate_log(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_dispatch_merges_the_pull_request_into_the_current_tip(self):
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.outputs()
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(out["merge"], merge)
        self.assertEqual(git(work, "rev-parse", "HEAD^1"), self.tip)
        self.assertEqual(git(work, "rev-parse", "HEAD^2"), self.pr_head)
        self.assertEqual(out["web"], "false")
        self.assertEqual(out["checks"], "true")  # a dispatch runs the webviews checks on the current tip
        self.assertEqual(out["ratchet"], "false")  # no panic-ratchet baseline here at all

    def test_dispatch_conflict_fails_clearly_and_still_names_the_base(self):
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        tip = commit(seed, {"scripts/cmux-next/marker.txt": "tip edits the same line\n"}, "conflicting")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next")
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflict", result.stdout + result.stderr)
        self.assertIn("#7", result.stdout + result.stderr)
        self.assertIn(tip, result.stderr)

    def test_dispatch_deepens_past_a_stale_merge_base_the_shallow_fetch_shows(self):
        # #24250 (run 39743273392): the head had merged the tip partway along and touched none of the
        # conflicting files, yet the shallow fetch's merge base was an older commit a side merge on the
        # base reaches, because the true one sat behind the base's shallow boundary.
        spec = importlib.util.spec_from_file_location("cmux_next_fast_gates", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        merged_in = commit(seed, {"shared.txt": "two\n"}, "the base change the pull request merges in")
        git(seed, "checkout", "-q", "pr")
        git(seed, "merge", "-q", "--no-edit", "feat-cmux-next")
        git(seed, "checkout", "-q", "feat-cmux-next")
        for n in range(module.FETCH_DEPTH + 10):
            git(seed, "commit", "-q", "--allow-empty", "-m", f"base moves on {n}")
        git(seed, "checkout", "-q", "-b", "side", self.root)
        commit(seed, {"side.txt": "side\n"}, "an old branch")
        git(seed, "checkout", "-q", "feat-cmux-next")
        git(seed, "merge", "-q", "--no-ff", "--no-edit", "side")
        commit(seed, {"shared.txt": "three\n"}, "the base edits a file the pull request never touched")
        git(seed, "push", "-q", "-f", str(self.remote), "feat-cmux-next", "pr:refs/pull/7/head")
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(work, "merge-base", "--all", "refs/fast-gates/head", "HEAD^1"), merged_in)
        self.assertEqual((work / "shared.txt").read_text(), "three\n")

    def test_dispatch_deepens_when_a_cut_hides_that_one_merge_base_descends_from_another(self):
        # Both sides reach the true base A at the cut and its ancestor B through short side branches, so the
        # shallow fetch reports {A, B}: no cut lies ahead of them, yet B is stale and the virtual base conflicts.
        spec = importlib.util.spec_from_file_location("cmux_next_fast_gates", SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        b = self.tip
        a = commit(seed, {"shared.txt": "two\n"}, "A: the true merge base")

        def side(name: str) -> str:
            git(seed, "checkout", "-q", "-b", name, b)
            return commit(seed, {f"{name}.txt": f"{name}\n"}, f"{name} off B")

        def tip(branch: str, files: dict[str, str]) -> None:
            git(seed, "checkout", "-q", "-B", branch, a)
            commit(seed, files, f"{branch} after A")
            for n in range(module.FETCH_DEPTH - 3):
                git(seed, "commit", "-q", "--allow-empty", "-m", f"{branch} moves on {n}")
            git(seed, "merge", "-q", "--no-ff", "--no-edit", f"side-{branch}")

        side("side-pr")
        side("side-feat-cmux-next")
        tip("pr", {"pr.txt": "pr\n"})
        tip("feat-cmux-next", {"shared.txt": "three\n"})
        git(seed, "push", "-q", "-f", str(self.remote), "feat-cmux-next", "pr:refs/pull/7/head")
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(work, "merge-base", "--all", "refs/fast-gates/head", "HEAD^1"), a)
        self.assertEqual((work / "shared.txt").read_text(), "three\n")

    def test_dispatch_refuses_a_head_that_moved_after_resolve(self):
        work = self.clone()
        result = self.dispatch(work, head="e" * 40)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the resolved head", result.stderr)
        self.assertEqual(self.gate_log(), [])

    def test_dispatch_refuses_a_base_that_is_not_on_the_branch(self):
        git(self.seed, "checkout", "-q", "-b", "elsewhere", self.root)
        other = commit(self.seed, {"other.txt": "x\n"}, "not on feat-cmux-next")
        git(self.seed, "push", "-q", str(self.remote), "elsewhere")
        work = self.clone()
        git(work, "fetch", "-q", "origin", "elsewhere")
        result = self.dispatch(work, base=other)
        self.assertEqual(result.returncode, 1)
        self.assertIn("not on feat-cmux-next", result.stderr)

    def test_prepare_needs_full_shas_for_head_and_base(self):
        work = self.clone()
        for flag in ("head", "base"):
            with self.subTest(flag=flag):
                result = self.dispatch(work, **{flag: "abc123"})
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"--{flag} must be a full commit sha", result.stderr)

    def test_dispatch_refuses_a_pr_that_is_not_digits(self):
        work = self.clone()
        for bad in ("7; rm -rf /", "", "07a", "-1"):
            with self.subTest(pr=bad):
                result = self.dispatch(work, pr=bad)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("pull request number", result.stderr)

    def test_pull_request_uses_the_checked_out_merge(self):
        work = self.clone(shallow=False)
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        result = self.script(work, "prepare", "--event", "pull_request", "--head", self.pr_head,
                             "--base", self.tip, "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["merge"], git(work, "rev-parse", "HEAD"))
        self.assertEqual(self.outputs()["checks"], "false")  # ci-web runs them on this same merge
        self.assertEqual(self.outputs()["ratchet"], "false")  # cmux-tui-spec's clippy job ran it on this merge
        self.assertNotIn("head_sha", self.outputs(), "head and base come from resolve, not from here")

    PANIC_ROWS = {"acpmux": {"unwrap_used": 3, "indexing_slicing": 700, "arithmetic_side_effects": 1430},
                  "cmux-tui": {"unwrap_used": 5, "indexing_slicing": 834, "arithmetic_side_effects": 90}}

    def panic_baseline(self, **lower) -> str:
        """The baseline with `crate__lint=value` rows lowered (rust-panic-baseline.json's shape)."""
        rows = json.loads(json.dumps(self.PANIC_ROWS))
        for key, value in lower.items():
            crate, lint = key.split("__")
            rows[crate.replace("_", "-")][lint] = value
        return json.dumps({"lints": ["unwrap_used", "indexing_slicing", "arithmetic_side_effects"],
                           "deny_lints": ["unwrap_used", "indexing_slicing"], "crates": rows}, indent=1) + "\n"

    def ratchet_dispatch(self, pr_files: dict[str, str], **lower) -> subprocess.CompletedProcess:
        """#28182's shape: PR 8 branches from a base with the baseline, changes `pr_files`, and the tip then
        lowers the rows in `lower`. Returns the dispatch's prepare."""
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        commit(seed, {"scripts/cmux-next/rust-panic-baseline.json": self.panic_baseline()}, "baseline")
        git(seed, "checkout", "-q", "-b", "pr8")
        head = commit(seed, pr_files, "pr 8")
        git(seed, "checkout", "-q", "feat-cmux-next")
        base = commit(seed, {"scripts/cmux-next/rust-panic-baseline.json": self.panic_baseline(**lower),
                             "tip2.txt": "tip\n"}, "lower the baseline")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next", "pr8:refs/pull/8/head")
        return self.dispatch(self.clone(), pr="8", head=head, base=base)

    def test_dispatch_reruns_the_ratchet_when_the_tip_lowered_a_row_the_pull_request_changes(self):
        # #28182: acpmux indexing_slicing went 700 -> 693 on the base after the PR's ratchet ran green.
        result = self.ratchet_dispatch({"cmux-tui/crates/acpmux/src/lib.rs": "fn f() {}\n"},
                                       acpmux__indexing_slicing=693)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "true")
        self.assertIn("acpmux", result.stderr)

    def test_a_row_lowered_for_another_crate_reruns_nothing(self):
        result = self.ratchet_dispatch({"cmux-tui/crates/acpmux/src/lib.rs": "fn f() {}\n"},
                                       cmux_tui__indexing_slicing=800)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "false")

    def test_a_lowered_tracked_lint_reruns_nothing(self):
        # arithmetic_side_effects only warns, so a PR over its lowered row cannot turn the base red.
        result = self.ratchet_dispatch({"cmux-tui/crates/acpmux/src/lib.rs": "fn f() {}\n"},
                                       acpmux__arithmetic_side_effects=1400)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "false")

    def test_a_pull_request_with_no_rust_reruns_nothing(self):
        result = self.ratchet_dispatch({"docs/notes.md": "notes\n"}, acpmux__indexing_slicing=693)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "false")

    def test_a_workspace_wide_rust_input_reruns_for_any_lowered_row(self):
        result = self.ratchet_dispatch({"cmux-tui/Cargo.lock": "# lock\n"}, cmux_tui__unwrap_used=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "true")

    def test_a_crate_dropped_from_the_baseline_counts_as_lowered_to_zero(self):
        result = self.ratchet_dispatch({"cmux-tui/crates/cmux-tui/src/lib.rs": "fn f() {}\n"})
        self.assertEqual(self.outputs()["ratchet"], "false", "nothing lowered yet")
        seed = self.seed
        rows = json.loads(self.panic_baseline())
        del rows["crates"]["cmux-tui"]
        base = commit(seed, {"scripts/cmux-next/rust-panic-baseline.json": json.dumps(rows)}, "cmux-tui at deny")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next")
        subprocess.run(["rm", "-rf", str(self.tmp / "work")], check=True)
        result = self.dispatch(self.clone(), pr="8", head=git(self.remote, "rev-parse", "refs/pull/8/head"),
                               base=base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["ratchet"], "true")

    def test_pull_request_deepens_so_a_head_that_brings_the_base_in_is_not_a_cut(self):
        # #24526 at 3a47dc1f: the head was a commit bringing the base in. The merge ref's depth-2 checkout cut it,
        # so it read as a root adding the whole tree, and the Sidebar-Look check saw 162 sidebar files.
        seed = self.seed
        git(seed, "checkout", "-q", "-b", "pr8", self.root)
        own = commit(seed, {"pr8.txt": "pr8\n"}, "the pull request's own change")
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit",
            "feat-cmux-next")
        head = git(seed, "rev-parse", "HEAD")
        git(seed, "checkout", "-q", "--detach", self.tip)
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit", head)
        git(seed, "push", "-q", str(self.remote), f"{head}:refs/pull/8/head", "HEAD:refs/pull/8/merge")
        git(seed, "checkout", "-q", "feat-cmux-next")
        git(self.remote, "config", "uploadpack.allowReachableSHA1InWant", "true")  # as GitHub allows
        work = self.tmp / "work8"
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", f"file://{self.remote}")
        git(work, "fetch", "-q", "--depth=2", "origin", "refs/pull/8/merge")  # what actions/checkout does
        git(work, "checkout", "-q", "--detach", "FETCH_HEAD")
        self.assertIn(head, (work / ".git" / "shallow").read_text(), "the fixture must start with the head cut")

        result = self.script(work, "prepare", "--event", "pull_request", "--head", head, "--base", self.tip,
                             "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(git(work, "rev-list", "--no-merges", f"{self.tip}..{merge}").split(), [own])
        self.assertEqual(git(work, "diff-tree", "--no-commit-id", "--name-only", "-r", "--root", own).split(),
                         ["pr8.txt"])

    def test_pull_request_in_a_full_clone_fetches_nothing_more(self):
        work = self.clone(shallow=False)
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        git(work, "remote", "set-url", "origin", str(self.tmp / "missing.git"))  # a fetch would fail

        result = self.script(work, "prepare", "--event", "pull_request", "--head", self.pr_head,
                             "--base", self.tip, "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pull_request_merge_onto_another_base_fails(self):
        work = self.clone(shallow=False)
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        result = self.script(work, "prepare", "--event", "pull_request", "--head", self.pr_head,
                             "--base", self.root, "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the resolved base", result.stderr)

    def test_pull_request_merge_of_another_head_fails(self):
        work = self.clone(shallow=False)
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        result = self.script(work, "prepare", "--event", "pull_request", "--head", "f" * 40,
                             "--base", self.tip, "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the pull request head", result.stderr)

    def test_a_catalog_or_protocol_spec_change_runs_the_webviews_checks_on_a_pull_request(self):
        # ci-web runs them only for a webviews/ change; check:catalog-keys and acpmux-protocol:check read these.
        seed = self.seed
        for path in ("Resources/Localizable.xcstrings", "cmux-tui/crates/acpmux/spec/acpmux-protocol.json"):
            with self.subTest(path=path):
                git(seed, "checkout", "-q", "pr")
                head = commit(seed, {path: f"{path}\n"}, f"change {path}")
                git(seed, "push", "-q", "-f", str(self.remote), "pr:refs/pull/7/head")
                work = self.tmp / f"work-{path.count('/')}"
                subprocess.run(["git", "clone", "-q", "-b", "feat-cmux-next", f"file://{self.remote}", str(work)],
                               check=True)
                git(work, "fetch", "-q", "origin", "refs/pull/7/head")
                git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
                    "--no-edit", "FETCH_HEAD")
                (self.tmp / "out.txt").unlink(missing_ok=True)
                result = self.script(work, "prepare", "--event", "pull_request", "--head", head,
                                     "--base", self.tip, "--output", str(self.tmp / "out.txt"))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.outputs()["checks"], "true")

    def test_a_web_change_asks_for_the_web_tools(self):
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        commit(seed, {"webviews/package.json": '{"scripts": {"check": "true"}}\n'}, "webviews package")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next")
        git(seed, "checkout", "-q", "pr")
        head = commit(seed, {"webviews/src/a.ts": "export const a = 1;\n"}, "web change")
        git(seed, "push", "-q", "-f", str(self.remote), "pr:refs/pull/7/head")
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(work, "rev-parse", "HEAD^2"), head)
        self.assertEqual(self.outputs()["web"], "true")

    def prepared(self) -> tuple[Path, dict[str, str]]:
        work = self.clone()
        result = self.dispatch(work)
        self.assertEqual(result.returncode, 0, result.stderr)
        return work, self.outputs()

    def test_run_calls_every_gate_against_the_base(self):
        work, out = self.prepared()
        summary = self.tmp / "summary.md"
        result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "true",
                             "--summary", str(summary))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = {entry["gate"]: entry for entry in self.gate_log()}
        self.assertEqual(set(calls), set(GATE_SCRIPTS))
        base, merge = self.tip, out["merge"]
        self.assertEqual(calls["web lint"]["argv"][:4], ["--base", base, "--head", merge])
        self.assertIn("--new-only", calls["web lint"]["argv"])  # per error over the base, not per job
        self.assertEqual(calls["prepush gate"]["argv"][:4], ["--base", base, "--head", merge])
        self.assertEqual(calls["webviews checks"]["argv"], ["--base", base])
        ratchet = calls["crash ratchet"]["argv"]
        self.assertEqual(ratchet[:2], ["--script", "scripts/cmux-next/crash_ratchet.py"])
        self.assertEqual(Path(ratchet[ratchet.index("--head") + 1]).resolve(), work.resolve())
        # The ratchet's and the crash-class rules' base tree is BASE exported, not the merge.
        self.assertEqual(calls["crash ratchet"]["base_marker"], "base\n")
        self.assertEqual(calls["crash-class rules"]["argv"][0], "--base")
        self.assertEqual(calls["crash-class rules"]["base_marker"], "base\n")
        for entry in calls.values():
            self.assertEqual(Path(entry["cwd"]).resolve(), work.resolve())
        text = summary.read_text()
        for name in GATE_SCRIPTS:
            self.assertIn(name, text)
        self.assertIn(base, text)

    def test_one_red_gate_fails_the_run_and_the_rest_still_run(self):
        work, out = self.prepared()
        for red in GATE_SCRIPTS:
            with self.subTest(red=red):
                self.log.unlink(missing_ok=True)
                result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "true", fail=red)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS))
                self.assertRegex(result.stdout + result.stderr, rf"(?m)^.*{re.escape(red)}.*fail")

    def test_no_web_change_skips_web_lint_only(self):
        work, out = self.prepared()
        result = self.script(work, "run", "--base", self.tip, "--web", "false", "--checks", "true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"web lint"})
        self.assertIn("web lint: skipped (no web path changed)", result.stdout)

    def test_a_pull_request_event_skips_the_webviews_checks(self):
        work, out = self.prepared()
        result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"webviews checks"})
        self.assertIn("webviews checks: skipped", result.stdout)

    def test_run_refuses_a_base_that_is_not_a_commit(self):
        work, _ = self.prepared()
        result = self.script(work, "run", "--base", "0" * 40, "--web", "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.gate_log(), [])


# A stand-in for bun: `install` succeeds; `run CHECK` prints webviews/findings/CHECK (each line a finding) and
# fails when that file has any.
FAKE_BUN = textwrap.dedent("""\
    #!/bin/sh
    if [ "$1" = install ]; then [ -n "$BUN_LOG" ] && pwd -P >> "$BUN_LOG"; exit 0; fi
    f="findings/$2"
    [ -s "$f" ] || { echo "$2: ok"; exit 0; }
    echo "$2: found"; cat "$f"; exit 1
""")


def type_error(code: str, message: str, where: str) -> str:
    """One type error as `vp check --no-fmt --no-lint` prints it (Oxlint's graphical report)."""
    return (f"  x typescript({code}): {message}\n     ,-[{where}]\n 1 | const a = 1;\n"
            "     :       ^\n     `----\n\n")


class WebviewsChecksGate(unittest.TestCase):
    """scripts/ci/fast_gate_webviews_checks.py fails only on findings the pull request adds over BASE."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="webviews-checks-test-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        (self.bin / "bun").write_text(FAKE_BUN)
        (self.bin / "bun").chmod(0o755)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "feat-cmux-next")
        spec = importlib.util.spec_from_file_location("fast_gate_webviews_checks", WEBVIEWS_CHECKS)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def findings(self, by_check: dict[str, str], message: str) -> str:
        files = {"webviews/package.json": "{}\n", "webviews/marker.txt": message + "\n"}
        for check in self.module.CHECKS:
            files[f"webviews/findings/{check}"] = by_check.get(check, "")
        return commit(self.repo, files, message)

    def gate(self, base: str) -> subprocess.CompletedProcess:
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}
        return subprocess.run([sys.executable, str(WEBVIEWS_CHECKS), "--base", base, "--repo", str(self.repo)],
                              capture_output=True, text=True, env=env)

    def test_a_check_the_pull_request_breaks_fails(self):
        base = self.findings({}, "base, green")
        self.findings({"check:fixed-waits": "  test/agent-pane-queued-images.test.ts: 2 fixed waits, baseline 0\n"},
                      "the merge")
        result = self.gate(base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("check:fixed-waits failed", result.stdout)

    def test_replay_of_22975_its_own_finding_over_a_red_base_fails(self):
        # #22975 merged with 01ea78b3, the commit that added check:fixed-waits: the base already had two findings,
        # the merge adds a third, in a test file of its own.
        red = ("  test/agent-pane-history-paging.test.ts: 3 fixed waits, baseline 2\n"
               "    test/agent-pane-history-paging.test.ts:191\n"
               "  test/agent-pane-stream-jitter.test.ts: 23 fixed waits, baseline 22\n"
               "    test/agent-pane-stream-jitter.test.ts:178\n")
        base = self.findings({"check:fixed-waits": red}, "01ea78b3")
        self.findings({"check:fixed-waits": red.replace(":191", ":195")
                       + "  test/agent-pane-queued-images.test.ts: 2 fixed waits, baseline 0\n"}, "#22975 merged")
        result = self.gate(base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        added = result.stdout.split("adds, over the base", 1)[1]
        self.assertIn("agent-pane-queued-images.test.ts: 2 fixed waits, baseline 0", added)
        self.assertNotIn("history-paging", added)  # a line number the merge moved is not a new finding

    def test_a_base_red_the_pull_request_adds_nothing_to_passes(self):
        red = "  test/a.test.ts: 3 fixed waits, baseline 2\n"
        base = self.findings({"check:fixed-waits": red}, "red base")
        self.findings({"check:fixed-waits": red}, "the merge, same red")
        result = self.gate(base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fails on the base", result.stdout)
        self.assertIn("all passed", result.stdout)

    def test_one_more_wait_in_a_file_the_base_already_fails_is_the_pull_requests(self):
        base = self.findings({"check:fixed-waits": "  test/a.test.ts: 3 fixed waits, baseline 2\n"}, "red base")
        self.findings({"check:fixed-waits": "  test/a.test.ts: 4 fixed waits, baseline 2\n"}, "the merge")
        self.assertEqual(self.gate(base).returncode, 1)

    def test_every_check_runs_after_a_red_one(self):
        base = self.findings({}, "base")
        self.findings({check: "  x\n" for check in self.module.CHECKS}, "all red")
        result = self.gate(base)
        self.assertEqual(result.returncode, 1)
        for check in self.module.CHECKS:
            self.assertIn(f"{check}: found", result.stdout)

    def test_a_second_finding_that_reads_like_a_base_one_is_new(self):
        base = self.findings({"check:catalog-keys": "  Localizable: key ok_button twice\n"}, "red base")
        self.findings({"check:catalog-keys": "  Localizable: key ok_button twice\n" * 2}, "the merge")
        self.assertEqual(self.gate(base).returncode, 1)

    def test_a_base_that_cannot_be_checked_out_charges_the_red_here(self):
        self.findings({}, "base")
        self.findings({"check:fixed-waits": "  x\n"}, "red")
        result = self.gate("f" * 40)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("could not check out the base", result.stdout)

    def test_the_checkout_root_and_timings_are_not_findings(self):
        added = self.module.added("  /w/merge/webviews/a.ts: bad (12.5s)\n", "  /w/base/webviews/a.ts: bad (3s)\n",
                                  "/w/merge", "/w/base")
        self.assertEqual(added, [])

    def test_replay_of_24274_the_format_check_file_count_is_not_a_finding(self):
        # #24274's fast gates: the base's `vp fmt --check` was red on the same files as the merge, and the merge
        # (with the pull request's new test files) closed on 2481 files where the base closed on 2479. That closing
        # line read as the one finding the merge added.
        red = "src/a.ts (2ms)\nFormat issues found in above 1 files. Run without `--check` to fix.\n"
        self.assertEqual(self.module.added(red + "Finished in 528ms on 2481 files using 4 threads.\n",
                                           red + "Finished in 2057ms on 2479 files using 4 threads.\n"), [])
        self.assertEqual(self.module.added("src/b.ts (1ms)\n" + red + "Finished in 5ms on 2481 files using 4 threads.\n",
                                           red + "Finished in 9ms on 2479 files using 4 threads.\n"), ["src/b.ts (1ms)"])
        # Only the whole closing line is noise: a file whose name starts like it is still a finding.
        self.assertEqual(self.module.added("Finished in 1ms on 2 files.ts (1ms)\n" + red, red),
                         ["Finished in 1ms on 2 files.ts (1ms)"])

    def test_a_format_issue_the_change_fixes_adds_no_finding(self):
        # The merge fixes one of the base's two misformatted files, so its count line reads "1 files" where the
        # base's reads "2 files"; that line is the run's, not a finding the merge adds.
        def fmt(*files: str) -> str:
            return "".join(f"{name} (2ms)\n" for name in files) + (
                f"Format issues found in above {len(files)} files. Run without `--check` to fix.\n"
                "Finished in 5ms on 2481 files using 4 threads.\n")
        self.assertEqual(self.module.added(fmt("src/a.ts"), fmt("src/a.ts", "src/b.ts")), [])
        self.assertEqual(self.module.added(fmt("src/a.ts", "src/c.ts"), fmt("src/a.ts", "src/b.ts")), ["src/c.ts (2ms)"])

    def test_replay_of_24524_the_lint_file_count_is_not_a_finding(self):
        # #24524's fast gates: the base's `vp lint` was red with the same 4 findings as the merge, and the merge
        # (with the pull request's one new test file) closed on 2465 files. `vp lint`'s closing line names its rules
        # too, so the `vp fmt` pattern missed it and it read as the one finding the merge added.
        red = "  x eslint(no-unused-vars): 'a' is declared but never used.\n"
        self.assertEqual(self.module.added(red + "Finished in 4.8s on 2465 files with 162 rules using 4 threads.\n",
                                           red + "Finished in 5.1s on 2464 files with 162 rules using 4 threads.\n"), [])
        self.assertEqual(self.module.added("Finished in 1ms on 2 files with 3 rules.ts (1ms)\n" + red, red),
                         ["Finished in 1ms on 2 files with 3 rules.ts (1ms)"])

    def test_replay_of_24252_unicode_frames_in_another_order_add_nothing(self):
        # #24252's fast gates: Oxlint printed its Unicode frame (`╭─[`, `│`, `·`, `╰`), and with 4 threads the
        # base and the merge listed the same 84 errors in another order. The run's summary glued onto whichever
        # error came last, so the base's Toasts.tsx TS2339 read as one the merge added.
        def unicode_error(message: str, where: str) -> str:
            return (f"  × typescript(TS2339): {message}\n    ╭─[{where}]\n 18 │           </div>\n"
                    f" 19 │           <button onClick={{() => onDismiss(toast.notification)}}>\n"
                    "    ·                                                ────────────\n 20 │             ×\n    ╰────\n\n")
        toast = unicode_error("Property 'notification' does not exist on type 'Toast'.", "src/components/Toasts.tsx:19:64")
        row = unicode_error("Property 'muted' does not exist on type 'Row'.", "src/components/Row.tsx:7:9")
        summary = ("Found 2 errors and 0 warnings in 2 files ({} 4 threads)\nnote: You are running `vp check` as a Vite+ "
                   "built-in command.\nerror: Type errors found\n")
        self.assertEqual(self.module.added(row + toast + summary.format("715ms,"), toast + row + summary.format("9ms,")), [])
        self.assertEqual([found for found, _ in self.module.findings(toast + summary.format("1ms,"))],
                         ["src/components/Toasts.tsx: typescript(TS2339): Property 'notification' does not exist on type 'Toast'."])

    def test_replay_of_23763_a_new_type_error_fails_over_a_base_red_with_another(self):
        # The base's type check is already red (a missing module); the merge moves that error two lines and adds
        # #23763's TS2339. Per error, the new one fails the gate and the base one stays a warning.
        base = self.findings({"typecheck": type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")},
                             "red base")
        self.findings({"typecheck": type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:6:21")
                       + type_error("TS2339", "Property 'muted' does not exist on type 'Row'.",
                                    "test/composer-row-layout.test.ts:350:22")}, "#23763 merged")
        result = self.gate(base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        added = result.stdout.split("typecheck adds, over the base", 1)[1].split("webviews checks:", 1)[0]
        self.assertIn("test/composer-row-layout.test.ts: typescript(TS2339): Property 'muted'", added)
        self.assertNotIn("src/a.ts", added)
        self.assertIn("::error title=webviews typecheck::", result.stdout)
        self.assertRegex(result.stdout, r"::warning title=webviews typecheck \(base\)::\d+ error")
        self.assertIn("base: src/a.ts: typescript(TS2307)", result.stdout)

    def test_a_base_only_type_error_is_a_warning(self):
        red = type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")
        base = self.findings({"typecheck": red + type_error("TS2322", "Type 'string' is not assignable.", "src/b.ts:9:3")},
                             "red base")
        self.findings({"typecheck": red.replace(":4:21", ":40:21")}, "the merge fixes one, adds none")
        result = self.gate(base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning title=webviews typecheck (base)::", result.stdout)
        self.assertIn("src/a.ts: typescript(TS2307)", result.stdout)

    def test_the_same_type_error_twice_in_a_file_is_new_the_second_time(self):
        red = type_error("TS2339", "Property 'muted' does not exist on type 'Row'.", "test/r.test.ts:350:22")
        base = self.findings({"typecheck": red}, "red base")
        self.findings({"typecheck": red + red.replace(":350:", ":351:")}, "the merge")
        self.assertEqual(self.gate(base).returncode, 1)

    def test_a_type_error_keys_on_file_code_and_message_not_line_or_frame(self):
        output = ("\x1b[31m  x typescript(TS2339): Property 'muted' does not exist on type 'Row'.\x1b[0m\n"
                  "     ,-[test/composer-row-layout.test.ts:350:22]\n"
                  " 349 |       expect(running.fill).toBe(\"rgba(0, 0, 0, 0)\");\n"
                  " 350 |       expect(running.muted).not.toBe(running.text);\n"
                  "     :                      ^^^^^\n"
                  "     `----\n\nFound 1 error and 0 warnings in 2325 files (3.3s, 12 threads)\n")
        self.assertEqual([key for key, _ in self.module.findings(output)],
                         ["test/composer-row-layout.test.ts: typescript(TS2339): "
                          "Property 'muted' does not exist on type 'Row'."])

    def test_a_push_with_no_base_charges_every_red(self):
        self.findings({"typecheck": type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")}, "red")
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}
        result = subprocess.run([sys.executable, str(WEBVIEWS_CHECKS), "--repo", str(self.repo)],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("typecheck failed", result.stdout)

    def base_installs(self, base_lock: str, head_lock: str) -> list[str]:
        """The base checks' bun installs when the merge's webviews/node_modules exists and the locks are as given."""
        (self.repo / ".gitignore").write_text("node_modules/\n")
        git(self.repo, "add", ".gitignore")
        (self.repo / "webviews/bun.lock").parent.mkdir(parents=True, exist_ok=True)
        (self.repo / "webviews/bun.lock").write_text(base_lock)
        git(self.repo, "add", "webviews/bun.lock")
        red = type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")
        base = self.findings({"typecheck": red}, "base")
        (self.repo / "webviews/bun.lock").write_text(head_lock)
        git(self.repo, "add", "webviews/bun.lock")
        self.findings({"typecheck": red}, "the merge")
        (self.repo / "webviews/node_modules").mkdir()
        log = self.tmp / "bun-installs.log"
        env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "BUN_LOG": str(log)}
        result = subprocess.run([sys.executable, str(WEBVIEWS_CHECKS), "--base", base, "--repo", str(self.repo)],
                                capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        merge = str((self.repo / "webviews").resolve())
        return [line for line in log.read_text().splitlines() if line != merge]

    def test_the_base_installs_its_own_dependencies_when_the_pull_request_changes_them(self):
        # A pull request that bumps a dependency and so adds a type error must not have the base checked with the
        # bumped dependency, where the same error would show and pass as the base's.
        installs = self.base_installs("lock: typescript 5.9\n", "lock: typescript 6.0\n")
        self.assertEqual(len(installs), 1, installs)
        self.assertIn("fast-gate-webviews-base-", installs[0])

    def test_the_base_shares_the_merges_dependencies_when_they_install_the_same(self):
        self.assertEqual(self.base_installs("lock: same\n", "lock: same\n"), [])

    def test_a_new_failure_beside_a_known_diagnostic_is_new(self):
        known = type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")
        new = self.module.added(known + "error: Failed to resolve vite config: ENOENT\n", known)
        self.assertEqual(new, ["error: Failed to resolve vite config: ENOENT"])

    def test_a_wrapped_message_compares_whole(self):
        def wrapped(detail: str) -> str:
            return (f"  x typescript(TS2322): Type '{{ a: number; }}' is not assignable to type 'Props'.\n"
                    f"  |   {detail}\n     ,-[src/a.tsx:3:7]\n 3 | <A a={{1}} />\n     :  ^\n     `----\n")
        self.assertEqual(len(self.module.added(wrapped("Property 'y' is missing in type"),
                                               wrapped("Property 'x' is missing in type"))), 1)
        self.assertEqual(self.module.added(wrapped("Property 'x' is missing in type"),
                                           wrapped("Property 'x' is missing in type")), [])

    def test_fewer_errors_than_the_base_adds_nothing(self):
        a = type_error("TS2307", "Cannot find module './x.json'.", "src/a.ts:4:21")
        b = type_error("TS2322", "Type 'string' is not assignable.", "src/b.ts:9:3")
        self.assertEqual(self.module.added(f"error: Type errors found\n{a}Found 1 error and 0 warnings in 9 files (1.0s)\n",
                                           f"error: Type errors found\n{a}{b}Found 2 errors and 0 warnings in 9 files (2.1s)\n"),
                         [])

    def test_vp_lint_count_that_falls_adds_nothing(self):
        # #24538's web lint: `vp lint` puts warnings first. The base said 4 errors; the merge fixed 3 of them, and
        # its `Found 0 warnings and 1 error.` failed the job as "1 finding over the base".
        errors = [type_error("TS2307", f"Cannot find module './{n}.json'.", f"src/{n}.ts:4:21") for n in "abcd"]
        self.assertEqual(self.module.added(f"{errors[0]}Found 0 warnings and 1 error.\n",
                                           "".join(errors) + "Found 0 warnings and 4 errors.\n"), [])
        self.assertEqual(self.module.added(f"{errors[0]}Found 2 warnings and 1 error.\n",
                                           f"{errors[0]}Found 1 warning and 1 error.\n"), [])
        # a line that only starts like the summary is still a finding, and so is text after a whole summary
        self.assertEqual(self.module.added("Found 1 warning and the rest\n", ""), ["Found 1 warning and the rest"])
        for crash in ("Found 1 warning and 1 error: panic", "Found 1 error and 0 warnings in 9 files (1.0s) then a panic",
                      "Found 1 warning and 1 error (panic)"):
            self.assertEqual(self.module.added(f"{errors[0]}{crash}\n", f"{errors[0]}Found 0 warnings and 1 error.\n"),
                             [crash])

    def test_a_wrapped_message_that_reads_like_the_summary_is_message_text(self):
        # An unframed diagnostic's message wraps onto the next line with no blank line between; a line there that
        # reads like the run's count is part of that message, so a new one is still a finding.
        summary = "Found 0 warnings and 1 error.\n"
        merge = "  x eslint(no-restricted-syntax): banned pattern\n  Found 0 warnings and 1 error.\n\n" + summary
        base = "  x eslint(no-restricted-syntax): banned pattern\n\n" + summary
        self.assertEqual(self.module.added(merge, base),
                         ["eslint(no-restricted-syntax): banned pattern Found 0 warnings and 1 error."])
        self.assertEqual(self.module.added(base, base), [])

    def test_vp_lint_warning_summary_in_either_order_is_noise(self):
        summary = "Found 5 warnings and 0 errors in 2481 files (1.0s)\n"
        self.assertEqual(self.module.findings(summary), [])

    def test_the_base_worktree_is_removed(self):
        base = self.findings({}, "base")
        self.findings({"check:fixed-waits": "  x\n"}, "red")
        self.gate(base)
        self.assertEqual(len(git(self.repo, "worktree", "list").splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
