#!/usr/bin/env python3
"""Regression coverage for the trusted Web complexity scope and trust boundary."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-complexity-trusted.yml"
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
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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



def test_checker_protects_trusted_scoper() -> None:
    if shutil.which("node") is None:
        raise AssertionError("node is required for the checker policy regression")

    temp = tempfile.TemporaryDirectory()
    try:
        root = Path(temp.name)
        trusted = root / "trusted"
        candidate = root / "candidate"
        (trusted / "web/scripts").mkdir(parents=True)
        (candidate / "web/scripts").mkdir(parents=True)
        shutil.copy2(CHECKER, trusted / "web/scripts/check-complexity.mjs")
        shutil.copy2(CHECKER, candidate / "web/scripts/check-complexity.mjs")
        (trusted / "web/node_modules/typescript").mkdir(parents=True)
        write(
            trusted,
            "web/node_modules/typescript/package.json",
            '{"type":"module","exports":"./index.js"}\n',
        )
        write(trusted, "web/node_modules/typescript/index.js", "export {};\n")
        write(trusted, ".github/workflows/web-complexity-trusted.yml", "trusted\n")
        write(candidate, ".github/workflows/web-complexity-trusted.yml", "trusted\n")
        write(trusted, "scripts/ci/scope-web-complexity.py", "trusted\n")
        write(candidate, "scripts/ci/scope-web-complexity.py", "candidate\n")

        result = run(
            [
                "node",
                str(trusted / "web/scripts/check-complexity.mjs"),
                "--repo-root",
                str(candidate),
                "--tool-root",
                str(trusted),
            ],
            check=False,
        )
        assert result.returncode == 2
        assert b"scripts/ci/scope-web-complexity.py is a trusted policy file" in result.stderr
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


def test_workflow_trust_boundary() -> None:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    job = document["jobs"]["complexity"]
    assert not job.get("continue-on-error")
    steps = job["steps"]
    by_name = {step["name"]: step for step in steps}
    order = [step["name"] for step in steps]

    trusted_checkout = by_name["Checkout trusted policy revision"]
    assert trusted_checkout["with"]["repository"] == "${{ github.repository }}"
    assert trusted_checkout["with"]["ref"] == "${{ env.TRUSTED_SHA }}"
    assert trusted_checkout["with"]["fetch-depth"] == "${{ github.event_name == 'push' && '0' || '1' }}"
    assert trusted_checkout["with"]["persist-credentials"] is False

    candidate_checkout = by_name["Checkout pull-request or merge-group source"]
    assert candidate_checkout["if"] == "github.event_name != 'push'"
    assert candidate_checkout["with"]["repository"] == "${{ env.CANDIDATE_REPOSITORY }}"
    assert candidate_checkout["with"]["ref"] == "${{ env.CANDIDATE_SHA }}"
    assert candidate_checkout["with"]["fetch-depth"] == 1
    assert candidate_checkout["with"]["persist-credentials"] is False

    assert order.index("Checkout pull-request or merge-group source") < order.index(
        "Determine pull-request complexity scope"
    )
    assert order.index("Determine pull-request complexity scope") < order.index("Setup Bun")

    scope_step = by_name["Determine pull-request complexity scope"]
    assert scope_step["if"] == "github.event_name == 'pull_request_target'"
    assert scope_step["id"] == "scope"
    scope_run = scope_step["run"]
    assert "python3 -I -S trusted/scripts/ci/scope-web-complexity.py" in scope_run
    assert 'git -C candidate fetch --no-tags --depth=1 "$GITHUB_WORKSPACE/trusted" "$TRUSTED_SHA"' in scope_run
    assert "candidate/scripts/" not in scope_run
    assert "bun " not in scope_run

    setup_condition = "github.event_name != 'pull_request_target' || steps.scope.outputs.mode != 'skip'"
    assert by_name["Setup Bun"]["if"] == setup_condition
    assert by_name["Install trusted web tooling"]["if"] == setup_condition
    assert by_name["Install trusted web tooling"]["working-directory"] == "trusted/web"
    assert by_name["Install trusted web tooling"]["run"] == "bun install --frozen-lockfile"
    assert by_name["Create empty trusted Bun config"]["if"] == setup_condition

    skip_step = by_name["Satisfy unchanged pull-request scope"]
    assert skip_step["if"] == "github.event_name == 'pull_request_target' && steps.scope.outputs.mode == 'skip'"

    bun_prefix = (
        'bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml" '
        "scripts/check-complexity.mjs"
    )
    checker_steps = [
        by_name["Check pull-request source with trusted policy"],
        by_name["Check merge-group source with trusted policy"],
        by_name["Check main push with trusted policy"],
    ]
    for step in checker_steps:
        assert step["working-directory"] == "trusted/web"
        assert bun_prefix in step["run"] or (
            "checker=(" in step["run"]
            and 'bun --no-env-file --config="$GITHUB_WORKSPACE/trusted/.bunfig-empty.toml"' in step["run"]
            and "scripts/check-complexity.mjs" in step["run"]
        )
        assert "working-directory: candidate" not in str(step)

    pr_check = checker_steps[0]
    assert pr_check["if"] == "github.event_name == 'pull_request_target' && steps.scope.outputs.mode != 'skip'"
    assert 'mapfile -d \'\' -t selected < "$RUNNER_TEMP/web-complexity-selected.zlist"' in pr_check["run"]
    assert '"${checker[@]}" --files "${selected[@]}"' in pr_check["run"]
    assert '"${checker[@]}"' in pr_check["run"]

    assert checker_steps[1]["if"] == "github.event_name == 'merge_group'"
    assert checker_steps[2]["if"] == "github.event_name == 'push'"

    workflow_text = WORKFLOW.read_text(encoding="utf-8")
    assert "scripts/ci/scope-web-complexity.py" in workflow_text
    assert "selected ${#selected[@]} changed existing production file(s)" in workflow_text


def main() -> int:
    test_scope_cases()
    test_deleted_grandfathered_source_fails_before_setup()
    test_full_scan_still_rejects_stale_deleted_baseline_entry()
    test_full_scan_allows_deleted_source_when_candidate_baseline_is_cleaned_up()
    test_candidate_baseline_symlink_fails_closed()
    test_policy_symlink_fails_closed()
    test_selected_symlink_fails_closed()
    test_checker_protects_trusted_scoper()
    test_checker_baseline_ratchet()
    test_workflow_trust_boundary()
    print("PASS: trusted Web complexity scopes before setup and preserves the ratchet")
    return 0


if __name__ == "__main__":
    sys.exit(main())
