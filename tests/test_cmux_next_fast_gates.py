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
    "defaults stamp": "scripts/ci/defaults_guard.py",
    "prepush gate": "scripts/cmux-next/prepush-gate.py",
    "crash-class rules": "scripts/ci/crash_class_fast_gate.py",
    "webviews checks": "scripts/ci/fast_gate_webviews_checks.py",
}
CI_WEB = ROOT / ".github/workflows/ci-web.yml"
WEBVIEWS_CHECKS = ROOT / "scripts/ci/fast_gate_webviews_checks.py"


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
        self.assertEqual(list(doc["jobs"]), ["resolve", "fast-gates", "post"])
        self.assertEqual(job(doc)["name"], "fast gates")
        # The same Linux runner expression as cmux-next-guards.yml's jobs.
        guards_runner = yaml.safe_load(GUARDS.read_text(encoding="utf-8"))["jobs"]["crash-ratchet"]["runs-on"]
        for key, each in doc["jobs"].items():
            with self.subTest(job=key):
                self.assertEqual(each["runs-on"], guards_runner)
                self.assertIn("blacksmith-4vcpu-ubuntu-2404", each["runs-on"])
                self.assertNotIn("macos", each["runs-on"].lower())
                self.assertLessEqual(int(each["timeout-minutes"]), 15)

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

    def test_concurrency_per_pull_request(self):
        concurrency = workflow()["concurrency"]
        self.assertEqual(concurrency["group"], "fast-gates-${{ github.event.pull_request.number || inputs.pr }}")
        self.assertIs(concurrency["cancel-in-progress"], True)

    def test_permissions_are_minimal(self):
        doc = workflow()
        self.assertEqual(doc["permissions"], {"contents": "read"})
        self.assertEqual(job(doc, "resolve")["permissions"], {"contents": "read", "pull-requests": "read"})
        # The job that runs pull request code can write nothing; only post can write a status.
        self.assertEqual(job(doc)["permissions"], {"contents": "read"})
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
        self.assertEqual(poster["needs"], ["resolve", "fast-gates"])
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
        self.assertNotIn("outputs", job(doc), "the gates job hands post nothing but its result")
        self.assertIn("github.run_id", post["env"]["TARGET_URL"])
        self.assertIn("github.token", post["env"]["GH_TOKEN"])
        body = post["run"]
        self.assertIn('"base $BASE"', body)
        self.assertIn("statuses/$HEAD_SHA", body)
        self.assertRegex(body, r"\[0-9a-f\]\{40\}")
        self.assertIn("state=success", body)
        self.assertIn("state=failure", body)

    def test_web_tools_install_only_for_web_changes_or_the_webviews_checks(self):
        steps = job(workflow())["steps"]
        bun = next(s for s in steps if s.get("uses", "").startswith("oven-sh/setup-bun@"))
        self.assertIn("steps.prepare.outputs.web == 'true'", bun["if"])
        self.assertIn("steps.prepare.outputs.checks == 'true'", bun["if"])
        self.assertEqual(bun["with"]["bun-version"], "1.4.2")
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
        # The type check compiles and stays with ci-web.
        doc = yaml.safe_load(CI_WEB.read_text(encoding="utf-8"))
        steps = [s for j in doc["jobs"].values() for s in j.get("steps", []) if s.get("id") == "webviews-check"]
        self.assertEqual(len(steps), 1)
        failing = set(re.findall(r"bun run (\S+) \|\| status=1", steps[0]["run"])) - {"typecheck"}
        spec = importlib.util.spec_from_file_location("fast_gate_webviews_checks", WEBVIEWS_CHECKS)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(set(module.CHECKS), failing)
        self.assertIn("check:fixed-waits", module.CHECKS)

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
        self.assertNotIn("head_sha", self.outputs(), "head and base come from resolve, not from here")

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
        self.assertEqual(calls["prepush gate"]["argv"][:4], ["--base", base, "--head", merge])
        self.assertEqual(calls["defaults stamp"]["argv"], ["check-stamp", "--base", base])
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
    [ "$1" = install ] && exit 0
    f="findings/$2"
    [ -s "$f" ] || { echo "$2: ok"; exit 0; }
    echo "$2: found"; cat "$f"; exit 1
""")


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

    def test_the_base_worktree_is_removed(self):
        base = self.findings({}, "base")
        self.findings({"check:fixed-waits": "  x\n"}, "red")
        self.gate(base)
        self.assertEqual(len(git(self.repo, "worktree", "list").splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
