"""No workflow step polls the GitHub API with the workflow's own GITHUB_TOKEN.

Every workflow in the repository shares one GITHUB_TOKEN budget an hour. A step
that sleeps in a loop and calls the API on each pass (a waiter, a coalescer)
spends that budget for as long as it waits: on 2026-10-25 a nightly-next tick
coalescer that listed runs every 15 s, among others, used it up, and every NEXT
nightly's legacy publish then failed with "API rate limit exceeded for
installation" (runs 40234225207 and 40240049419).

A step polls when its script has a loop (shell for/while/until, a JavaScript
for/while, a Python for/while) with a sleep inside it, and the step calls the
API (gh, curl to api.github.com, github-script's `github.`, urllib) with
github.token: GH_TOKEN/GITHUB_TOKEN set from `github.token` or
`secrets.GITHUB_TOKEN`, or actions/github-script with no `github-token:`.
Wait with a job-level `concurrency` group, a `workflow_run` trigger, or another
token (an App token has its own budget) instead. A loop that only retries a
failed call a few times is flagged too: allowlist it below with a reason.

ALLOWED lists the steps that poll today, as `workflow file: step name`, each with
why it may stay. Shrink it; do not grow it without a reason the review accepts.
"""

from __future__ import annotations

import re
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
    "merge-group-fail-fast.yml: Locate and watch the merge-group CI run":
        "per merge group: finds and watches its CI run (lawrencecchen's #16224 cuts it)",
    "nightly-next-tick.yml: Coalesce tick requests without cancelling work":
        "removed by the nightly-next tick PR (one shared concurrency group instead)",
    "tui-publish-npm.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
    "tui-publish-pypi.yml: Require successful verified artifact run": "a release, by hand: at most 24 reads",
}

OWN_TOKEN = re.compile(r"\$\{\{\s*(github\.token|secrets\.GITHUB_TOKEN)\s*\}\}")
SHELL_LOOP = re.compile(r"(?m)^\s*(for|while|until)\b[^\n]*(;\s*do\b|\n\s*do\b)")
SHELL_DONE = re.compile(r"(?m)^\s*done\b|;\s*done\b")
SLEEP = re.compile(r"\bsleep\s+[\d\"$]|setTimeout\(|time\.sleep\(|\bsleep\(")
API = re.compile(r"\bgh\s+(api|run|pr|issue|release|workflow|label|search|cache)\b|api\.github\.com|\bgithub\.(rest|graphql|request|paginate)\b|urllib\.request|\bgh_json\(")
JS_LOOP = re.compile(r"\b(for|while)\s*\(")
PY_LOOP = re.compile(r"(?m)^\s*(for\s+\w[^\n]*\bin\b[^\n]*|while\s+[^\n]*):\s*$")


def own_token_env(step: dict, job: dict, workflow: dict) -> bool:
    for scope in (workflow.get("env") or {}, job.get("env") or {}, step.get("env") or {}):
        for name in ("GH_TOKEN", "GITHUB_TOKEN"):
            if name in scope and OWN_TOKEN.search(str(scope[name])):
                return True
    return False


def loop_bodies(script: str) -> list[str]:
    """The text of each loop in a script, approximately: a shell loop to its `done`, a
    JavaScript or Python loop to the end of its indented block (or 40 lines)."""
    bodies = []
    for match in SHELL_LOOP.finditer(script):
        end = SHELL_DONE.search(script, match.end())
        bodies.append(script[match.start(): end.end() if end else len(script)])
    lines = script.splitlines()
    for index, line in enumerate(lines):
        if JS_LOOP.search(line) or PY_LOOP.match(line):
            indent = len(line) - len(line.lstrip())
            block = [line]
            for follow in lines[index + 1: index + 41]:
                if follow.strip() and len(follow) - len(follow.lstrip()) <= indent and not follow.strip().startswith(("}", ")")):
                    break
                block.append(follow)
            bodies.append("\n".join(block))
    return bodies


def polling_steps() -> dict[str, str]:
    found = {}
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (workflow.get("jobs") or {}).values():
            for index, step in enumerate(job.get("steps") or []):
                uses = str(step.get("uses", ""))
                with_ = step.get("with") or {}
                if uses.startswith("actions/github-script"):
                    script = str(with_.get("script", ""))
                    token = with_.get("github-token")
                    own = token is None or bool(OWN_TOKEN.search(str(token)))
                else:
                    script = str(step.get("run", ""))
                    own = own_token_env(step, job, workflow)
                if not own or not script:
                    continue
                # The API call may sit in a helper the loop calls (the old tick coalescer's
                # activeRuns()), so a sleeping loop in a script that calls the API counts.
                if not API.search(script):
                    continue
                for body in loop_bodies(script):
                    if SLEEP.search(body):
                        found[f"{path.name}: {step.get('name') or f'step {index + 1}'}"] = body.strip().splitlines()[0]
                        break
    return found


def test_no_new_github_token_polling_loop() -> None:
    found = polling_steps()
    new = {key: line for key, line in found.items() if key not in ALLOWED}
    assert not new, (
        "these steps sleep in a loop and call the GitHub API with github.token, which spends the "
        "budget every workflow shares (see this file's docstring for what to do instead):\n"
        + "\n".join(f"  {key}  ({line})" for key, line in sorted(new.items()))
    )


def test_the_allowlist_has_no_stale_entries() -> None:
    stale = sorted(set(ALLOWED) - set(polling_steps()))
    assert not stale, f"no longer polling, remove from ALLOWED: {stale}"


def test_the_scanner_catches_the_old_tick_coalescer() -> None:
    script = """
for (let attempt = 0; attempt < 48; attempt += 1) {
  const { data } = await github.rest.actions.listWorkflowRuns({ owner, repo, workflow_id });
  await sleep(15000);
}
"""
    assert any(SLEEP.search(b) and API.search(b) for b in loop_bodies(script))
    shell = 'until gh run view "$id" --json status | grep -q completed; do\n  sleep 30\ndone\n'
    assert any(SLEEP.search(b) and API.search(b) for b in loop_bodies(shell))
    assert not any(SLEEP.search(b) and API.search(b) for b in loop_bodies("for f in *.txt; do\n  wc -l \"$f\"\ndone\n"))


if __name__ == "__main__":
    for key, line in sorted(polling_steps().items()):
        print(f"{key}  |  {line}")
