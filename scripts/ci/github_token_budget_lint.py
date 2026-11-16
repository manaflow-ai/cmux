#!/usr/bin/env python3
"""Warn on workflow steps that call the GitHub API with the repository's GITHUB_TOKEN but have no budget line.

Every workflow in the repository shares one GITHUB_TOKEN REST pool, 1,000 requests an hour; when it runs out,
nightly and publish steps fail with "API rate limit exceeded for installation" (the NEXT nightly's notarization,
2026-11-04, run 41790985234). tests/test_ci_no_github_token_polling.py already refuses new polling loops on that
token; this lists EVERY step that spends it and compares the list with .github/github-token-budget.json, which
gives each one (`workflow file: step name`, the polling guard's key) a short reason and, where known, its calls
per run. A step missing from the file prints a `::warning` annotation asking for a budget line, or for a move to
git (`git ls-remote`, `git fetch --filter=blob:none`), the event payload or an App token. It never fails: exit 0
whatever it finds. A budget line whose step no longer spends the token is printed (not a warning) so the file
can shrink.

A step spends the token when:
- it runs a script (shell `run:`, a Python `shell:`, a heredoc fed to python/node/bun, or a repository script it
  runs, transitively) that calls the API (github_token_polling's detectors: `gh <verb>`, curl to the API URL,
  urlopen and gh helpers in Python, github.rest/graphql/request/paginate in JavaScript), and the token those calls
  can use is github.token: GH_TOKEN/GITHUB_TOKEN as github_token_polling.calls_with_own_token reads them, or any
  other env value the step sees that carries `github.token` / `secrets.GITHUB_TOKEN` (a script reading its own
  BUDGET_TOKEN, say). A `secrets.APP || github.token` fallback counts: the step can spend it.
- it is actions/github-script with no `github-token:` or with the default one, and its script calls the API;
- it uses an action that calls the REST API with its token input left at, or set to, the default
  (API_ACTIONS: actions/download-artifact with `run-id`, actions/attest*, dorny/paths-filter, ...).

Not caught: local composite actions and reusable workflows' internals (scan their own files), setup-* actions'
manifest reads, and everything github_token_polling's docstring lists. A reviewer catches those.

    python3 scripts/ci/github_token_budget_lint.py [--workflows DIR] [--budget FILE]
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from github_token_polling import (  # noqa: E402
    JS_API, OWN_TOKEN, Scripts, api_url_names, api_url_pattern, calls_with_own_token, heredoc_effects, js_code,
    python_aliases, python_effects, python_http_call, script_paths, shell_api, shell_words,
)

API_HELPERS = ("gh_json", "gh_api", "gh_run", "gh_items")

ROOT = Path(__file__).resolve().parents[2]
BUDGET = ROOT / ".github" / "github-token-budget.json"
WORKFLOWS = ROOT / ".github" / "workflows"

# action -> (its token input, its default is github.token, a `with:` key that must be set for it to call the API)
API_ACTIONS: dict[str, tuple[str, bool, str | None]] = {
    "actions/download-artifact": ("github-token", False, "run-id"),
    "actions/attest-build-provenance": ("github-token", True, None),
    "actions/attest": ("github-token", True, None),
    "actions/attest-sbom": ("github-token", True, None),
    "dorny/paths-filter": ("token", True, None),
    "tj-actions/changed-files": ("token", True, None),
    "peter-evans/create-pull-request": ("token", True, None),
    "peter-evans/create-or-update-comment": ("token", True, None),
    "peter-evans/find-comment": ("token", True, None),
    "softprops/action-gh-release": ("token", True, None),
    "actions/labeler": ("repo-token", True, None),
    "actions/stale": ("repo-token", True, None),
    "anthropics/claude-code-action": ("github_token", False, None),
    "manaflow-ai/cla-github-action": ("github-token", False, None),
}


def env_scopes(step: dict, job: dict, workflow: dict) -> tuple[dict, dict, dict]:
    return step.get("env") or {}, job.get("env") or {}, workflow.get("env") or {}


def hands_own_token(step: dict, job: dict, workflow: dict, text: str) -> bool:
    """Whether the step's scripts can call the API with github.token (see the module docstring)."""
    if calls_with_own_token(step, job, workflow, text):
        return True
    seen: set[str] = set()
    for scope in env_scopes(step, job, workflow):
        for name, value in scope.items():
            if name in seen:
                continue  # an inner scope's value hides an outer one
            seen.add(name)
            if name not in ("GH_TOKEN", "GITHUB_TOKEN") and OWN_TOKEN.search(str(value or "")):
                return True
    return False


def python_calls(text: str) -> bool:
    """Whether Python code calls the API, directly or through a callable bound to urlopen or a gh helper
    (`opener=urllib.request.urlopen`): python_effects plus the aliases python_polls follows."""
    if python_effects(text)[0]:
        return True
    try:
        aliases = python_aliases(ast.parse(text))
    except SyntaxError:
        return False
    return any(python_http_call(t) or t.split(".")[-1] in API_HELPERS for ts in aliases.values() for t in ts)


def action_spends(step: dict, job: dict, workflow: dict) -> bool:
    uses = str(step.get("uses") or "")
    name = uses.split("@", 1)[0]
    with_ = step.get("with") or {}
    if name == "actions/github-script":
        token = with_.get("github-token")
        if token is not None and not OWN_TOKEN.search(str(token)):
            return False
        return bool(JS_API.search(js_code(str(with_.get("script", "")))))
    if name not in API_ACTIONS:
        return False
    key, default_own, needs = API_ACTIONS[name]
    if needs and not with_.get(needs):
        return False
    token = with_.get(key)
    if token is None:
        if name == "manaflow-ai/cla-github-action":
            return calls_with_own_token(step, job, workflow, "$GITHUB_TOKEN")
        return default_own
    return bool(OWN_TOKEN.search(str(token)))


def run_spends(step: dict, job: dict, workflow: dict, scripts: Scripts) -> bool:
    script = str(step.get("run", "") or "")
    if not script:
        return False
    shell = str(step.get("shell") or ((job.get("defaults") or {}).get("run") or {}).get("shell")
                or ((workflow.get("defaults") or {}).get("run") or {}).get("shell") or "")
    if shell.startswith("python"):
        calls, runs = python_calls(script), []
    else:
        words = [w.lstrip("\0") if not w.startswith("\0") else w for w, _ in shell_words(script)]
        scopes = env_scopes(step, job, workflow)
        names = api_url_names(script, scopes)
        runs = scripts.closure(script_paths(words))
        calls = (shell_api(words, api_url_pattern(names)) or heredoc_effects(words)[0]
                 or scripts.effects(runs, api_url_names("", scopes))[0]
                 or any(path.endswith(".py") and python_calls(scripts.read(path)[3]) for path in runs))
    if not calls:
        return False
    every_text = script + "".join(scripts.read(path)[3] for path in runs)
    return hands_own_token(step, job, workflow, every_text)


def step_spends(step: dict, job: dict, workflow: dict, scripts: Scripts | None = None) -> bool:
    """Whether the step calls the GitHub API with the repository's GITHUB_TOKEN."""
    if not isinstance(step, dict):
        return False
    if step.get("uses"):
        return action_spends(step, job, workflow)
    return run_spends(step, job, workflow, scripts or Scripts(None))


def spending_steps(workflows: Path) -> list[str]:
    """Every `workflow file: step name` that spends the token, sorted, each once."""
    found: set[str] = set()
    scripts = Scripts(workflows.parent.parent)
    for path in sorted(workflows.glob("*.y*ml")):
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if not isinstance(workflow, dict):
            continue
        for job in (workflow.get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            for index, step in enumerate(job.get("steps") or []):
                if step_spends(step, job, workflow, scripts):
                    found.add(f"{path.name}: {step.get('name') or f'step {index + 1}'}")
    return sorted(found)


def load_budget(path: Path) -> dict[str, str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    steps = data.get("steps") if isinstance(data, dict) else None
    if not isinstance(steps, dict):
        raise ValueError(f"{path}: no \"steps\" object")
    return {str(k): str(v) for k, v in steps.items()}


def compare(found: list[str], budget: dict[str, str]) -> tuple[list[str], list[str]]:
    """(steps that spend the token with no budget line, budget lines whose step no longer spends it)."""
    return [s for s in found if s not in budget], sorted(k for k in budget if k not in set(found))


def escape(text: str) -> str:
    """A workflow command's message data: %, CR and LF escaped."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def warning(step: str, budget_file: str) -> str:
    workflow = step.split(": ", 1)[0]
    text = (f"{step} calls the GitHub API with the repository GITHUB_TOKEN (1,000 requests an hour shared by "
            f"every workflow) and has no line in {budget_file}. Add one with a reason and its calls per run, "
            "or read it from git, the event payload or an App token instead.")
    return f"::warning file=.github/workflows/{workflow},title=GITHUB_TOKEN budget::{escape(text)}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--workflows", type=Path, default=WORKFLOWS)
    parser.add_argument("--budget", type=Path, default=BUDGET)
    args = parser.parse_args(argv)
    try:
        budget = load_budget(args.budget)
        found = spending_steps(args.workflows)
    except Exception as error:  # noqa: BLE001 - warn-only: a broken lint never fails the job
        print(f"::warning title=GITHUB_TOKEN budget::{escape(f'the budget lint could not run: {str(error)[:200]}')}")
        return 0
    try:
        shown = args.budget.resolve().relative_to(ROOT).as_posix()
    except ValueError:
        shown = str(args.budget)
    missing, stale = compare(found, budget)
    print(f"GITHUB_TOKEN budget: {len(found)} steps spend the repository token, {len(found) - len(missing)} "
          f"budgeted, {len(missing)} not, in {shown}.")
    for step in missing:
        print(warning(step, shown))
    for step in stale:
        print(f"no longer spends the token (drop its line from {shown}): {step}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
