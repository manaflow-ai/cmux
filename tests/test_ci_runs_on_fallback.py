#!/usr/bin/env python3
"""No job waits on one reserved machine, and no compile route evicts another's run.

Leo's rule (2026-10-24): every reservation, a label only one host serves, has a
fallback within minutes, and "a CI test fails on a runs-on that can resolve to a
single-host label with no fallback". Until this file, the only such check was
tests/test_ci_nightly_off_blacksmith.py, and it reads nightly workflows only, so a
single-host label anywhere else (a PR compile, a side lane) went unchecked.

This guard covers every workflow:
- a runs-on never names one machine literally (a glaeda-runner-* label, a mini's
  host name);
- a runs-on that reads a single-host variable (vars.*_TRUSTED_RUNNER) always has a
  later `||` alternative, so an unset or retired host falls through to a pool;
- a compile or fallback job's concurrency group never evicts another head's run.
  GitHub keeps one pending run per group and cancels the older pending one when a
  newer run queues, whatever cancel-in-progress says. So a group shared by
  unrelated heads cancels a fallback compile before it gets a runner: on
  2026-10-26 the private shadow Release compile's single group cancelled about
  forty dispatches in 13 minutes, nx-chat's two fallback compiles among them,
  each with 0 jobs. The group must be keyed per pull request, commit, run or
  branch ref. cancel-in-progress is allowed only where the key is the pull
  request or the ref, where the cancelled run is a superseded head.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

# One machine: a per-runner glaeda label, or a mini or perf host's name.
SINGLE_HOST = re.compile(
    r"\b(?:glaeda-runner-[a-z0-9][a-z0-9-]*|cmux\d+s?(?:-perf)?|cmuxs-mac-mini-\d+|cmux-austin-mini-\d+"
    r"|cmux-lawrence)\b",
    re.IGNORECASE,
)
# A repository variable naming one trusted runner (vars.CI_NIGHTLY_TRUSTED_RUNNER and the like).
SINGLE_HOST_VAR = re.compile(r"\bvars\.([A-Z0-9_]*TRUSTED_RUNNER)\b")
# A job that compiles, or is a fallback route for one.
COMPILE_OR_FALLBACK = re.compile(r"compile|fallback", re.IGNORECASE)
# Keys that scope a group to one pull request, commit, run or branch.
HEAD_KEYS = ("github.run_id", "github.sha", "head_sha", "head.sha", "inputs.sha", "pull_request.number",
             "github.event.number", "inputs.pr", "github.head_ref", "github.ref")
# Keys under which a cancel only ever hits a superseded head of the same pull request or branch.
SUPERSEDE_KEYS = ("pull_request.number", "github.event.number", "inputs.pr", "github.head_ref", "github.ref")

# Groups shared across heads on purpose, each with why no fallback compile waits in it.
SHARED_GROUP_ALLOWED = {
    # Branch-tip only (push to feat-cmux-next, or a dispatch): each run compiles the change since
    # the last verified commit, so a newer tip that evicts a pending one covers its commits too.
    ("cmux-next-tip-test-compile.yml", "cmux-next-tip-test-compile"),
}


def workflows() -> list[Path]:
    return sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")])


def load(path: Path) -> dict:
    # BaseLoader keeps `on:` a string key and every scalar a string, as GitHub reads them.
    return yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}


def runs_on_text(job: dict) -> str:
    value = job.get("runs-on")
    if isinstance(value, dict):
        value = [value.get("group", ""), *(value.get("labels") or [])]
    if isinstance(value, list):
        return " ".join(str(item) for item in value)
    return str(value or "")


def group_text(concurrency: object) -> tuple[str, str] | None:
    if not concurrency:
        return None
    if isinstance(concurrency, str):
        return concurrency, "false"
    return str(concurrency.get("group") or ""), str(concurrency.get("cancel-in-progress") or "false").strip()


def evicting(name: str, concurrency: object) -> str | None:
    """Why this concurrency evicts another head's run, or None."""
    found = group_text(concurrency)
    if found is None:
        return None
    group, cancel = found
    if (name, group) in SHARED_GROUP_ALLOWED:
        return None
    if not any(key in group for key in HEAD_KEYS):
        return f"group {group!r} is shared by every head"
    if cancel not in ("false", "") and not any(key in group for key in SUPERSEDE_KEYS):
        return f"group {group!r} cancels in progress without a pull request or ref key"
    return None


class RunsOnFallbackTests(unittest.TestCase):
    def test_workflows_are_found(self) -> None:
        self.assertIn("cmux-next.yml", {path.name for path in workflows()})

    def test_no_runs_on_names_one_machine(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                match = SINGLE_HOST.search(runs_on_text(job))
                if match:
                    failures.append(f"{path.name} {job_id}: {match.group(0)}")
        self.assertEqual(failures, [], "a runs-on must name a pool, never one machine")

    def test_a_single_host_variable_always_has_a_fallback(self) -> None:
        failures = []
        for path in workflows():
            for job_id, job in (load(path).get("jobs") or {}).items():
                text = runs_on_text(job)
                for match in SINGLE_HOST_VAR.finditer(text):
                    if "||" not in text[match.end():]:
                        failures.append(f"{path.name} {job_id}: vars.{match.group(1)} is the last alternative")
        self.assertEqual(failures, [], "a single-host runner variable needs a later `||` pool fallback")

    def test_compile_and_fallback_routes_never_evict_another_head(self) -> None:
        failures = []
        for path in workflows():
            doc = load(path)
            for job_id, job in (doc.get("jobs") or {}).items():
                if not COMPILE_OR_FALLBACK.search(f"{job_id} {job.get('name') or ''}"):
                    continue
                for where, concurrency in (("job", job.get("concurrency")), ("workflow", doc.get("concurrency"))):
                    why = evicting(path.name, concurrency)
                    if why:
                        failures.append(f"{path.name} {job_id} ({where}): {why}")
        self.assertEqual(failures, [], "a compile or fallback route must be keyed per head")

    def test_the_rules_catch_what_they_are_for(self) -> None:
        # 2026-10-26: the shadow Release compile's one dispatch group.
        self.assertIsNotNone(evicting("x.yml", {"group": "${{ github.event_name == 'workflow_dispatch' && "
                                                         "'shadow-release-compile' || 'pick' }}",
                                                "cancel-in-progress": "false"}))
        self.assertIsNotNone(evicting("x.yml", {"group": "compile-${{ github.run_id }}",
                                                "cancel-in-progress": "true"}))
        self.assertIsNone(evicting("x.yml", {"group": "compile-${{ github.event.pull_request.number }}",
                                             "cancel-in-progress": "true"}))
        self.assertIsNone(evicting("x.yml", {"group": "fallback-${{ inputs.pr }}-${{ inputs.sha }}",
                                             "cancel-in-progress": "false"}))
        self.assertTrue(SINGLE_HOST.search("glaeda-runner-cmux15"))
        self.assertTrue(SINGLE_HOST.search("runs-on: cmux22"))
        self.assertFalse(SINGLE_HOST.search("glaeda-side-std-xcode-26.6"))
        self.assertFalse(SINGLE_HOST.search("blacksmith-6vcpu-macos-26"))


if __name__ == "__main__":
    unittest.main()
