#!/usr/bin/env python3
"""No workflow step polls the GitHub API with the workflow's own GITHUB_TOKEN.

Every workflow in the repository shares one GITHUB_TOKEN budget an hour. A step
that sleeps in a loop and calls the API on each pass (a waiter, a coalescer)
spends that budget for as long as it waits: on 2026-10-25 a nightly-next tick
coalescer that listed runs every 15 s, among others, used it up, and every NEXT
nightly's legacy publish then failed with "API rate limit exceeded for
installation" (runs 40234225207 and 40240049419).

A step polls when its script has a loop (shell for/while/until, a JavaScript
for/while, a Python for/while) with a sleep inside it, the script calls the API
(gh, curl to api.github.com, github-script's `github.`, urllib), and the token
it calls with is github.token: the GH_TOKEN/GITHUB_TOKEN the step sees (the
step's own env first, then the job's, then the workflow's) comes from
`github.token` or `secrets.GITHUB_TOKEN`, or the step is actions/github-script
with no `github-token:` of another kind. Wait with a job-level `concurrency`
group, a `workflow_run` trigger, or another token (an App token has its own
budget) instead. A loop that only retries a failed call a few times is flagged
too: allowlist it below with a reason. Not caught: a sleep inside a shell
function or helper script the loop calls.

ALLOWED lists the steps that poll today, as `workflow file: step name`, each with
why it may stay. Shrink it; do not grow it without a reason the review accepts.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

ALLOWED: dict[str, str] = {
    "ci-macos.yml: Wait for routed Linux preflight":
        "release-admission only (release_build and full_suite): one jobs read every 5 s, up to 210; "
        "should become a `needs:` on linux-preflight",
    "ci-main-full-suite.yml: Dispatch CI on main": "finds the run it just dispatched: at most 30 reads, 3 s apart",
    "cmux-tui-release.yml: Dispatch registry publishers": "a release, by hand: finds the publisher runs it dispatched",
    "coderouter-release.yml: Publish immutable GitHub release": "a release: retries a failed publish 5 times",
    "ios-testflight.yml: Decide whether a TestFlight upload is needed":
        "orders uploads: waits only while an earlier TestFlight run is active, listing runs and jobs "
        "each pass; a candidate for a concurrency group",
    "merge-group-fail-fast.yml: Locate and watch the merge-group CI run":
        "per merge group: finds and watches its CI run (lawrencecchen's #16224 cuts it)",
    "nightly-next-tick.yml: Coalesce tick requests without cancelling work":
        "removed by the nightly-next tick PR (one shared concurrency group instead)",
    "tui-publish-npm.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
    "tui-publish-pypi.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
}

OWN_TOKEN = re.compile(r"\$\{\{\s*(github\.token|secrets\.GITHUB_TOKEN)\s*\}\}")
SHELL_LOOP = re.compile(r"(?m)^[ \t]*(?:[^#\n]*?(?:;|&&|\|\||\bthen|\belse|\{)\s*)?(for|while|until)\b")
DO_DONE = re.compile(r"(?<![\w-])(do|done)(?![\w-])")
SLEEP = re.compile(r"\bsleep\s+[\d\"$]|setTimeout\(|time\.sleep\(|\bsleep\(")
API = re.compile(r"\bgh\s+(api|run|pr|issue|release|workflow|label|search|cache)\b|api\.github\.com"
                 r"|\bgithub\.(rest|graphql|request|paginate)\b|urllib\.request|\bgh_json\(")
JS_LOOP = re.compile(r"\b(for|while)\s*\(")
PY_LOOP = re.compile(r"(?m)^\s*(for\s+\w[^\n]*\bin\b[^\n]*|while\s+[^\n]*):\s*$")


def calls_with_own_token(step: dict, job: dict, workflow: dict) -> bool:
    """Whether the GH_TOKEN or GITHUB_TOKEN the step sees is github.token: the innermost scope that
    sets a name wins, so a step's App token overrides a job's github.token."""
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        for scope in (step.get("env") or {}, job.get("env") or {}, workflow.get("env") or {}):
            if name in scope:
                if OWN_TOKEN.search(str(scope[name])):
                    return True
                break
    return False


def shell_loop_bodies(script: str) -> list[str]:
    """Each shell loop from its keyword to its matching `done`, nested loops counted."""
    bodies = []
    for match in SHELL_LOOP.finditer(script):
        depth, end = 0, len(script)
        for word in DO_DONE.finditer(script, match.end()):
            depth += 1 if word.group(1) == "do" else -1
            if depth <= 0:
                end = word.end()
                break
        bodies.append(script[match.start(1): end])
    return bodies


def block_loop_bodies(script: str) -> list[str]:
    """Each JavaScript or Python loop to the end of its indented block (at most 60 lines)."""
    bodies = []
    lines = script.splitlines()
    for index, line in enumerate(lines):
        if JS_LOOP.search(line) or PY_LOOP.match(line):
            indent = len(line) - len(line.lstrip())
            block = [line]
            for follow in lines[index + 1: index + 61]:
                if follow.strip() and len(follow) - len(follow.lstrip()) <= indent \
                        and not follow.strip().startswith(("}", ")")):
                    break
                block.append(follow)
            bodies.append("\n".join(block))
    return bodies


def polls(script: str) -> str | None:
    """The first line of a loop that sleeps, in a script that calls the API; else None."""
    if not API.search(script):
        return None
    for body in shell_loop_bodies(script) + block_loop_bodies(script):
        if SLEEP.search(body):
            return body.strip().splitlines()[0]
    return None


def polling_steps() -> dict[str, str]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (workflow.get("jobs") or {}).values():
            for index, step in enumerate(job.get("steps") or []):
                with_ = step.get("with") or {}
                if str(step.get("uses", "")).startswith("actions/github-script"):
                    script = str(with_.get("script", ""))
                    token = with_.get("github-token")
                    own = token is None or bool(OWN_TOKEN.search(str(token)))
                else:
                    script = str(step.get("run", ""))
                    own = calls_with_own_token(step, job, workflow)
                line = polls(script) if own and script else None
                if line:
                    found[f"{path.name}: {step.get('name') or f'step {index + 1}'}"] = line
    return found


class GithubTokenPollingTests(unittest.TestCase):
    def test_no_new_github_token_polling_loop(self) -> None:
        new = {key: line for key, line in polling_steps().items() if key not in ALLOWED}
        self.assertFalse(new, (
            "these steps sleep in a loop and call the GitHub API with github.token, which spends the "
            "budget every workflow shares (see this file's docstring for what to do instead):\n"
            + "\n".join(f"  {key}  ({line})" for key, line in sorted(new.items()))))

    def test_the_allowlist_has_no_stale_entries(self) -> None:
        stale = sorted(set(ALLOWED) - set(polling_steps()))
        self.assertFalse(stale, f"no longer polling, remove from ALLOWED: {stale}")

    def test_the_scanner_catches_polling_loops(self) -> None:
        coalescer = """
const activeRuns = async () => (await github.rest.actions.listWorkflowRuns({ owner, repo, workflow_id })).data;
for (let attempt = 0; attempt < 48; attempt += 1) {
  const runs = await activeRuns();
  await sleep(15000);
}
"""
        self.assertTrue(polls(coalescer))
        self.assertTrue(polls('until gh run view "$id" --json status | grep -q completed; do\n  sleep 30\ndone\n'))
        nested = ("for i in 1 2 3; do\n  for j in a b; do\n    echo $j\n  done\n"
                  "  gh api repos/o/r/actions/runs >/dev/null\n  sleep 10\ndone\n")
        self.assertTrue(polls(nested))
        self.assertTrue(polls("x=1; while true; do gh api rate_limit; sleep 5; done"))
        self.assertIsNone(polls('for f in *.txt; do\n  wc -l "$f"\ndone\ngh api rate_limit\n'))
        self.assertIsNone(polls("for i in 1 2; do sleep 1; done\n"))

    def test_the_innermost_token_wins(self) -> None:
        job = {"env": {"GH_TOKEN": "${{ github.token }}"}}
        self.assertTrue(calls_with_own_token({}, job, {}))
        self.assertFalse(calls_with_own_token({"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}, job, {}))
        self.assertTrue(calls_with_own_token({"env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}, {}, {}))


if __name__ == "__main__":
    unittest.main()
