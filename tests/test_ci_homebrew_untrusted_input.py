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

import json
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

    # A bare payload and a semver-prefixed one. The prefixed case matters
    # because the version regex is what keeps the one remaining `steps.*`
    # interpolation safe: a regex widened to admit `1.2.3-beta.1` would pass a
    # payload starting with digits straight through, and a bare `$(...)`
    # payload cannot see that.
    for label, shape in (
        ("a hostile head_branch", "$(touch${{IFS}}{marker})"),
        ("a semver-prefixed hostile head_branch", "v1.2.3$(touch${{IFS}}{marker})"),
    ):
        with tempfile.TemporaryDirectory() as tmp:
            marker = os.path.join(tmp, "pwned")
            context = {
                "github.event.workflow_run.head_branch": shape.format(marker=marker),
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
            written = open(output).read()
            _check(not os.path.exists(marker), f"{label} never runs as a command in the version step")
            _check("skip=true" in written, f"{label} is skipped, not used as a version")
            _check("version=" not in written, f"{label} never reaches the version output")

    # The version output is the one value still interpolated into a `run:`
    # body's neighbours, so pin the pattern that constrains it. Anchors and a
    # digits-and-dots-only body are what stop a payload from surviving; a
    # widened pattern must update this assertion and think about it.
    _check(
        r"^[0-9]+\.[0-9]+\.[0-9]+$" in str(step["run"]),
        "the version step pins an anchored semver pattern with no wildcard tail",
    )

    for name, job_def in workflow["jobs"].items():
        for s in job_def.get("steps", []):
            run = str(s.get("run", ""))
            for expr in re.findall(r"\$\{\{\s*([^}]+?)\s*\}\}", run):
                # `steps.version.outputs` is derived from the branch name, so it
                # is attacker data one regex away from arbitrary text. It reaches
                # a script through `env:` like the rest.
                _check(
                    not expr.startswith(
                        ("github.event.workflow_run", "github.event.inputs", "inputs.", "steps.version.outputs")
                    ),
                    f"{name}: `{s.get('name')}` does not substitute {expr} into its script",
                )

    gate_if = str(workflow["jobs"]["gate"].get("if", ""))
    for condition in (
        "github.event.workflow_run.path == '.github/workflows/release.yml'",
        "github.event.workflow_run.head_repository.full_name == github.repository",
    ):
        _check(condition in gate_if, f"the gate requires {condition}")

    # release.yml ships from a tag push and from a manual dispatch, and both
    # need write access. Every other trigger, `pull_request` above all, would
    # let a branch in this repository drive the job that holds the tap token.
    triggers = re.search(
        r"contains\(\s*fromJSON\(\s*'(\[[^']*\])'\s*\)\s*,\s*github\.event\.workflow_run\.event\s*\)",
        gate_if,
    )
    _check(triggers is not None, "the gate allow-lists github.event.workflow_run.event")
    allowed = set(json.loads(triggers.group(1))) if triggers else set()
    _check(
        allowed == {"push", "workflow_dispatch"},
        f"the gate's workflow_run.event allow-list is exactly push and workflow_dispatch (found {sorted(allowed)})",
    )

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)


if __name__ == "__main__":
    main()
