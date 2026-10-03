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
import os
import shutil
import subprocess
import tempfile
import sys
from pathlib import Path

import yaml
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

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
CONTENT_GROUP = (
    "web-complexity-trusted-${{ github.event.pull_request.number || "
    "github.event.merge_group.head_sha || github.ref }}"
)


def validate_metadata_routing(document: dict) -> None:
    """Metadata edits must publish a real verdict under the required name."""
    job = document["jobs"]["complexity"]
    assert job["name"] == REQUIRED_CHECK, "required checks need a stable literal name"
    assert "if" not in job, "metadata edits must execute the verdict, not publish a skipped check"
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
        b".github/workflows/web-complexity.yml",
        b"scripts/ci/scope-web-complexity.py",
        b"scripts/ci/web_complexity_scope.py",
        b"web/.oxlintrc.json",
        b"web/bun.lock",
        b"web/bunfig.toml",
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


EXPECTED_CHECKS = [{'env': {'SCOPE_MODE': "${{ steps.selected_scope.outputs.mode || 'full' }}",
          'SELECTED_COUNT': '${{ steps.selected_scope.outputs.selected_count }}',
          'MERGE_REPO': '${{ steps.merge.outputs.repo }}',
          'MERGE_TREE': '${{ steps.merge.outputs.tree }}'},
  'if': "github.event_name != 'push' && steps.scope.outputs.run == 'true'",
  'name': 'Check pull-request or merge-group source with trusted policy',
  'run': 'set -euo pipefail\n'
         'checker=(\n'
         '  bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml"\n'
         '  scripts/check-complexity.mjs\n'
         '  --repo-root "$GITHUB_WORKSPACE/candidate"\n'
         '  --tool-root "$GITHUB_WORKSPACE/trusted"\n'
         '  --base-baseline "$GITHUB_WORKSPACE/trusted/web/oxlint-complexity-baseline.txt"\n'
         '  --head "$CANDIDATE_SHA"\n'
         ')\n'
         'if [[ -n "$MERGE_REPO" && -n "$MERGE_TREE" ]]; then\n'
         '  checker+=(--merge-repo "$MERGE_REPO" --merge-tree "$MERGE_TREE")\n'
         'fi\n'
         'case "$SCOPE_MODE" in\n'
         '  full|skip)\n'
         '    echo "Web complexity: selected $SELECTED_COUNT production file(s) for conservative '
         'full scan."\n'
         '    "${checker[@]}"\n'
         '    ;;\n'
         '  changed)\n'
         '    mapfile -d \'\' -t selected < "$RUNNER_TEMP/web-complexity-selected.zlist"\n'
         '    [[ "${#selected[@]}" -eq "$SELECTED_COUNT" ]]\n'
         '    echo "Web complexity: selected ${#selected[@]} changed existing production '
         'file(s)."\n'
         '    if [[ "${#selected[@]}" -eq 0 ]]; then\n'
         '      exit 0\n'
         '    fi\n'
         '    "${checker[@]}" --files "${selected[@]}"\n'
         '    ;;\n'
         '  *)\n'
         '    echo "::error::Unexpected Web complexity scope mode: $SCOPE_MODE"\n'
         '    exit 1\n'
         '    ;;\n'
         'esac\n',
  'working-directory': 'trusted/web'},
 {'env': {'BEFORE_SHA': '${{ github.event.before }}', 'HEAD_SHA': '${{ github.sha }}'},
  'if': "github.event_name == 'push'",
  'name': 'Check main push with trusted policy',
  'run': 'set -euo pipefail\n'
         'if [ -n "${BEFORE_SHA:-}" ] && [ "$BEFORE_SHA" != '
         '"0000000000000000000000000000000000000000" ]; then\n'
         '  bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" '
         'scripts/check-complexity.mjs --base "$BEFORE_SHA" --head "$HEAD_SHA"\n'
         'else\n'
         '  bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" '
         'scripts/check-complexity.mjs\n'
         'fi\n',
  'working-directory': 'trusted/web'}]


SCOPER = ROOT / "scripts" / "ci" / "scope-web-complexity.py"
CHECKER = ROOT / "web" / "scripts" / "check-complexity.mjs"
BASELINE = "web/oxlint-complexity-baseline.txt"
FINGERPRINT = "0" * 64
BASELINE_ENTRY = (
    f"app/debt.ts\t{FINGERPRINT}\t"
    "function debt has a complexity of 21. Maximum allowed is 20.\n"
)


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError(
            f"{args!r} failed with {result.returncode}:\n"
            f"stdout={result.stdout.decode('utf-8', errors='replace')}\n"
            f"stderr={result.stderr.decode('utf-8', errors='replace')}"
        )
    return result


def git(repo: Path, *args: str) -> bytes:
    return run(["git", *args], cwd=repo).stdout


def write(repo: Path, relative: str, content: str = "x\n") -> None:
    filename = repo / relative
    filename.parent.mkdir(parents=True, exist_ok=True)
    filename.write_text(content, encoding="utf-8")


def commit(repo: Path, message: str) -> str:
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD").decode().strip()


def init_repo(base_baseline: str = "") -> tuple[Path, str, Path, tempfile.TemporaryDirectory[str]]:
    temp = tempfile.TemporaryDirectory()
    root = Path(temp.name)
    repo = root / "candidate"
    repo.mkdir()
    git(repo, "init", "-q")
    git(repo, "config", "user.email", "ci@example.com")
    git(repo, "config", "user.name", "CI")
    git(repo, "config", "commit.gpgsign", "false")
    write(repo, BASELINE, base_baseline)
    write(repo, "README.md", "base\n")
    base = commit(repo, "base")
    trusted_baseline = root / "trusted-baseline.txt"
    trusted_baseline.write_text(base_baseline, encoding="utf-8")
    return repo, base, trusted_baseline, temp


def scope(
    repo: Path,
    base: str,
    head: str,
    trusted_baseline: Path,
) -> tuple[subprocess.CompletedProcess[bytes], bytes, dict[str, str]]:
    root = repo.parent
    selected = root / "selected.zlist"
    github_output = root / "github-output.txt"
    result = run(
        [
            sys.executable,
            "-I",
            "-S",
            str(SCOPER),
            "--repo-root",
            str(repo),
            "--base",
            base,
            "--head",
            head,
            "--base-baseline",
            str(trusted_baseline),
            "--selected-output",
            str(selected),
            "--github-output",
            str(github_output),
        ],
        check=False,
    )
    selected_bytes = selected.read_bytes() if selected.exists() else b""
    outputs: dict[str, str] = {}
    if github_output.exists():
        for line in github_output.read_text(encoding="utf-8").splitlines():
            key, value = line.split("=", 1)
            outputs[key] = value
    return result, selected_bytes, outputs


def assert_scope(
    mutate,
    *,
    expected_mode: str,
    expected_selected: bytes = b"",
    base_baseline: str = "",
) -> None:
    repo, base, trusted_baseline, temp = init_repo(base_baseline)
    try:
        mutate(repo)
        head = commit(repo, "candidate")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
        assert outputs["mode"] == expected_mode, outputs
        assert selected == expected_selected, selected
        assert int(outputs["selected_count"]) == expected_selected.count(b"\0"), outputs
    finally:
        temp.cleanup()


def test_scope_cases() -> None:
    assert_scope(
        lambda repo: write(repo, "Sources/App.swift", "let answer = 42\n"),
        expected_mode="skip",
    )

    def docs_assets_locales(repo: Path) -> None:
        write(repo, "web/app/guide/readme.mdx", "# Guide\n")
        write(repo, "web/public/logo.svg", "<svg />\n")
        write(repo, "web/messages/fr.json", "{}\n")

    assert_scope(docs_assets_locales, expected_mode="skip")

    repo, base, trusted_baseline, temp = init_repo()
    try:
        write(repo, "web/app/page.tsx", "export const value = 1;\n")
        base = commit(repo, "base source")
        write(repo, "web/app/page.tsx", "export const value = 2;\n")
        head = commit(repo, "edit source")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
        assert outputs["mode"] == "changed", outputs
        assert outputs["selected_count"] == "1", outputs
        assert selected == b"web/app/page.tsx\0", selected
    finally:
        temp.cleanup()

    repo, base, trusted_baseline, temp = init_repo()
    try:
        write(repo, "web/app/- odd name.ts", "export const odd = true;\n")
        head = commit(repo, "weird but safe")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
        assert outputs["mode"] == "changed", outputs
        assert selected == b"web/app/- odd name.ts\0", selected
        assert b"- odd" not in result.stdout
        assert b"- odd" not in result.stderr
    finally:
        temp.cleanup()

    repo, base, trusted_baseline, temp = init_repo()
    try:
        write(repo, "web/app/odd\nname.ts", "export const odd = true;\n")
        head = commit(repo, "control character path")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert selected == b""
        assert outputs == {}
        assert b"unsupported control characters" in result.stderr
        assert b"odd" not in result.stderr
    finally:
        temp.cleanup()

    repo, base, trusted_baseline, temp = init_repo()
    try:
        write(repo, "web/--format.ts", "export const optionLike = true;\n")
        head = commit(repo, "option-like path")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert selected == b""
        assert outputs == {}
        assert b"beginning with '-'" in result.stderr
        assert b"--format.ts" not in result.stderr
    finally:
        temp.cleanup()

    policy_paths = (
        ".github/workflows/web-complexity.yml",
        ".github/workflows/web-complexity-trusted.yml",
        "scripts/ci/scope-web-complexity.py",
        "scripts/ci/web_complexity_scope.py",
        "web/.oxlintrc.json",
        "web/bun.lock",
        "web/package.json",
        "web/scripts/check-complexity.mjs",
    )
    for policy_path in policy_paths:
        assert_scope(
            lambda repo, path=policy_path: write(repo, path, "changed\n"),
            expected_mode="full",
        )

    assert_scope(
        lambda repo: (repo / BASELINE).write_text("", encoding="utf-8"),
        expected_mode="full",
        base_baseline=BASELINE_ENTRY,
    )
    assert_scope(
        lambda repo: (repo / BASELINE).write_text(BASELINE_ENTRY, encoding="utf-8"),
        expected_mode="full",
        base_baseline="",
    )


def test_deleted_grandfathered_source_fails_before_setup() -> None:
    repo, base, trusted_baseline, temp = init_repo(BASELINE_ENTRY)
    try:
        write(repo, "web/app/debt.ts", "export function debt() { return 1; }\n")
        base = commit(repo, "base with debt")
        trusted_baseline.write_text(BASELINE_ENTRY, encoding="utf-8")
        (repo / "web/app/debt.ts").unlink()
        head = commit(repo, "delete debt")
        result, _, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert outputs == {}
        stderr = result.stderr.decode("utf-8", errors="replace")
        assert "grandfathered baseline entry" in stderr
        assert "remove the stale baseline entry" in stderr
        assert "debt.ts" not in stderr
    finally:
        temp.cleanup()


def test_full_scan_still_rejects_stale_deleted_baseline_entry() -> None:
    repo, base, trusted_baseline, temp = init_repo(BASELINE_ENTRY)
    try:
        write(repo, "web/app/debt.ts", "export function debt() { return 1; }\n")
        base = commit(repo, "base with debt")
        trusted_baseline.write_text(BASELINE_ENTRY, encoding="utf-8")
        (repo / "web/app/debt.ts").unlink()
        write(repo, "web/package.json", '{"scripts": {}}\n')
        head = commit(repo, "delete debt and change policy input")
        result, _, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert outputs == {}
        assert b"grandfathered baseline entry" in result.stderr
    finally:
        temp.cleanup()


def test_full_scan_allows_deleted_source_when_candidate_baseline_is_cleaned_up() -> None:
    repo, base, trusted_baseline, temp = init_repo(BASELINE_ENTRY)
    try:
        write(repo, "web/app/debt.ts", "export function debt() { return 1; }\n")
        base = commit(repo, "base with debt")
        trusted_baseline.write_text(BASELINE_ENTRY, encoding="utf-8")
        (repo / "web/app/debt.ts").unlink()
        (repo / BASELINE).write_text("", encoding="utf-8")
        head = commit(repo, "delete debt and clean baseline")
        result, selected, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
        assert outputs["mode"] == "full", outputs
        assert selected == b""
    finally:
        temp.cleanup()


def test_candidate_baseline_symlink_fails_closed() -> None:
    repo, base, trusted_baseline, temp = init_repo()
    try:
        outside = repo.parent / "outside-baseline.txt"
        outside.write_text(BASELINE_ENTRY, encoding="utf-8")
        baseline = repo / BASELINE
        baseline.unlink()
        baseline.symlink_to(outside)
        head = commit(repo, "symlink baseline")
        result, _, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert outputs == {}
    finally:
        temp.cleanup()


def test_policy_symlink_fails_closed() -> None:
    repo, base, trusted_baseline, temp = init_repo()
    try:
        outside = repo.parent / "outside-package.json"
        outside.write_text("{}\n", encoding="utf-8")
        package = repo / "web/package.json"
        package.parent.mkdir(parents=True, exist_ok=True)
        package.symlink_to(outside)
        head = commit(repo, "symlink policy input")
        result, _, outputs = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert outputs == {}
        assert b"regular file" in result.stderr
    finally:
        temp.cleanup()


def test_selected_symlink_fails_closed() -> None:
    repo, base, trusted_baseline, temp = init_repo()
    try:
        target = repo / "outside.txt"
        target.write_text("outside\n", encoding="utf-8")
        link = repo / "web/app/escape.ts"
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        head = commit(repo, "symlink")
        result, _, _ = scope(repo, base, head, trusted_baseline)
        assert result.returncode == 2
        assert b"regular file" in result.stderr
    finally:
        temp.cleanup()


def checker_fixture(candidate_baseline: str, base_baseline: str) -> tuple[Path, Path, tempfile.TemporaryDirectory[str]]:
    temp = tempfile.TemporaryDirectory()
    root = Path(temp.name)
    repo = root / "repo"
    (repo / "web/scripts").mkdir(parents=True)
    shutil.copy2(CHECKER, repo / "web/scripts/check-complexity.mjs")
    (repo / "web/node_modules/typescript").mkdir(parents=True)
    write(
        repo,
        "web/node_modules/typescript/package.json",
        '{"type":"module","exports":"./index.js"}\n',
    )
    write(repo, "web/node_modules/typescript/index.js", "export {};\n")
    write(repo, BASELINE, candidate_baseline)
    previous = root / "base-baseline.txt"
    previous.write_text(base_baseline, encoding="utf-8")
    return repo, previous, temp



def test_checker_compares_strict_trusted_tree_entries() -> None:
    if shutil.which("node") is None:
        raise AssertionError("node is required for the checker policy regression")

    temp = tempfile.TemporaryDirectory()
    try:
        root = Path(temp.name)
        trusted = root / "trusted"
        candidate = root / "candidate"
        (trusted / "web/scripts").mkdir(parents=True)
        shutil.copy2(CHECKER, trusted / "web/scripts/check-complexity.mjs")
        policy_paths = (
            "scripts/ci/scope-web-complexity.py",
            "web/scripts/check-complexity.mjs",
            ".github/workflows/web-complexity-trusted.yml",
        )
        write(trusted, policy_paths[0], "trusted\n")
        write(trusted, policy_paths[2], "trusted\n")
        write(trusted, "web/.oxlintrc.json", '{"rules":{"complexity":["error",{"max":20,"variant":"classic"}]}}\n')
        write(trusted, "web/package.json", '{"devDependencies":{"oxlint":"1.0.0"}}\n')
        write(trusted, "web/bun.lock", '"oxlint": "1.0.0"\n')
        write(trusted, BASELINE, "")
        git(trusted, "init", "-q")
        git(trusted, "config", "user.email", "ci@example.com")
        git(trusted, "config", "user.name", "CI")
        git(trusted, "config", "commit.gpgsign", "false")
        base = commit(trusted, "trusted policy")
        # The workflow uses separate shallow checkouts. Only trusted needs the
        # module stub: no source scan runs in this policy-only fixture.
        run(["git", "clone", "-q", "--depth=1", trusted.as_uri(), str(candidate)])
        git(candidate, "config", "user.email", "ci@example.com")
        git(candidate, "config", "user.name", "CI")
        git(candidate, "config", "commit.gpgsign", "false")
        git(candidate, "config", "core.filemode", "true")
        (trusted / "web/node_modules/typescript").mkdir(parents=True)
        write(
            trusted,
            "web/node_modules/typescript/package.json",
            '{"type":"module","exports":"./index.js"}\n',
        )
        write(trusted, "web/node_modules/typescript/index.js", "export {};\n")

        def check(head: str) -> subprocess.CompletedProcess[bytes]:
            return run(
                [
                    "node",
                    str(trusted / "web/scripts/check-complexity.mjs"),
                    "--repo-root", str(candidate),
                    "--tool-root", str(trusted),
                    "--head", head,
                    "--base-baseline", str(trusted / BASELINE),
                ],
                cwd=trusted / "web",
                check=False,
            )

        unchanged = check(base)
        assert unchanged.returncode == 0, unchanged.stderr
        failures = []
        for relative in policy_paths:
            for change in ("symlink", "mode", "content", "deleted"):
                git(candidate, "reset", "--hard", base)
                git(candidate, "clean", "-fd")
                policy = candidate / relative
                if change == "symlink":
                    copy = candidate / "web/evil/policy-copy"
                    copy.parent.mkdir(parents=True, exist_ok=True)
                    copy.write_bytes(policy.read_bytes())
                    policy.unlink()
                    policy.symlink_to(os.path.relpath(copy, policy.parent))
                    assert policy.read_bytes() == (trusted / relative).read_bytes()
                elif change == "mode":
                    policy.chmod(policy.stat().st_mode ^ 0o111)
                elif change == "content":
                    policy.write_text("changed\n", encoding="utf-8")
                else:
                    policy.unlink()
                head = commit(candidate, f"{change} {relative}")
                result = check(head)
                reason = "must remain present" if change == "deleted" else "is a trusted policy file"
                expected = f"{relative} {reason}".encode()
                if result.returncode != 2 or expected not in result.stderr:
                    failures.append(f"{change} {relative}: exit {result.returncode}, stderr={result.stderr!r}")
        assert not failures, "\n".join(failures)
    finally:
        temp.cleanup()


def test_checker_judges_trusted_files_in_the_merge() -> None:
    if shutil.which("node") is None:
        raise AssertionError("node is required for the checker merge regression")

    temp = tempfile.TemporaryDirectory()
    try:
        root = Path(temp.name)
        repo = root / "repo"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "ci@example.com")
        git(repo, "config", "user.name", "CI")
        (repo / "web/scripts").mkdir(parents=True)
        shutil.copy2(CHECKER, repo / "web/scripts/check-complexity.mjs")
        write(repo, ".github/workflows/web-complexity-trusted.yml", "old\n")
        write(repo, "scripts/ci/scope-web-complexity.py", "old\n")
        branch_point = commit(repo, "branch point")

        # Main updates a trusted file after the branch point.
        write(repo, "scripts/ci/scope-web-complexity.py", "main\n")
        main = commit(repo, "main updates the scoper")

        # The trusted checkout is main, with the checker's module dependency.
        trusted = root / "trusted"
        git(repo, "worktree", "add", "-q", "--detach", str(trusted), main)
        (trusted / "web/node_modules/typescript").mkdir(parents=True)
        write(
            trusted,
            "web/node_modules/typescript/package.json",
            '{"type":"module","exports":"./index.js"}\n',
        )
        write(trusted, "web/node_modules/typescript/index.js", "export {};\n")

        def branch(name: str, change) -> tuple[Path, str]:
            candidate = root / name
            git(repo, "worktree", "add", "-q", "-b", name, str(candidate), branch_point)
            change(candidate)
            head = commit(candidate, name)
            tree = git(repo, "merge-tree", "--write-tree", main, head).decode().split("\n")[0]
            return candidate, tree

        def check(candidate: Path, *extra: str) -> subprocess.CompletedProcess[bytes]:
            return run(
                [
                    "node",
                    str(trusted / "web/scripts/check-complexity.mjs"),
                    "--repo-root",
                    str(candidate),
                    "--tool-root",
                    str(trusted),
                    *extra,
                ],
                check=False,
            )

        # A stale branch that leaves the trusted files alone.
        stale, stale_tree = branch("stale", lambda path: write(path, "README.md", "docs\n"))
        result = check(stale)
        assert result.returncode == 2, "without a merge the stale head is compared strictly"
        assert b"is a trusted policy file" in result.stderr
        result = check(stale, "--merge-repo", str(repo / ".git"), "--merge-tree", stale_tree)
        # Past the trusted-file gate, the next check reads the complexity config,
        # which this fixture does not provide.
        assert b".oxlintrc.json" in result.stderr, result.stderr

        # A branch that edits a trusted file main did not touch.
        edited, edited_tree = branch(
            "edited",
            lambda path: write(path, ".github/workflows/web-complexity-trusted.yml", "edit\n"),
        )
        result = check(edited, "--merge-repo", str(repo / ".git"), "--merge-tree", edited_tree)
        assert result.returncode == 2
        assert b".github/workflows/web-complexity-trusted.yml is a trusted policy file" in result.stderr

        # A symlink to identical content is not the trusted file.
        def symlink_workflow(path: Path) -> None:
            write(path, "web/copy.yml", "old\n")
            workflow = path / ".github/workflows/web-complexity-trusted.yml"
            workflow.unlink()
            workflow.symlink_to("../../web/copy.yml")

        linked, linked_tree = branch("linked", symlink_workflow)
        result = check(linked, "--merge-repo", str(repo / ".git"), "--merge-tree", linked_tree)
        assert result.returncode == 2
        assert b".github/workflows/web-complexity-trusted.yml is a trusted policy file" in result.stderr

        # The same bytes with a different mode are not the trusted file either.
        def make_executable(path: Path) -> None:
            (path / ".github/workflows/web-complexity-trusted.yml").chmod(0o755)

        mode, mode_tree = branch("mode", make_executable)
        result = check(mode, "--merge-repo", str(repo / ".git"), "--merge-tree", mode_tree)
        assert result.returncode == 2
        assert b".github/workflows/web-complexity-trusted.yml is a trusted policy file" in result.stderr
    finally:
        temp.cleanup()


MERGE_STEP = "Merge pull request into its base for the trusted-file check"
MERGE_UPSTREAM = 'upstream="https://github.com/${GITHUB_REPOSITORY}.git"'


def test_merge_step_merges_only_when_rebase_merging_is_off() -> None:
    steps = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["complexity"]["steps"]
    script = next(step["run"] for step in steps if step.get("name") == MERGE_STEP)
    assert script.count(MERGE_UPSTREAM) == 1, "the merge step must fetch from the upstream repository"
    script = script.replace(MERGE_UPSTREAM, 'upstream="$TEST_UPSTREAM"')

    temp = tempfile.TemporaryDirectory()
    try:
        root = Path(temp.name)
        repo = root / "upstream"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "main")
        git(repo, "config", "user.email", "ci@example.com")
        git(repo, "config", "user.name", "CI")
        git(repo, "config", "uploadpack.allowFilter", "true")
        git(repo, "config", "uploadpack.allowAnySHA1InWant", "true")
        write(repo, "scripts/ci/scope-web-complexity.py", "old\n")
        write(repo, "web/scripts/check-complexity.mjs", "checker\n")
        write(repo, ".github/workflows/web-complexity-trusted.yml", "workflow\n")
        branch_point = commit(repo, "branch point")
        write(repo, "scripts/ci/scope-web-complexity.py", "fixed\n")
        commit(repo, "main fixes the scoper")

        # A stale branch that never touches the trusted files.
        git(repo, "checkout", "-q", "-b", "stale", branch_point)
        write(repo, "README.md", "docs\n")
        stale = commit(repo, "docs")

        # A branch that merged main after main changed a trusted file, as
        # "Update branch" does, before main changed it again.
        git(repo, "checkout", "-q", "-b", "updated", stale)
        git(repo, "merge", "-q", "--no-edit", "main")
        updated = git(repo, "rev-parse", "HEAD").decode().strip()
        git(repo, "checkout", "-q", "main")
        write(repo, "scripts/ci/scope-web-complexity.py", "fixed again\n")
        main = commit(repo, "main fixes the scoper again")

        # The step asks the repository whether rebase merging is allowed.
        stub = root / "bin"
        stub.mkdir()
        # The stub answers only the exact query the gate depends on, so a
        # changed field, owner, name or jq path fails like a broken API.
        write(
            stub,
            "gh",
            "#!/bin/sh\n"
            'case "$*" in\n'
            "  'api graphql -f owner=example -f name=repo -f query=query($owner: String!, $name: String!) "
            "{ repository(owner: $owner, name: $name) { rebaseMergeAllowed } } "
            "--jq .data.repository.rebaseMergeAllowed') ;;\n"
            '  *) echo "unexpected gh call: $*" >&2; exit 2 ;;\n'
            "esac\n"
            # Real gh prints the error body on stdout when a request fails.
            '[ "$GH_STUB" = fail ] && { echo \'{"message":"Bad credentials"}\'; exit 1; }\n'
            'echo "$GH_STUB"\n',
        )
        (stub / "gh").chmod(0o755)

        def run_step(head: str, rebase: str) -> dict[str, str]:
            label = f"{head[:7]}-{rebase}"
            output = root / f"output-{label}"
            runner_temp = root / f"runner-{label}"
            runner_temp.mkdir()
            output.touch()
            run(
                ["bash", "-c", script],
                env={
                    "PATH": f"{stub}:/usr/bin:/bin:/usr/local/bin",
                    "HOME": str(root),
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_REPOSITORY": "example/repo",
                    "RUNNER_TEMP": str(runner_temp),
                    "TRUSTED_SHA": main,
                    "CANDIDATE_SHA": head,
                    "TEST_UPSTREAM": f"file://{repo}",
                    "GH_STUB": rebase,
                },
            )
            return dict(line.split("=", 1) for line in output.read_text().splitlines() if "=" in line)

        def merged_tree(head: str) -> str:
            return git(repo, "merge-tree", "--write-tree", main, head).decode().split("\n")[0]

        # A rebase merge replays commits one by one, so the merge of the head
        # does not describe what lands. The step must stay strict.
        assert run_step(stale, "true") == {}, "rebase merging allowed: compare strictly"
        assert run_step(stale, "fail") == {}, "unknown setting: compare strictly"

        assert run_step(stale, "false").get("tree") == merged_tree(stale)
        assert run_step(updated, "false").get("tree") == merged_tree(updated), (
            "a branch that merged main is judged by its merge"
        )
    finally:
        temp.cleanup()


def test_checker_baseline_ratchet() -> None:
    if shutil.which("node") is None:
        raise AssertionError("node is required for the checker ratchet regression")

    repo, previous, temp = checker_fixture("", BASELINE_ENTRY)
    try:
        result = run(
            [
                "node",
                str(repo / "web/scripts/check-complexity.mjs"),
                "--repo-root",
                str(repo),
                "--tool-root",
                str(repo),
                "--base-baseline",
                str(previous),
                "--files",
                "web/app/deleted.ts",
            ],
            check=False,
        )
        assert result.returncode == 0, result.stderr.decode("utf-8", errors="replace")
    finally:
        temp.cleanup()

    repo, previous, temp = checker_fixture(BASELINE_ENTRY, "")
    try:
        result = run(
            [
                "node",
                str(repo / "web/scripts/check-complexity.mjs"),
                "--repo-root",
                str(repo),
                "--tool-root",
                str(repo),
                "--base-baseline",
                str(previous),
                "--files",
                "web/app/deleted.ts",
            ],
            check=False,
        )
        assert result.returncode == 1
        assert b"baseline may only shrink" in result.stderr
    finally:
        temp.cleanup()




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
    trusted_checkout = next(
        step
        for step in job["steps"]
        if step.get("name") == "Checkout trusted policy revision"
    )
    expected_fetch_depth = "${{ github.event_name != 'push' && 1 || 0 }}"
    if trusted_checkout.get("with", {}).get("fetch-depth") != expected_fetch_depth:
        print(
            "FAIL: trusted policy checkout must stay shallow on PR/merge-group runs "
            "and retain full history only for main pushes"
        )
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

    test_scope_cases()
    test_deleted_grandfathered_source_fails_before_setup()
    test_full_scan_still_rejects_stale_deleted_baseline_entry()
    test_full_scan_allows_deleted_source_when_candidate_baseline_is_cleaned_up()
    test_candidate_baseline_symlink_fails_closed()
    test_policy_symlink_fails_closed()
    test_selected_symlink_fails_closed()
    test_checker_compares_strict_trusted_tree_entries()
    test_checker_judges_trusted_files_in_the_merge()
    test_merge_step_merges_only_when_rebase_merging_is_off()
    test_checker_baseline_ratchet()
    print("PASS: trusted web complexity scopes work before Bun and runs checks from the trusted checkout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
