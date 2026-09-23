#!/usr/bin/env python3
"""The trusted complexity check must not take Bun configuration from the tree it judges.

Bun loads bunfig.toml (including preload scripts) and .env from its working
directory. The workflow runs on pull_request_target, so a check started inside
the pull request's checkout would run that pull request's code.

The two check steps are compared whole. A list of forbidden shell forms
(`|| true`, `|| ( true )`, `set +e`, ...) can always be extended by one more
form; an exact step cannot be weakened without this test changing with it.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity-trusted.yml"
CANDIDATE_WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity.yml"

# --config takes its value with "=". As a separate argument Bun runs the config
# file as the script, exits 0, and the check never happens.
BUN = 'bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" scripts/check-complexity.mjs'

# Body/title edits do not change source or policy. Base retargets still do.
# Keep ignored events off the required check name and its concurrency group:
# GitHub treats a skipped required job as passing, and a new pending run can
# replace a pending run even when cancel-in-progress is false.
METADATA_ONLY = (
    "github.event_name == 'pull_request_target' && github.event.action == 'edited' && "
    "!github.event.changes.base && (github.event.changes.body || github.event.changes.title)"
)
REQUIRED_CHECK = "Web complexity"
IGNORED_CHECK = "Web complexity metadata (ignored)"
CONTENT_GROUP = (
    "web-complexity-trusted-${{ github.event.pull_request.number || "
    "github.event.merge_group.head_sha || github.ref }}"
)


def validate_metadata_routing(document: dict) -> None:
    """Validate that metadata edits cannot replace required content checks."""
    job = document["jobs"]["complexity"]
    assert job["if"] == "${{ !(" + METADATA_ONLY + ") }}", "metadata edits must not allocate content runners"
    assert job["name"] == (
        "${{ " + METADATA_ONLY + " && '" + IGNORED_CHECK + "' || '" + REQUIRED_CHECK + "' }}"
    ), "ignored metadata must not publish a skipped-success under the required check name"
    assert document["concurrency"]["group"] == (
        CONTENT_GROUP + "${{ " + METADATA_ONLY + " && '-metadata' || '' }}"
    ), "metadata edits must not cancel or replace an in-flight content check"
    assert document["concurrency"]["cancel-in-progress"] is True
    # PyYAML's YAML 1.1 loader treats the Actions `on` key as a boolean.
    events = document.get("on", document.get(True))
    assert events["pull_request_target"]["types"] == [
        "opened", "edited", "reopened", "synchronize", "ready_for_review"
    ], "source changes and base retargets must still validate"
    assert "merge_group" in events and "push" in events



def validate_scope_python(scope_run: str) -> None:
    """Validate the executable Python used to select complexity work."""
    marker = "python3 - <<'PY'\n"
    assert scope_run.count(marker) == 1, "scope step must contain exactly one Python heredoc"
    source = scope_run.split(marker, 1)[1]
    body, terminator, tail = source.rpartition("\nPY")
    assert terminator and not tail.strip(), "scope Python heredoc terminator changed"
    tree = ast.parse(body)

    assignments = {
        target.id: node.value
        for node in tree.body
        if isinstance(node, ast.Assign)
        for target in node.targets
        if isinstance(target, ast.Name)
    }
    assert ast.literal_eval(assignments["policy"]) == {
        b".github/workflows/web-complexity-trusted.yml",
        b"web/.oxlintrc.json",
        b"web/bun.lock",
        b"web/package.json",
        b"web/oxlint-complexity-baseline.txt",
        b"web/scripts/check-complexity.mjs",
    }, "trusted complexity policy inputs changed"
    assert ast.literal_eval(assignments["excluded"]) == (
        b".next/",
        b"coverage/",
        b"db/migrations/",
        b"e2e/",
        b"node_modules/",
        b"out/",
        b"public/",
        b"scripts/",
        b"tests/",
        b"tools/",
    ), "trusted complexity exclusions changed"

    changed = assignments["changed"]
    assert (
        isinstance(changed, ast.Call)
        and isinstance(changed.func, ast.Attribute)
        and changed.func.attr == "split"
        and len(changed.args) == 1
        and isinstance(changed.args[0], ast.Constant)
        and changed.args[0].value == b"\0"
    ), "changed paths must split NUL-delimited git output"
    check_output = changed.func.value
    assert (
        isinstance(check_output, ast.Call)
        and isinstance(check_output.func, ast.Attribute)
        and isinstance(check_output.func.value, ast.Name)
        and check_output.func.value.id == "subprocess"
        and check_output.func.attr == "check_output"
        and len(check_output.args) == 1
        and not check_output.keywords
    ), "changed paths must come directly from subprocess.check_output"
    argv = check_output.args[0]
    assert isinstance(argv, ast.List), "git diff argv must be a literal list"
    actual_argv = [
        ("name", item.id) if isinstance(item, ast.Name)
        else ("const", item.value) if isinstance(item, ast.Constant)
        else ("other", ast.dump(item))
        for item in argv.elts
    ]
    assert actual_argv == [
        ("const", "git"),
        ("const", "-C"),
        ("name", "root"),
        ("const", "diff"),
        ("const", "--no-renames"),
        ("const", "--name-only"),
        ("const", "-z"),
        ("name", "base"),
        ("name", "head"),
        ("const", "--"),
    ], "trusted complexity git diff command changed"

    if_tests = [node.test for node in ast.walk(tree) if isinstance(node, ast.If)]
    assert any(
        isinstance(test, ast.Compare)
        and isinstance(test.left, ast.Name)
        and test.left.id == "path"
        and any(isinstance(op, ast.In) for op in test.ops)
        and any(isinstance(value, ast.Name) and value.id == "policy" for value in test.comparators)
        for test in if_tests
    ), "policy must be used by an executable path filter"
    assert any(
        any(
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "startswith"
            and isinstance(node.func.value, ast.Name)
            and node.func.value.id == "web_path"
            and len(node.args) == 1
            and isinstance(node.args[0], ast.Name)
            and node.args[0].id == "excluded"
            for node in ast.walk(test)
        )
        for test in if_tests
    ), "excluded prefixes must be used by an executable path filter"


EXPECTED_CHECKS = [
    {
        "name": "Check pull-request or merge-group source with trusted policy",
        "if": "github.event_name != 'push' && steps.scope.outputs.run == 'true'",
        "working-directory": "trusted/web",
        "run": (
            "set -euo pipefail\n"
            f"{BUN} \\\n"
            '  --repo-root "$GITHUB_WORKSPACE/candidate" \\\n'
            '  --tool-root "$GITHUB_WORKSPACE/trusted" \\\n'
            '  --base-baseline "$GITHUB_WORKSPACE/trusted/web/oxlint-complexity-baseline.txt" \\\n'
            '  --head "$CANDIDATE_SHA"\n'
        ),
    },
    {
        "name": "Check main push with trusted policy",
        "if": "github.event_name == 'push'",
        "working-directory": "trusted/web",
        "env": {"BEFORE_SHA": "${{ github.event.before }}", "HEAD_SHA": "${{ github.sha }}"},
        "run": (
            "set -euo pipefail\n"
            'if [ -n "${BEFORE_SHA:-}" ] && [ "$BEFORE_SHA" != "0000000000000000000000000000000000000000" ]; then\n'
            f'  {BUN} --base "$BEFORE_SHA" --head "$HEAD_SHA"\n'
            "else\n"
            f"  {BUN}\n"
            "fi\n"
        ),
    },
]


def main() -> int:
    """Validate the trusted web-complexity workflow security contract."""
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    validate_metadata_routing(document)
    job = document["jobs"]["complexity"]

    candidate_text = CANDIDATE_WORKFLOW.read_text(encoding="utf-8")
    pull_request_block = candidate_text.split("  pull_request:\n", 1)[1].split("  push:\n", 1)[0]
    if "    paths:\n      - web/**\n" not in pull_request_block:
        print("FAIL: contributor complexity workflow must only queue for web/** pull-request changes")
        return 1
    if ".github/workflows/web-complexity.yml" in pull_request_block:
        print("FAIL: editing the candidate workflow must not self-queue the candidate complexity job")
        return 1
    if job.get("continue-on-error"):
        print("FAIL: the complexity job must not continue on error")
        return 1
    steps = job["steps"]
    checks = [step for step in steps if "check-complexity.mjs" in str(step.get("run", "")) and "bun " in step["run"]]
    if checks != EXPECTED_CHECKS:
        print(
            "FAIL: the complexity check steps changed. They must run from trusted/web, start Bun with "
            "--no-env-file and the empty --config=, and fail the job when the check fails. "
            "Update EXPECTED_CHECKS in the same reviewed change."
        )
        return 1

    names = [step.get("name") for step in steps]
    scope_index = names.index("Select complexity work before installing Bun")
    setup_index = names.index("Setup Bun")
    if scope_index >= setup_index:
        print("FAIL: PR complexity scope must be decided before Bun setup")
        return 1

    expensive = {
        "Setup Bun",
        "Install trusted web tooling",
        "Create empty trusted Bun config",
    }
    expected_if = "github.event_name == 'push' || steps.scope.outputs.run == 'true'"
    for step in steps:
        if step.get("name") in expensive and step.get("if") != expected_if:
            print(f"FAIL: {step['name']} must be skipped for complexity-irrelevant PRs")
            return 1

    scope = steps[scope_index]
    scope_run = str(scope.get("run", ""))
    try:
        validate_scope_python(scope_run)
    except (AssertionError, KeyError, SyntaxError, ValueError) as error:
        print(f"FAIL: trusted complexity scope contract changed: {error}")
        return 1

    print("PASS: trusted web complexity scopes work before Bun and runs checks from the trusted checkout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
