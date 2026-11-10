#!/usr/bin/env python3
"""
Regression coverage for bash job-control noise from cmux shell integration.

The bug only appears in an interactive bash attached to a tty. A normal
subprocess cannot reproduce the prompt-time "[N] Done" notifications, so this
test drives bash through a PTY.
"""

from __future__ import annotations

import os
import pty
import re
import select
import shlex
import shutil
import signal
import socket
import tempfile
import time
from pathlib import Path


PROMPT = "__CMUX_TEST_PROMPT__ "
JOB_DONE_RE = re.compile(r"^\[[0-9]+\][^\n\r]*\bDone\b", re.MULTILINE)


class InteractiveBash:
    def __init__(self, env: dict[str, str]) -> None:
        self.env = env
        self.pid: int | None = None
        self.fd: int | None = None
        self.output = bytearray()

    def __enter__(self) -> "InteractiveBash":
        pid, fd = pty.fork()
        if pid == 0:
            os.execvpe("bash", ["bash", "--noprofile", "--norc", "-i"], self.env)
        self.pid = pid
        self.fd = fd
        self.run(f"PS1='{PROMPT}'")
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        if self.fd is not None:
            try:
                os.write(self.fd, b"exit\n")
                self._read_until(b"exit", timeout=1)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
        if self.pid is not None:
            try:
                os.killpg(os.getpgid(self.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.waitpid(self.pid, 0)
            except ChildProcessError:
                pass

    def run(self, command: str, timeout: float = 5) -> None:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        self._drain()
        os.write(self.fd, command.encode("utf-8") + b"\n")
        chunk = self._read_until(PROMPT.encode("utf-8"), timeout=timeout)
        if PROMPT.encode("utf-8") not in chunk:
            raise AssertionError(
                f"timed out waiting for prompt after {command!r}\n\n"
                f"Captured output:\n{self.text}"
            )

    def _read_until(self, marker: bytes, *, timeout: float) -> bytes:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        deadline = time.time() + timeout
        captured = bytearray()
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if self.fd not in ready:
                continue
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                break
            if not data:
                break
            captured.extend(data)
            self.output.extend(data)
            if marker in captured:
                break
        return bytes(captured)

    def _drain(self) -> None:
        if self.fd is None:
            raise RuntimeError("bash PTY is not open")
        while True:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if self.fd not in ready:
                return
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                return
            if not data:
                return
            self.output.extend(data)

    @property
    def text(self) -> str:
        return self.output.decode("utf-8", errors="replace")


def _remove_tree_after_reporters_exit(path: str) -> None:
    """Remove the scratch tree once the integration's background reporters stop.

    ``set -m`` puts the reporters the integration forks into their own process
    groups, so killing the shell's group leaves them briefly alive and still
    writing into this tree; a plain ``TemporaryDirectory`` cleanup then races
    them and fails with ``ENOTEMPTY`` on shared CI runners.
    """
    deadline = time.monotonic() + 5
    while True:
        try:
            shutil.rmtree(path)
            return
        except OSError:
            if time.monotonic() >= deadline:
                shutil.rmtree(path, ignore_errors=True)
                return
            time.sleep(0.1)


def test_bash_integration_does_not_emit_done_notifications() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    integration_script = repo_root / "Resources/shell-integration/cmux-bash-integration.bash"

    tmp = tempfile.mkdtemp()
    try:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        repo_path = tmp_path / "repo"
        git_dir = repo_path / ".git"
        bin_path = tmp_path / "bin"
        gh_stub = bin_path / "gh"
        send_log = tmp_path / "send.log"

        git_dir.mkdir(parents=True)
        (git_dir / "HEAD").write_text("ref: refs/heads/feature/bash-done\n", encoding="utf-8")
        bin_path.mkdir()
        gh_stub.write_text('#!/bin/sh\n[ "$3" != "456" ]\n', encoding="utf-8")
        gh_stub.chmod(0o755)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX")
            }
            env.update(
                {
                    "LC_ALL": "C",
                    "LANG": "C",
                    "PATH": f"{bin_path}{os.pathsep}{os.environ.get('PATH', '')}",
                    "HISTFILE": "/dev/null",
                }
            )

            with InteractiveBash(env) as bash:
                bash.run("set -m")
                bash.run("HISTCONTROL=ignorespace")
                bash.run(f"export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run("export CMUX_TAB_ID=tab-test CMUX_PANEL_ID=panel-test")
                # Seed an old command without running it. Loading the integration
                # must not mistake history from an earlier session for new work.
                bash.run(" history -s 'gh pr merge 987'")
                bash.run(
                    f" source {shlex.quote(str(integration_script))}; "
                    "_cmux_send() { printf '%s\\n' \"$1\" >> "
                    f"{shlex.quote(str(send_log))}; }}"
                )
                bash.run("_CMUX_TTY_NAME=ttys-test")
                bash.run(f"cd {shlex.quote(str(repo_path))}")

                # The next prompts exercise the shell-state, port-kick, TTY,
                # CWD, PR-action, and git-branch reporters.
                bash.run("gh pr merge 123")
                bash.run(" true")
                bash.run("gh pr close 456")
                bash.run(" true")
                # Re-enabling reporting must not replay commands run while disabled.
                for flag in ("CMUX_NO_PR_WATCH", "CMUX_NO_GIT_WATCH"):
                    bash.run(f"export {flag}=1")
                    bash.run("gh pr merge 999")
                    bash.run("gh pr close 456")
                    bash.run(f" unset {flag}")
                bash.run("unset CMUX_SOCKET_PATH")
                bash.run("gh pr close 456")
                bash.run(f" export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run("gh pr merge 123")
                bash.run(" true")
                bash.run("cd ..")
                bash.run("true")
                bash.run("sleep 0.2")
                bash.run("echo __CMUX_DONE_CHECK__")

                sent_payloads = (
                    send_log.read_text(encoding="utf-8")
                    if send_log.exists()
                    else ""
                )
                expected_payload = (
                    'report_pr_action merge --tab=tab-test '
                    '--panel=panel-test --target="123"'
                )
                actual_payloads = [
                    line for line in sent_payloads.splitlines()
                    if line.startswith("report_pr_action ")
                ]
                if actual_payloads != [expected_payload, expected_payload]:
                    raise AssertionError(
                        "bash integration did not emit exactly one PR action "
                        "payload per successful gh command.\n\n"
                        f"Expected payload twice:\n{expected_payload}\n\n"
                        f"Observed payloads:\n{actual_payloads}\n\n"
                        f"Sent payloads:\n{sent_payloads}\n\n"
                        f"Full PTY output:\n{bash.text}"
                    )

                done_lines = JOB_DONE_RE.findall(bash.text)
                if done_lines:
                    matching_lines = [
                        line
                        for line in bash.text.splitlines()
                        if JOB_DONE_RE.search(line)
                    ]
                    raise AssertionError(
                        "bash integration emitted job completion notifications:\n"
                        + "\n".join(matching_lines)
                        + "\n\nFull PTY output:\n"
                        + bash.text
                    )
        finally:
            sock.close()
    finally:
        _remove_tree_after_reporters_exit(tmp)


def test_bash_prompt_history_ignores_other_terminals_history() -> None:
    """Bash before 4.4 reads PR commands from history at the prompt.

    With shared history (`history -a; history -n` in PROMPT_COMMAND), another
    terminal's `gh pr merge` becomes this shell's newest history entry. It must
    not be reported as this terminal's action; only commands typed here count.
    CMUX_BASH_TEST_PROMPT_HISTORY=1 selects the pre-4.4 path on a newer bash.
    """
    repo_root = Path(__file__).resolve().parents[1]
    integration_script = repo_root / "Resources/shell-integration/cmux-bash-integration.bash"

    tmp = tempfile.mkdtemp()
    try:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        repo_path = tmp_path / "repo"
        bin_path = tmp_path / "bin"
        gh_stub = bin_path / "gh"
        send_log = tmp_path / "send.log"
        shared_history = tmp_path / "shared_history"
        # Bash 3.2's `history -n` reads nothing new from a file that started empty.
        shared_history.write_text("echo seed\n", encoding="utf-8")

        (repo_path / ".git").mkdir(parents=True)
        (repo_path / ".git" / "HEAD").write_text("ref: refs/heads/feature/x\n", encoding="utf-8")
        bin_path.mkdir()
        gh_stub.write_text('#!/bin/sh\n[ "$3" != "456" ]\n', encoding="utf-8")
        gh_stub.chmod(0o755)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX")
            }
            env.update(
                {
                    "LC_ALL": "C",
                    "LANG": "C",
                    "PATH": f"{bin_path}{os.pathsep}{os.environ.get('PATH', '')}",
                    "HISTFILE": str(shared_history),
                    "CMUX_BASH_TEST_PROMPT_HISTORY": "1",
                }
            )

            def other_terminal_runs(command: str) -> None:
                with shared_history.open("a", encoding="utf-8") as handle:
                    handle.write(command + "\n")

            with InteractiveBash(env) as bash:
                bash.run("HISTCONTROL=ignorespace; shopt -s histappend")
                bash.run(f" export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run(" export CMUX_TAB_ID=tab-test CMUX_PANEL_ID=panel-test")
                bash.run(f" cd {shlex.quote(str(repo_path))}")
                bash.run(
                    f" source {shlex.quote(str(integration_script))}; "
                    "_cmux_send() { printf '%s\\n' \"$1\" >> "
                    f"{shlex.quote(str(send_log))}; }}; "
                    '_cmux_send_bg() { _cmux_send "$1"; }'
                )
                # A user hook appended after cmux's, as .bashrc setups do.
                bash.run(' PROMPT_COMMAND="$PROMPT_COMMAND;history -a;history -n"')
                # The prompt after a PROMPT_COMMAND change reports nothing.
                bash.run("true")
                bash.run("gh pr merge 7")
                bash.run("true")

                other_terminal_runs("gh pr merge")
                bash.run("echo b")
                bash.run("")
                bash.run(" true")
                bash.run("gh pr close 456")
                bash.run("")

                # A hook appended later with a newline, the way starship does.
                bash.run(' PROMPT_COMMAND="$PROMPT_COMMAND"$\'\\n\'"history -a; history -n"')
                bash.run("true")
                other_terminal_runs("gh pr close 5")
                bash.run("echo b")
                bash.run("")
                bash.run("gh pr merge 9")
                bash.run("")

                # A hook ending in a comment must not swallow cmux's mark.
                bash.run(' PROMPT_COMMAND="$PROMPT_COMMAND"$\'\\n\'"history -a; history -n # sync"')
                bash.run("true")
                other_terminal_runs("gh pr merge")
                bash.run("echo b")
                bash.run("")
                bash.run("gh pr merge 11")
                bash.run("")

                # Clearing history restarts bash's numbering at 1; the next
                # command must still count as new. Drop the shared-history
                # hooks first, since `history -n` would refill the list.
                bash.run(' PROMPT_COMMAND="${PROMPT_COMMAND%%;history -a*}"')
                bash.run("true")
                bash.run("history -c")
                bash.run("gh pr merge 13")
                bash.run("")
                bash.run("false")
                bash.run("echo status=$?")

            sent_payloads = send_log.read_text(encoding="utf-8") if send_log.exists() else ""
            actual_payloads = [
                line for line in sent_payloads.splitlines()
                if line.startswith("report_pr_action ")
            ]
            expected_payloads = [
                f'report_pr_action merge --tab=tab-test --panel=panel-test --target="{target}"'
                for target in ("7", "9", "11", "13")
            ]
            if actual_payloads != expected_payloads:
                raise AssertionError(
                    "prompt-history PR reporting must report only this terminal's "
                    "successful gh commands.\n\n"
                    f"Expected:\n{expected_payloads}\n\n"
                    f"Observed:\n{actual_payloads}\n\n"
                    f"Full PTY output:\n{bash.text}"
                )
            if "status=1" not in bash.text:
                raise AssertionError(
                    "prompt hooks must preserve the previous command's exit status.\n\n"
                    f"Full PTY output:\n{bash.text}"
                )
        finally:
            sock.close()
    finally:
        _remove_tree_after_reporters_exit(tmp)


def _run_prompt_history_session(setup: list[str], steps: list[str]) -> tuple[list[str], list[str], str]:
    """Runs bash on the pre-4.4 prompt-history path with shared history.

    Each step is a command line typed into this shell, or `other:<command>`
    for a command another terminal appends to the shared history file. Returns
    the PR-action payloads, the lines the setup's preexec logged, and the PTY.
    """
    repo_root = Path(__file__).resolve().parents[1]
    integration_script = repo_root / "Resources/shell-integration/cmux-bash-integration.bash"

    tmp = tempfile.mkdtemp()
    try:
        tmp_path = Path(tmp)
        socket_path = tmp_path / "cmux.sock"
        repo_path = tmp_path / "repo"
        bin_path = tmp_path / "bin"
        gh_stub = bin_path / "gh"
        send_log = tmp_path / "send.log"
        preexec_log = tmp_path / "preexec.log"
        shared_history = tmp_path / "shared_history"
        # Bash 3.2's `history -n` reads nothing new from a file that started empty.
        shared_history.write_text("echo seed\n", encoding="utf-8")

        (repo_path / ".git").mkdir(parents=True)
        (repo_path / ".git" / "HEAD").write_text("ref: refs/heads/feature/x\n", encoding="utf-8")
        bin_path.mkdir()
        gh_stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        gh_stub.chmod(0o755)

        state_tmp = tmp_path / "state"
        state_tmp.mkdir()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(socket_path))
            sock.listen(1)

            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("CMUX")
            }
            env.update(
                {
                    "LC_ALL": "C",
                    "LANG": "C",
                    "PATH": f"{bin_path}{os.pathsep}{os.environ.get('PATH', '')}",
                    "HISTFILE": str(shared_history),
                    "CMUX_BASH_TEST_PROMPT_HISTORY": "1",
                    "PREEXEC_LOG": str(preexec_log),
                    "TMPDIR": str(state_tmp),
                }
            )

            with InteractiveBash(env) as bash:
                bash.run("HISTCONTROL=ignorespace; shopt -s histappend")
                bash.run(f" export CMUX_SOCKET_PATH={shlex.quote(str(socket_path))}")
                bash.run(" export CMUX_TAB_ID=tab-test CMUX_PANEL_ID=panel-test")
                bash.run(f" cd {shlex.quote(str(repo_path))}")
                bash.run(
                    f" source {shlex.quote(str(integration_script))}; "
                    "_cmux_send() { printf '%s\\n' \"$1\" >> "
                    f"{shlex.quote(str(send_log))}; }}; "
                    '_cmux_send_bg() { _cmux_send "$1"; }'
                )
                for command in setup:
                    bash.run(command)
                for step in steps:
                    if step.startswith("other:"):
                        with shared_history.open("a", encoding="utf-8") as handle:
                            handle.write(step[len("other:"):] + "\n")
                    else:
                        bash.run(step)
            text = bash.text
        finally:
            sock.close()

        # The history scratch file must not keep command text (which can hold
        # secrets) once the shell exits.
        scratches = list(state_tmp.glob("cmux-bash-*/history-entry-*"))
        if not scratches:
            raise AssertionError(f"no history scratch file under {state_tmp}")
        for scratch in scratches:
            if scratch.read_text(encoding="utf-8", errors="replace"):
                raise AssertionError(
                    f"history scratch file {scratch} kept command text after the shell exited"
                )
        sent = send_log.read_text(encoding="utf-8") if send_log.exists() else ""
        payloads = [line for line in sent.splitlines() if line.startswith("report_pr_action ")]
        preexec = preexec_log.read_text(encoding="utf-8").splitlines() if preexec_log.exists() else []
        return payloads, preexec, text
    finally:
        _remove_tree_after_reporters_exit(tmp)


def _merge_payloads(*targets: str) -> list[str]:
    return [
        f'report_pr_action merge --tab=tab-test --panel=panel-test --target="{target}"'
        for target in targets
    ]


def test_bash_prompt_history_with_bash_preexec() -> None:
    """bash-preexec keeps `__bp_interactive_mode` last to arm its DEBUG trap.

    cmux's mark must not run after it (preexec would fire on the mark and skip
    the user's command), a history sync in precmd_functions must not get
    another terminal's command reported.
    """
    bash_preexec = (
        ' __bp_precmd_invoke_cmd() { local s=$? f; for f in "${precmd_functions[@]}"; do '
        '(exit $s); "$f"; done; }; '
        "__bp_interactive_mode() { _bp_armed=1; }; "
        "_sync() { history -a; history -n; }; precmd_functions=(_sync); "
        "trap '[[ -n \"${_bp_armed:-}\" ]] && { _bp_armed=; "
        "printf \"%s\\n\" \"$BASH_COMMAND\" >> \"$PREEXEC_LOG\"; }' DEBUG; "
        'PROMPT_COMMAND="__bp_precmd_invoke_cmd"$\'\\n\'"$PROMPT_COMMAND"$\'\\n\'"__bp_interactive_mode"'
    )
    payloads, preexec, text = _run_prompt_history_session(
        [bash_preexec, "true"],
        [
            "echo one", "echo two", "echo three", "gh pr merge 21",
            "other:gh pr merge", "echo four", "", "other:gh pr merge 77", "",
            "gh pr merge 22", "echo five",
        ],
    )
    for expected in ("echo three", "echo four", "gh pr merge 22", "echo five"):
        if expected not in preexec or "_cmux_bash_pr_history_mark" in preexec:
            raise AssertionError(
                "cmux's prompt hooks must leave bash-preexec's `__bp_interactive_mode` "
                f"last so preexec fires for every command; missing {expected!r}.\n\n"
                f"Preexec saw:\n{preexec}\n\nFull PTY output:\n{text}"
            )
    if payloads != _merge_payloads("21", "22"):
        raise AssertionError(
            "with bash-preexec, only this terminal's gh commands may be reported.\n\n"
            f"Observed:\n{payloads}\n\nFull PTY output:\n{text}"
        )


def test_bash_prompt_history_untrusted_prompts_report_nothing() -> None:
    """Prompts where another terminal's command could look like ours report nothing.

    That covers a history sync hook placed ahead of cmux's (an empty Enter or
    an ignored command adds no entry, so the next entry is another
    terminal's), and the prompts right after a hook is appended, before
    cmux's mark is trusted again.
    """
    payloads, _, text = _run_prompt_history_session(
        [' PROMPT_COMMAND="history -a; history -n"$\'\\n\'"$PROMPT_COMMAND"'],
        [
            "echo a", "echo b", "other:gh pr merge 77", "",
            "other:gh pr merge 78", " echo hidden", "other:gh pr close 79", "echo b",
        ],
    )
    if payloads:
        raise AssertionError(
            "a history hook ahead of cmux's must not get another terminal's command "
            f"reported.\n\nObserved:\n{payloads}\n\nFull PTY output:\n{text}"
        )

    payloads, _, text = _run_prompt_history_session(
        [' PROMPT_COMMAND="$PROMPT_COMMAND;history -a;history -n"'],
        ["other:gh pr merge 77", "echo a", "echo b", "gh pr merge 3", ""],
    )
    if payloads != _merge_payloads("3"):
        raise AssertionError(
            "another terminal's command written during the first commands must not "
            f"be reported; this shell's own must be.\n\nObserved:\n{payloads}\n\n"
            f"Full PTY output:\n{text}"
        )


def test_bash_prompt_history_keeps_starship_timer() -> None:
    """starship (without bash-preexec) arms its DEBUG-trap timer last in PROMPT_COMMAND.

    The same session checks that HISTCONTROL=erasedups, which keeps the newest
    history number in place for a repeated command, does not hide a repeat.
    """
    starship = (
        " starship_precmd() { STARSHIP_PREEXEC_READY=true; }; "
        "trap '[[ \"${STARSHIP_PREEXEC_READY:-}\" == true ]] && { STARSHIP_PREEXEC_READY=false; "
        "printf \"%s\\n\" \"$BASH_COMMAND\" >> \"$PREEXEC_LOG\"; }' DEBUG; "
        'PROMPT_COMMAND="$PROMPT_COMMAND"$\'\\n\'"starship_precmd"'
    )
    payloads, preexec, text = _run_prompt_history_session(
        [starship, "true"],
        ["echo a", "echo b", "gh pr merge 4", "echo c",
         " HISTCONTROL=erasedups", "gh pr merge 4", "echo d"],
    )
    if "_cmux_bash_pr_history_mark" in preexec or "echo c" not in preexec:
        raise AssertionError(
            "cmux's mark must not fire starship's command timer.\n\n"
            f"Timer started on:\n{preexec}\n\nFull PTY output:\n{text}"
        )
    if payloads != _merge_payloads("4", "4"):
        raise AssertionError(
            "starship setups still report PR commands, including a repeat under "
            f"erasedups.\n\nObserved:\n{payloads}\n\n"
            f"Full PTY output:\n{text}"
        )

    # Real starship sets PROMPT_COMMAND=starship_precmd and evaluates the hooks
    # it found earlier from STARSHIP_PROMPT_COMMAND inside starship_precmd,
    # before it re-arms its timer; cmux's entry ends up ahead of it.
    real_starship = (
        " starship_precmd() { local s=$?; (exit $s); "
        'if [[ -n "${STARSHIP_PROMPT_COMMAND-}" ]]; then eval "$STARSHIP_PROMPT_COMMAND"; fi; '
        "STARSHIP_PREEXEC_READY=true; }; "
        "trap '[[ \"${STARSHIP_PREEXEC_READY:-}\" == true ]] && { STARSHIP_PREEXEC_READY=false; "
        "printf \"%s\\n\" \"$BASH_COMMAND\" >> \"$PREEXEC_LOG\"; }' DEBUG; "
        'STARSHIP_PROMPT_COMMAND="history -a; history -n"; '
        'PROMPT_COMMAND="_cmux_prompt_command;starship_precmd"'
    )
    payloads, preexec, text = _run_prompt_history_session(
        [real_starship, "true"],
        ["echo a", "echo b", "gh pr merge 4", "other:gh pr merge", "echo c", "",
         "gh pr merge 5", "echo d"],
    )
    if "_cmux_bash_pr_history_mark" in preexec or "echo d" not in preexec:
        raise AssertionError(
            "cmux's mark must not fire starship's command timer when starship keeps "
            f"the other hooks in STARSHIP_PROMPT_COMMAND.\n\nTimer started on:\n{preexec}"
            f"\n\nFull PTY output:\n{text}"
        )
    if payloads != _merge_payloads("4", "5"):
        raise AssertionError(
            "with starship's STARSHIP_PROMPT_COMMAND layout, only this terminal's gh "
            f"commands may be reported.\n\nObserved:\n{payloads}\n\nFull PTY output:\n{text}"
        )


if __name__ == "__main__":
    test_bash_integration_does_not_emit_done_notifications()
    print("PASS: no bash job completion notifications observed")
    test_bash_prompt_history_ignores_other_terminals_history()
    print("PASS: prompt-history PR reporting ignores other terminals' history")
    test_bash_prompt_history_with_bash_preexec()
    print("PASS: prompt-history PR reporting keeps bash-preexec working")
    test_bash_prompt_history_untrusted_prompts_report_nothing()
    print("PASS: prompt-history PR reporting skips untrusted prompts")
    test_bash_prompt_history_keeps_starship_timer()
    print("PASS: prompt-history PR reporting keeps starship's timer")
