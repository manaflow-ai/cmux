#!/usr/bin/env python3
"""Regression: CLI `new-workspace --cwd` should preload sidebar metadata without focus."""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: list[str]) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return (proc.stdout or "").strip()


def _parse_sidebar_state(text: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        parsed[key.strip()] = value.strip()
    return parsed


def _wait_for_sidebar_git_branch(cli: str, workspace: str, timeout: float = 15.0) -> dict[str, str]:
    deadline = time.time() + timeout
    last_state = ""

    while time.time() < deadline:
        state_text = _run_cli(cli, ["sidebar-state", "--workspace", workspace])
        last_state = state_text
        state = _parse_sidebar_state(state_text)
        raw_branch = state.get("git_branch", "")
        branch = raw_branch.split(" ", 1)[0]
        if branch and branch != "none":
            return state
        time.sleep(0.1)

    raise cmuxError(
        "Timed out waiting for background git metadata on new workspace. "
        f"Last sidebar-state: {last_state!r}"
    )


def _create_git_repo(root: Path) -> tuple[Path, str]:
    repo = root / "repo"
    repo.mkdir(parents=True, exist_ok=True)

    subprocess.run(
        ["git", "-c", "init.defaultBranch=main", "init"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "config", "user.name", "cmux-test"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "config", "user.email", "cmux-test@example.com"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    (repo / "README.md").write_text("issue 915\n", encoding="utf-8")
    subprocess.run(
        ["git", "add", "README.md"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        ["git", "-c", "commit.gpgsign=false", "commit", "-m", "init"],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    branch = subprocess.check_output(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=repo,
        text=True,
    ).strip()
    return repo, branch


def main() -> int:
    cli = _find_cli_binary()
    temp_root = Path(tempfile.mkdtemp(prefix="cmux_issue_915_"))
    created_workspace: str | None = None

    try:
        repo_path, expected_branch = _create_git_repo(temp_root)

        with cmux(SOCKET_PATH) as c:
            baseline_workspace = c.current_workspace()

            created = _run_cli(cli, ["new-workspace", "--cwd", str(repo_path)])
            _must(created.startswith("OK "), f"new-workspace expected OK response, got: {created!r}")
            created_workspace = created.removeprefix("OK ").strip()
            _must(bool(created_workspace), f"new-workspace returned no workspace handle: {created!r}")

            _must(
                c.current_workspace() == baseline_workspace,
                "new-workspace --cwd should preserve selected workspace",
            )

            sidebar_state = _wait_for_sidebar_git_branch(cli, created_workspace)
            _must(
                sidebar_state.get("cwd", "") == str(repo_path),
                f"Expected sidebar cwd={repo_path!r}, got {sidebar_state.get('cwd', '')!r}",
            )

            raw_branch = sidebar_state.get("git_branch", "")
            observed_branch = raw_branch.split(" ", 1)[0]
            _must(
                observed_branch == expected_branch,
                f"Expected sidebar git branch {expected_branch!r}, got {raw_branch!r}",
            )

            _must(
                c.current_workspace() == baseline_workspace,
                "background metadata load should not switch selected workspace",
            )
    finally:
        if created_workspace:
            try:
                _run_cli(cli, ["close-workspace", "--workspace", created_workspace])
            except Exception:
                pass
        shutil.rmtree(temp_root, ignore_errors=True)

    print("PASS: new-workspace --cwd preloads sidebar metadata without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
