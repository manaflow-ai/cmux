#!/usr/bin/env python3
"""cmux-next fast gates: the PR merged with its base, five gates in fail mode, one commit status.

Four base reds landed on 2026-10-21 through checks that only warn on a pull request or run only
on push: webviews lint/format and switch-fetches (ci-web's react-apps-check is warn-only on a PR;
cmux-next-web-lint.yml's `web lint (fast)` fails only on push), a self-merge past its own red
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
import time
import unittest
from pathlib import Path

import yaml
# tests/git_fixture_env.py, loaded by path: `python3 -I` puts no script folder on sys.path.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
# tests/process_gone.py, loaded by path the same way.
_process_gone_spec = _git_fixture_importlib.spec_from_file_location(
    "process_gone", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), "process_gone.py"))
process_gone = _git_fixture_importlib.module_from_spec(_process_gone_spec)
_process_gone_spec.loader.exec_module(process_gone)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workflow_jobs  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
NOT_POOL = "!startsWith(runner.name, 'cmux-runner-pool-')"
WORKFLOW = ROOT / ".github/workflows/cmux-next-fast-gates.yml"
GUARDS = ROOT / ".github/workflows/cmux-next-guards.yml"
SCRIPT = ROOT / "scripts/ci/cmux_next_fast_gates.py"
GATE_SCRIPTS = {
    "web lint": "scripts/web_lint_prepush.py",
    "crash ratchet": "scripts/ci/crash_ratchet_compare.py",
    "prepush gate": "scripts/cmux-next/prepush-gate.py",
    "crash-class rules": "scripts/ci/crash_class_fast_gate.py",
    "webviews checks": "scripts/ci/fast_gate_webviews_checks.py",
    "protocol skew": "scripts/ci/protocol_skew_check.py",
    "entry logs": "scripts/ci/entry_logs.py",
    "settings catalog keys": "scripts/ci/settings_catalog_keys.py",
    "egress gate": "scripts/ci/egress_new_sites.py",
}
# Every gate starts in the first batch except webviews checks, which waits behind web lint; derived so a new gate
# does not leave the parallel barrier one marker short.
FIRST_BATCH_GATES = len(GATE_SCRIPTS) - 1
CI_WEB = ROOT / ".github/workflows/ci-web.yml"
WEBVIEWS_CHECKS = ROOT / "scripts/ci/fast_gate_webviews_checks.py"


def load(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def fast_gates_source() -> str:
    return (ROOT / "scripts/ci/cmux_next_fast_gates.py").read_text(encoding="utf-8")


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
    def test_callers_forward_status_secrets(self):
        # Run 45940333376/job 140314249449: the router passed no secrets, so minting the app token
        # failed and a green gate could not post its status after the repository token hit quota.
        # Derive the contract from every secret the callee reads, so a new fallback cannot silently
        # work on dispatch alone. GITHUB_TOKEN is supplied by Actions, not by the caller.
        secrets = set(re.findall(r"secrets\.([A-Za-z_][A-Za-z_0-9]*)", WORKFLOW.read_text())) - {"GITHUB_TOKEN"}
        declared = (workflow()[True]["workflow_call"] or {}).get("secrets", {})
        self.assertTrue(secrets)
        self.assertEqual(set(declared), secrets)
        for secret in secrets:
            self.assertFalse(declared[secret].get("required", False))
        callers = []
        for path in sorted(WORKFLOW.parent.glob("*.yml")):
            if "uses: ./.github/workflows/cmux-next-fast-gates.yml" not in path.read_text():
                continue
            for name, caller in yaml.safe_load(path.read_text())["jobs"].items():
                if caller.get("uses") != "./.github/workflows/cmux-next-fast-gates.yml":
                    continue
                callers.append((path.name, name))
                with self.subTest(workflow=path.name, job=name):
                    self.assertEqual(caller.get("secrets"), {
                        secret: "${{ secrets." + secret + " }}" for secret in secrets
                    })
        self.assertTrue(callers)

    def test_name_job_and_runner(self):
        doc = workflow()
        self.assertEqual(doc["name"], "cmux-next fast gates")
        self.assertEqual(list(doc["jobs"]), ["resolve", "fast-gates", "panic-ratchet", "post", "fast-gates-fail-fast",
                                           "lane-receipt-audit"])
        self.assertEqual(job(doc)["name"], "fast gates")
        # Linux CI is one persistent pool (hq decisions/junctions.md 2026-11-20): every job names cmux-linux past the
        # fork branches, with no placement job and no dispatch runner input. Fork pull requests keep their ephemeral
        # Blacksmith branch. The light jobs never took hosted Ubuntu again after it left them queued for hours
        # (cmux#45735).
        self.assertNotIn("runner", doc[True]["workflow_dispatch"]["inputs"])
        declared = json.loads((ROOT / ".github/runners.json").read_text())["hosted_light_jobs"]
        for key, each in doc["jobs"].items():
            # resolve is held to the 2-vCPU pool by fast_check_route.py check: it carries the route (route_job), so
            # the decision takes no pool runner.
            if key == "resolve":
                continue
            # A reusable-workflow caller (the head fail-fast job) takes its runner and bound in the called workflow.
            if "uses" in each:
                continue
            with self.subTest(runner=key):
                self.assertNotIn(f"cmux-next-fast-gates.yml#{key}", declared)
                cells = workflow_jobs.runs_on_cells(each)
                self.assertTrue(cells, f"{key}: no runs-on, or a matrix value nothing resolves")
                for runner in cells:
                    self.assertTrue(runner.startswith(
                        "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == "
                        "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && "
                        "'ubuntu-24.04' || "), runner)
                    self.assertNotIn("github.run_attempt == 1 && 'ubuntu-24.04'", runner)
                    self.assertNotIn("needs.", runner)
                    self.assertNotIn("inputs.", runner)
                    # #48644 (2026-11-23): every own-branch Linux job, the write-token ones too, takes the one
                    # cmux-linux label; only the fork branch reads a variable.
                    self.assertTrue(runner.endswith("|| 'cmux-linux' }}"), runner)
                    self.assertNotIn("vars.RUNNER_POOLS", runner)
                    self.assertNotIn("macos", runner.lower())
                    self.assertNotIn("vars.LINUX_RUNNER", runner)
        for key, each in doc["jobs"].items():
            if "uses" in each:
                continue
            with self.subTest(job=key):
                # The panic ratchet builds cmux-tui twice, as cmux-tui-spec.yml's clippy job (40) does once. The gates
                # job's own budget (--budget-seconds) ends a stalled gate with its reason well inside its 25.
                limit = {"panic-ratchet": 40, "fast-gates": 25}.get(key, 15)
                self.assertLessEqual(int(each["timeout-minutes"]), limit)
                cells = workflow_jobs.runs_on_cells(each)
                self.assertTrue(cells, f"{key}: no runs-on, or a matrix value nothing resolves")
                for runner in cells:
                    self.assertNotIn("macos", runner.lower())

    def test_pool_checkouts_fetch_unfiltered_from_the_mirror(self):
        # 2026-11-25: actions/checkout adds --filter=blob:none to any sparse checkout, and on a pool VM a partial fetch
        # borrowing the mirror made git copy ~3 GB of promisor objects (60-75 s a checkout, resolve p90 107 s against a
        # 30 s budget). A pool VM runs its own unfiltered fetch into a fresh .git that borrows the mirror; the same
        # sparse paths; every other runner keeps the action with blob:none.
        doc = workflow()
        for key, name in (("resolve", "Checkout the merge ref"),
                          ("fast-gates", "Checkout")):
            with self.subTest(job=key):
                steps = doc["jobs"][key]["steps"]
                action, pool = step_named(steps, name), step_named(steps, "Pool mirror: c" + name[1:])
                self.assertEqual(steps.index(pool), steps.index(action) + 1)
                self.assertEqual(action["with"]["filter"], "blob:none")
                self.assertIn(NOT_POOL, action["if"])
                self.assertIn(NOT_POOL[1:], pool["if"])
                self.assertNotIn(NOT_POOL, pool["if"])
                self.assertEqual(pool["env"]["SPARSE"], action["with"]["sparse-checkout"])
                self.assertEqual(pool["env"]["SHA"], "${{ github.sha }}")
                self.assertEqual(pool.get("timeout-minutes"), action.get("timeout-minutes"))
                run = pool["run"]
                self.assertIn('echo "$mirror" > .git/objects/info/alternates', run)
                self.assertIn("find . -mindepth 1 -maxdepth 1 -exec rm -rf {} +", run)
                fetch = next(line for line in run.splitlines() if re.search(r"\bgit\b.* fetch ", line))
                self.assertNotIn("--filter", fetch)
                self.assertIn("--depth=2", fetch)
                self.assertNotIn("$TOKEN", fetch)

    def test_pool_checkout_script_checks_out_the_sparse_paths_from_a_borrowed_mirror(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            step = step_named(job(workflow())["steps"], "Pool mirror: checkout")
            seed = tmp / "seed"
            git(tmp, "init", "-q", "-b", "main", str(seed))
            for rel in ("scripts/ci/a.py", "Packages/p/b.swift", "outside/c.txt", "top.txt"):
                (seed / rel).parent.mkdir(parents=True, exist_ok=True)
                (seed / rel).write_text(rel)
            git(seed, "add", "-A")
            git(seed, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "one")
            (seed / "scripts/ci/d.py").write_text("d")
            git(seed, "add", "-A")
            git(seed, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "two")
            sha = git(seed, "rev-parse", "HEAD").strip()
            git(tmp, "clone", "-q", "--bare", str(seed), str(tmp / "mirror.git"))
            run = step["run"].replace("/var/lib/cmux-git/cmux.git/objects", str(tmp / "mirror.git/objects")).replace(
                "https://github.com/$GITHUB_REPOSITORY", "file://" + str(seed))
            ws = tmp / "ws"
            (ws / ".git").mkdir(parents=True)
            (ws / "stale.txt").write_text("from an earlier job")
            env = {**os.environ, "GITHUB_WORKSPACE": str(ws), "SHA": sha, "TOKEN": "t", "SPARSE": step["env"]["SPARSE"]}
            subprocess.run(["bash", "-c", run], env=env, check=True, capture_output=True, text=True)
            self.assertEqual(git(ws, "rev-parse", "HEAD").strip(), sha)
            git(ws, "rev-parse", "HEAD^1")
            self.assertTrue((ws / "scripts/ci/d.py").exists() and (ws / "Packages/p/b.swift").exists())
            self.assertTrue((ws / "top.txt").exists())
            self.assertFalse((ws / "outside").exists())
            self.assertFalse((ws / "stale.txt").exists())
            promisor = subprocess.run(["git", "-C", str(ws), "config", "--get", "remote.origin.promisor"],
                                      capture_output=True, text=True)
            self.assertEqual(promisor.stdout.strip(), "")

    def test_checkout_holds_every_gate_input_and_walks_commits_only(self):
        inputs = json.loads((ROOT / "scripts/ci/fast-check-inputs.json").read_text())[
            "workflows"][".github/workflows/cmux-next-fast-gates.yml"]["fast-gates"]["inputs"]
        step = step_named(job(workflow())["steps"], "Checkout")
        self.assertEqual(step["with"]["filter"], "blob:none")
        patterns = step["with"]["sparse-checkout"].split()
        for path in inputs:
            with self.subTest(input=path):
                # scripts/ and .github/ are whole; a bare file or a glob is named as it is.
                self.assertTrue("/" + path in patterns or path.lstrip("*/") in "".join(patterns)
                                or any(("/" + path).startswith(p) and p.endswith("/") for p in patterns), path)
        self.assertIn("--filter=tree:0", fast_gates_source())

    def test_checkout_holds_every_tests_module_a_gate_imports(self):
        # cmux#57582 (run 45880398424): the egress gate imports tests/test_egress_gate.py, which the sparse checkout
        # left out, so every pull request's fast gates failed on ModuleNotFoundError. A gate script's `tests/` import,
        # followed through the modules it imports, must be on disk.
        patterns = step_named(job(workflow())["steps"], "Checkout")["with"]["sparse-checkout"].split()
        scripts = sorted(set(re.findall(r'"((?:scripts|tests)/[\w./-]+\.py)"', fast_gates_source())))
        self.assertIn("scripts/ci/egress_new_sites.py", scripts)
        seen: set[str] = set()
        todo = [ROOT / s for s in scripts]
        while todo:
            path = todo.pop()
            if not path.exists():
                continue
            for name in re.findall(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", path.read_text(encoding="utf-8"), re.M):
                module = ROOT / "tests" / f"{name}.py"
                if module.exists() and name not in seen:
                    seen.add(name)
                    todo.append(module)
                    with self.subTest(gate=str(path.relative_to(ROOT)), module=name):
                        self.assertIn(f"/tests/{name}.py", patterns, f"{path.relative_to(ROOT)} imports tests/{name}.py")
        self.assertIn("test_egress_gate", seen)
        # 2026-11-27 (#61088, run 45997666983): test_outbound_hosts.py began importing tests/guard_delta.py and merged
        # without this test running: it names none of these modules, so focused_tests.py never picked it for a change to
        # one. Each module this walk reaches selects this test (scripts/ci/focused-tests-extra.json), so a new import
        # is made in a file that already runs it.
        extra = json.loads((ROOT / "scripts/ci/focused-tests-extra.json").read_text())["rules"]
        selects = {rule["prefix"] for rule in extra if "tests/test_cmux_next_fast_gates.py" in rule.get("python", [])}
        for name in sorted(seen):
            with self.subTest(selects=name):
                self.assertIn(f"tests/{name}.py", selects,
                              f'add {{"prefix": "tests/{name}.py", "python": ["tests/test_cmux_next_fast_gates.py"]}} to '
                              "scripts/ci/focused-tests-extra.json")

    def test_triggers_have_no_paths_filter(self):
        on = triggers(workflow())
        # A feat-cmux-next pull request runs it from pr-router.yml (scripts/ci/pr_router.json), with no path filter
        # either: a head the router starts nothing for starts none of its jobs.
        self.assertEqual(set(on), {"workflow_call", "workflow_dispatch"})
        routed = json.loads((ROOT / "scripts/ci/pr_router.json").read_text())["callees"]["cmux-next-fast-gates.yml"]
        for key in ("paths", "paths-ignore", "affects", "skip_docs_only"):
            self.assertNotIn(key, routed, "a paths filter leaves PRs with no status")
        self.assertIn("ready_for_review", routed["types"])
        self.assertIn("uses: ./.github/workflows/cmux-next-fast-gates.yml",
                      (ROOT / ".github/workflows/pr-router.yml").read_text())
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
            # A reusable-workflow caller (the head fail-fast job) has no steps of its own.
            for step in each.get("steps", []):
                self.assertNotRegex(step.get("run", ""), r"\$\{\{",
                                    f"{key} step {step.get('name')!r} interpolates an expression into shell")

    def test_dispatch_refuses_a_fork_or_another_base_before_pr_code_runs(self):
        doc = workflow()
        resolve = job(doc, "resolve")
        # resolve runs no code the change made: on dispatch it checks nothing out at all, and on a pull request it
        # runs only the router (isolated, -I), and only when the change leaves the router and its map as the base has
        # them (else every gate runs and nothing of the PR's is read).
        for step in resolve["steps"]:
            if step.get("uses", "").startswith("actions/checkout@") or step.get("name", "").startswith("Pool mirror:"):
                if "the base for the receipt verifier (lane dispatch)" in step.get("name", ""):
                    # A lane dispatch checks out the base commit's verifier, never the pull request's code (#60742).
                    self.assertIn("steps.resolve.outputs.lane_dispatch == 'true'", step["if"])
                    self.assertIn("steps.resolve.outputs.base", str(step.get("with", {}).get("ref", "")) + str(step.get("env", {})))
                    continue
                self.assertTrue(step["if"].replace(" ", "").startswith("${{github.event_name=='pull_request'&&"),
                                step.get("name"))
            if step.get("id") == "route":
                self.assertEqual(step["if"].replace(" ", ""), "${{github.event_name=='pull_request'}}")
                self.assertTrue(step["continue-on-error"])
                body = step["run"]
                for file in ("scripts/ci/fast_check_route.py", "scripts/ci/fast-check-inputs.json"):
                    self.assertIn(file, body.split("python3")[0])
                self.assertIn('"$(git rev-parse "HEAD:$file")" != "$(git rev-parse "HEAD^1:$file")"', body)
                self.assertIn("python3 -I scripts/ci/fast_check_route.py route --workflow "
                              ".github/workflows/cmux-next-fast-gates.yml", body)
                continue
            if step.get("id", "").startswith("receipt-"):
                continue  # the base's verifier, copied out of git (test_receipt_steps_run_only_the_base_verifier)
            self.assertNotIn("scripts/", step.get("run", ""), step.get("name"))
        self.assertIn("steps.route.outputs.fast_gates", resolve["outputs"]["fast_gates"])
        body = step_named(resolve["steps"], "Resolve")["run"]
        self.assertIn('"$head_repo" != "$GITHUB_REPOSITORY"', body)
        self.assertIn('"$base_ref" != "$BRANCH"', body)
        self.assertIn('"$state" != open', body)
        self.assertEqual(step_named(resolve["steps"], "Resolve")["env"]["BRANCH"], "feat-cmux-next")
        # The gates job, which runs the PR's code, starts only after resolve passed, and not at all when a valid
        # local test receipt covers it (unless the receipt is audited).
        self.assertEqual(job(doc)["needs"], ["resolve"])
        self.assertIn("needs.resolve.result == 'success'", job(doc)["if"])
        self.assertIn("needs.resolve.outputs.receipt_valid != 'true' "
                      "|| needs.resolve.outputs.receipt_audit == 'true'", job(doc)["if"])
        prepare = step_named(job(doc)["steps"], "Merge with the base")
        self.assertIn("needs.resolve.outputs.head_sha", prepare["env"]["HEAD_SHA"])
        self.assertIn("needs.resolve.outputs.base", prepare["env"]["BASE"])
        self.assertIn('--head "$HEAD_SHA" --base "$BASE"', prepare["run"])

    def resolve_dispatch(self, *, fields=None, error=None, failures=0, graphql_fields=None, event=None):
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
                "GRAPHQL_FIELDS": (graphql_fields or "open|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|topic/x|" + "c" * 40)
                .replace("|", "\t"),
                "PR_FIELDS": fields.replace("|", "\t") if fields is not None else "open\tmanaflow-ai/cmux\tfeat-cmux-next\t" + "a" * 40 + "\ttopic/x",
                **(event or {}),
            }
            result = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, timeout=10)
            return (result, calls.read_text().splitlines(),
                    waits.read_text().splitlines() if waits.exists() else [],
                    output.read_text() if output.exists() else "")

    def test_dispatch_on_the_branch_takes_its_own_sha_as_the_base(self):
        """A dispatch on feat-cmux-next carries the tip the merger dispatched against (github.sha); the
        resolver reads the pull request only, not the branch again over the shared REST quota."""
        result, calls, _, output = self.resolve_dispatch(
            event={"DISPATCH_REF": "refs/heads/feat-cmux-next", "DISPATCH_SHA": "e" * 40})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("/pulls/28116", json.loads(calls[0])[1])
        self.assertIn("base=" + "e" * 40, output)
        # Another ref's sha is not the branch tip: it is read.
        result, calls, _, output = self.resolve_dispatch(
            event={"DISPATCH_REF": "refs/heads/main", "DISPATCH_SHA": "e" * 40})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 2)
        self.assertIn("base=" + "b" * 40, output)

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
        for fields, words in (("open|fork/cmux|feat-cmux-next|" + "a" * 40 + "|topic/x|" + "c" * 40, "comes from fork/cmux"),
                              ("merged|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|topic/x|" + "c" * 40, "is merged"),
                              ("open|manaflow-ai/cmux|feat-cmux-next|" + "a" * 40 + "|topic/x|", "incomplete")):
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
        result, calls, waits, output = self.resolve_dispatch(fields="open|fork/cmux|feat-cmux-next|" + "a" * 40 + "|topic/x")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("comes from fork/cmux", result.stdout + result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertEqual(output, "")

    def test_concurrency_per_pull_request(self):
        concurrency = workflow()["concurrency"]
        # Then the land tier's suffix (tests/test_ci_label_events_skip_full_ci.py): another label event gets its own group.
        self.assertTrue(concurrency["group"].startswith("fast-gates-${{ github.event.pull_request.number || inputs.pr }}"),
                        concurrency["group"])
        self.assertIn("format('-label-{0}', github.run_id)", concurrency["group"])
        self.assertIs(concurrency["cancel-in-progress"], True)

    def test_permissions_are_minimal(self):
        doc = workflow()
        self.assertEqual(doc["permissions"], {"contents": "read"})
        # resolve runs no pull request code; its receipt steps read the receipt's run, ask the controller for a lane's
        # receipt with an OIDC token (audience cmux-ci-lane-receipt), and post a valid one's status.
        self.assertEqual(job(doc, "resolve")["permissions"], {"contents": "read", "pull-requests": "read",
                                                              "actions": "read", "statuses": "write",
                                                              "id-token": "write"})
        # The jobs that run pull request code can write nothing; only resolve and post can write a status.
        self.assertEqual(job(doc)["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "panic-ratchet")["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "post")["permissions"], {"statuses": "write"})

    def test_every_gate_fails_the_job(self):
        doc = workflow()
        self.assertNotIn("CMUX_NEXT_STYLE_GUARDS", json.dumps(doc))
        gates = job(doc)
        self.assertNotIn("continue-on-error", gates)
        for step in gates["steps"]:
            # The R2 cache reads (#51750) are best-effort: a miss or an error falls through to the GitHub store's
            # restore step, so they are the one kind of step allowed to keep going; no gate is.
            if step.get("uses") == "./.github/actions/cache-restore" and step.get("with", {}).get("backend") == "r2":
                continue
            # The GitHub store's Bun restore is bounded and best-effort too: past its bound the gates install cold,
            # and the next step drops what it half extracted.
            if step.get("id") == "bun-cache" and step.get("uses", "").startswith("actions/cache/restore@"):
                continue
            # The pinned Node and Bun restores (scripts/ci/toolchain-r2.sh) are best-effort: a miss leaves the setup
            # step after it to download as before, so they never decide the job.
            if "toolchain-r2.sh\" restore " in step.get("run", ""):
                continue
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

    def test_a_lane_receipt_is_looked_up_and_its_audit_reported(self):
        doc = workflow()
        verify = step_named(job(doc, "resolve")["steps"], "Verify the local test receipt")
        # The lane flag only when the base's verifier knows it, and vars.CI_LANE_RECEIPTS=0 turns it off.
        self.assertIn('''grep -q -- '"--lane"' "$verifier/ci_receipt.py"; then DISCOVER_ARGS+=(--lane)''', verify["run"])
        self.assertEqual(verify["env"]["LANE"], "${{ vars.CI_LANE_RECEIPTS }}")
        post = job(doc, "post")
        self.assertEqual(post["outputs"]["state"], "${{ steps.status.outputs.state }}")
        self.assertIn('echo "state=$state" >> "${GITHUB_OUTPUT:-/dev/null}"', step_named(post["steps"], "Post the cmux-next/fast-gates status")["run"])
        audit = job(doc, "lane-receipt-audit")
        self.assertEqual(audit["needs"], ["resolve", "post"])
        for fragment in ("needs.resolve.outputs.receipt_audit == 'true'",
                         "startsWith(needs.resolve.outputs.receipt_producer, 'lane:')",
                         "needs.post.outputs.state == 'success' || needs.post.outputs.state == 'failure'"):
            self.assertIn(fragment, audit["if"])
        # No checkout and no repository code next to the OIDC token; a failed report changes no verdict.
        self.assertEqual(audit["permissions"], {"id-token": "write"})
        self.assertIs(audit["continue-on-error"], True)
        self.assertFalse(any("uses" in step for step in audit["steps"]))
        self.assertIn("audience=cmux-ci-lane-receipt", audit["steps"][0]["run"])

    def test_a_lane_head_takes_its_receipt_at_the_merger_dispatch(self):
        # 78 of 100 fast-gates runs on 2026-11-26 were the merger's dispatches; on feat-cmux-next the pull request event
        # skips the gates, so a lane receipt has to count there (Leo: "Shift checks left into the lanes").
        steps = job(workflow(), "resolve")["steps"]
        resolve = step_named(steps, "Resolve the head and the base")
        body = resolve["run"]
        self.assertIn(".head.ref] | @tsv", body)
        self.assertIn("headRefName", body)
        self.assertIn('if [[ "$head_ref" == lane/* && "${LANE:-1}" != 0 ]]; then', body)
        # The head tree is read over git, not REST: the REST budget was spent on every dispatch on 2026-11-27.
        self.assertNotIn("git/commits/$head", body)
        self.assertIn('head_tree="$(head_commit_tree "$head")"', body)
        self.assertIn("--depth=1 --filter=tree:0", body)
        self.assertIn('echo "merge_tree="; echo "lane_dispatch=true"', body)
        self.assertEqual(resolve["env"]["LANE"], "${{ vars.CI_LANE_RECEIPTS }}")
        verify = step_named(steps, "Verify the local test receipt")
        self.assertIn("(github.event_name == 'workflow_dispatch' && steps.resolve.outputs.lane_dispatch == 'true')",
                      verify["if"])
        self.assertIn('[[ -n "$PR_NUMBER" && "${DISCOVER:-1}" != 0 ]]', verify["run"])
        names = [s.get("name", "") for s in steps]
        for name in ("Checkout the base for the receipt verifier (lane dispatch)",
                     "Pool mirror: checkout the base for the receipt verifier (lane dispatch)"):
            checkout = step_named(steps, name)
            self.assertLess(names.index("Resolve the head and the base"), names.index(name))
            self.assertLess(names.index(name), names.index("Verify the local test receipt"))
            self.assertIn("steps.resolve.outputs.lane_dispatch == 'true'", checkout["if"])
            self.assertIs(checkout["continue-on-error"], True)
        checkout = step_named(steps, "Checkout the base for the receipt verifier (lane dispatch)")
        self.assertIs(checkout["with"]["persist-credentials"], False)
        self.assertEqual(checkout["with"]["ref"], "${{ steps.resolve.outputs.base }}")
        self.assertIn("/scripts/ci/ci_receipt.py", checkout["with"]["sparse-checkout"])

    def test_receipt_steps_run_only_the_base_verifier_and_only_when_named(self):
        doc = workflow()
        self.assertNotIn("receipt", doc["jobs"], "the receipt is resolve's steps, not a runner of its own")
        resolve = job(doc, "resolve")
        self.assertEqual(resolve["permissions"], {"contents": "read", "pull-requests": "read", "actions": "read",
                                                  "statuses": "write", "id-token": "write"})
        verify = step_named(resolve["steps"], "Verify the local test receipt")
        self.assertEqual(verify["id"], "receipt-verify")
        # No API call unless a same-repository pull request names a receipt in its body (or is a lane's), and only
        # where the gates would run.
        for fragment in ("github.event_name == 'pull_request'",
                         "github.event.pull_request.head.repo.full_name == github.repository",
                         "contains(github.event.pull_request.body, 'CI-Receipt:')",
                         "steps.route.outputs.fast_gates != 'false'"):
            self.assertIn(fragment, verify["if"])
        # A verifier that fails or hangs leaves resolve green, and the gates run.
        self.assertIs(verify["continue-on-error"], True)
        # 5: OIDC 20 s + the lookup's 60 s deadline (#61555) + the head-tree and base git reads, 60 s each.
        self.assertLessEqual(int(verify["timeout-minutes"]), 5)
        self.assertLess(int(verify["timeout-minutes"]), int(resolve["timeout-minutes"]))
        body = verify["run"]
        # The verifier is the base commit's, copied out of git, never a file of the pull request's work tree.
        self.assertEqual(verify["env"]["BASE"], "${{ steps.resolve.outputs.base }}")
        self.assertIn('git show "$BASE:scripts/ci/$file" > "$verifier/$file"', body)
        self.assertIn("for file in ci_receipt.py deadline_http.py cmux_next_fast_gates.py; do", body)
        self.assertIn('verifier="$RUNNER_TEMP/', body)
        self.assertIn('python3 -I "$verifier/ci_receipt.py" verify fast-gates', body)
        self.assertNotRegex(body, r"python3 (-I )?scripts/")
        # The body reaches the verifier through the environment, never spliced into the script.
        self.assertNotIn("github.event.pull_request.body", body)
        self.assertEqual(verify["env"]["PR_BODY"], "${{ github.event.pull_request.body }}")
        posted = step_named(resolve["steps"], "Post the cmux-next/fast-gates status from the receipt")
        self.assertEqual(posted["id"], "receipt-post")
        self.assertIs(posted["continue-on-error"], True)
        self.assertIn("steps.receipt-verify.outputs.valid == 'true'", posted["if"])
        self.assertIn("steps.resolve.outputs.post == 'true'", posted["if"])
        self.assertIn("context=cmux-next/fast-gates", posted["run"])
        self.assertIn('"base $RECEIPT_BASE', posted["run"])
        # A receipt step that failed, its post included, counts as no receipt: the gates run and post writes.
        valid = resolve["outputs"]["receipt_valid"]
        self.assertIn("steps.receipt-verify.outcome == 'success'", valid)
        self.assertIn("steps.receipt-post.outcome != 'failure'", valid)
        for name in ("audit", "run_url", "producer"):
            self.assertEqual(resolve["outputs"][f"receipt_{name}"], f"${{{{ steps.receipt-verify.outputs.{name} }}}}")

    def test_status_context_and_description(self):
        doc = workflow()
        poster = job(doc, "post")
        self.assertEqual(poster["needs"], ["resolve", "fast-gates", "panic-ratchet"])
        # A valid receipt posted the status itself; post judges only runs the gates ran (an audit included).
        self.assertIn("needs.resolve.outputs.receipt_valid != 'true' "
                      "|| needs.resolve.outputs.receipt_audit == 'true'", poster["if"])
        self.assertIn("!cancelled()", poster["if"])
        self.assertIn("needs.resolve.result == 'success'", poster["if"])
        # Fork pull requests have no write token: resolve says post=false, the gates still pass or fail.
        self.assertIn("needs.resolve.outputs.post == 'true'", poster["if"])
        self.assertIn('"$PR_REPO" == "$GITHUB_REPOSITORY"', step_named(job(doc, "resolve")["steps"], "Resolve")["run"])
        # post checks nothing out and runs no repository code: one App token mint, then the post.
        self.assertEqual([s["name"] for s in poster["steps"]],
                         ["Mint the status token", "Post the cmux-next/fast-gates status"])
        mint = poster["steps"][0]
        self.assertTrue(mint["uses"].startswith("actions/create-github-app-token@"))
        self.assertEqual(mint["with"]["permission-statuses"], "write")
        self.assertIs(mint["continue-on-error"], True)
        post = poster["steps"][1]
        self.assertNotIn("uses", post)
        self.assertEqual(post["env"]["APP_TOKEN"], "${{ steps.status-token.outputs.token }}")
        self.assertEqual(post["env"]["CONTEXT"], "cmux-next/fast-gates")
        # Head and base come from resolve, never from anything the gates job wrote.
        self.assertIn("needs.resolve.outputs.head_sha", post["env"]["HEAD_SHA"])
        self.assertIn("needs.resolve.outputs.base", post["env"]["BASE"])
        self.assertEqual(post["env"]["GATES"].replace(" ", ""), "${{needs.fast-gates.result}}")
        self.assertEqual(post["env"]["RATCHET"].replace(" ", ""), "${{needs.panic-ratchet.result}}")
        # The gates job hands post nothing but its result; its one output only says whether the ratchet runs,
        # and comes from prepare, before any pull request code ran.
        self.assertEqual(job(doc)["outputs"], {"ratchet": "${{ steps.prepare.outputs.ratchet }}"})
        # The receipt steps' outputs come from the base commit's verifier, never from pull request code. The route's
        # one output (fast_check_route.py from the merge) only counts when the gates were skipped, and post runs only
        # for a same-repository pull request (resolve's post), whose author can already push to the base.
        self.assertNotIn("outputs.", json.dumps(post["env"]).replace("needs.resolve.outputs.", "")
                         .replace("needs.resolve.outputs.fast_gates", "")
                         .replace("steps.status-token.outputs.token", ""))
        self.assertIn("github.run_id", post["env"]["TARGET_URL"])
        self.assertIn("github.token", post["env"]["GH_TOKEN"])
        body = post["run"]
        self.assertIn('"base $BASE"', body)
        self.assertIn("statuses/$HEAD_SHA", body)
        self.assertRegex(body, r"\[0-9a-f\]\{40\}")
        self.assertIn("state=success", body)
        self.assertIn("state=failure", body)
        # A skipped panic ratchet (nothing to rejudge) passes; a failed one fails the status. A job that timed out
        # or was cancelled judged nothing: pending, "stopped", never failure (cmux#38640, 2026-11-09: two
        # dispatches timed out at 10 min and posted failure, read as the pull request's own red).
        for gates, ratchet, state in (("success", "skipped", "success"), ("success", "success", "success"),
                                      ("success", "failure", "failure"), ("success", "cancelled", "pending"),
                                      ("failure", "skipped", "failure"), ("cancelled", "skipped", "pending"),
                                      ("failure", "cancelled", "failure"),
                                      # Every other way a job can end judged nothing either (cmux#39743: abandoned
                                      # gates, whose placed runner never reported, posted failure).
                                      ("abandoned", "skipped", "pending"), ("skipped", "skipped", "pending"),
                                      ("", "", "pending"), ("timed_out", "skipped", "pending"),
                                      ("success", "abandoned", "pending"), ("success", "", "pending"),
                                      ("failure", "abandoned", "failure"), ("failure", "", "failure"),
                                      ("abandoned", "success", "pending"), ("cancelled", "failure", "pending")):
            with self.subTest(gates=gates, ratchet=ratchet):
                self.assertEqual(self.posted_state(body, gates, ratchet), state)
                described = self.posted_description
                self.assertTrue(described.startswith("base " + "b" * 40), described)
                self.assertEqual("stopped" in described, state == "pending", described)

    def posted_state(self, body: str, gates: str, ratchet: str) -> str:
        with tempfile.TemporaryDirectory(prefix="fast-gates-state-") as tmp:
            root = Path(tmp)
            fake = root / "gh"
            fake.write_text(f"#!/bin/sh\nprintf '%s\\n' \"$@\" > {root}/args\n")
            fake.chmod(0o755)
            env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "HEAD_SHA": "a" * 40, "BASE": "b" * 40,
                   "GATES": gates, "RATCHET": ratchet, "ROUTED_OUT": "false", "CONTEXT": "cmux-next/fast-gates",
                   "TARGET_URL": "https://example.invalid/run", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                   "GITHUB_STEP_SUMMARY": str(root / "summary"), "GH_TOKEN": "job"}
            done = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stderr)
            args = (root / "args").read_text().splitlines()
            self.posted_description = next(arg.split("=", 1)[1] for arg in args if arg.startswith("description="))
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

    def test_a_rate_limited_status_post_heals_instead_of_ending_green_unposted(self):
        """2026-11-25: run 45554419892 judged cmux#46179 green, its post was refused for the spent installation
        budget and the job ended green; nothing posted it again and the land waited 5.3 h on "not posted yet"."""
        poster = job(workflow(), "post")
        post = step_named(poster["steps"], "Post the cmux-next/fast-gates status")
        body = post["run"]
        wait = int(post["env"]["POST_WAIT_SECONDS"])
        # The longest wait for a reset fits the job's limit with a minute to spare.
        self.assertLessEqual(wait + 60, poster["timeout-minutes"] * 60)

        def run_post(script: str, **extra: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
            with tempfile.TemporaryDirectory(prefix="fast-gates-status-") as tmp:
                root = Path(tmp)
                fake = root / "gh"
                # Each call logs "<token> <args>"; the script decides per call what GitHub answers.
                fake.write_text(f"#!/bin/bash\necho \"$GH_TOKEN $*\" >> {root}/calls\n{script}\n")
                fake.chmod(0o755)
                env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "HEAD_SHA": "a" * 40, "BASE": "b" * 40,
                       "GATES": "success", "RATCHET": "skipped", "ROUTED_OUT": "false",
                       "CONTEXT": "cmux-next/fast-gates", "TARGET_URL": "https://example.invalid/run",
                       "GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_STEP_SUMMARY": str(root / "summary"),
                       "GH_TOKEN": "job", "APP_TOKEN": "app", "POST_MIN_GAP_SECONDS": "0", **extra}
                done = subprocess.run(["bash", "-c", body], env=env, capture_output=True, text=True, timeout=20)
                calls = (root / "calls").read_text().splitlines()
                return done, [c for c in calls if "/statuses/" in c]

        limited = "echo 'gh: API rate limit exceeded for installation (HTTP 403)' >&2; exit 1"
        # The App token posts; the repository's budget is never touched.
        done, posts = run_post('[[ "$*" == *statuses/* ]] && exit 0; exit 1')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([p.split()[0] for p in posts], ["app"])
        # A spent App budget moves the post to GITHUB_TOKEN at once.
        done, posts = run_post(f'[[ "$*" == *statuses/* && "$GH_TOKEN" == job ]] && exit 0\n'
                               f'[[ "$*" == *statuses/* ]] && {{ {limited}; }}\necho 0')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([p.split()[0] for p in posts], ["app", "job"])
        # Both spent: wait for the reset, then post (the second round's App post goes through).
        done, posts = run_post(f'n=$(grep -c statuses/ "$(dirname "$0")/calls")\n'
                               f'[[ "$*" == *statuses/* && $n -ge 3 ]] && exit 0\n'
                               f'[[ "$*" == *statuses/* ]] && {{ {limited}; }}\ndate +%s')
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(len(posts), 3)
        self.assertIn("posting again", done.stdout)
        # Both spent past the bound: the job fails, named, so a re-run posts it; never green with nothing posted.
        done, posts = run_post(f'[[ "$*" == *statuses/* ]] && {{ {limited}; }}\necho $(( $(date +%s) + 3000 ))')
        self.assertEqual(done.returncode, 1)
        self.assertIn("::error title=GitHub API budget::", done.stdout)
        self.assertIn("re-run this failed job", done.stdout)
        self.assertEqual(len(posts), 2)
        # No App token (a fork, no app configured): GITHUB_TOKEN alone.
        done, posts = run_post('[[ "$*" == *statuses/* ]] && exit 0; exit 1', APP_TOKEN="")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([p.split()[0] for p in posts], ["job"])
        # Any other API failure is red at once, with GitHub's words.
        done, posts = run_post("echo 'gh: HTTP 404 Not Found' >&2; exit 1")
        self.assertEqual(done.returncode, 1)
        self.assertIn("HTTP 404", done.stderr)
        self.assertEqual(len(posts), 1)
        # 2026-11-26 (jobs 139914769975, 139917024944): App and GITHUB_TOKEN spent, the reset 457 s away, the job
        # failed and a rerun posted green. The CI pool's tokens post first, each its own hour.
        both_spent = (f'[[ "$*" == *statuses/* && "$GH_TOKEN" == pool* ]] && exit 0\n'
                      f'[[ "$*" == *statuses/* ]] && {{ {limited}; }}\necho $(( $(date +%s) + 457 ))')
        done, posts = run_post(both_spent, POOL_TOKENS="pool1 pool2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([p.split()[0] for p in posts], ["app", "pool1"])
        # A pool token that cannot post (expired, no statuses grant) is passed over, never a red.
        done, posts = run_post('[[ "$*" == *statuses/* && "$GH_TOKEN" == job ]] && exit 0\n'
                               '[[ "$*" == *statuses/* && "$GH_TOKEN" == pool* ]] && '
                               '{ echo "gh: Resource not accessible by integration (HTTP 403)" >&2; exit 1; }\n'
                               f'[[ "$*" == *statuses/* ]] && {{ {limited}; }}\necho 0', POOL_TOKENS="pool1 pool2")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([p.split()[0] for p in posts], ["app", "pool1", "pool2", "job"])
        self.assertIn("passing it over", done.stdout)
        # The bound covers that 457 s reset after a first gap, inside the light jobs' 15 minutes.
        self.assertGreaterEqual(wait, 457 + 300)
        self.assertIn("CI_POOL_TOKEN_1", post["env"]["POOL_TOKENS"])

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

    def test_a_stalled_install_ends_named_inside_the_job_limit(self):
        # 2026-11-09: the web lint's bun install hung on the registry with no idle limit of its own and sat silent
        # until the job's 15-minute limit cancelled it; land-judge refused the cancelled check.
        gates = job(workflow())
        run = step_named(gates["steps"], "Fast gates")
        self.assertEqual(run["env"]["BUN_CONFIG_HTTP_IDLE_TIMEOUT"], "30")
        self.assertEqual(run["env"]["BUN_CONFIG_HTTP_RETRY_COUNT"], "5")
        budget = re.search(r"--budget-seconds (\d+)", run["run"])
        self.assertIsNotNone(budget)
        # Room after the budget for checkout, setup and the cache save, all inside the limit; and the gates get more
        # time than the whole job had before the budget (15 min), so a slow runner never turns a passing run red.
        self.assertLessEqual(int(budget.group(1)) + 240, gates["timeout-minutes"] * 60)
        self.assertGreater(int(budget.group(1)), 15 * 60)

    def test_a_dispatch_never_saves_a_cache(self):
        # A dispatch runs on feat-cmux-next's ref after pull request code ran: a cache it saved would be the base's.
        steps = job(workflow())["steps"]
        # #51100 (2026-11-23): restore only, on pull requests and dispatches alike; cmux-next-web-lint.yml's web-lint
        # job saves the key on each feat-cmux-next push. So no step here saves a cache at all.
        for step in steps:
            self.assertFalse(step.get("uses", "").startswith("actions/cache@"), step.get("name"))
        # #51750 reads R2 first (./.github/actions/cache-restore, backend r2), then the GitHub store's restore step.
        restore = step_named([s for s in steps if not s["name"].endswith(" from R2")], "Restore the Bun package cache")
        self.assertTrue(restore["uses"].startswith("actions/cache/restore@"))
        for name in ("Restore the Bun package cache", "Restore the pinned lint tools"):
            r2 = step_named(steps, f"{name} from R2")
            self.assertEqual(r2["uses"], "./.github/actions/cache-restore", name)
            self.assertEqual(r2["with"]["backend"], "r2", name)
        # The lint tools never change per PR and are off the GitHub store (RFD 0148 row 19): R2 only, and a miss
        # is prepush-gate.py's sha256-checked download.
        self.assertEqual([s["name"] for s in steps if s["name"].startswith("Restore the pinned lint tools")],
                         ["Restore the pinned lint tools from R2"])

    def test_the_bun_cache_restore_is_bounded_and_never_left_half_done(self):
        # 2026-11-23: on a Freestyle VM the 710 MB restore ran at about 1 MB/s, and at 600 s its link expired.
        # It failed every time, adding 605 s (median) to a job whose gates then installed cold anyway.
        steps = job(workflow())["steps"]
        restore = next(s for s in steps if s.get("id") == "bun-cache")
        self.assertTrue(restore["uses"].startswith("actions/cache/restore@"))
        self.assertLessEqual(restore["timeout-minutes"], 3)
        self.assertIs(restore["continue-on-error"], True)
        drop = step_named(steps, "Drop a partly restored Bun package cache")
        self.assertIn(f"steps.{restore['id']}.outcome == 'failure'", drop["if"])
        self.assertIn(f"steps.{restore['id']}.outcome == 'cancelled'", drop["if"])
        self.assertIn("steps.bun-r2.outcome == 'failure'", drop["if"])
        self.assertIn("~/.bun/install/cache", drop["run"])
        self.assertEqual(steps.index(drop), steps.index(restore) + 1)
        gates = step_named(steps, "Fast gates on the merge")
        self.assertLess(steps.index(drop), steps.index(gates))

    def test_every_step_before_the_gates_is_bounded(self):
        # 2026-11-23: 255 fast gates jobs sat to the 25-minute limit (about 6.3k runner minutes), each in one setup
        # step with no bound of its own: a checkout fetch, the base deepen, a cache restore or setup-node's download
        # from GitHub at Freestyle's ~0.9 MB/s. Each step before the gates ends on its own bound, so the job fails
        # then, naming the step, and the bounds together leave the gates room inside the job limit.
        gates_job = job(workflow())
        steps = gates_job["steps"]
        gates = steps.index(step_named(steps, "Fast gates on the merge"))
        # A step that runs only on a pool VM and one that runs only off it are alternatives (the pool mirror's
        # checkout replaces actions/checkout, cmux#55973): a job pays one side's bounds, never both.
        pool = "${{ startsWith(runner.name, 'cmux-runner-pool-') }}"
        off_pool = "${{ !startsWith(runner.name, 'cmux-runner-pool-') }}"
        common = on_pool = not_pool = 0
        for step in steps[:gates]:
            with self.subTest(step=step["name"]):
                self.assertIn("timeout-minutes", step)
                minutes = int(step["timeout-minutes"])
                if step.get("if") == pool:
                    on_pool += minutes
                elif step.get("if") == off_pool:
                    not_pool += minutes
                else:
                    common += minutes
        self.assertLessEqual(common + max(on_pool, not_pool), 40)
        # Node never comes from GitHub's node-versions releases (setup-node's download): the tool cache or nodejs.org.
        node = step_named(steps, "Setup Node")
        self.assertNotIn("uses", node)
        self.assertEqual(node["run"], "scripts/ci/ensure-setup-node.sh 24.22.1")
        self.assertLessEqual(int(node["timeout-minutes"]), 3)

    def test_a_warm_runner_skips_unpacking_the_bun_cache_archive(self):
        # docs/ci/cmux-next-workflow-notes/2026-11-26-bun-cache-warm.md (2026-11-23): on a runner whose own Bun cache is already filled (a persistent pool runner), the
        # archive restore spent 400-1,096 s in 12 of 14 jobs cut at their limit. The check runs first, the restore only
        # when it is not warm, and CI_BUN_CACHE_RESTORE_WARM=1 restores everywhere again.
        steps = job(workflow())["steps"]
        names = [s.get("name") for s in steps]
        warm = step_named(steps, "Is this runner's own Bun package cache warm")
        self.assertEqual(warm["id"], "bun-warm")
        self.assertIn("CI_BUN_CACHE_RESTORE_WARM", warm["env"]["RESTORE_ON_WARM"])
        for restore_id in ("bun-r2", "bun-cache"):
            restore = next(s for s in steps if s.get("id") == restore_id)
            self.assertIn("steps.bun-warm.outputs.warm != 'true'", restore["if"])
            self.assertLess(names.index(warm["name"]), names.index(restore["name"]))

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
        self.assertIn("check:surface-bypass", module.CHECKS)
        self.assertEqual(module.CHECK_CLASSES["check:surface-bypass"], module.LINT)  # advisory on the nightly
        # The type check is its own job (ci-self-heal 0c, Leo 2026-11-19): a type error is a red of its own and
        # never the test shard's; the same per-error base comparison runs there.
        self.assertIn("--skip typecheck", steps[0]["run"])
        typecheck = doc["jobs"]["webviews-typecheck"]
        run = "\n".join(s.get("run", "") for s in typecheck["steps"])
        self.assertIn('--base "$BASE_REF" --only typecheck', run)
        self.assertEqual(typecheck["steps"][0]["with"]["fetch-depth"],
                         "${{ github.event_name == 'pull_request' && '2' || '1' }}")
        with self.assertRaises(SystemExit):
            module.main(["--only", "not-a-check", "--no-install"])

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
        # The same-input receipt steps (#49946) are the exception: they fail open by design (an error runs the shard
        # in full) and the last two run after the gate, so none of them is a verdict. The React Compiler transform
        # cache steps fail open the same way: a miss or a broken cache only makes the shard compile from scratch.
        # Shard 1's background starts (scripts/ci/shard1_background.sh) fail open too: each check's own step waits for
        # it, runs it inline when it never started, and that step's outcome is the one the gate reads.
        receipt_steps = ("same-input receipt", "the receipt's results", "React Compiler transform cache")
        fail_open = [s for s in steps if "shard1_background.sh start" in s.get("run", "")]
        for step in fail_open:
            with self.subTest(started=step["name"]):
                started = step["run"].split("shard1_background.sh start ", 1)[1].split()[0]
                waits = [s for s in steps if f"shard1_background.sh wait {started} " in s.get("run", "")]
                self.assertEqual(len(waits), 1)
                self.assertIn(f"${{{{ steps.{waits[0]['id']}.outcome }}}}", gated)
        for step in steps:
            if step in fail_open:
                continue
            # The pinned toolchain restores (scripts/ci/toolchain-r2.sh) are best-effort too: a miss is setup's download.
            if "toolchain-r2.sh\" restore " in str(step.get("run", "")):
                continue
            # So are the bounded package cache restores (cmux#55346): a miss or a timeout is a cold install, not a verdict.
            if str(step.get("uses", "")).startswith(("actions/cache@", "actions/cache/restore@")):
                continue
            if step.get("continue-on-error") is True and not any(r in step["name"] for r in receipt_steps):
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


def commits(repo: Path, changes: list[tuple[dict[str, str], str]]) -> list[str]:
    """Make one commit per (files, message) on the checked-out branch with a single `git fast-import`, then sync the
    work tree, and return their shas. A loop of `git commit` costs a process per commit (three with `commit`), and the
    deepen fixtures need hundreds: 250 of them took about 70 s on a CI runner and pushed tooling-tests past its bound."""
    branch = git(repo, "symbolic-ref", "HEAD")
    when = int(time.time())
    stream = [f"reset {branch}", f"from {git(repo, 'rev-parse', 'HEAD')}", ""]
    for mark, (files, message) in enumerate(changes, start=1):
        data = message.encode()
        stream += [f"commit {branch}", f"mark :{mark}", f"author t <t@example.com> {when} +0000",
                   f"committer t <t@example.com> {when} +0000", f"data {len(data)}", message]
        for rel, text in files.items():
            stream += [f"M 100644 inline {rel}", f"data {len(text.encode())}", text]
        stream.append("")
    marks = Path(git(repo, "rev-parse", "--absolute-git-dir")) / "fast-import-marks"
    subprocess.run(["git", "-C", str(repo), "fast-import", "--quiet", f"--export-marks={marks}"],
                   input="\n".join(stream).encode() + b"\n", check=True, capture_output=True)
    shas = dict(line.split() for line in marks.read_text().splitlines())
    marks.unlink()
    git(repo, "reset", "-q", "--hard", branch)
    return [shas[f":{mark}"] for mark in range(1, len(changes) + 1)]


# A stand-in for each gate script: records its argv (and, for the crash ratchet, the base tree it
# was given), and fails when its gate name is in $FAKE_FAIL.
FAKE = textwrap.dedent("""\
    import json, os, sys
    import time
    from pathlib import Path
    name = {name!r}
    entry = {{"gate": name, "argv": sys.argv[1:], "cwd": os.getcwd()}}
    if "--base" in sys.argv and Path(sys.argv[sys.argv.index("--base") + 1]).is_dir():
        base = Path(sys.argv[sys.argv.index("--base") + 1])
        entry["base_marker"] = (base / "scripts/cmux-next/marker.txt").read_text()
    with open(os.environ["FAKE_LOG"], "a") as log:
        log.write(json.dumps(entry) + "\\n")
    barrier = os.environ.get("FAKE_BARRIER")
    if barrier and name != "webviews checks":
        marker = Path(barrier) / ("started-" + name.replace(" ", "-"))
        marker.touch()
        expected = int(os.environ.get("FAKE_BARRIER_COUNT", "1"))
        deadline = time.monotonic() + float(os.environ.get("FAKE_BARRIER_TIMEOUT", "2"))
        while len(list(Path(barrier).glob("started-*"))) < expected and time.monotonic() < deadline:
            time.sleep(0.01)
        if len(list(Path(barrier).glob("started-*"))) < expected:
            raise SystemExit("parallel gate barrier was not reached")
    time.sleep(float(os.environ.get("FAKE_SLEEP", "0")))
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
        git_fixture_env.init_repo(self.remote, "--bare")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next", f"pr:refs/pull/7/head")
        self.seed = seed
        self.log = self.tmp / "gates.jsonl"

    def script(self, repo: Path, *args: str, fail: str = "", sleep: float = 0,
               barrier: Path | None = None, budget: int | None = None,
               summary: Path | None = None) -> subprocess.CompletedProcess:
        env = {**os.environ, "FAKE_LOG": str(self.log), "FAKE_FAIL": fail,
               "FAKE_SLEEP": str(sleep),
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        if barrier is not None:
            env.update({"FAKE_BARRIER": str(barrier), "FAKE_BARRIER_COUNT": str(FIRST_BATCH_GATES)})
        extra = []
        if budget is not None:
            extra += ["--budget-seconds", str(budget)]
        if summary is not None:
            extra += ["--summary", str(summary)]
        return subprocess.run([sys.executable, str(SCRIPT), *args, *extra, "--repo", str(repo)],
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
        commits(seed, [({}, f"base moves on {n}") for n in range(module.FETCH_DEPTH + 10)])
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
            commits(seed, [({}, f"{branch} moves on {n}") for n in range(module.FETCH_DEPTH - 3)])
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
        self.assertEqual(self.outputs()["checks"], "false")  # it changes no input of the webviews checks
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

    def test_pull_request_a_few_commits_from_its_base_deepens_once_by_the_first_step_without_blobs(self):
        # 2026-11-13: runs 43473169308 and 43474564309 (heads 9 and 32 commits from their base) spent 87 to 108 s
        # in one --deepen=200 that brought every blob of 200 commits a side; the gates needed none of them.
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        commits(seed, [({"old.txt": f"old {n}\n"}, f"old base {n}") for n in range(60)])  # history past the first step
        # within it: each commit's blob is one a deepen with blobs would bring
        old_commit = commits(seed, [({"old.txt": f"newer {n}\n"}, f"newer base {n}") for n in range(40)])[20]
        old = git(seed, "rev-parse", f"{old_commit}:old.txt")
        fork = git(seed, "rev-parse", "HEAD")
        git(seed, "checkout", "-q", "-b", "pr10", fork)
        heads = [commit(seed, {"pr10.txt": f"{n}\n"}, f"the pull request's change {n}") for n in range(5)]
        git(seed, "checkout", "-q", "feat-cmux-next")
        base = commit(seed, {"tip.txt": "moved\n"}, "the base moves on")
        git(seed, "checkout", "-q", "--detach", base)
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit",
            heads[-1])
        git(seed, "push", "-q", "-f", str(self.remote), f"{base}:refs/heads/feat-cmux-next",
            f"{heads[-1]}:refs/pull/10/head", "HEAD:refs/pull/10/merge")
        git(seed, "checkout", "-q", "feat-cmux-next")
        for key in ("uploadpack.allowReachableSHA1InWant", "uploadpack.allowFilter"):  # as GitHub allows
            git(self.remote, "config", key, "true")
        work = self.tmp / "work10"
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", f"file://{self.remote}")
        git(work, "fetch", "-q", "--depth=2", "origin", "refs/pull/10/merge")  # what actions/checkout does
        git(work, "checkout", "-q", "--detach", "FETCH_HEAD")

        result = self.script(work, "prepare", "--event", "pull_request", "--head", heads[-1], "--base", base,
                             "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(re.findall(r"deepened by (\d+)", result.stderr), ["32"])
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(git(work, "rev-list", "--reverse", "--no-merges", f"{base}..{merge}").split(), heads)
        # The commit is here (the base side reaches it); its tree is not (tree:0), so neither is its blob, and
        # listing never fetches them.
        tree = git(seed, "rev-parse", f"{old_commit}^{{tree}}").strip()
        listed = git(work, "rev-list", "--objects", "--missing=print", "-1", old_commit).split()
        self.assertIn(f"?{tree}", listed, "the deepen brought a tree no gate read")
        self.assertNotIn(old, listed, "the deepen brought a blob no gate read")
        # A gate that does read it gets it on demand: the fetch marked origin as the promisor.
        self.assertEqual(git(work, "show", f"{old_commit}:old.txt"), "newer 20")

    def pool_merge(self, pr: str) -> tuple[str, str, list[str]]:
        """A base 60 commits deep, a pull request of 5 commits off it, and its merge ref; returns (base, head, own)."""
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        commits(seed, [({"old.txt": f"old {n}\n"}, f"old base {n}") for n in range(60)])
        fork = git(seed, "rev-parse", "HEAD")
        git(seed, "checkout", "-q", "-b", f"pr{pr}", fork)
        own = [commit(seed, {f"pr{pr}.txt": f"{n}\n"}, f"the pull request's change {n}") for n in range(5)]
        git(seed, "checkout", "-q", "feat-cmux-next")
        base = commit(seed, {"tip.txt": "moved\n"}, "the base moves on")
        git(seed, "checkout", "-q", "--detach", base)
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit", own[-1])
        git(seed, "push", "-q", "-f", str(self.remote), f"{base}:refs/heads/feat-cmux-next",
            f"{own[-1]}:refs/pull/{pr}/head", f"HEAD:refs/pull/{pr}/merge")
        git(seed, "checkout", "-q", "feat-cmux-next")
        for key in ("uploadpack.allowReachableSHA1InWant", "uploadpack.allowFilter"):  # as GitHub allows
            git(self.remote, "config", key, "true")
        return base, own[-1], own

    def pool_checkout(self, pr: str, mirror: Path) -> Path:
        """What the pool checkout does: a fresh repo borrowing the mirror, the merge ref at depth 2."""
        work = self.tmp / f"pool{pr}"
        work.mkdir()
        git(work, "init", "-q")
        (work / ".git" / "objects" / "info" / "alternates").write_text(f"{mirror / 'objects'}\n")
        git(work, "remote", "add", "origin", f"file://{self.remote}")
        git(work, "fetch", "-q", "--depth=2", "origin", f"refs/pull/{pr}/merge")
        git(work, "checkout", "-q", "--detach", "FETCH_HEAD")
        self.assertTrue((work / ".git" / "shallow").exists(), "the fixture must start shallow")
        return work

    def test_pull_request_on_a_pool_mirror_unshallows_locally_without_a_deepen_fetch(self):
        base, head, own = self.pool_merge("11")
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(self.remote), str(mirror)], check=True)
        work = self.pool_checkout("11", mirror)

        result = self.script(work, "prepare", "--event", "pull_request", "--head", head, "--base", base,
                             "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("unshallowed locally", result.stderr)
        self.assertNotIn("deepened by", result.stderr)
        self.assertEqual(git(work, "rev-parse", "--is-shallow-repository"), "false")
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(git(work, "rev-list", "--reverse", "--no-merges", f"{base}..{merge}").split(), own)

    def test_pull_request_on_a_stale_pool_mirror_deepens_from_the_remote(self):
        mirror = self.tmp / "mirror.git"
        subprocess.run(["git", "clone", "-q", "--mirror", str(self.remote), str(mirror)], check=True)
        base, head, own = self.pool_merge("12")  # all of it newer than the mirror's sync
        work = self.pool_checkout("12", mirror)

        result = self.script(work, "prepare", "--event", "pull_request", "--head", head, "--base", base,
                             "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lacks some history", result.stderr)
        self.assertIn("deepened by", result.stderr)
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(git(work, "rev-list", "--reverse", "--no-merges", f"{base}..{merge}").split(), own)

    def test_pull_request_deepens_until_the_base_reaches_below_the_pull_requests_fork(self):
        # #37015 at 5f689d98 (run 42236372118): the PR forked from an old base commit and later merged a newer tip
        # M. Deepening stopped once both sides met at M with no cut ahead of it, but the base's cut sat above the
        # fork while the PR side reached the root, so base..merge held every base commit under the cut and the
        # Sidebar-Look check refused about 620 of them.
        seed = self.seed
        git(seed, "checkout", "-q", "-b", "pr9", self.root)
        first = commit(seed, {"pr9.txt": "one\n"}, "the pull request's first change")
        git(seed, "checkout", "-q", "feat-cmux-next")
        # past the first deepen step, so the base's cut lands between M and the fork
        commits(seed, [({}, f"base moves on {n}") for n in range(250)])
        merged_in = commit(seed, {"shared.txt": "two\n"}, "M: the tip the pull request merges in")
        git(seed, "checkout", "-q", "pr9")
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit",
            merged_in)
        second = commit(seed, {"pr9.txt": "two\n"}, "the pull request's second change")
        git(seed, "checkout", "-q", "feat-cmux-next")
        commits(seed, [({}, f"base moves on after M {n}") for n in range(10)])
        base = git(seed, "rev-parse", "HEAD")
        git(seed, "checkout", "-q", "--detach", base)
        git(seed, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff", "--no-edit",
            second)
        git(seed, "push", "-q", "-f", str(self.remote), f"{base}:refs/heads/feat-cmux-next",
            f"{second}:refs/pull/9/head", "HEAD:refs/pull/9/merge")
        git(seed, "checkout", "-q", "feat-cmux-next")
        git(self.remote, "config", "uploadpack.allowReachableSHA1InWant", "true")  # as GitHub allows
        work = self.tmp / "work9"
        work.mkdir()
        git(work, "init", "-q")
        git(work, "remote", "add", "origin", f"file://{self.remote}")
        git(work, "fetch", "-q", "--depth=2", "origin", "refs/pull/9/merge")  # what actions/checkout does
        git(work, "checkout", "-q", "--detach", "FETCH_HEAD")

        result = self.script(work, "prepare", "--event", "pull_request", "--head", second, "--base", base,
                             "--output", str(self.tmp / "out.txt"))

        self.assertEqual(result.returncode, 0, result.stderr)
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(git(work, "rev-list", "--reverse", "--no-merges", f"{base}..{merge}").split(),
                         [first, second])

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

    def test_a_webviews_catalog_or_protocol_spec_change_runs_the_webviews_checks_on_a_pull_request(self):
        # check:catalog-keys and acpmux-protocol:check read the catalogs and the spec. A webviews/ change too, though
        # ci-web's webview suite runs them on the same merge: land-judge's merged-tree carry lands a base merge on this
        # status and not on that suite, so cmux#49052's base merge would have landed its `foldsPrompt` type error
        # (cmuxterm-hq#19108) with the type check run only inside a suite nothing waited for.
        seed = self.seed
        for path in ("Resources/Localizable.xcstrings", "cmux-tui/crates/acpmux/spec/acpmux-protocol.json",
                     "webviews/src/agent-session/acpmux/conversation/turns.ts"):
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
        self.assertEqual(calls["protocol skew"]["argv"], ["--base", base, "--head", merge])
        self.assertEqual(calls["entry logs"]["argv"], ["check", "--base", base, "--head", merge])
        self.assertEqual(calls["settings catalog keys"]["argv"][0], "--root")
        self.assertEqual(calls["settings catalog keys"]["argv"][-2:], ["--base-rev", base])  # a base red is a note
        self.assertEqual(calls["egress gate"]["argv"][:4], ["--base", base, "--head", merge])
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
        self.assertIn("Runner CPUs:", text)
        self.assertIn("child CPU", text)

    def test_one_red_gate_fails_the_run_and_the_rest_still_run(self):
        work, out = self.prepared()
        for red in GATE_SCRIPTS:
            with self.subTest(red=red):
                self.log.unlink(missing_ok=True)
                result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "true", fail=red)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS))
                self.assertRegex(result.stdout + result.stderr, rf"(?m)^.*{re.escape(red)}.*fail")

    def test_independent_gates_run_in_parallel(self):
        work, out = self.prepared()
        barrier = self.tmp / "parallel-barrier"
        barrier.mkdir()
        result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "true",
                             sleep=0.2, barrier=barrier)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The first batch cannot finish until every first-batch marker exists. A serial implementation therefore fails
        # deterministically at the barrier instead of relying on a wall-clock threshold that flakes on loaded hosts.
        self.assertEqual(len(list(barrier.glob("started-*"))), FIRST_BATCH_GATES)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS))

    def test_a_zero_budget_stops_every_started_gate_and_still_names_a_critical_path_gate(self):
        # Gates start side by side (#50061), so a spent budget no longer leaves every gate unstarted: each lane's first
        # gate starts and is stopped as stalled, and a gate queued behind another in its lane (webviews checks behind
        # web lint) never starts. The summary still names a critical-path gate, never "no gate ran".
        work, _ = self.prepared()
        summary = self.tmp / "summary.md"
        result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "true",
                             budget=0, summary=summary)
        self.assertNotEqual(result.returncode, 0)
        text = summary.read_text()
        self.assertRegex(text, r"Critical-path gate: \*\*(?!no gate ran)[^*]+\*\* \(")
        self.assertIn("failed (no time left)", text)

    def test_gate_logs_are_named_per_gate_across_batches(self):
        module = load(SCRIPT)
        with tempfile.TemporaryDirectory(prefix="fast-gates-logs-") as tmp:
            log_dir = Path(tmp)
            # Each gate prints its own line: a runner without /usr/bin/time (timed_gate_argv) adds none, and a
            # silent gate left an empty log there (tooling-tests on cmux-linux, runs 45339026481, 45350194064).
            first = module.run_gate_batch([[("crash ratchet", [sys.executable, "-c", "print('crash ratchet')"])]],
                                          Path(tmp), None, log_dir)
            second = module.run_gate_batch([[("webviews checks", [sys.executable, "-c", "print('webviews checks')"])]],
                                           Path(tmp), None, log_dir)
            self.assertIn("crash-ratchet.log", {path.name for path in log_dir.iterdir()})
            self.assertIn("webviews-checks.log", {path.name for path in log_dir.iterdir()})
            self.assertTrue((log_dir / "crash-ratchet.log").read_text())
            self.assertTrue((log_dir / "webviews-checks.log").read_text())

    def test_no_web_change_skips_web_lint_only(self):
        work, out = self.prepared()
        result = self.script(work, "run", "--base", self.tip, "--web", "false", "--checks", "true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"web lint"})
        self.assertIn("web lint: skipped (no web path changed)", result.stdout)

    def test_checks_false_skips_the_webviews_checks(self):
        work, out = self.prepared()
        result = self.script(work, "run", "--base", self.tip, "--web", "true", "--checks", "false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"webviews checks"})
        self.assertIn("webviews checks: skipped", result.stdout)

    def test_a_change_outside_the_ratchets_inputs_skips_the_crash_ratchet_only(self):
        work, out = self.prepared()
        before = git(work, "rev-parse", "HEAD")
        # pr_owned_findings.py is a crash-class input and not a ratchet one.
        commit(work, {"docs/note.md": "note\n", "scripts/ci/pr_owned_findings.py": "# changed\n"}, "no ratchet input")
        result = self.script(work, "run", "--base", before, "--web", "true", "--checks", "true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"crash ratchet"})
        self.assertIn("crash ratchet: skipped (no change under Packages", result.stdout)

    def test_a_change_outside_every_crash_input_skips_the_ratchet_and_the_crash_class_rules(self):
        work, out = self.prepared()
        before = git(work, "rev-parse", "HEAD")
        commit(work, {"docs/note.md": "note\n", "cmux-tui/README.md": "readme\n"}, "no crash input")
        result = self.script(work, "run", "--base", before, "--web", "true", "--checks", "true")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()},
                         set(GATE_SCRIPTS) - {"crash ratchet", "crash-class rules"})
        self.assertIn("crash-class rules: skipped (no change under Packages", result.stdout)

    def test_every_crash_class_input_runs_the_crash_class_rules(self):
        module = load(SCRIPT)
        work, _ = self.prepared()
        for path in ("Packages/macOS/CmuxNext/Sources/A.swift", "Packages/Other/x.swift",
                     "scripts/cmux-next/check-concurrency.sh", "scripts/cmux-next/check-objc-selectors.py",
                     "scripts/ci/crash_class_fast_gate.py", "scripts/ci/crash-class-gate.sh",
                     "scripts/ci/pr_owned_findings.py", ".github/workflows/cmux-next-crash-class.yml"):
            with self.subTest(path=path):
                before = git(work, "rev-parse", "HEAD")
                commit(work, {path: f"{path}\n"}, f"change {path}")
                self.assertTrue(module.crash_class_inputs_changed(work, before, git(work, "rev-parse", "HEAD")))
        before = git(work, "rev-parse", "HEAD")
        commit(work, {"Packages-notes.md": "x\n", "scripts/cmux-next-other/a.py": "x\n",
                      "cmux-tui/crates/c/lib.rs": "x\n", "webviews/a.ts": "x\n"}, "no crash-class input")
        self.assertFalse(module.crash_class_inputs_changed(work, before, git(work, "rev-parse", "HEAD")))

    def test_an_unreadable_diff_runs_the_crash_gates(self):
        module = load(SCRIPT)
        work, _ = self.prepared()
        self.assertTrue(module.crash_class_inputs_changed(work, "0" * 40, "HEAD"))
        self.assertTrue(module.ratchet_inputs_changed(work, "0" * 40, "HEAD"))

    def test_every_ratchet_input_runs_the_crash_ratchet(self):
        module = load(SCRIPT)
        work, _ = self.prepared()
        for path in ("Packages/A/x.swift", "cmux-tui/crates/c/lib.rs", "scripts/cmux-next/crash-safety-baseline.json",
                     "scripts/ci/crash_ratchet_compare.py"):
            with self.subTest(path=path):
                before = git(work, "rev-parse", "HEAD")
                commit(work, {path: f"{path}\n"}, f"change {path}")
                self.assertTrue(module.ratchet_inputs_changed(work, before, git(work, "rev-parse", "HEAD")))
        before = git(work, "rev-parse", "HEAD")
        commit(work, {"Packages-notes.md": "x\n", "scripts/cmux-next-other/a.py": "x\n"}, "look-alike paths")
        self.assertFalse(module.ratchet_inputs_changed(work, before, git(work, "rev-parse", "HEAD")))

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


class GateBudget(unittest.TestCase):
    def test_a_gate_past_the_budget_is_stopped_with_its_children(self):
        module = load(SCRIPT)
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "child.pid"
            # The gate starts a child (as web lint starts bun install) that would outlive a kill of the gate alone;
            # both block on signal.pause(), so only the stop ends them.
            gate = ("import pathlib, signal, subprocess, sys; "
                    "child = subprocess.Popen([sys.executable, '-c', 'import signal; signal.pause()']); "
                    f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid)); signal.pause()")
            self.assertIsNone(module.run_gate([sys.executable, "-c", gate], Path(tmp), 5))
            child = int(pid_file.read_text(encoding="utf-8"))

            # A zombie counts as gone; without /proc (macOS) the helper asks ps instead of reading "gone".
            self.assertTrue(process_gone.died(child), "the gate's child kept running after the gate was stopped")

    def test_a_child_that_ignores_sigterm_is_killed_too(self):
        module = load(SCRIPT)
        with tempfile.TemporaryDirectory() as tmp:
            pid_file = Path(tmp) / "child.pid"
            child_code = "import signal; signal.signal(signal.SIGTERM, signal.SIG_IGN); signal.pause()"
            gate = ("import pathlib, signal, subprocess, sys; "
                    f"child = subprocess.Popen([sys.executable, '-c', {child_code!r}]); "
                    f"pathlib.Path({str(pid_file)!r}).write_text(str(child.pid)); signal.pause()")
            self.assertIsNone(module.run_gate([sys.executable, "-c", gate], Path(tmp), 5))
            child = int(pid_file.read_text(encoding="utf-8"))

            self.assertTrue(process_gone.died(child), "a child that ignores SIGTERM outlived its stopped gate")

    def test_a_gate_inside_the_budget_keeps_its_exit_code(self):
        module = load(SCRIPT)
        self.assertEqual(module.run_gate([sys.executable, "-c", "raise SystemExit(3)"], Path.cwd(), 30), 3)
        self.assertEqual(module.run_gate([sys.executable, "-c", "pass"], Path.cwd(), None), 0)


class BunInstallScript(unittest.TestCase):
    """scripts/ci/bun-install.sh, the same bound for the web jobs outside these gates (web-complexity.yml)."""

    SCRIPT = ROOT / "scripts/ci/bun-install.sh"

    def install(self, fake_bun: str, **env: str) -> subprocess.CompletedProcess:
        tmp = Path(tempfile.mkdtemp(prefix="bun-install-test-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)])
        bin_dir = tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "bun").write_text("#!/bin/sh\n" + fake_bun, encoding="utf-8")
        (bin_dir / "bun").chmod(0o755)
        (tmp / "count").write_text("", encoding="utf-8")
        environment = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "COUNT": str(tmp / "count"),
                       # A closed local port: the registry probe answers at once, with no network.
                       "BUN_CONFIG_REGISTRY": "http://127.0.0.1:9/", **env}
        result = subprocess.run(["bash", str(self.SCRIPT)], cwd=tmp, env=environment, capture_output=True, text=True,
                                timeout=60)
        result.attempts = len((tmp / "count").read_text(encoding="utf-8"))
        return result

    def test_a_hung_install_is_retried_then_fails_with_its_reason(self):
        result = self.install('printf x >> "$COUNT"; sleep 30\n', BUN_INSTALL_ATTEMPT_SECONDS="1",
                              BUN_INSTALL_ATTEMPTS="2")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.attempts, 2)
        self.assertIn("::warning title=bun install retry::", result.stdout)
        self.assertIn("::error title=bun install stalled::", result.stdout)
        self.assertIn("no result in 1s", result.stdout)

    def test_a_second_attempt_that_installs_passes(self):
        result = self.install('printf x >> "$COUNT"; [ "$(wc -c < "$COUNT")" -ge 2 ] || sleep 30\n',
                              BUN_INSTALL_ATTEMPT_SECONDS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("installed in", result.stdout)

    def test_bun_gets_an_idle_limit_and_the_callers_arguments(self):
        result = self.install('echo "idle=$BUN_CONFIG_HTTP_IDLE_TIMEOUT retry=$BUN_CONFIG_HTTP_RETRY_COUNT args=$*"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("idle=30 retry=5 args=install --frozen-lockfile", result.stdout)

    def test_a_zero_bound_is_refused(self):
        # GNU `timeout 0` disables the deadline, so a zero would let a hung install run to the job limit again.
        result = self.install("exit 0\n", BUN_INSTALL_ATTEMPT_SECONDS="0")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a positive whole number", result.stderr)

    def test_a_registry_password_never_reaches_the_log(self):
        result = self.install("exit 0\n", BUN_CONFIG_REGISTRY="http://ci:s3cret@127.0.0.1:9/")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("s3cret", result.stdout + result.stderr)
        self.assertIn("registry http://127.0.0.1:9/", result.stdout)

    def test_web_complexity_installs_through_it_with_the_package_cache(self):
        doc = yaml.safe_load((ROOT / ".github/workflows/web-complexity.yml").read_text(encoding="utf-8"))
        steps = doc["jobs"]["complexity"]["steps"]
        self.assertEqual(step_named(steps, "Install web dependencies")["run"],
                         "bash ../scripts/ci/bun-install.sh --frozen-lockfile")
        # Base branches save the cache; every other ref restores it only (a save and a restore twin).
        caches = [s for s in steps if s.get("name", "").startswith("Cache Bun package cache")]
        self.assertEqual(len(caches), 2, [s.get("name") for s in caches])
        install = steps.index(step_named(steps, "Install web dependencies"))
        for cache in caches:
            self.assertEqual(cache["with"]["path"], "~/.bun/install/cache")
            self.assertLess(steps.index(cache), install)


class BunInstallScriptWithoutGnuTimeout(BunInstallScript):
    """The same bun-install.sh tests through scripts/ci/timeout.sh's perl watchdog, the path a Mac runner takes.

    2026-11-11: bun-install.sh called GNU `timeout` bare; tooling-tests passed on Linux and failed on the Macs
    it then ran on ("timeout: command not found") on #40892, #41288, #41299 and #41305.
    """

    def install(self, fake_bun: str, **env: str) -> subprocess.CompletedProcess:
        return super().install(fake_bun, **{"CI_TIMEOUT_IMPL": "perl", **env})


TIMEOUT_SCRIPT = ROOT / "scripts/ci/timeout.sh"


class PortableTimeout(unittest.TestCase):
    """scripts/ci/timeout.sh keeps GNU timeout's contract with GNU timeout and with the perl watchdog a Mac uses."""

    IMPLS = ("", "perl")  # "": GNU timeout where the host has one (the watchdog where it has none)

    def run_timeout(self, impl: str, *args: str) -> tuple[subprocess.CompletedProcess, float]:
        env = {**os.environ, "CI_TIMEOUT_IMPL": impl}
        started = time.monotonic()
        result = subprocess.run(["bash", str(TIMEOUT_SCRIPT), *args], env=env, capture_output=True, text=True,
                                timeout=60)
        return result, time.monotonic() - started

    def test_the_command_keeps_its_exit_code_and_output(self):
        for impl in self.IMPLS:
            with self.subTest(impl=impl or "default"):
                result, _ = self.run_timeout(impl, "10", "sh", "-c", "echo out; echo err >&2; exit 3")
                self.assertEqual((result.returncode, result.stdout, result.stderr), (3, "out\n", "err\n"))

    def test_the_deadline_ends_the_command_and_its_children_with_124(self):
        # The child `sleep` would hold the pipe open for 30 s if only its parent shell were signalled.
        for impl in self.IMPLS:
            with self.subTest(impl=impl or "default"):
                result, took = self.run_timeout(impl, "--kill-after=5", "1", "sh", "-c", "sleep 30; echo late")
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertNotIn("late", result.stdout)
                self.assertLess(took, 10)

    def test_a_command_that_ignores_term_is_killed_with_137(self):
        for impl in self.IMPLS:
            with self.subTest(impl=impl or "default"):
                result, took = self.run_timeout(impl, "--kill-after=1", "1", "sh", "-c",
                                                "trap '' TERM; sleep 30")
                # GNU timeout's KILL goes to its own process group, itself included: a shell reads 137 (128+9),
                # Python's subprocess -9. The watchdog exits 137, which a shell reads the same way.
                self.assertIn(result.returncode, (137, -9), result.stderr)
                self.assertLess(took, 10)

    def test_duration_suffixes_zero_and_a_missing_command(self):
        for impl in self.IMPLS:
            with self.subTest(impl=impl or "default"):
                self.assertEqual(self.run_timeout(impl, "1s", "sleep", "3")[0].returncode, 124)
                self.assertEqual(self.run_timeout(impl, "0", "true")[0].returncode, 0)  # 0: no deadline
                self.assertEqual(self.run_timeout(impl, "5", "no-such-command-cmux-test")[0].returncode, 127)

    def test_a_timeout_shim_on_path_that_points_back_here_does_not_loop(self):
        # macos-cross-runtime-check.sh puts a `timeout` on PATH that runs this file.
        tmp = Path(tempfile.mkdtemp(prefix="timeout-shim-test-"))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(tmp)])
        shim = tmp / "timeout"
        shim.write_text(f'#!/usr/bin/env bash\nexec bash "{TIMEOUT_SCRIPT}" "$@"\n', encoding="utf-8")
        shim.chmod(0o755)
        env = {**os.environ, "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}"}
        result = subprocess.run(["timeout", "--kill-after=1", "1", "sleep", "5"], env=env, capture_output=True,
                                text=True, timeout=30)
        self.assertEqual(result.returncode, 124, result.stderr)


# A `timeout` or `gtimeout` in command position: first on a line or after a separator, `then`, `do`, `exec`, ...
BARE_TIMEOUT = re.compile(
    r"(?:^|[;&|({!`]|\$\(|\b(?:then|do|else|exec|env|nohup|nice|xargs|time))\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"
    r"(g?timeout)\s")


def shell_scripts(folder: Path) -> list[Path]:
    found = []
    for path in sorted(folder.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix in (".sh", ".bash"):
            found.append(path)
            continue
        try:
            with path.open("rb") as handle:
                first = handle.readline()
        except OSError:
            continue
        if first.startswith(b"#!") and re.search(rb"\b(?:ba|z|da)?sh\b", first):
            found.append(path)
    return found


QUOTED = re.compile(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'')
# A job whose runs-on can name a Mac: a macOS label or pool, or a nightly signing Mac.
MAC_RUNS_ON = re.compile(r"'macos-\d|MACOS_RUNNER|RUNNER_POOLS\)\.macos|CI_NIGHTLY_|glaeda-nightly")


def bare_timeout_calls(text: str) -> list[tuple[int, str]]:
    calls = []
    for number, line in enumerate(text.splitlines(), 1):
        code = line.split(" #", 1)[0] if not line.lstrip().startswith("#") else ""
        # Message text is not a call; a quoted command substitution ("$(timeout 5 x)") still is.
        code = QUOTED.sub(lambda m: m.group(0) if "$(" in m.group(0) or "`" in m.group(0) else '""', code)
        if BARE_TIMEOUT.search(code):
            calls.append((number, line.strip()))
    return calls


class CiScriptsCallPortableTimeout(unittest.TestCase):
    """Detector: no scripts/ci shell script runs `timeout` or `gtimeout` itself; each goes through scripts/ci/timeout.sh.

    macOS has no `timeout`, and a CI job (tooling-tests, the web tests) can land on a Mac runner, so a bare call passes
    or fails by placement. Pattern page: cmuxterm-hq docs/handbook/gnu-tool-missing-on-a-mac-runner.md.
    """

    def test_no_scripts_ci_shell_script_calls_timeout_bare(self):
        offenders = []
        for path in shell_scripts(ROOT / "scripts/ci"):
            if path == TIMEOUT_SCRIPT:
                continue
            for number, line in bare_timeout_calls(path.read_text(encoding="utf-8", errors="replace")):
                offenders.append(f"{path.relative_to(ROOT)}:{number}: {line}")
        self.assertEqual(offenders, [], "macOS runners have no `timeout`: run the command through "
                         "`bash scripts/ci/timeout.sh [--kill-after=D] SECONDS CMD...` instead")

    def test_a_workflow_that_copies_a_script_out_copies_the_wrapper_with_it(self):
        # ci-web.yml and cmux-next-web.yml run the head's run-webviews-tests.sh from a copy in $RUNNER_TEMP; a copy
        # without its sibling timeout.sh would fail every file with "No such file or directory".
        users = [path.name for path in shell_scripts(ROOT / "scripts/ci")
                 if path != TIMEOUT_SCRIPT and "timeout.sh" in path.read_text(encoding="utf-8", errors="replace")]
        self.assertIn("run-webviews-tests.sh", users)
        missing = []
        for workflow_path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            text = workflow_path.read_text(encoding="utf-8").replace("\\\n", " ")
            for line in text.splitlines():
                if not re.search(r"(?:^|[;&|]\s*|\s)cp\s", line):
                    continue
                for name in users:
                    if re.search(rf"scripts/ci/{re.escape(name)}\b", line) and "scripts/ci/timeout.sh" not in line:
                        missing.append(f"{workflow_path.name}: {line.strip()[:160]}")
        self.assertEqual(missing, [], "copy scripts/ci/timeout.sh beside every script that runs it")

    def test_the_detector_catches_the_shapes_that_broke(self):
        self.assertEqual(len(bare_timeout_calls('  timeout --kill-after=15 "$s" bun install "$@"\n')), 1)
        self.assertEqual(len(bare_timeout_calls("if command -v timeout >/dev/null; then timeout 5 x; fi\n")), 1)
        self.assertEqual(len(bare_timeout_calls('out="$(FOO=1 gtimeout 9 cmd)"\n')), 1)
        self.assertEqual(bare_timeout_calls('# timeout 5 cmd\necho "no result in a timeout"\nbun test --timeout 5\n'
                                            'bash "$ci_timeout" 5 cmd\necho "$f: its own retry; timeout budget"\n'), [])

    def test_no_mac_workflow_step_calls_timeout_bare(self):
        # nightly-next-one's "Ask main's nightly-next tick at notarization" ran `timeout 60 gh workflow run ...`
        # and exited 127 on a signing Mac with no GNU timeout (runs 43715748978, 43717516369); continue-on-error hid
        # it, so the next nightly never set up during notarization. A `command -v timeout` on the line guards it.
        offenders = []
        for workflow_path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
            jobs = (yaml.safe_load(workflow_path.read_text(encoding="utf-8")) or {}).get("jobs") or {}
            for job_id, job in jobs.items():
                if not isinstance(job, dict) or not MAC_RUNS_ON.search(str(job.get("runs-on", ""))):
                    continue
                for step in job.get("steps") or []:
                    run = step.get("run") if isinstance(step, dict) else None
                    if not isinstance(run, str):
                        continue
                    for _, line in bare_timeout_calls(run):
                        if "command -v timeout" not in line:
                            offenders.append(f"{workflow_path.name} {job_id} [{step.get('name')}]: {line[:160]}")
        self.assertEqual(offenders, [], "macOS runners have no `timeout`: run the command through "
                         "`bash scripts/ci/timeout.sh [--kill-after=D] SECONDS CMD...` instead")


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
        # Imported by name: the one module object every test reads (tests/test_script_module_loads.py).
        if str(WEBVIEWS_CHECKS.parent) not in sys.path:
            sys.path.insert(0, str(WEBVIEWS_CHECKS.parent))
        import fast_gate_webviews_checks
        self.module = fast_gate_webviews_checks

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

    def test_a_new_ratchet_the_base_has_no_script_for_is_not_charged_for_its_baselined_findings(self):
        # check:surface-bypass lands with its script and baseline: the base cannot run it, so its findings are not new.
        base = self.findings({}, "base without the script")
        commit(self.repo, {"webviews/scripts/check-surface-bypass.ts": "// the ratchet\n",
                           "webviews/findings/check:surface-bypass": "  src/a.tsx: 3 raw-button, baseline 3\n"},
               "the transition")
        result = self.gate(base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("check:surface-bypass is new; base has no command", result.stdout)

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

    def test_a_type_error_naming_a_node_modules_path_is_the_base_one(self):
        # Fast gates 45874767698 (cmux#57053): the base's bench/browsers.ts TS2345 names node_modules under each
        # checkout's root in its message, so a key that unrooted only the path read it as the merge's own.
        def diagnostic(root: str) -> str:
            return ("  x typescript(TS2345): Argument of type 'import(\"" + root + "/webviews/node_modules/"
                    "playwright-core/types/types\").LaunchOptions | undefined' is not assignable to parameter of "
                    "type 'LaunchOptions | undefined'.\n"
                    "    ,-[bench/browsers.ts:42:60]\n"
                    " 42 |   chromium.launch = (options) => launch(withShippedJsFlags(options));\n"
                    "    `----\n")
        for base_root in ("/w/merge", "/tmp/fast-gate-webviews-base-x/base"):
            new, old = self.module.compare(diagnostic("/w/merge"), diagnostic(base_root), "/w/merge",
                                           "/tmp/fast-gate-webviews-base-x/base")
            self.assertEqual(new, [], base_root)
            self.assertEqual(len(old), 1, base_root)

    def test_a_vite_config_stack_frame_matches_the_base_across_temp_names(self):
        merge = ("error: Failed to resolve vite config\n"
                 "    at markdownHost (file:///r/webviews/node_modules/.vite-temp/"
                 "vite.config.ts.timestamp-1795525836293-8f8fc7091050a8.mjs:3240:23)\n")
        base = merge.replace("1795525836293-8f8fc7091050a8", "1795525901234-0a1b2c3d4e5f60")
        new, old = self.module.compare(merge, base)
        self.assertEqual(new, [])
        self.assertTrue(old)

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

    def test_a_vite_config_stack_names_no_new_finding_on_the_merge(self):
        def crash(stamp: str, line: int) -> str:
            return (f"    at markdownHost (file:///r/webviews/node_modules/.vite-temp/"
                    f"vite.config.ts.timestamp-{stamp}.mjs:{line}:23)\n")
        merge, base = crash("1795526354921-166d4b4b7bbf6", 3240), crash("1795526301002-0a1b2c3d4e5f", 3238)
        self.assertEqual(self.module.added(merge, base), [])
        self.assertEqual(len(self.module.added(merge + "    at other (x.mjs:1:1)\n", base)), 1)

    def test_a_base_frame_in_the_shared_node_modules_is_the_merges(self):
        # The base's webviews/node_modules links to the merge's, so the base's stack names the merge's root.
        frame = "    at async resolveConfig (file:///m/webviews/node_modules/vite/dist/node.js:42734:22)\n"
        own = "    at x (file:///b/base/webviews/src/a.ts:1:1)\n"
        merge = frame + own.replace("/b/base", "/m")
        self.assertEqual(self.module.added(merge, frame + own, "/m", "/b/base"), [])
        self.assertEqual(len(self.module.added(merge, own, "/m", "/b/base")), 1)

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

    def test_a_vite_config_stack_frame_keys_without_its_temp_stamp(self):
        def frames(stamp: str) -> str:
            return ("error: Failed to resolve vite config: ENOENT\n"
                    f"    at markdownHost (file:///r/webviews/node_modules/.vite-temp/vite.config.ts.timestamp-{stamp}.mjs"
                    ":3176:23)\n")
        self.assertEqual(self.module.added(frames("1795522394672-bd727a4797f8c8"), frames("1795522301234-0a1b2c3d4e5f60")),
                         [])

    def test_a_crash_dump_keys_without_its_process_id(self):
        def dump(pid: int) -> str:
            return f"Error: spawnSync tsgo ETIMEDOUT\n{{\n  errno: -110,\n  code: 'ETIMEDOUT',\n  pid: {pid},\n}}\n"
        self.assertEqual(self.module.added(dump(1276995), dump(1180412)), [])
        self.assertEqual(self.module.added(dump(1276995) + "Error: new crash\n", dump(1180412)), ["Error: new crash"])

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

    # In GitHub Actions `vp lint` prints each finding as a workflow command; GitHub turns the line into an annotation
    # and its log keeps only `##[warning]MESSAGE`, so a new finding printed as that raw line names no file.
    UNUSED = ("::warning file=src/agent-session/acpmux/ModelPicker.tsx,line={line},endLine={line},col=34,"
              "endColumn=52,title=eslint(no-unused-expressions)::Expected expression to be used\n")

    def test_a_vite_config_stack_differing_only_by_its_temp_bundle_name_is_the_base_one(self):
        def stack(stamp: str) -> str:
            return ("failed to load config from /w/webviews/vite.config.ts\n"
                    f"    at markdownHost (file:///w/webviews/node_modules/.vite-temp/vite.config.ts.timestamp-{stamp}.mjs:3240:23)\n")
        new, old = self.module.compare(stack("1795534024051-bd9bea275ee978"), stack("1795533990112-0a1b2c3d4e5f60"))
        self.assertEqual(new, [])
        self.assertEqual(len(old), 2)

    def test_an_annotation_finding_that_only_moved_lines_is_the_base_one(self):
        merge = self.UNUSED.format(line=803) + "Found 1 warning and 0 errors.\n"
        base = self.UNUSED.format(line=791) + "Found 1 warning and 0 errors.\n"
        new, old = self.module.compare(merge, base)
        self.assertEqual(new, [])
        self.assertEqual(len(old), 1)

    def test_a_new_annotation_finding_shows_its_file_and_line(self):
        merge = self.UNUSED.format(line=791) + "::error file=src/a%2Cb.ts,line=4,col=2,title=x%3Ay::bad%25 one\n"
        new = self.module.added(merge, "")
        self.assertEqual(new, ["src/agent-session/acpmux/ModelPicker.tsx:791:34: Expected expression to be used "
                               "[warning eslint(no-unused-expressions)]",
                               "src/a,b.ts:4:2: bad% one [error x:y]"])
        self.assertFalse([line for line in new if line.startswith("::")])

    def test_the_base_worktree_is_removed(self):
        base = self.findings({}, "base")
        self.findings({"check:fixed-waits": "  x\n"}, "red")
        self.gate(base)
        self.assertEqual(len(git(self.repo, "worktree", "list").splitlines()), 1)


class DeepenFallbackTests(unittest.TestCase):
    """GitHub's pack-objects aborted a tree:0 deepen on #52583 twice (jobs 138890366419, 138894346038)."""

    def run_deepen_fetch(self, failures: dict[str, str]):
        module = load(SCRIPT)
        calls = []

        def fake_git(repo, *args, check=True):
            calls.append(args)
            stderr = next((err for flag, err in failures.items() if flag in args), "")
            code = 128 if stderr else 0
            if check and code:
                raise SystemExit(f"fast-gates: git {' '.join(args)} failed: {stderr}")
            return subprocess.CompletedProcess(args, code, "", stderr)

        module.git = fake_git
        module.log = lambda message: None
        module.deepen_fetch(Path("."), "origin", "--deepen=32", ["a", "b"])
        return calls

    def test_a_pack_objects_abort_retries_with_blob_none(self):
        bug = "BUG: builtin/pack-objects.c:5098: should_include_obj\nerror: pack-objects died of signal 6"
        calls = self.run_deepen_fetch({"--filter=tree:0": bug})
        self.assertEqual([c[3] for c in calls], ["--filter=tree:0", "--filter=blob:none"])
        self.assertTrue(all("--deepen=32" in c for c in calls))

    def test_a_clean_deepen_fetches_once(self):
        self.assertEqual(len(self.run_deepen_fetch({})), 1)

    def test_any_other_failure_still_fails(self):
        with self.assertRaises(SystemExit):
            self.run_deepen_fetch({"--filter=tree:0": "fatal: could not read from remote repository"})


class FetchesSkipSubmodules(unittest.TestCase):
    """Fast gates only read history: a fetch that recursed into submodules failed run 46017930661 on a reused pool
    workspace with "Could not access submodule 'ghostty'" (handbook whole-origin-fetch-pulls-submodule-pins)."""

    def test_every_fetch_passes_no_recurse_submodules(self) -> None:
        source = (Path(__file__).resolve().parents[1] / "scripts/ci/cmux_next_fast_gates.py").read_text(encoding="utf-8")
        calls = re.findall(r'git\(repo, "fetch",[^\n]*', source)
        self.assertTrue(calls)
        for call in calls:
            self.assertIn('"--no-recurse-submodules"', call)


if __name__ == "__main__":
    unittest.main()
