#!/usr/bin/env python3
"""Every workflow that a push or a pull request starts declares a concurrency group that can hold its runs back.

A push to feat-cmux-next or main lands about once a minute here, and a PR head moves as often as its lane pushes. A workflow with no
`concurrency:` starts one run per push and per PR event and keeps all of them, so its superseded runs sit beside the
newest on one runner pool and one App quota. NOW's ci-parallel detector (leo-workspace tools/ci_trace.py
detect_parallel, more than 4 runs of one workflow live on one branch) paged for this all day on 2026-11-25 (lane
ci-parallel-2200). The usual group is `${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}`
with `cancel-in-progress: true`: one run per PR or branch, the newest wins. A workflow whose every push must be judged
(a release, a seed) keys its push runs on the sha and does not cancel them; that is a
group too.

Checked: a workflow triggered by `push` to a shared branch (no branch filter, a glob, main or feat-cmux-next),
`pull_request` or `pull_request_target` has a workflow-level `concurrency:`, or one on at least one job. A
group keyed only on `github.run_id` is unique per run and holds nothing, so it does not count. Dispatch-, schedule-,
issue- and workflow_run-only workflows are out of scope: each of their runs is its own target (a dispatch's
run-name names its target: cmux-next-hot-verify.yml's names the PR and head), and the detector reads them that way.

ALLOW lists a workflow that knowingly runs without a group, with why. Keep it empty: add the group instead.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml


class _Loader(yaml.SafeLoader):
    """Leaves `on`, `yes`, `no` and `off` as the strings Actions reads, not booleans."""


_Loader.yaml_implicit_resolvers = {
    first: [(tag, pat) for tag, pat in resolvers if not (first in "yYnNoO" and tag == "tag:yaml.org,2002:bool")]
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
}


def load_workflow(path: Path):
    return yaml.load(path.read_text(encoding="utf-8"), Loader=_Loader)

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
TRIGGERS = ("push", "pull_request", "pull_request_target")
RUN_ID_ONLY = re.compile(r"^[^$]*\$\{\{\s*github\.run_id\s*\}\}[^$]*$")
ALLOW: dict[str, str] = {}


SHARED = ("main", "feat-cmux-next")


def triggers(doc: dict) -> set[str]:
    """The workflow's events, with a push counted only when it can fire on a shared branch: no branch filter, a glob,
    or main or feat-cmux-next named (a smoke test on its own lane/ branch has one pusher)."""
    on = doc.get("on", doc.get(True))
    if isinstance(on, str):
        return {on}
    if isinstance(on, list):
        return {str(x) for x in on}
    out = {str(k) for k in (on or {})}
    push = (on or {}).get("push")
    branches = push.get("branches") if isinstance(push, dict) else None
    if "push" in out and isinstance(push, dict) and push.get("tags") and branches is None:
        out.discard("push")  # a tag-only push: a release, not a landing
    elif "push" in out and branches is not None and not any(b in SHARED or "*" in str(b) for b in branches):
        out.discard("push")
    return out


def holds(conc: object) -> bool:
    """Whether a concurrency value can hold a run back: any group not keyed only on the run id."""
    group = conc.get("group") if isinstance(conc, dict) else conc
    return bool(group) and not RUN_ID_ONLY.match(str(group).strip())


def findings(workflows: Path, allow: dict[str, str]) -> list[str]:
    out = []
    for path in sorted([*workflows.glob("*.yml"), *workflows.glob("*.yaml")]):
        doc = load_workflow(path)
        if not isinstance(doc, dict):
            continue
        hit = sorted(triggers(doc) & set(TRIGGERS))
        if not hit or path.name in allow:
            continue
        if holds(doc.get("concurrency")):
            continue
        jobs = [j for j in (doc.get("jobs") or {}).values() if isinstance(j, dict)]
        # cmux's release, repin, autofix and seed flows group their jobs, not the run, on purpose (a publish never
        # cancels; a cheap plan job runs free): a job-level group is a decision, so it counts.
        if any(holds(j.get("concurrency")) for j in jobs):
            continue
        out.append(f"{path.name}: runs on {', '.join(hit)} with no concurrency group: add\n"
                   "  concurrency:\n"
                   "    group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}\n"
                   "    cancel-in-progress: true")
    names = {p.name for p in workflows.iterdir()}
    out += [f"{name}: listed in ALLOW but no such workflow" for name in allow if name not in names]
    return out


class WorkflowConcurrency(unittest.TestCase):
    def test_every_push_and_pr_workflow_has_a_group(self) -> None:
        self.assertTrue(list(WORKFLOWS.glob("*.yml")), "no workflow files found, so nothing is checked")
        self.assertEqual(findings(WORKFLOWS, ALLOW), [], "\n".join(findings(WORKFLOWS, ALLOW)))

    def test_every_allowed_workflow_says_why(self) -> None:
        for name, why in ALLOW.items():
            with self.subTest(workflow=name):
                self.assertGreater(len(why.split()), 5, "an allowed workflow names why it runs without a group")

    def test_the_check_catches_a_missing_and_a_run_id_group(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "none.yml").write_text("on:\n  push:\n    branches: [main]\njobs:\n  a:\n    runs-on: x\n")
            (d / "runid.yml").write_text("on: pull_request\nconcurrency:\n  group: x-${{ github.run_id }}\n"
                                         "jobs:\n  a:\n    runs-on: x\n")
            (d / "ok.yml").write_text("on: [push, pull_request]\nconcurrency:\n"
                                      "  group: ${{ github.workflow }}-${{ github.ref }}\n"
                                      "  cancel-in-progress: true\njobs:\n  a:\n    runs-on: x\n")
            (d / "jobs.yml").write_text("on: pull_request_target\njobs:\n  a:\n    runs-on: x\n"
                                        "    concurrency: a-${{ github.ref }}\n")
            (d / "partial.yml").write_text("on: push\njobs:\n  a:\n    runs-on: x\n    concurrency: a\n"
                                           "  b:\n    runs-on: x\n")
            (d / "jobid.yml").write_text("on: push\njobs:\n  a:\n    runs-on: x\n"
                                         "    concurrency: a-${{ github.run_id }}\n")
            (d / "lane.yml").write_text("on:\n  push:\n    branches: [lane/x]\njobs:\n  a:\n    runs-on: x\n")
            (d / "dispatch.yml").write_text("on:\n  workflow_dispatch:\n  issues:\njobs:\n  a:\n    runs-on: x\n")
            found = findings(d, {"gone.yml": "stale entry"})
        self.assertEqual([f.split(":")[0] for f in found], ["jobid.yml", "none.yml", "runid.yml", "gone.yml"], found)


if __name__ == "__main__":
    unittest.main(verbosity=2)
