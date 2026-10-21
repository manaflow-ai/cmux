#!/usr/bin/env python3
"""cmux-next fast gates: the PR merged with its base, four gates in fail mode, one commit status.

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
}


def workflow() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))


def triggers(doc: dict) -> dict:
    # PyYAML reads the bare key `on` as the boolean True.
    return doc.get("on", doc.get(True))


def job(doc: dict) -> dict:
    jobs = doc["jobs"]
    return next(iter(jobs.values()))


def step_named(steps: list[dict], fragment: str) -> dict:
    found = [s for s in steps if fragment in s.get("name", "")]
    if len(found) != 1:
        raise AssertionError(f"expected one step named like {fragment!r}, found {[s.get('name') for s in found]}")
    return found[0]


class WorkflowShape(unittest.TestCase):
    def test_name_job_and_runner(self):
        doc = workflow()
        self.assertEqual(doc["name"], "cmux-next fast gates")
        self.assertEqual(len(doc["jobs"]), 1, "one job, `fast gates`")
        gates = job(doc)
        self.assertEqual(gates["name"], "fast gates")
        # The same Linux runner expression as cmux-next-guards.yml's jobs.
        guards_runner = yaml.safe_load(GUARDS.read_text(encoding="utf-8"))["jobs"]["crash-ratchet"]["runs-on"]
        self.assertEqual(gates["runs-on"], guards_runner)
        self.assertIn("blacksmith-4vcpu-ubuntu-2404", gates["runs-on"])
        self.assertNotIn("macos", gates["runs-on"].lower())
        self.assertLessEqual(int(gates["timeout-minutes"]), 15)

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
        steps = job(doc)["steps"]
        validate = step_named(steps, "Validate")
        self.assertEqual(steps[0], validate, "the input is checked before anything runs")
        self.assertIn("inputs.pr", validate["env"]["PR"])
        self.assertRegex(validate["run"], r"\^\[0-9\]")
        # PR-controlled values reach shell through env only, never ${{ }} inside run.
        for step in steps:
            self.assertNotRegex(step.get("run", ""), r"\$\{\{",
                                f"step {step.get('name')!r} interpolates an expression into shell")

    def test_concurrency_per_pull_request(self):
        concurrency = workflow()["concurrency"]
        self.assertEqual(concurrency["group"], "fast-gates-${{ github.event.pull_request.number || inputs.pr }}")
        self.assertIs(concurrency["cancel-in-progress"], True)

    def test_permissions_are_minimal(self):
        doc = workflow()
        self.assertEqual(doc["permissions"], {"contents": "read"})
        self.assertEqual(job(doc)["permissions"], {"contents": "read", "statuses": "write"})

    def test_four_gates_fail_the_job(self):
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
        gates = job(workflow())
        post = step_named(gates["steps"], "status")
        self.assertIn("!cancelled()", post["if"])
        # Fork pull requests have no write token: no status, the job still passes or fails.
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", post["if"])
        self.assertEqual(post["env"]["CONTEXT"], "cmux-next/fast-gates")
        self.assertIn("steps.prepare.outputs.head_sha", post["env"]["HEAD_SHA"])
        self.assertIn("steps.prepare.outputs.base", post["env"]["BASE"])
        self.assertIn("github.run_id", post["env"]["TARGET_URL"])
        self.assertIn("github.token", post["env"]["GH_TOKEN"])
        body = post["run"]
        self.assertIn('"base $BASE"', body)
        self.assertIn("statuses/$HEAD_SHA", body)
        self.assertRegex(body, r"\[0-9a-f\]\{40\}")
        self.assertIn("state=success", body)
        self.assertIn("state=failure", body)

    def test_web_tools_install_only_for_web_changes(self):
        steps = job(workflow())["steps"]
        bun = next(s for s in steps if s.get("uses", "").startswith("oven-sh/setup-bun@"))
        self.assertIn("steps.prepare.outputs.web == 'true'", bun["if"])
        self.assertEqual(bun["with"]["bun-version"], "1.4.2")

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

    def clone(self) -> Path:
        work = self.tmp / "work"
        subprocess.run(["git", "clone", "-q", "--depth=1", "-b", "feat-cmux-next",
                        f"file://{self.remote}", str(work)], check=True)
        return work

    def outputs(self) -> dict[str, str]:
        out = self.tmp / "out.txt"
        return dict(line.split("=", 1) for line in out.read_text().splitlines() if "=" in line)

    def gate_log(self) -> list[dict]:
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_dispatch_merges_the_pull_request_into_the_current_tip(self):
        work = self.clone()
        result = self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", "7",
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.outputs()
        self.assertEqual(out["base"], self.tip)
        self.assertEqual(out["head_sha"], self.pr_head)
        merge = git(work, "rev-parse", "HEAD")
        self.assertEqual(out["merge"], merge)
        self.assertEqual(git(work, "rev-parse", "HEAD^1"), self.tip)
        self.assertEqual(git(work, "rev-parse", "HEAD^2"), self.pr_head)
        self.assertEqual(out["web"], "false")

    def test_dispatch_conflict_fails_clearly_and_still_names_the_base(self):
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        tip = commit(seed, {"scripts/cmux-next/marker.txt": "tip edits the same line\n"}, "conflicting")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next")
        work = self.clone()
        result = self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", "7",
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflict", result.stdout + result.stderr)
        self.assertIn("#7", result.stdout + result.stderr)
        out = self.outputs()
        self.assertEqual(out["base"], tip)
        self.assertEqual(out["head_sha"], self.pr_head)

    def test_dispatch_refuses_a_pr_that_is_not_digits(self):
        work = self.clone()
        for bad in ("7; rm -rf /", "", "07a", "-1"):
            with self.subTest(pr=bad):
                result = self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", bad,
                                     "--output", str(self.tmp / "out.txt"))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("pull request number", result.stderr)

    def test_pull_request_uses_the_checked_out_merge(self):
        work = self.clone()
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        result = self.script(work, "prepare", "--event", "pull_request", "--pr-head", self.pr_head,
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 0, result.stderr)
        out = self.outputs()
        self.assertEqual(out["base"], self.tip)
        self.assertEqual(out["head_sha"], self.pr_head)
        self.assertEqual(out["merge"], git(work, "rev-parse", "HEAD"))

    def test_pull_request_merge_of_another_head_fails(self):
        work = self.clone()
        git(work, "fetch", "-q", "origin", "refs/pull/7/head")
        git(work, "-c", "user.name=t", "-c", "user.email=t@example.com", "merge", "-q", "--no-ff",
            "--no-edit", "FETCH_HEAD")
        result = self.script(work, "prepare", "--event", "pull_request", "--pr-head", "f" * 40,
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 1)
        self.assertIn("not the pull request head", result.stderr)

    def test_a_web_change_asks_for_the_web_tools(self):
        seed = self.seed
        git(seed, "checkout", "-q", "feat-cmux-next")
        commit(seed, {"webviews/package.json": '{"scripts": {"check": "true"}}\n'}, "webviews package")
        git(seed, "push", "-q", str(self.remote), "feat-cmux-next")
        git(seed, "checkout", "-q", "pr")
        head = commit(seed, {"webviews/src/a.ts": "export const a = 1;\n"}, "web change")
        git(seed, "push", "-q", "-f", str(self.remote), "pr:refs/pull/7/head")
        work = self.clone()
        result = self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", "7",
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.outputs()["head_sha"], head)
        self.assertEqual(self.outputs()["web"], "true")

    def prepared(self) -> tuple[Path, dict[str, str]]:
        work = self.clone()
        result = self.script(work, "prepare", "--event", "workflow_dispatch", "--pr", "7",
                             "--output", str(self.tmp / "out.txt"))
        self.assertEqual(result.returncode, 0, result.stderr)
        return work, self.outputs()

    def test_run_calls_every_gate_against_the_base(self):
        work, out = self.prepared()
        summary = self.tmp / "summary.md"
        result = self.script(work, "run", "--base", out["base"], "--web", "true", "--summary", str(summary))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = {entry["gate"]: entry for entry in self.gate_log()}
        self.assertEqual(set(calls), set(GATE_SCRIPTS))
        base, merge = out["base"], out["merge"]
        self.assertEqual(calls["web lint"]["argv"][:4], ["--base", base, "--head", merge])
        self.assertEqual(calls["prepush gate"]["argv"][:4], ["--base", base, "--head", merge])
        self.assertEqual(calls["defaults stamp"]["argv"], ["check-stamp", "--base", base])
        ratchet = calls["crash ratchet"]["argv"]
        self.assertEqual(ratchet[:2], ["--script", "scripts/cmux-next/crash_ratchet.py"])
        self.assertEqual(Path(ratchet[ratchet.index("--head") + 1]).resolve(), work.resolve())
        # The ratchet's base tree is BASE exported, not the merge.
        self.assertEqual(calls["crash ratchet"]["base_marker"], "base\n")
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
                result = self.script(work, "run", "--base", out["base"], "--web", "true", fail=red)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS))
                self.assertRegex(result.stdout + result.stderr, rf"(?m)^.*{re.escape(red)}.*fail")

    def test_no_web_change_skips_web_lint_only(self):
        work, out = self.prepared()
        result = self.script(work, "run", "--base", out["base"], "--web", "false")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual({e["gate"] for e in self.gate_log()}, set(GATE_SCRIPTS) - {"web lint"})
        self.assertIn("web lint", result.stdout)
        self.assertIn("skipped", result.stdout)

    def test_run_refuses_a_base_that_is_not_a_commit(self):
        work, _ = self.prepared()
        result = self.script(work, "run", "--base", "0" * 40, "--web", "false")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.gate_log(), [])


if __name__ == "__main__":
    unittest.main()
