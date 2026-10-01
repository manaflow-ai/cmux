#!/usr/bin/env python3
"""update-homebrew.yml must not let a triggering run's metadata run code.

The job holds the Homebrew tap token. `workflow_run` matches the source
workflow by display name, and `github.event.workflow_run.head_branch` comes
from whoever pushed the run's branch, so its value is attacker data. GitHub
substitutes `${{ ... }}` into a `run:` script as text before the shell parses
it: a branch named `$(touch${IFS}pwned)` used to run as a command. Values must
reach the script through `env:`, and the gate must accept only the real
release workflow run from a tag push in this repository.

This test renders each step the way the runner does (expressions substituted
into `run:` and `env:`), runs the version step with a hostile branch name, and
checks that nothing executed.
"""

import os
import re
import subprocess
import sys
import tempfile

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOMEBREW = os.path.join(ROOT, ".github", "workflows", "update-homebrew.yml")
FAILURES = []


def _check(cond, msg):
    if not cond:
        FAILURES.append(msg)
        print(f"FAIL: {msg}")
    else:
        print(f"ok: {msg}")


def render(text, context):
    """Substitute `${{ expr }}` like the runner: known paths get their value,
    anything else becomes empty."""
    return re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", lambda m: context.get(m.group(1).strip(), ""), str(text))


def main():
    workflow = yaml.safe_load(open(HOMEBREW, encoding="utf-8"))
    job = workflow["jobs"]["update-cask"]
    step = next(s for s in job["steps"] if s.get("id") == "version")

    with tempfile.TemporaryDirectory() as tmp:
        marker = os.path.join(tmp, "pwned")
        hostile = f"$(touch${{IFS}}{marker})"
        context = {
            "github.event.workflow_run.head_branch": hostile,
            "github.event.inputs.version": "",
            "github.event_name": "workflow_run",
        }
        output = os.path.join(tmp, "output")
        open(output, "w").close()
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "GITHUB_OUTPUT": output}
        for key, value in (step.get("env") or {}).items():
            env[key] = render(value, context)
        script = render(step["run"], context)
        subprocess.run(["bash", "-e", "-c", script], env=env, cwd=tmp, capture_output=True, text=True)
        _check(not os.path.exists(marker), "a hostile head_branch never runs as a command in the version step")
        _check("skip=true" in open(output).read(), "a non-release branch name is skipped, not used as a version")

    for name, job_def in workflow["jobs"].items():
        for s in job_def.get("steps", []):
            run = str(s.get("run", ""))
            for expr in re.findall(r"\$\{\{\s*([^}]+?)\s*\}\}", run):
                _check(
                    not expr.startswith(("github.event.workflow_run", "github.event.inputs")),
                    f"{name}: `{s.get('name')}` does not substitute {expr} into its script",
                )

    gate_if = str(workflow["jobs"]["gate"].get("if", ""))
    for condition in (
        "github.event.workflow_run.path == '.github/workflows/release.yml'",
        "github.event.workflow_run.head_repository.full_name == github.repository",
        "github.event.workflow_run.event == 'push'",
    ):
        _check(condition in gate_if, f"the gate requires {condition}")

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
