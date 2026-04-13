#!/usr/bin/env python3
"""
Regression: cmux's bundled Ghostty zsh integration must preserve a user-selected
portable TERM across SSH hops.

When the active local TERM is xterm-256color, the SSH wrapper should keep that
TERM for remote sessions and skip the xterm-ghostty terminfo bootstrap. This
avoids deeper nested hops inheriting xterm-ghostty on hosts that do not also
run Ghostty shell integration.
"""

from __future__ import annotations

import os
import pty
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

PROMPT_MARKER = b"cmux-ready> "
WRAPPED_SSH_ARG_FRAGMENTS = (
    "-o SetEnv COLORTERM=truecolor",
    "-o SendEnv TERM_PROGRAM TERM_PROGRAM_VERSION",
)


def _write_executable(path: Path, content: str) -> None:
    """Create an executable helper script for the shell harness."""
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def _write_prompting_zshrc(path: Path, extra_content: str = "") -> None:
    """Write a minimal prompting zshrc for PTY-driven interactive runs."""
    path.write_text(
        (
            """
setopt prompt_percent
PROMPT='cmux-ready> '
RPROMPT=''
"""
            + extra_content
        ).lstrip(),
        encoding="utf-8",
    )


def _recorded_lines(path: Path) -> list[str]:
    """Return non-empty lines recorded by the fake helper binaries."""
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding="utf-8").splitlines() if line]


def _timeout_output_text(data: str | bytes | None) -> str:
    """Normalize TimeoutExpired stdio payloads into text."""
    if data is None:
        return ""
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return data


def _run_prompted_shell(
    *, root: Path, zsh_path: str, env: dict[str, str], shell_command: str
) -> tuple[bool, str]:
    """Drive an interactive prompted shell and run the requested command once."""
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [zsh_path, "-d", "-i"],
        cwd=str(root),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)

    output = bytearray()
    saw_prompt = False
    ssh_sent = False
    exit_sent = False
    timed_out = False
    try:
        deadline = time.time() + 8
        while time.time() < deadline:
            if proc.poll() is not None:
                break

            readable, _, _ = select.select([master], [], [], 0.2)
            if master in readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

            prompt_count = output.count(PROMPT_MARKER)
            if prompt_count >= 1:
                saw_prompt = True

            if saw_prompt and not ssh_sent:
                os.write(master, f"{shell_command}\n".encode("utf-8"))
                ssh_sent = True
                continue

            if ssh_sent and not exit_sent and Path(env["CMUX_TEST_TERM_OUT"]).exists() and prompt_count >= 2:
                os.write(master, b"exit\n")
                exit_sent = True
                continue
        else:
            timed_out = True
    finally:
        try:
            if proc.poll() is None:
                if not exit_sent:
                    try:
                        os.write(master, b"exit\n")
                    except OSError:
                        pass
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        finally:
            os.close(master)

    combined = output.decode("utf-8", errors="replace").strip()
    if timed_out:
        return False, f"interactive zsh session timed out: {combined}"
    if proc.returncode != 0:
        return False, f"interactive zsh exited non-zero rc={proc.returncode}: {combined}"
    if not saw_prompt:
        return False, f"did not observe first interactive prompt: {combined}"
    if not ssh_sent:
        return False, f"did not invoke ssh after first interactive prompt: {combined}"

    return True, combined


def _run_exec_string_shell(
    *,
    root: Path,
    zsh_path: str,
    env: dict[str, str],
    command_string: str,
    login_shell: bool,
) -> tuple[bool, str]:
    """Run a one-shot interactive exec-string shell and return combined output."""
    argv = [zsh_path, "-d"]
    if login_shell:
        argv.append("-l")
    argv.extend(["-i", "-c", command_string])

    try:
        result = subprocess.run(
            argv,
            cwd=str(root),
            env=env,
            capture_output=True,
            text=True,
            timeout=8,
        )
    except subprocess.TimeoutExpired as exc:
        combined = (_timeout_output_text(exc.stdout) + _timeout_output_text(exc.stderr)).strip()
        return False, f"zsh exec-string session timed out after 8s: {combined}"

    combined = ((result.stdout or "") + (result.stderr or "")).strip()
    if result.returncode != 0:
        return False, f"zsh exited non-zero rc={result.returncode}: {combined}"
    return True, combined


def _run_case(
    *,
    root: Path,
    wrapper_dir: Path,
    zsh_path: str,
    features: str,
    term: str,
    expect_term: str,
    expect_infocmp: bool,
    expect_wrapper: bool,
    expected_target: str,
    mode: str = "prompted",
    shell_command: str = "ssh nested.example",
    login_shell: bool = False,
    zprofile_extra_content: str = "",
    zshrc_extra_content: str = "",
    ssh_g_output: str = "user nested\nhostname nested.example\n",
    ssh_g_status: int = 0,
    infocmp_status: int = 1,
    infocmp_stdout: str = "",
    expect_bootstrap: bool = False,
    expected_bootstrap_fragments: tuple[str, ...] = (),
) -> tuple[bool, str]:
    """Run one SSH-wrapper scenario and validate the recorded behavior."""
    base = Path(tempfile.mkdtemp(prefix="cmux_issue_2458_"))
    try:
        home = base / "home"
        orig = base / "orig-zdotdir"
        fakebin = base / "fakebin"
        term_out = base / "term.txt"
        args_out = base / "ssh-args.txt"
        infocmp_out = base / "infocmp.txt"

        home.mkdir(parents=True, exist_ok=True)
        orig.mkdir(parents=True, exist_ok=True)
        fakebin.mkdir(parents=True, exist_ok=True)

        (orig / ".zshenv").write_text("", encoding="utf-8")
        (orig / ".zprofile").write_text(
            f'export PATH="$CMUX_TEST_FAKEBIN:$PATH"\n{zprofile_extra_content}',
            encoding="utf-8",
        )
        _write_prompting_zshrc(orig / ".zshrc", extra_content=zshrc_extra_content)

        _write_executable(
            fakebin / "ssh",
            """#!/bin/sh
if [ "$1" = "-G" ]; then
  printf '%b' "${CMUX_TEST_SSH_G_OUTPUT:-user nested\\nhostname nested.example\\n}"
  exit "${CMUX_TEST_SSH_G_STATUS:-0}"
fi
printf '%s\\n' "${TERM:-}" >> "$CMUX_TEST_TERM_OUT"
printf '%s\\n' "$*" >> "$CMUX_TEST_SSH_ARGS_OUT"
exit 0
""",
        )
        _write_executable(
            fakebin / "infocmp",
            """#!/bin/sh
printf 'called\\n' >> "$CMUX_TEST_INFOCMP_OUT"
printf '%s' "${CMUX_TEST_INFOCMP_STDOUT:-}"
exit "${CMUX_TEST_INFOCMP_STATUS:-1}"
""",
        )

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["TERM"] = term
        env["PATH"] = f"{fakebin}:{env.get('PATH', '')}"
        env["TERM_PROGRAM"] = "Ghostty"
        env["TERM_PROGRAM_VERSION"] = "1.0"
        env["ZDOTDIR"] = str(wrapper_dir)
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(orig)
        env["GHOSTTY_RESOURCES_DIR"] = str(root / "ghostty" / "src")
        env["CMUX_SHELL_INTEGRATION_DIR"] = str(wrapper_dir)
        env["CMUX_LOAD_GHOSTTY_ZSH_INTEGRATION"] = "1"
        env["CMUX_SHELL_INTEGRATION"] = "0"
        env["GHOSTTY_SHELL_FEATURES"] = features
        env["CMUX_TEST_TERM_OUT"] = str(term_out)
        env["CMUX_TEST_SSH_ARGS_OUT"] = str(args_out)
        env["CMUX_TEST_INFOCMP_OUT"] = str(infocmp_out)
        env["CMUX_TEST_INFOCMP_STATUS"] = str(infocmp_status)
        env["CMUX_TEST_INFOCMP_STDOUT"] = infocmp_stdout
        env["CMUX_TEST_SSH_G_OUTPUT"] = ssh_g_output
        env["CMUX_TEST_SSH_G_STATUS"] = str(ssh_g_status)
        env["CMUX_TEST_FAKEBIN"] = str(fakebin)
        env.pop("GHOSTTY_BIN_DIR", None)
        env.pop("TERMINFO", None)

        if mode == "prompted":
            ok, detail = _run_prompted_shell(root=root, zsh_path=zsh_path, env=env, shell_command=shell_command)
        elif mode == "exec_string":
            ok, detail = _run_exec_string_shell(
                root=root,
                zsh_path=zsh_path,
                env=env,
                command_string=shell_command,
                login_shell=login_shell,
            )
        else:
            return False, f"unsupported test mode: {mode}"

        if not ok:
            return False, detail

        recorded_terms = _recorded_lines(term_out)
        recorded_args = _recorded_lines(args_out)
        if not recorded_terms:
            return False, f"fake ssh did not record TERM: {detail}"
        if not recorded_args:
            return False, f"fake ssh did not record argv: {detail}"

        recorded_term = recorded_terms[-1]
        if recorded_term != expect_term:
            return False, f"expected remote TERM={expect_term!r}, got {recorded_term!r}"

        recorded_args_line = recorded_args[-1]
        if expected_target not in recorded_args_line:
            return False, f"expected ssh target {expected_target!r} in {recorded_args_line!r}"

        bootstrap_args_line = next((line for line in recorded_args if "ControlMaster=yes" in line), None)
        if expect_bootstrap and bootstrap_args_line is None:
            return False, f"expected a bootstrap ssh invocation, recorded args were {recorded_args!r}"
        if not expect_bootstrap and bootstrap_args_line is not None:
            return False, f"unexpected bootstrap ssh invocation {bootstrap_args_line!r}"
        if bootstrap_args_line is not None:
            for fragment in expected_bootstrap_fragments:
                if fragment not in bootstrap_args_line:
                    return False, f"missing bootstrap fragment {fragment!r} in {bootstrap_args_line!r}"

        for fragment in WRAPPED_SSH_ARG_FRAGMENTS:
            fragment_present = fragment in recorded_args_line
            if expect_wrapper and not fragment_present:
                return False, f"missing expected wrapped ssh args fragment {fragment!r} in {recorded_args_line!r}"
            if not expect_wrapper and fragment_present:
                return False, f"unexpected wrapped ssh args fragment {fragment!r} in {recorded_args_line!r}"

        infocmp_called = infocmp_out.exists()
        if infocmp_called != expect_infocmp:
            return False, f"expected infocmp_called={expect_infocmp}, got {infocmp_called}"

        return True, ""
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main() -> int:
    """Exercise prompted and exec-string SSH wrapper flows under zsh."""
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "Resources" / "shell-integration"
    ghostty_integration = root / "ghostty" / "src" / "shell-integration" / "zsh" / "ghostty-integration"
    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing wrapper .zshenv at {wrapper_dir}")
        return 0
    if not ghostty_integration.exists():
        print(f"SKIP: missing Ghostty zsh integration at {ghostty_integration}")
        return 0

    zsh_path = shutil.which("zsh")
    if zsh_path is None:
        print("SKIP: zsh not installed")
        return 0

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-256color",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
    )
    if not ok:
        print(f"FAIL: portable TERM case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
    )
    if not ok:
        print(f"FAIL: ssh-env-only fallback case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="tmux-256color",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
    )
    if not ok:
        print(f"FAIL: tmux/custom TERM normalization case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=True,
        expect_wrapper=True,
        expected_target="nested.example",
    )
    if not ok:
        print(f"FAIL: xterm-ghostty fallback case failed: {detail}")
        return 1
    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-ghostty",
        expect_infocmp=True,
        expect_wrapper=True,
        expected_target="nested.example",
        expect_bootstrap=True,
        expected_bootstrap_fragments=("-p 2222", "-J jumpbox", "-F /tmp/cmux-fake-ssh-config"),
        shell_command="ssh -p 2222 -J jumpbox -F /tmp/cmux-fake-ssh-config nested.example",
        infocmp_status=0,
        infocmp_stdout="xterm-ghostty|Ghostty terminal\\n",
    )
    if not ok:
        print(f"FAIL: bootstrap ssh option preservation case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
        shell_command="ssh -fN nested.example",
        infocmp_status=0,
        infocmp_stdout="xterm-ghostty|Ghostty terminal\\n",
        expect_bootstrap=False,
    )
    if not ok:
        print(f"FAIL: bundled no-run ssh flags case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
        shell_command="ssh -oBogusOption=yes nested.example",
        ssh_g_output="Bad configuration option: bogusoption\n",
        ssh_g_status=255,
        expect_bootstrap=False,
    )
    if not ok:
        print(f"FAIL: ssh -G failure fallback case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-ghostty",
        expect_infocmp=False,
        expect_wrapper=False,
        expected_target="nested.example",
        zshrc_extra_content="""
export GHOSTTY_SHELL_FEATURES='title,cursor'
""",
    )
    if not ok:
        print(f"FAIL: user opt-out case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env",
        term="xterm-ghostty",
        expect_term="xterm-256color",
        expect_infocmp=False,
        expect_wrapper=True,
        expected_target="nested.example",
        mode="exec_string",
        zshrc_extra_content="""
TRAPDEBUG() { :; }
setopt no_debug_before_cmd
ssh() { command ssh "$@"; }
""",
    )
    if not ok:
        print(f"FAIL: exec-string wrapper case failed: {detail}")
        return 1

    ok, detail = _run_case(
        root=root,
        wrapper_dir=wrapper_dir,
        zsh_path=zsh_path,
        features="ssh-env,ssh-terminfo",
        term="xterm-ghostty",
        expect_term="xterm-ghostty",
        expect_infocmp=False,
        expect_wrapper=False,
        expected_target="bootstrap-host",
        mode="exec_string",
        shell_command="true",
        login_shell=True,
        zprofile_extra_content="""
ssh bootstrap-host
""",
        zshrc_extra_content="""
export GHOSTTY_SHELL_FEATURES='title,cursor'
""",
    )
    if not ok:
        print(f"FAIL: login-shell startup opt-out case failed: {detail}")
        return 1

    print(
        "PASS: Ghostty zsh SSH wrapper preserves portable TERM, falls back from xterm-ghostty, "
        "and respects prompted, exec-string, and login-shell opt-out startup flows"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
