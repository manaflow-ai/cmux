#!/usr/bin/env python3
"""
Regression coverage for the shell-side sidebar PR probe in two repo shapes the
old probe could not handle:

1) git's reftable ref backend. With `extensions.refStorage=reftable`, git keeps
   `$GIT_DIR/HEAD` as a fixed placeholder ("ref: refs/heads/.invalid") and stores
   the live ref state in `reftable/tables.list`. The probe read HEAD as text (no
   git, for speed), so it saw ".invalid" and probed `gh pr view .invalid` -> no
   PR. The branch detector now falls back to `git symbolic-ref` only for that
   placeholder, and the HEAD-watch signature folds in `reftable/tables.list` so
   branch switches are still detected (the placeholder alone never changes).

2) repos whose `origin` is not a github.com remote (e.g. a push/proxy mirror)
   but which DO have another github.com remote. The probe only read
   `[remote "origin"]`, so it derived no `--repo` slug. It now scans every
   remote and picks the best github.com URL (upstream > origin > other,
   alphabetical), mirroring the app-side GitMetadataService ordering.

Each case drives the real integration functions in both zsh and bash. The
reftable cases are hermetic: they write the placeholder HEAD and a fake
`reftable/tables.list` directly and stub `git` on PATH, so they don't depend on
the test machine's git supporting reftable.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELLS = [
    ("zsh", ["-f", "-c"], ROOT / "Resources/shell-integration/cmux-zsh-integration.zsh"),
    ("bash", ["--noprofile", "--norc", "-c"], ROOT / "Resources/shell-integration/cmux-bash-integration.bash"),
]
INVALID_HEAD = "ref: refs/heads/.invalid\n"


def _write_executable(path: Path, contents: str) -> None:
    path.write_text(contents, encoding="utf-8")
    path.chmod(0o755)


def _git_stub() -> str:
    # Only `symbolic-ref --quiet --short HEAD` is expected; record every call so
    # the loose-ref fast path can assert git was never spawned.
    return textwrap.dedent(
        """\
        #!/bin/sh
        printf '%s\\n' "$*" >> "$CMUX_TEST_GIT_LOG"
        if [ "$1" = "-C" ]; then shift 2; fi
        if [ "$1" = "symbolic-ref" ]; then
          printf '%s\\n' "$CMUX_TEST_BRANCH"
          exit 0
        fi
        exit 0
        """
    )


def _run(shell: str, shell_args: list[str], script: Path, body: str, env: dict[str, str]) -> tuple[int, str, str]:
    command = f'source "$CMUX_TEST_SCRIPT"\n{body}'
    full_env = dict(os.environ)
    full_env.update(env)
    full_env["CMUX_TEST_SCRIPT"] = str(script)
    result = subprocess.run(
        [shell, *shell_args, command],
        env=full_env,
        capture_output=True,
        text=True,
        timeout=10,
    )
    return result.returncode, result.stdout, result.stderr


def _reftable_branch_case(base: Path, shell: str, shell_args: list[str], script: Path) -> list[str]:
    failures: list[str] = []
    work = base / shell / "reftable-branch"
    bindir = work / "bin"
    bindir.mkdir(parents=True, exist_ok=True)
    _write_executable(bindir / "git", _git_stub())
    git_log = work / "git.log"

    # reftable repo: placeholder HEAD + a reftable/ stack list.
    rt = work / "reftable-repo"
    (rt / ".git" / "reftable").mkdir(parents=True, exist_ok=True)
    (rt / ".git" / "HEAD").write_text(INVALID_HEAD, encoding="utf-8")
    (rt / ".git" / "reftable" / "tables.list").write_text("0x01-0x02-aaaa.ref\n", encoding="utf-8")

    env = {
        "PATH": f"{bindir}:{os.environ.get('PATH', '')}",
        "CMUX_TEST_GIT_LOG": str(git_log),
        "CMUX_TEST_BRANCH": "feature/reftable-branch",
    }
    rc, out, err = _run(shell, shell_args, script, f'_cmux_git_branch_for_path "{rt}"', env)
    if rc != 0 or out.strip() != "feature/reftable-branch":
        failures.append(f"{shell}: reftable branch fallback expected feature/reftable-branch, got rc={rc} out={out!r} err={err!r}")
    git_log_text = git_log.read_text(encoding="utf-8") if git_log.exists() else ""
    if "symbolic-ref" not in git_log_text:
        failures.append(f"{shell}: reftable branch detection did not invoke git symbolic-ref")

    # loose-ref repo: must resolve from HEAD text WITHOUT spawning git.
    loose = work / "loose-repo"
    (loose / ".git").mkdir(parents=True, exist_ok=True)
    (loose / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
    loose_log = work / "git-loose.log"
    env2 = dict(env)
    env2["CMUX_TEST_GIT_LOG"] = str(loose_log)
    rc, out, err = _run(shell, shell_args, script, f'_cmux_git_branch_for_path "{loose}"', env2)
    if rc != 0 or out.strip() != "main":
        failures.append(f"{shell}: loose-ref branch expected main, got rc={rc} out={out!r} err={err!r}")
    if loose_log.exists() and "symbolic-ref" in loose_log.read_text(encoding="utf-8"):
        failures.append(f"{shell}: loose-ref branch detection spawned git (should stay on the fast text path)")
    return failures


def _reftable_signature_case(base: Path, shell: str, shell_args: list[str], script: Path) -> list[str]:
    failures: list[str] = []
    work = base / shell / "reftable-signature"
    gitdir = work / ".git"
    (gitdir / "reftable").mkdir(parents=True, exist_ok=True)
    (gitdir / "HEAD").write_text(INVALID_HEAD, encoding="utf-8")
    tables = gitdir / "reftable" / "tables.list"
    head = gitdir / "HEAD"

    tables.write_text("0x01-0x02-aaaa.ref\n", encoding="utf-8")
    rc, sig1, err = _run(shell, shell_args, script, f'_cmux_git_head_signature "{head}"', {})
    if rc != 0 or not sig1.strip().startswith("reftable:"):
        failures.append(f"{shell}: reftable signature should be reftable-derived, got rc={rc} out={sig1!r} err={err!r}")

    # A branch switch rewrites tables.list; the signature must change so the
    # HEAD watch refreshes the badge (the placeholder HEAD never changes).
    tables.write_text("0x01-0x02-aaaa.ref\n0x03-0x03-bbbb.ref\n", encoding="utf-8")
    rc, sig2, _ = _run(shell, shell_args, script, f'_cmux_git_head_signature "{head}"', {})
    if sig1.strip() == sig2.strip():
        failures.append(f"{shell}: reftable signature did not change after tables.list changed ({sig1.strip()!r})")

    # Loose-ref HEAD keeps its plain text signature.
    loose_head = work / "loose-HEAD"
    loose_head.write_text("ref: refs/heads/main\n", encoding="utf-8")
    rc, sig3, _ = _run(shell, shell_args, script, f'_cmux_git_head_signature "{loose_head}"', {})
    if sig3.strip() != "ref: refs/heads/main":
        failures.append(f"{shell}: loose-ref signature expected the HEAD line, got {sig3!r}")
    return failures


def _multi_remote_slug_case(base: Path, shell: str, shell_args: list[str], script: Path) -> list[str]:
    failures: list[str] = []
    cases = {
        # origin is a non-github proxy; a separate github remote must be used.
        "non-github-origin": (
            textwrap.dedent(
                """\
                [remote "origin"]
                    url = https://gitstream.example.com/acme/widgets.git
                [remote "github"]
                    url = https://github.com/acme/widgets.git
                """
            ),
            "acme/widgets",
        ),
        # upstream outranks origin.
        "upstream-beats-origin": (
            textwrap.dedent(
                """\
                [remote "origin"]
                    url = git@github.com:me/fork.git
                [remote "upstream"]
                    url = https://github.com/acme/widgets.git
                """
            ),
            "acme/widgets",
        ),
        # origin outranks an arbitrarily named remote.
        "origin-beats-other": (
            textwrap.dedent(
                """\
                [remote "zzz"]
                    url = https://github.com/other/repo.git
                [remote "origin"]
                    url = https://github.com/acme/widgets.git
                """
            ),
            "acme/widgets",
        ),
    }
    for name, (config, expected) in cases.items():
        repo = base / shell / "slug" / name / "repo"
        (repo / ".git").mkdir(parents=True, exist_ok=True)
        (repo / ".git" / "HEAD").write_text("ref: refs/heads/main\n", encoding="utf-8")
        (repo / ".git" / "config").write_text(config, encoding="utf-8")
        rc, out, err = _run(shell, shell_args, script, f'_cmux_github_repo_slug_for_path "{repo}"', {})
        if rc != 0 or out.strip() != expected:
            failures.append(f"{shell}: slug {name} expected {expected}, got rc={rc} out={out!r} err={err!r}")
    return failures


def main() -> int:
    base = Path("/tmp") / f"cmux_pr_probe_reftable_multi_remote_{os.getpid()}"
    failures: list[str] = []
    ran = 0
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)
        for shell, shell_args, script in SHELLS:
            if not script.exists():
                failures.append(f"{shell}: integration script missing at {script}")
                continue
            if shutil.which(shell) is None:
                print(f"SKIP: {shell} not available")
                continue
            ran += 1
            failures += _reftable_branch_case(base, shell, shell_args, script)
            failures += _reftable_signature_case(base, shell, shell_args, script)
            failures += _multi_remote_slug_case(base, shell, shell_args, script)

        if ran == 0:
            failures.append("no shell integration cases executed - regression coverage is a no-op")

        if failures:
            print("FAIL:")
            for failure in failures:
                print(f"  {failure}")
            return 1
        print(f"PASS: {ran} shell integration(s) handle reftable HEAD and multi-remote GitHub slug detection")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
