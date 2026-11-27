#!/usr/bin/env python3
"""The PR runs what base runs: no new check may first run after the merge.

A workflow that a push to feat-cmux-next starts and a pull request into it cannot start
gives its verdict only once the change is on the base. In the 7 days to 2026-11-13 the
base took 140 fixes for 3,676 landings (3.81 per 100), and of the 44 fixes that name a
check about 14 name one a pull request never ran.

.github/post-merge-checks.json lists every such workflow as `publish` (a deploy, a
publish, a bot: nothing a pull request could have caught) or `check` (a verdict about
the code, which belongs on the pull request), each with a reason. This test fails when

  - a workflow runs after the merge only and is not in the list: give it a pull_request
    trigger (path-filtered is fine), have a workflow that pull requests start call it, or
    run each of its commands in a step of the step table (ci/steps.toml) whose job a
    workflow that pull requests start runs (`ci/run run --job JOB`, pr-pipeline.yml);
  - a listed workflow is gone, lost its push trigger or gained a pull request path: drop
    its entry;
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import re
import sys
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
LIST = ROOT / ".github" / "post-merge-checks.json"
BASE = "feat-cmux-next"
KINDS = ("check", "publish")


def branch_pattern(glob: str) -> re.Pattern[str]:
    """GitHub's branch filter glob: ** crosses '/', * does not, [] is a class, and
    ? and + quantify the character before them."""
    out: list[str] = []
    i = 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**", i):
            out.append(".*")
            i += 2
            continue
        if c == "*":
            out.append("[^/]*")
        elif c in "?+" and out:
            out[-1] = "(?:" + out[-1] + ")" + c
        elif c == "[":
            end = glob.find("]", i)
            if end < 0:
                out.append(re.escape(c))
            else:
                out.append(glob[i:end + 1])
                i = end + 1
                continue
        else:
            out.append(re.escape(c))
        i += 1
    return re.compile("".join(out) + r"\Z")


def branch_matches(trigger: dict | None, branch: str, *, push: bool) -> bool:
    """Whether `branch` passes the trigger's branch filter (paths aside): the pushed
    branch for push, the base branch for pull_request and pull_request_target."""
    trigger = trigger or {}
    if "branches-ignore" in trigger:
        return not any(branch_pattern(p).match(branch) for p in trigger["branches-ignore"])
    if "branches" not in trigger:
        # A push with only tag filters starts on no branch; a pull request has no tag filter.
        return not (push and ("tags" in trigger or "tags-ignore" in trigger))
    matched = False
    for pattern in trigger["branches"]:
        negated = pattern.startswith("!")
        if branch_pattern(pattern[1:] if negated else pattern).match(branch):
            matched = not negated
    return matched


def triggers(doc: dict) -> dict:
    on = doc.get("on", doc.get(True)) or {}
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return dict.fromkeys(on)
    return on


def called_workflows(doc: dict) -> set[str]:
    """The local reusable workflows this one's jobs call."""
    found = set()
    for job in (doc.get("jobs") or {}).values():
        uses = job.get("uses") if isinstance(job, dict) else None
        if isinstance(uses, str) and uses.startswith("./.github/workflows/"):
            found.add(uses.rsplit("/", 1)[1].split("@", 1)[0])
    return found


TABLE_JOB_RUN = re.compile(r"(?:ci/run|scripts/ci/ci_steps\.py)\s+run\s[^\n]*?--job[ =](?P<job>[A-Za-z0-9_-]+)")


def run_commands(doc: dict) -> list[str]:
    """Each command line of the workflow's `run:` steps, comments and blanks left out."""
    lines = []
    for job in (doc.get("jobs") or {}).values():
        for step in (job.get("steps") or []) if isinstance(job, dict) else []:
            for line in str(step.get("run") or "").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    lines.append(line)
    return lines


def table_runs(workflows: dict[str, dict], reached: set[str]) -> str:
    """The `run` text of the step table's steps in each job a reached workflow runs through ci/run."""
    jobs = {m.group("job") for name in reached for line in run_commands(workflows[name])
            for m in TABLE_JOB_RUN.finditer(line)}
    if not jobs or not (ROOT / "ci" / "steps.toml").is_file():
        return ""
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import ci_steps  # noqa: PLC0415

    return "\n".join(step.run for step in ci_steps.load().steps.values() if step.job in jobs)


def post_merge_only(workflows: dict[str, dict], base: str = BASE, table: str | None = None) -> set[str]:
    """Workflows a push to `base` starts that no pull request into `base` can reach,
    directly or as a reusable workflow called (at any depth) from one that it starts.
    A workflow whose every command a step of the table runs on the pull request is
    reached too (`table`: those steps' `run` text; None reads ci/steps.toml)."""
    on_pr = {
        name
        for name, doc in workflows.items()
        if any(
            event in triggers(doc) and branch_matches(triggers(doc)[event], base, push=False)
            for event in ("pull_request", "pull_request_target")
        )
    }
    reached, frontier = set(on_pr), list(on_pr)
    while frontier:
        for callee in called_workflows(workflows[frontier.pop()]):
            if callee in workflows and callee not in reached and "workflow_call" in triggers(workflows[callee]):
                reached.add(callee)
                frontier.append(callee)
    if table is None:
        table = table_runs(workflows, reached)
    if table:
        reached |= {name for name, doc in workflows.items()
                    if (commands := run_commands(doc)) and all(c in table for c in commands)}
    return {
        name
        for name, doc in workflows.items()
        if name not in reached
        and "push" in triggers(doc)
        and branch_matches(triggers(doc)["push"], base, push=True)
    }


def load_workflows() -> dict[str, dict]:
    return {
        path.name: yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for path in sorted(WORKFLOWS.glob("*.y*ml"))
    }


def load_list() -> dict:
    return json.loads(LIST.read_text(encoding="utf-8"))


class PostMergeOnlyMatcherTest(unittest.TestCase):
    def test_branch_filters(self) -> None:
        self.assertTrue(branch_matches({"branches": ["main", BASE]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["main"]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["feat-cmux-next-*"]}, BASE, push=True))
        self.assertTrue(branch_matches({"branches-ignore": ["main"]}, BASE, push=False))
        self.assertTrue(branch_matches(None, BASE, push=False))
        self.assertTrue(branch_matches({"paths": ["x/**"]}, BASE, push=False))
        self.assertFalse(branch_matches({"tags": ["v*"]}, BASE, push=True))
        self.assertFalse(branch_matches({"branches": ["**", "!feat-cmux-next"]}, BASE, push=True))

    def test_post_merge_only(self) -> None:
        push = {"push": {"branches": [BASE]}}
        both = {"on": {**push, "pull_request": {"paths": ["a/**"]}}}
        other_base = {"on": {**push, "pull_request": {"branches": ["main"]}}}
        target = {"on": {**push, "pull_request_target": None}}
        reusable = {"on": {**push, "workflow_call": None}}
        nested = {"on": {**push, "workflow_call": None}}
        not_callable = {"on": push}
        caller = {"on": "pull_request", "jobs": {"a": {"uses": "./.github/workflows/reusable.yml"}}}
        reusable["jobs"] = {"b": {"uses": "./.github/workflows/nested.yml"}, "c": {"uses": "./.github/workflows/plain.yml"}}
        found = post_merge_only({
            "only.yml": {"on": push},
            "main.yml": {"on": {"push": {"branches": ["main"]}}},
            "both.yml": both,
            "other.yml": other_base,
            "target.yml": target,
            "reusable.yml": reusable,
            "nested.yml": nested,
            "plain.yml": not_callable,
            "caller.yml": caller,
            "dispatch.yml": {"on": "workflow_dispatch"},
        }, table="")
        self.assertEqual(found, {"only.yml", "other.yml", "plain.yml"})

    def test_a_workflow_the_step_table_runs_on_the_pull_request(self) -> None:
        push = {"push": {"branches": [BASE]}}
        steps = {"steps": [{"run": "# checks\npython3 a.py\n"}, {"run": "./b.sh"}]}
        workflows = {"moved.yml": {"on": push, "jobs": {"j": steps}},
                     "partly.yml": {"on": push, "jobs": {"j": {"steps": [{"run": "python3 a.py"}, {"run": "c.sh"}]}}},
                     "empty.yml": {"on": push, "jobs": {"j": {"steps": [{"uses": "x"}]}}}}
        self.assertEqual(post_merge_only(workflows, table="rc=0\npython3 a.py || rc=1\n./b.sh --pr || rc=1"),
                         {"partly.yml", "empty.yml"})
        self.assertEqual(post_merge_only(workflows, table=""), set(workflows))


# Workflows whose pull-request leg moved into steps of ci/steps.toml in other words (a runner picker, caches and
# uploads stayed behind), so no command matches line for line: the workflow keeps the push, and these steps run
# its checks on a pull request (CI v2 step 11).
FOLDED: dict[str, tuple[str, ...]] = {
    # The push run restores the pinned Bun from the CI cache bucket first (toolchain-r2.sh, #53053).
    "app-platform.yml": ("app-platform",),
    "cmux-next-ios-kit.yml": ("ios-kit",),
}
# ios-reliability-matrix.yml has no push left (its phone and protocol cells run in the post-merge batch, suites
# pr-pipeline-ios and pr-pipeline-linux); cmux-next-ios-kit.yml's push names only its own file (registration).


def folded(workflows: dict[str, dict]) -> set[str]:
    """The FOLDED workflows whose steps are in the table, in a job a pull request's pipeline runs."""
    sys.path.insert(0, str(ROOT / "scripts" / "ci"))
    import ci_steps  # noqa: PLC0415

    steps = ci_steps.load().steps
    jobs = {m.group("job") for doc in workflows.values() for line in run_commands(doc)
            for m in TABLE_JOB_RUN.finditer(line)}
    return {name for name, wanted in FOLDED.items() if all(s in steps and steps[s].job in jobs for s in wanted)}


class PostMergeChecksListTest(unittest.TestCase):
    def setUp(self) -> None:
        workflows = load_workflows()
        self.found = post_merge_only(workflows) - folded(workflows)
        self.listed = load_list()
        self.entries = self.listed["workflows"]

    def test_each_folded_workflow_still_runs_on_the_push(self) -> None:
        workflows = load_workflows()
        self.assertEqual(folded(workflows), set(FOLDED), "a folded step is gone or left the pipeline's jobs")
        for name in FOLDED:
            with self.subTest(workflow=name):
                self.assertIn(name, post_merge_only(workflows), "it runs on a pull request again: drop it from FOLDED")

    def test_every_post_merge_only_workflow_is_listed(self) -> None:
        for name in sorted(self.found - set(self.entries)):
            with self.subTest(workflow=name):
                self.fail(
                    f"{name} runs on a push to {BASE} and on no pull request into it, so it can "
                    "only go red after the merge. Give it a pull_request trigger (path-filtered "
                    "is fine) or call it from a workflow pull requests start. Only a deploy, a "
                    f"publish or a bot belongs in {LIST.relative_to(ROOT)}, as kind `publish`."
                )

    def test_the_list_only_shrinks(self) -> None:
        for name in sorted(set(self.entries) - self.found):
            with self.subTest(workflow=name):
                self.fail(
                    f"{name} is gone, no longer starts on a push to {BASE}, or now runs on pull "
                    f"requests: drop it from {LIST.relative_to(ROOT)}."
                )

    def test_entries_say_what_they_are(self) -> None:
        for name, entry in self.entries.items():
            with self.subTest(workflow=name):
                self.assertIn(entry.get("kind"), KINDS)
                self.assertGreaterEqual(len(entry.get("why", "").split()), 4, "say why in a few words")


class CloudProbeRequestRoutingTest(unittest.TestCase):
    """Dry-run the dispatcher shell without credentials, network or cloud machines."""

    def test_dispatch_and_multi_commit_push_routes(self) -> None:
        workflow = yaml.safe_load((WORKFLOWS / "cloud-probes.yml").read_text())
        route = next(step["run"] for step in workflow["jobs"]["probes"]["steps"]
                     if step.get("id") == "route")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args: str) -> str:
                return subprocess.check_output(["git", *args], cwd=root, text=True).strip()
            git("init", "-q")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "test")
            git("config", "commit.gpgsign", "false")
            git("config", "core.hooksPath", "/dev/null")
            git("commit", "--allow-empty", "-qm", "base")
            base = git("rev-parse", "HEAD")
            request = root / ".github/cloud-machine-count-probe/request"
            request.parent.mkdir(parents=True)
            request.write_text("count requested")
            git("add", ".")
            git("commit", "-qm", "count request")
            count = git("rev-parse", "HEAD")
            request = root / ".github/cloud-surge-proof/request"
            request.parent.mkdir(parents=True)
            request.write_text("surge requested")
            git("add", ".")
            git("commit", "-qm", "surge request")
            both = git("rev-parse", "HEAD")
            cases = [
                ("workflow_dispatch", "machine-count", base, both, "true", "false"),
                ("workflow_dispatch", "surge", base, both, "false", "true"),
                ("push", "", base, count, "true", "false"),
                ("push", "", count, both, "false", "true"),
                ("push", "", base, both, "true", "true"),
                ("push", "", both, both, "false", "false"),
            ]
            output = root / "outputs"
            for event, operation, before, head, want_count, want_surge in cases:
                with self.subTest(event=event, operation=operation, before=before, head=head):
                    output.write_text("")
                    env = dict(os.environ, EVENT_NAME=event, OPERATION=operation, BEFORE=before,
                               GITHUB_SHA=head, GITHUB_OUTPUT=str(output), GH_TOKEN="")
                    env.pop("BASH_ENV", None)
                    subprocess.run(["bash", "-c", route], cwd=root, env=env, check=True)
                    self.assertEqual(output.read_text(), f"count={want_count}\nsurge={want_surge}\n")
            env["EVENT_NAME"], env["OPERATION"] = "workflow_dispatch", "typo"
            result = subprocess.run(["bash", "-c", route], cwd=root, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            env["EVENT_NAME"], env["BEFORE"] = "push", "0" * 40
            result = subprocess.run(["bash", "-c", route], cwd=root, env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"dispatch one explicit probe", result.stderr)


if __name__ == "__main__":
    unittest.main()
