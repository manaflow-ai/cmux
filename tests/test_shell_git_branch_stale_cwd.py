#!/usr/bin/env python3
"""
Regression coverage for stale shell-side git branch payloads after cwd changes.

When a cmux shell leaves a git repository for a non-git directory, an async
reporter still holding the OLD repository path (the background HEAD-watch loop or
a deferred prompt probe) must not repopulate the sidebar branch. The integrations
guard every git-branch payload with ``_cmux_git_report_path_is_active`` so a
report whose target path no longer matches the shell's current cwd is dropped.

Each case drives that guard through the real integration functions: after the
shell has moved to the non-git directory (so the active-cwd marker points there),
a reporter for the old repo path is launched in a *background* subshell -- the
same cross-process shape as the real HEAD-watch -- and must emit nothing, while a
reporter for the current cwd must emit ``clear_git_branch``.

The marker is rewritten with ``noclobber`` enabled so the case also covers the
force-clobber redirect: a plain ``>`` would silently skip the update under
``set -C`` and leave the stale path active. Removing the active-path guard, or
weakening the force-clobber write, from either integration makes its case fail.
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import textwrap
from pathlib import Path


class BoundUnixSocket:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.sock: socket.socket | None = None

    def __enter__(self) -> "BoundUnixSocket":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.bind(str(self.path))
        self.sock.listen(1)
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.sock is not None:
            self.sock.close()
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


def _shell_command(kind: str) -> str:
    # Both cases are symmetric: leave the repo, record the non-git cwd as the
    # active path via the real setter (with noclobber on, so the force-clobber
    # write is exercised), fire a stale background reporter for the old repo path
    # (must be suppressed), then report the current cwd (must clear).
    # preexec/precmd are neutralized so only the functions under test write to
    # the send log.
    if kind == "zsh":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            precmd_functions=()
            preexec_functions=()
            _cmux_send() { print -r -- "$1" >> "$CMUX_TEST_SEND_LOG"; }
            cd "$CMUX_TEST_NONREPO"
            setopt noclobber
            _cmux_set_git_active_pwd "$PWD"
            unsetopt noclobber
            _cmux_report_git_branch_for_path "$CMUX_TEST_REPO" &
            wait
            _cmux_report_git_branch_for_path "$PWD"
            """
        )

    if kind == "bash":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() { printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }
            _cmux_send_bg() { _cmux_send "$1"; }
            cd "$CMUX_TEST_NONREPO"
            set -C
            _cmux_set_git_active_pwd "$PWD"
            set +C
            _cmux_report_git_branch_for_path "$CMUX_TEST_REPO" &
            wait
            _cmux_report_git_branch_for_path "$PWD"
            """
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _read_lines(path: Path) -> list[str]:
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def _run_case(
    base: Path,
    *,
    shell: str,
    shell_args: list[str],
    script: Path,
) -> tuple[int, str]:
    repo = base / shell / "repo"
    nonrepo = base / shell / "nonrepo"
    socket_path = base / shell / "cmux.sock"
    send_log = base / shell / "send.log"
    head_file = repo / ".git" / "HEAD"

    head_file.parent.mkdir(parents=True, exist_ok=True)
    nonrepo.mkdir(parents=True, exist_ok=True)
    head_file.write_text("ref: refs/heads/old-branch\n", encoding="utf-8")

    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_TAB_ID"] = "00000000-0000-0000-0000-000000000001"
    env["CMUX_PANEL_ID"] = "00000000-0000-0000-0000-000000000002"
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_REPO"] = str(repo)
    env["CMUX_TEST_NONREPO"] = str(nonrepo)
    env["CMUX_TEST_SEND_LOG"] = str(send_log)
    # Don't leak an inherited marker path into the integration; let it create its
    # own secure temp marker so the force-clobber write is what's under test.
    env.pop("_CMUX_GIT_ACTIVE_PWD_FILE", None)

    with BoundUnixSocket(socket_path):
        try:
            result = subprocess.run(
                [shell, *shell_args, _shell_command(shell)],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
        except FileNotFoundError:
            return 1, f"{shell}: shell binary not found; cannot exercise integration guard"

    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return result.returncode, f"{shell}: shell failed\n{output}"

    lines = _read_lines(send_log)
    stale_reports = [line for line in lines if line.startswith("report_git_branch ")]
    clear_reports = [line for line in lines if line.startswith("clear_git_branch ")]
    if stale_reports:
        return 1, f"{shell}: stale branch report was emitted after cwd left repo: {lines}"
    if not clear_reports:
        return 1, f"{shell}: expected non-git cwd to emit clear_git_branch: {lines}"
    return 0, f"{shell}: ok"


def _same_repo_shell_command(kind: str) -> str:
    # An in-repo `cd pkg` must NOT suppress a same-repo report. The HEAD watch
    # keeps reporting the preexec watch_pwd (the repo root) while the marker now
    # points at a subdirectory of the same repo; the guard must still allow it so
    # live branch updates survive `cd pkg && long-cmd`.
    if kind == "zsh":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            precmd_functions=()
            preexec_functions=()
            _cmux_send() { print -r -- "$1" >> "$CMUX_TEST_SEND_LOG"; }
            cd "$CMUX_TEST_REPO/pkg"
            _cmux_set_git_active_pwd "$PWD"
            _cmux_report_git_branch_for_path "$CMUX_TEST_REPO"
            """
        )

    if kind == "bash":
        return textwrap.dedent(
            """\
            source "$CMUX_TEST_SCRIPT"
            _cmux_send() { printf '%s\\n' "$1" >> "$CMUX_TEST_SEND_LOG"; }
            _cmux_send_bg() { _cmux_send "$1"; }
            cd "$CMUX_TEST_REPO/pkg"
            _cmux_set_git_active_pwd "$PWD"
            _cmux_report_git_branch_for_path "$CMUX_TEST_REPO"
            """
        )

    raise ValueError(f"Unsupported shell kind: {kind}")


def _run_same_repo_case(
    base: Path,
    *,
    shell: str,
    shell_args: list[str],
    script: Path,
) -> tuple[int, str]:
    repo = base / f"{shell}-samerepo" / "repo"
    socket_path = base / f"{shell}-samerepo" / "cmux.sock"
    send_log = base / f"{shell}-samerepo" / "send.log"
    head_file = repo / ".git" / "HEAD"

    (repo / "pkg").mkdir(parents=True, exist_ok=True)
    head_file.parent.mkdir(parents=True, exist_ok=True)
    head_file.write_text("ref: refs/heads/feature-x\n", encoding="utf-8")

    env = dict(os.environ)
    env["CMUX_SOCKET_PATH"] = str(socket_path)
    env["CMUX_TAB_ID"] = "00000000-0000-0000-0000-000000000001"
    env["CMUX_PANEL_ID"] = "00000000-0000-0000-0000-000000000002"
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_REPO"] = str(repo)
    env["CMUX_TEST_SEND_LOG"] = str(send_log)
    env.pop("_CMUX_GIT_ACTIVE_PWD_FILE", None)

    with BoundUnixSocket(socket_path):
        try:
            result = subprocess.run(
                [shell, *shell_args, _same_repo_shell_command(shell)],
                env=env,
                capture_output=True,
                text=True,
                timeout=20,
            )
        except FileNotFoundError:
            return 1, f"{shell}: shell binary not found; cannot exercise same-repo guard"

    output = (result.stdout or "") + (result.stderr or "")
    if result.returncode != 0:
        return result.returncode, f"{shell}: shell failed\n{output}"

    lines = _read_lines(send_log)
    reports = [line for line in lines if line.startswith("report_git_branch ")]
    if not any("feature-x" in line for line in reports):
        return 1, f"{shell}: in-repo cd suppressed a same-repo branch report (live updates would break): {lines}"
    return 0, f"{shell}: same-repo report survives in-repo cd"


def _run_zsh_chpwd_keeps_watch(base: Path, *, script: Path) -> tuple[int, str]:
    # The zsh chpwd hook must scope the marker to the new cwd WITHOUT tearing down
    # a running HEAD watch -- chpwd fires mid-line for `cd foo && long-cmd`, so
    # stopping the watch there would drop live branch updates during the long
    # step. Stand up a long-lived stand-in watch process, record its pid the way
    # the integration does, change directory (which fires the hook) and assert the
    # process survived.
    nonrepo = base / "zsh-chpwd" / "nonrepo"
    nonrepo.mkdir(parents=True, exist_ok=True)

    command = textwrap.dedent(
        """\
        source "$CMUX_TEST_SCRIPT"
        precmd_functions=()
        preexec_functions=()
        sleep 5 &
        watch_pid=$!
        _CMUX_GIT_HEAD_WATCH_PID=$watch_pid
        cd "$CMUX_TEST_NONREPO"
        if kill -0 "$watch_pid" 2>/dev/null; then print -r -- WATCH_ALIVE; else print -r -- WATCH_DEAD; fi
        kill "$watch_pid" 2>/dev/null || true
        """
    )

    env = dict(os.environ)
    env["CMUX_TEST_SCRIPT"] = str(script)
    env["CMUX_TEST_NONREPO"] = str(nonrepo)
    env.pop("_CMUX_GIT_ACTIVE_PWD_FILE", None)

    try:
        result = subprocess.run(
            ["zsh", "-f", "-c", command],
            env=env,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except FileNotFoundError:
        return 1, "zsh: shell binary not found; cannot exercise chpwd watch behavior"

    output = (result.stdout or "") + (result.stderr or "")
    if "WATCH_ALIVE" not in output:
        return 1, f"zsh: chpwd tore down a running HEAD watch on cd; compound-command live updates would break: {output!r}"
    return 0, "zsh chpwd: keeps the HEAD watch alive"


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cases = [
        ("zsh", ["-f", "-c"], root / "Resources/shell-integration/cmux-zsh-integration.zsh"),
        ("bash", ["--noprofile", "--norc", "-c"], root / "Resources/shell-integration/cmux-bash-integration.bash"),
    ]

    base = Path("/tmp") / f"cmux_shell_git_branch_stale_cwd_{os.getpid()}"
    try:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True, exist_ok=True)

        failures: list[str] = []
        ran = 0
        for shell, shell_args, script in cases:
            if not script.exists():
                failures.append(f"{shell}: integration script missing at {script}")
                continue
            ran += 1
            rc, detail = _run_case(base, shell=shell, shell_args=shell_args, script=script)
            if rc != 0:
                failures.append(detail)
            rc_same, detail_same = _run_same_repo_case(base, shell=shell, shell_args=shell_args, script=script)
            if rc_same != 0:
                failures.append(detail_same)

        # zsh-only: chpwd must keep a running HEAD watch alive so compound commands
        # like `cd foo && long-cmd` still get live branch updates (cases[0] is zsh).
        zsh_script = cases[0][2]
        if zsh_script.exists():
            rc, detail = _run_zsh_chpwd_keeps_watch(base, script=zsh_script)
            if rc != 0:
                failures.append(detail)

        # A green run with zero executed cases would silently stop guarding the
        # fix (e.g. the integration scripts were renamed). Treat it as failure.
        if ran == 0:
            failures.append("no shell integration cases executed - regression coverage is a no-op")

        if failures:
            print("FAIL:")
            for failure in failures:
                print(failure)
            return 1

        print(f"PASS: {ran} shell integration(s) scope git branch reports to the current cwd")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
