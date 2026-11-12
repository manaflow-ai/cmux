#!/usr/bin/env python3
"""Behavioral guard: reload-build's macOS caches stay warm across ref spellings.

reload-cloud dispatches reload-build.yml with a `ref` input that may be a
branch, a short SHA, or a full SHA, often for an ephemeral branch that exists
for one call. Run 35938367902 (ref=9a0702e0f5, a short SHA) and run
35941854226 (ref=a full SHA on the same branch) both restored nothing; the
first rebuilt cold in 753 seconds. The DerivedData key embedded the raw
`ref` text, so every spelling produced a new key, and the only cross-branch
fallback was a `main-` prefix no run ever saved.

This test runs the workflow's real "Prepare macOS cache metadata" script in a
scratch Git repository and resolves the restore-keys the workflow passes to
actions/cache, then asserts:

- every spelling of one commit produces the same save key;
- a later commit, dispatched under any ref text, restores an entry saved by an
  earlier one through a restore-key that names neither a branch nor a SHA.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path

import yaml
import git_fixture_env  # noqa: F401  (disables git auto maintenance)


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "reload-build.yml"
METADATA_STEP = "Prepare macOS cache metadata"
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
OUTPUT_REF = re.compile(r"^\$\{\{ steps\.cache_meta\.outputs\.([A-Za-z0-9_]+) \}\}$")

FAKE_XCODEBUILD = """#!/bin/sh
printf 'Xcode 27.0\\nBuild version 27A266a\\n'
"""


def build_steps() -> list[dict]:
    workflow = yaml.safe_load(WORKFLOW.read_text())
    return workflow["jobs"]["build"]["steps"]


def step_named(name: str) -> dict:
    for step in build_steps():
        if step.get("name") == name:
            return step
    raise AssertionError(f"reload-build.yml has no step named {name!r}")


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        capture_output=True,
        env={**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"},
    ).stdout.strip()


def make_repo(root: Path) -> Path:
    repo = root / "work" / "cmux" / "cmux"
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "reload-blacksmith/12624-cloud-auth-latency-1789854264")
    git(repo, "config", "user.email", "guard@example.invalid")
    git(repo, "config", "user.name", "guard")
    resolved = repo / "cmux.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm"
    resolved.mkdir(parents=True)
    (resolved / "Package.resolved").write_text('{"pins": [], "version": 3}\n')
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", "fixture")
    return repo


def commit_change(repo: Path, text: str) -> None:
    (repo / "Sources.swift").write_text(text)
    # A package bump changes Package.resolved; the SourcePackages checkouts of
    # every unchanged package are still worth restoring.
    resolved = repo / "cmux.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm"
    (resolved / "Package.resolved").write_text(f'{{"pins": ["{text.strip()}"], "version": 3}}\n')
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", text)


def step_env(source_ref: str, dispatch_ref: str) -> dict[str, str]:
    """Evaluate the step's own `env:` block for one dispatch.

    Every expression that can carry ref text receives the spelling under test,
    so ref-text keying fails here under any env name the step chooses.
    """
    values = {
        "inputs.ref": source_ref,
        "github.ref_name": dispatch_ref,
        "github.ref": f"refs/heads/{dispatch_ref}",
        "github.head_ref": dispatch_ref,
        "github.event.repository.default_branch": "main",
    }
    env = {}
    for name, raw in (step_named(METADATA_STEP).get("env") or {}).items():
        match = EXPRESSION.fullmatch(str(raw).strip())
        if not match:
            env[name] = str(raw)
            continue
        text = ""
        for operand in match.group(1).split("||"):
            operand = operand.strip()
            assert operand in values, f"{METADATA_STEP}: unmodelled env expression {raw!r}"
            text = values[operand]
            if text:
                break
        env[name] = text
    return env


def cache_metadata(
    repo: Path, source_ref: str, run_id: str, dispatch_ref: str | None = None
) -> dict[str, str]:
    script = step_named(METADATA_STEP)["run"]
    if dispatch_ref is None:
        dispatch_ref = source_ref or "main"
    bin_dir = repo.parent.parent.parent / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "xcodebuild"
    fake.write_text(FAKE_XCODEBUILD)
    fake.chmod(0o755)
    output = repo.parent.parent.parent / f"github-output-{run_id}"
    output.write_text("")
    env = {
        **os.environ,
        **step_env(source_ref, dispatch_ref),
        "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
        "GITHUB_OUTPUT": str(output),
        "GITHUB_WORKSPACE": "/Users/runner/_work/cmux/cmux",
        "GITHUB_RUN_ID": run_id,
        "GITHUB_RUN_ATTEMPT": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
    }
    result = subprocess.run(
        ["bash", "-e", "-c", script],
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    values = {"_stdout": result.stdout}
    for line in output.read_text().splitlines():
        name, _, value = line.partition("=")
        values[name] = value
    return values


def resolved_restore_keys(step_name: str, outputs: dict[str, str]) -> list[str]:
    raw = step_named(step_name)["with"].get("restore-keys", "")
    keys = []
    for line in str(raw).splitlines():
        line = line.strip()
        if not line:
            continue
        match = OUTPUT_REF.match(line)
        assert match, f"{step_name}: restore-key {line!r} is not a cache_meta output"
        keys.append(outputs[match.group(1)])
    return [key for key in keys if key]


def resolved_key(step_name: str, outputs: dict[str, str]) -> str:
    match = OUTPUT_REF.match(str(step_named(step_name)["with"]["key"]).strip())
    assert match, f"{step_name}: key is not a cache_meta output"
    return outputs[match.group(1)]


def restores(step_name: str, outputs: dict[str, str], saved_key: str) -> bool:
    """actions/cache semantics: exact key first, then each restore-key prefix."""
    if resolved_key(step_name, outputs) == saved_key:
        return True
    return any(saved_key.startswith(prefix) for prefix in resolved_restore_keys(step_name, outputs))


def test_every_ref_spelling_of_one_commit_keys_identically() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = make_repo(Path(temp_dir))
        branch = git(repo, "branch", "--show-current")
        full_sha = git(repo, "rev-parse", "HEAD")
        spellings = ["", full_sha[:10], full_sha, branch, f"refs/heads/{branch}"]
        bases = {
            spelling or "<dispatch ref>": cache_metadata(repo, spelling, "100")["derived_data_key_base"]
            for spelling in spellings
        }
        assert len(set(bases.values())) == 1, (
            "DerivedData key must depend on the resolved commit, not the ref text:\n"
            + "\n".join(f"  {name}: {base}" for name, base in bases.items())
        )


def test_later_commit_restores_an_earlier_entry_under_any_ref_text() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = make_repo(Path(temp_dir))
        first_sha = git(repo, "rev-parse", "HEAD")
        earlier = cache_metadata(repo, first_sha[:10], "200")
        commit_change(repo, "let changed = true\n")
        second_sha = git(repo, "rev-parse", "HEAD")
        for spelling in (second_sha, second_sha[:7], "some-other-ephemeral-branch", ""):
            later = cache_metadata(repo, spelling, "201")
            for step, key in (
                ("Restore DerivedData cache", earlier["derived_data_key"]),
                ("Restore SPM SourcePackages cache", earlier["spm_key"]),
            ):
                assert restores(step, later, key), (
                    f"{step}: dispatch ref {spelling or '<dispatch ref>'!r} cannot restore "
                    f"{key!r}; restore-keys were {resolved_restore_keys(step, later)!r}"
                )


def test_generic_fallback_names_no_branch_or_commit() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = make_repo(Path(temp_dir))
        sha = git(repo, "rev-parse", "HEAD")
        outputs = cache_metadata(repo, sha[:10], "300")
        fallback = resolved_restore_keys("Restore DerivedData cache", outputs)[-1]
        branch = git(repo, "branch", "--show-current")
        assert sha not in fallback and sha[:10] not in fallback, fallback
        assert branch.split("/")[0] not in fallback, fallback
        # The path, runner, and Xcode contracts still gate the fallback.
        for part in ("xcode-27.0-27A266a", outputs["workspace_key"], outputs["runner_key"]):
            assert part in fallback, (part, fallback)


def test_off_default_dispatch_warns_that_its_save_is_private() -> None:
    with tempfile.TemporaryDirectory() as temp_dir:
        repo = make_repo(Path(temp_dir))
        sha = git(repo, "rev-parse", "HEAD")
        private = cache_metadata(repo, sha, "400", dispatch_ref="reload-blacksmith/one-call")
        shared = cache_metadata(repo, sha, "401", dispatch_ref="main")
        assert "::notice::" in private["_stdout"], private["_stdout"]
        assert "::notice::" not in shared["_stdout"], shared["_stdout"]


def main() -> int:
    test_every_ref_spelling_of_one_commit_keys_identically()
    test_later_commit_restores_an_earlier_entry_under_any_ref_text()
    test_generic_fallback_names_no_branch_or_commit()
    test_off_default_dispatch_warns_that_its_save_is_private()
    print("PASS: reload-build caches key on the commit and fall back across refs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
