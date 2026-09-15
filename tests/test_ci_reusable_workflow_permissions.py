#!/usr/bin/env python3
"""Behavioral tests for the reusable-workflow permission guard.

Regression test for https://github.com/manaflow-ai/cmux/issues/12149: release.yml called
ios-screenshots.yml, which declared `actions: write` while the caller granted no `actions`
scope at all. GitHub refused the whole release workflow at parse time (startup_failure), so a
v* tag push could not build. The guard under test reproduces GitHub's rule for every local
`uses: ./.github/workflows/*.yml` call so that shape can never land again.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts" / "ci" / "check_reusable_workflow_permissions.py"
WORKFLOWS_DIR = ROOT / ".github" / "workflows"
CI_WORKFLOW = WORKFLOWS_DIR / "ci.yml"

spec = importlib.util.spec_from_file_location("check_reusable_workflow_permissions", CHECKER)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

# The manaflow-ai/cmux Actions setting "Workflow permissions" is "Read and write" (verified via
# `gh api repos/manaflow-ai/cmux/actions/permissions/workflow` on 2026-09-08). It only matters for
# callers that declare no `permissions` block anywhere; every current caller declares one.
REPOSITORY_DEFAULT_WORKFLOW_PERMISSIONS = "write"

_keepalive: list[tempfile.TemporaryDirectory[str]] = []


def workflows_tree(files: dict[str, str]) -> Path:
    tmp = tempfile.TemporaryDirectory(prefix="cmux-reusable-perms-")
    _keepalive.append(tmp)
    workflows = Path(tmp.name) / ".github" / "workflows"
    workflows.mkdir(parents=True)
    for name, text in files.items():
        (workflows / name).write_text(textwrap.dedent(text), encoding="utf-8")
    return workflows


def run_cli(workflows: Path, *, default: str = "write", verbose: bool = False) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(CHECKER),
        "--workflows-dir",
        str(workflows),
        "--default-workflow-permissions",
        default,
    ]
    if verbose:
        command.append("--verbose")
    return subprocess.run(command, capture_output=True, text=True, check=False)


def check(files: dict[str, str], *, default: str = "write") -> tuple[list, list[str]]:
    return module.check_workflows_dir(workflows_tree(files), default)


def failures_for(files: dict[str, str], *, default: str = "write") -> list[str]:
    return check(files, default=default)[1]


RELEASE_SHAPE_BEFORE_FIX = {
    # release.yml as of main on 2026-09-08 (permissions and the reusable call, verbatim shape).
    "release.yml": """\
        name: Release macOS app

        on:
          push:
            tags:
              - "v*"
          workflow_dispatch:

        permissions:
          contents: write
          attestations: write
          id-token: write

        jobs:
          generate-ios-screenshots:
            name: Generate iOS App Store screenshots
            uses: ./.github/workflows/ios-screenshots.yml
            with:
              ref: ${{ github.ref }}
              languages: "en-US,de-DE,fr-FR,ar-SA,es-ES,zh-Hant,zh-Hans,ko,ja"
              upload: false
            secrets: inherit

          build-sign-notarize:
            needs:
              - generate-ios-screenshots
            runs-on: macos-26
            steps:
              - run: echo build
        """,
    # ios-screenshots.yml as of main on 2026-09-08: the callee asked for a scope the caller lacks.
    "ios-screenshots.yml": """\
        name: iOS App Store screenshots

        on:
          workflow_call:
            inputs:
              ref:
                type: string
                default: ""
          workflow_dispatch:
        permissions:
          contents: read
          actions: write

        jobs:
          screenshots:
            runs-on: macos-26
            steps:
              - uses: actions/checkout@v6
              - run: fastlane screenshots
        """,
}


RELEASE_SHAPE_BEFORE_FIX = {name: textwrap.dedent(text) for name, text in RELEASE_SHAPE_BEFORE_FIX.items()}


def test_issue_12149_release_shape_is_rejected_before_any_job_runs() -> None:
    result = run_cli(workflows_tree(RELEASE_SHAPE_BEFORE_FIX))

    assert result.returncode == 1, result
    assert "PASS" not in result.stdout, result.stdout
    failure = result.stderr
    assert "release.yml: job 'generate-ios-screenshots' uses ./.github/workflows/ios-screenshots.yml" in failure, failure
    assert "requests 'actions: write' (ios-screenshots.yml workflow-level permissions)" in failure, failure
    assert "only allows 'actions: none' (release.yml workflow-level permissions)" in failure, failure
    assert "1 reusable-workflow permission mismatch(es) across 1 local call site(s)" in failure, failure


def test_callee_that_keeps_or_reduces_the_grant_passes() -> None:
    fixed = dict(RELEASE_SHAPE_BEFORE_FIX)
    fixed["ios-screenshots.yml"] = fixed["ios-screenshots.yml"].replace("  actions: write\n", "")

    result = run_cli(workflows_tree(fixed), verbose=True)

    assert result.returncode == 0, result
    assert result.stderr == "", result.stderr
    assert "PASS: every local reusable-workflow call stays within its caller's permissions (1 call site(s) in 1 caller workflow(s))" in result.stdout, result.stdout
    assert "request: contents: read" in result.stdout, result.stdout


def test_callee_job_level_permissions_count_even_when_the_job_is_gated() -> None:
    # Mirrors cmux-tui-build-package.yml: its attest job is optional at runtime, but GitHub still
    # validates the declared job-level ceiling against the caller (see 4b9720dc750).
    callee = """\
        on:
          workflow_call:
        permissions: {}
        jobs:
          build:
            permissions:
              contents: read
            runs-on: ubuntu-latest
            steps:
              - run: echo build
          attest:
            if: ${{ false }}
            permissions:
              contents: read
              id-token: write
              attestations: write
            runs-on: ubuntu-latest
            steps:
              - run: echo attest
        """
    caller_without_ceiling = textwrap.dedent("""\
        on: push
        permissions: {}
        jobs:
          package:
            permissions:
              contents: read
            uses: ./.github/workflows/package.yml
        """)
    failures = failures_for({"caller.yml": caller_without_ceiling, "package.yml": callee})
    assert len(failures) == 2, failures
    assert any("requests 'id-token: write' (package.yml job 'attest' permissions)" in f for f in failures), failures
    assert any("requests 'attestations: write' (package.yml job 'attest' permissions)" in f for f in failures), failures
    assert all("only allows" in f and "(caller.yml job 'package' permissions)" in f for f in failures), failures

    caller_with_ceiling = caller_without_ceiling.replace(
        "      contents: read\n", "      contents: read\n      id-token: write\n      attestations: write\n"
    )
    assert failures_for({"caller.yml": caller_with_ceiling, "package.yml": callee}) == []


def test_caller_job_block_replaces_the_workflow_block_entirely() -> None:
    caller = """\
        on: push
        permissions:
          contents: write
          packages: write
        jobs:
          call:
            permissions:
              contents: read
            uses: ./.github/workflows/callee.yml
        """
    callee = """\
        on:
          workflow_call:
        permissions:
          contents: read
          packages: read
        jobs:
          run:
            runs-on: ubuntu-latest
            steps:
              - run: echo hi
        """
    failures = failures_for({"caller.yml": caller, "callee.yml": callee})

    assert len(failures) == 1, failures
    assert "requests 'packages: read' (callee.yml workflow-level permissions)" in failures[0], failures
    assert "only allows 'packages: none' (caller.yml job 'call' permissions)" in failures[0], failures


def test_callee_without_any_permissions_block_inherits_the_caller() -> None:
    caller = """\
        on: push
        permissions:
          contents: read
        jobs:
          call:
            uses: ./.github/workflows/callee.yml
        """
    callee = """\
        on:
          workflow_call:
        jobs:
          one:
            runs-on: ubuntu-latest
            steps:
              - run: echo one
          two:
            runs-on: ubuntu-latest
            steps:
              - run: echo two
        """
    edges, failures = check({"caller.yml": caller, "callee.yml": callee})

    assert failures == []
    assert len(edges) == 1 and edges[0].requests == (), edges


def test_shorthand_permission_blocks() -> None:
    def caller(block: str) -> str:
        return f"""\
            on: push
            permissions: {block}
            jobs:
              call:
                uses: ./.github/workflows/callee.yml
            """

    def callee(block: str) -> str:
        return f"""\
            on:
              workflow_call:
            permissions: {block}
            jobs:
              run:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
            """

    read_all_vs_contents_read = failures_for({"caller.yml": caller("{ contents: read }"), "callee.yml": callee("read-all")})
    assert any("requests 'actions: read'" in f and "only allows 'actions: none'" in f for f in read_all_vs_contents_read), read_all_vs_contents_read
    assert not any("'contents: read'" in f and "only allows" in f for f in read_all_vs_contents_read), read_all_vs_contents_read

    assert failures_for({"caller.yml": caller("write-all"), "callee.yml": callee("read-all")}) == []
    assert failures_for({"caller.yml": caller("write-all"), "callee.yml": callee("write-all")}) == []
    assert failures_for({"caller.yml": caller("{}"), "callee.yml": callee("{}")}) == []

    nothing_vs_contents_read = failures_for({"caller.yml": caller("{}"), "callee.yml": callee("{ contents: read }")})
    assert len(nothing_vs_contents_read) == 1, nothing_vs_contents_read
    assert "requests 'contents: read'" in nothing_vs_contents_read[0] and "only allows 'contents: none'" in nothing_vs_contents_read[0], nothing_vs_contents_read


def test_caller_without_permissions_uses_the_repository_default() -> None:
    caller = """\
        on: push
        jobs:
          call:
            uses: ./.github/workflows/callee.yml
        """

    def callee(scope: str, level: str) -> str:
        return f"""\
            on:
              workflow_call:
            permissions:
              {scope}: {level}
            jobs:
              run:
                runs-on: ubuntu-latest
                steps:
                  - run: echo hi
            """

    contents_write = {"caller.yml": caller, "callee.yml": callee("contents", "write")}
    assert failures_for(contents_write, default="write") == []
    restricted = failures_for(contents_write, default="read")
    assert len(restricted) == 1 and "repository default workflow permissions (read)" in restricted[0], restricted

    # The default token never carries id-token, whichever repository setting applies.
    for default in ("write", "read"):
        id_token = failures_for({"caller.yml": caller, "callee.yml": callee("id-token", "write")}, default=default)
        assert len(id_token) == 1 and "only allows 'id-token: none'" in id_token[0], (default, id_token)
        # metadata: read is always available.
        assert failures_for({"caller.yml": caller, "callee.yml": callee("metadata", "read")}, default=default) == []


def test_nested_calls_are_checked_with_the_intermediate_job_grant() -> None:
    top = textwrap.dedent("""\
        on: push
        permissions:
          contents: read
          id-token: write
        jobs:
          call:
            uses: ./.github/workflows/middle.yml
        """)
    middle_without_ceiling = textwrap.dedent("""\
        on:
          workflow_call:
        permissions:
          contents: read
        jobs:
          inner:
            uses: ./.github/workflows/leaf.yml
        """)
    leaf = """\
        on:
          workflow_call:
        permissions:
          contents: read
          id-token: write
        jobs:
          run:
            runs-on: ubuntu-latest
            steps:
              - run: echo leaf
        """
    edges, failures = check({"top.yml": top, "middle.yml": middle_without_ceiling, "leaf.yml": leaf})

    assert [(edge.caller.name, edge.job, edge.callee.name) for edge in edges] == [
        ("top.yml", "call", "middle.yml"),
        ("middle.yml", "inner", "leaf.yml"),
    ], edges
    assert len(failures) == 1, failures
    assert "middle.yml (reached via top.yml): job 'inner' uses ./.github/workflows/leaf.yml" in failures[0], failures
    assert "requests 'id-token: write' (leaf.yml workflow-level permissions)" in failures[0], failures
    assert "only allows 'id-token: none' (middle.yml workflow-level permissions)" in failures[0], failures

    middle_with_ceiling = middle_without_ceiling.replace(
        "  inner:\n", "  inner:\n    permissions:\n      contents: read\n      id-token: write\n"
    )
    assert failures_for({"top.yml": top, "middle.yml": middle_with_ceiling, "leaf.yml": leaf}) == []

    # The intermediate job's own ceiling is itself a request against the top-level caller.
    top_without_id_token = top.replace("  id-token: write\n", "")
    outer = failures_for({"top.yml": top_without_id_token, "middle.yml": middle_with_ceiling, "leaf.yml": leaf})
    assert any("top.yml: job 'call' uses ./.github/workflows/middle.yml" in f and "(middle.yml job 'inner' permissions)" in f for f in outer), outer


def test_external_reusable_workflows_are_skipped() -> None:
    caller = """\
        on: push
        permissions: {}
        jobs:
          external:
            uses: octo-org/octo-repo/.github/workflows/build.yml@v1
          action_step:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v6
        """
    edges, failures = check({"caller.yml": caller})

    assert edges == [] and failures == []


def test_missing_local_callee_fails() -> None:
    caller = """\
        on: push
        permissions:
          contents: read
        jobs:
          call:
            uses: ./.github/workflows/does-not-exist.yml
        """
    failures = failures_for({"caller.yml": caller})

    assert len(failures) == 1 and "does-not-exist.yml, but that workflow file does not exist" in failures[0], failures


def test_reader_ignores_lookalike_text_and_accepts_github_yaml_shapes() -> None:
    callee = (
        "---\r\n"
        "name: shapes\r\n"
        "on:\r\n"
        "  push:\r\n"
        "    branches:\r\n"
        "    - main\r\n"
        "  workflow_call:\r\n"
        '"permissions": { contents: read }  # flow mapping, quoted key, inline comment\r\n'
        "jobs:\r\n"
        "  run:\r\n"
        "    runs-on: ubuntu-latest\r\n"
        "    steps:\r\n"
        "      - name: Print a permissions block that must not be read as one\r\n"
        "        run: |\r\n"
        "          cat <<'EOF'\r\n"
        "          permissions:\r\n"
        "            actions: write\r\n"
        "          EOF\r\n"
        "      # a comment between steps\r\n"
        "      - run: echo 'permissions: write-all'\r\n"
        "  other:\r\n"
        "    permissions:\r\n"
        "      contents: read # trailing comment\r\n"
        "      packages: 'read'\r\n"
        "    runs-on: ubuntu-latest\r\n"
        "    steps:\r\n"
        "      - run: echo other\r\n"
    )
    caller = """\
        on: push
        permissions:
          contents: write
          packages: read
        jobs:
          call:
            uses: './.github/workflows/callee.yml'
            with:
              example: "value: with colon"
        """
    workflows = workflows_tree({"caller.yml": caller, "callee.yml": callee})
    parsed = module.parse_workflow(workflows / "callee.yml")

    assert parsed["permissions"] == {"contents": "read"}, parsed
    assert set(parsed["jobs"]) == {"run", "other"}, parsed
    assert parsed["jobs"]["other"]["permissions"] == {"contents": "read", "packages": "read"}, parsed
    assert "permissions" not in parsed["jobs"]["run"], parsed
    requests = module.callee_requests(parsed, "callee.yml")
    assert {(r.scope, r.level) for r in requests} == {("contents", 1), ("packages", 1)}, requests

    edges, failures = module.check_workflows_dir(workflows, "write")
    assert failures == [] and len(edges) == 1, (edges, failures)


def test_repository_workflows_stay_within_their_callers_grants() -> None:
    result = run_cli(WORKFLOWS_DIR, default=REPOSITORY_DEFAULT_WORKFLOW_PERMISSIONS)

    assert result.returncode == 0, f"{result.stdout}\n{result.stderr}"
    assert result.stdout.startswith("PASS:"), result.stdout

    # Behavioral completeness: every local `uses:` job in the tree was actually checked.
    pattern = re.compile(r"^\s+uses:\s*['\"]?\./\.github/workflows/", re.MULTILINE)
    expected_calls = sum(len(pattern.findall(path.read_text(encoding="utf-8"))) for path in WORKFLOWS_DIR.glob("*.yml"))
    assert expected_calls > 0
    assert f"({expected_calls} call site(s) in" in result.stdout, (expected_calls, result.stdout)


def test_ci_runs_this_guard_in_workflow_guard_tests() -> None:
    text = CI_WORKFLOW.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^  workflow-guard-tests:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text)
    assert match is not None, "workflow-guard-tests job missing from ci.yml"

    assert "run: python3 tests/test_ci_reusable_workflow_permissions.py" in match.group(1), match.group(1)


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: reusable workflow permission guard")
