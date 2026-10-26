#!/usr/bin/env python3
"""No workflow step polls the GitHub API with the workflow's own GITHUB_TOKEN.

Every workflow in the repository shares one GITHUB_TOKEN budget an hour. A step
that sleeps in a loop and calls the API on each pass (a waiter, a coalescer)
spends that budget for as long as it waits: on 2026-10-25 a nightly-next tick
coalescer that listed runs every 15 s, among others, used it up, and every NEXT
nightly's legacy publish then failed with "API rate limit exceeded for
installation" (runs 40234225207 and 40240049419).

A step polls when one loop in its script (shell for/while/until, a JavaScript
for/while, a Python for/while) both sleeps and calls the API (gh, curl to
api.github.com, github-script's `github.`, urllib), counting the bodies of the
script's own functions the loop calls, and the token it calls with is
github.token. That token is the GH_TOKEN the step sees (the step's own env
first, then the job's, then the workflow's), since gh prefers it; only with no
GH_TOKEN anywhere, GITHUB_TOKEN. Either counts when it comes from
`github.token` or `secrets.GITHUB_TOKEN`; an actions/github-script step counts
with no `github-token:` of another kind. Wait with a job-level `concurrency`
group, a `workflow_run` trigger, or another token (an App token has its own
budget) instead. A loop that only retries a failed call a few times is flagged
too: allowlist it below with a reason. Not caught: a sleep or call inside a
separate script file the loop runs.

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


def scope_value(name: str, step: dict, job: dict, workflow: dict) -> str | None:
    """The innermost value of an env name the step sees (step, then job, then workflow), or None."""
    for scope in (step.get("env") or {}, job.get("env") or {}, workflow.get("env") or {}):
        if name in scope:
            return str(scope[name])
    return None


def calls_with_own_token(step: dict, job: dict, workflow: dict) -> bool:
    """Whether the token gh calls with is github.token: GH_TOKEN wins over GITHUB_TOKEN wherever it
    is set (gh's own precedence), and the innermost scope that sets a name wins, so a step's App
    token overrides a job's github.token."""
    gh_token = scope_value("GH_TOKEN", step, job, workflow)
    token = gh_token if gh_token is not None else scope_value("GITHUB_TOKEN", step, job, workflow)
    return bool(token and OWN_TOKEN.search(token))


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


SHELL_FUNCTION = re.compile(r"(?m)^([ \t]*)(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\(\)[ \t]*\{")
PY_FUNCTION = re.compile(r"(?m)^([ \t]*)(?:async[ \t]+)?def[ \t]+([A-Za-z_]\w*)[ \t]*\(")
JS_FUNCTION = re.compile(r"(?m)^([ \t]*)(?:async[ \t]+)?function[ \t]*\*?[ \t]*([A-Za-z_$][\w$]*)[ \t]*\("
                         r"|^([ \t]*)(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?"
                         r"(?:\([^)]*\)|[A-Za-z_$][\w$]*)[ \t]*=>")


def functions(script: str) -> dict[str, str]:
    """The script's own functions (shell, Python, JavaScript), name to body: the definition line and
    every later line indented deeper than it (a closing brace at its depth ends the body). A
    one-line definition is just that line."""
    lines = script.splitlines()
    found: dict[str, str] = {}
    for pattern in (SHELL_FUNCTION, PY_FUNCTION, JS_FUNCTION):
        for match in pattern.finditer(script):
            groups = match.groups()
            indent, name = (groups[0], groups[1]) if groups[1] else (groups[2], groups[3])
            start = script.count("\n", 0, match.start())
            body = [lines[start]]
            for follow in lines[start + 1: start + 200]:
                if follow.strip() and len(follow) - len(follow.lstrip()) <= len(indent or ""):
                    if follow.strip().startswith(("}", ")")):
                        body.append(follow)
                    break
                body.append(follow)
            found[name] = "\n".join(body)
    return found


def expanded(body: str, helpers: dict[str, str], seen: frozenset[str] = frozenset()) -> str:
    """A loop body with the bodies of the script's functions it calls appended, transitively."""
    out = [body]
    for name, text in helpers.items():
        if name not in seen and re.search(rf"(?<![\w$-]){re.escape(name)}(?![\w$-])", body):
            out.append(expanded(text, helpers, seen | {name}))
    return "\n".join(out)


def polls(script: str) -> str | None:
    """The first line of a loop that both sleeps and calls the API, counting the script's own
    functions it calls; else None."""
    helpers = functions(script)
    for body in shell_loop_bodies(script) + block_loop_bodies(script):
        whole = expanded(body, helpers)
        if SLEEP.search(whole) and API.search(whole):
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
        # An API call outside the sleeping loop is not polling.
        self.assertIsNone(polls("gh api rate_limit\nfor i in 1 2 3; do\n  sleep 5\ndone\n"))
        # A sleep and a call hidden in the script's own shell function are.
        helper = ('state() {\n  gh run view "$1" --json status\n}\n'
                  "for _ in 1 2 3; do\n  state 42 | grep -q completed && break\n  sleep 15\ndone\n")
        self.assertTrue(polls(helper))
        nap = "nap() {\n  sleep 15\n}\nwhile true; do\n  gh api repos/o/r/actions/runs\n  nap\ndone\n"
        self.assertTrue(polls(nap))
        py = ("import time\ndef runs():\n    return gh_json('api', 'x')\n\n"
              "for _ in range(10):\n    runs()\n    time.sleep(5)\n")
        self.assertTrue(polls(py))

    def test_the_innermost_token_wins(self) -> None:
        job = {"env": {"GH_TOKEN": "${{ github.token }}"}}
        self.assertTrue(calls_with_own_token({}, job, {}))
        self.assertFalse(calls_with_own_token({"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}, job, {}))
        self.assertTrue(calls_with_own_token({"env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}, {}, {}))
        # gh prefers GH_TOKEN: an App GH_TOKEN beside an inherited GITHUB_TOKEN is the App's budget,
        # and a github.token GH_TOKEN beside an App GITHUB_TOKEN is the shared one.
        workflow = {"env": {"GITHUB_TOKEN": "${{ secrets.GITHUB_TOKEN }}"}}
        self.assertFalse(calls_with_own_token({"env": {"GH_TOKEN": "${{ steps.app.outputs.token }}"}}, {}, workflow))
        self.assertTrue(calls_with_own_token({"env": {"GH_TOKEN": "${{ github.token }}",
                                                      "GITHUB_TOKEN": "${{ steps.app.outputs.token }}"}}, {}, {}))


if __name__ == "__main__":
    unittest.main()
