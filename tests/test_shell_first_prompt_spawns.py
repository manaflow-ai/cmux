#!/usr/bin/env python3
"""Regression: shell integration must not spawn work for disabled features.

Every new cmux terminal pays for the integration's source and first prompt
before the user can type. With git and PR watching turned off
(CMUX_NO_GIT_WATCH=1, CMUX_NO_PR_WATCH=1) the integrations used to:

- create a `cmux-git-active-pwd.XXXXXX` temp file with `/usr/bin/mktemp` at
  source time, a file only the git watchers read;
- spawn `/bin/rm` for five PR cache files on every prompt, although those files
  only exist while PR watching is on.

zsh also scanned Ghostty's `_ghostty_deferred_init` body once per patched hook
(five full passes) to insert its job-table guards.

The behavior checks at the end keep the enabled paths intact: stale PR cache
files are still removed, the git active-pwd marker is still written when git
watching is on, and every Ghostty hook still receives its guard.
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
import tempfile
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INTEGRATION_DIR = ROOT / "Resources" / "shell-integration"
ZSH_INTEGRATION = INTEGRATION_DIR / "cmux-zsh-integration.zsh"
BASH_INTEGRATION = INTEGRATION_DIR / "cmux-bash-integration.bash"
PR_CACHE_SUFFIXES = ("branch", "repo", "result", "timestamp", "no-pr-branch")
GHOSTTY_HOOKS = (
    "_ghostty_precmd",
    "_ghostty_preexec",
    "_ghostty_zle_line_init",
    "_ghostty_zle_line_finish",
    "_ghostty_zle_keymap_select",
)
DEFERRED_FILLER_LINES = 120


def shell_argv(shell_name: str) -> list[str]:
    if shell_name == "zsh":
        return ["/bin/zsh", "-f", "-c"]
    return ["/bin/bash", "--noprofile", "--norc", "-c"]


def prompt_function(shell_name: str) -> str:
    return "_cmux_precmd" if shell_name == "zsh" else "_cmux_prompt_command"


def xtrace_on(shell_name: str) -> str:
    return "setopt xtrace" if shell_name == "zsh" else "set -x"


def integration_path(shell_name: str) -> Path:
    return ZSH_INTEGRATION if shell_name == "zsh" else BASH_INTEGRATION


def base_environment(
    directory: Path,
    socket_path: Path,
    panel_id: str,
    watch: bool,
) -> dict[str, str]:
    tmpdir = directory / "tmp"
    tmpdir.mkdir(exist_ok=True)
    home = directory / "home"
    home.mkdir(exist_ok=True)
    environment = {
        "CMUX_PANEL_ID": panel_id,
        "CMUX_SHELL_INTEGRATION": "1",
        "CMUX_SOCKET_PATH": str(socket_path),
        "CMUX_TAB_ID": "11111111-1111-1111-1111-111111111111",
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
        "TMPDIR": str(tmpdir),
    }
    if not watch:
        environment["CMUX_NO_GIT_WATCH"] = "1"
        environment["CMUX_NO_PR_WATCH"] = "1"
    return environment


def run(shell_name: str, script: str, environment: dict[str, str], cwd: Path) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        shell_argv(shell_name) + [script],
        env=environment,
        cwd=str(cwd),
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"{shell_name} exited {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr[-4000:]}"
        )
    return result


def active_pwd_files(environment: dict[str, str]) -> list[Path]:
    return sorted(Path(environment["TMPDIR"]).glob("cmux-git-active-pwd.*"))


def trace_mentions_command(trace: str, command: str) -> list[str]:
    hits = []
    for line in trace.splitlines():
        if not line.startswith("+"):
            continue
        body = line.split("> ", 1)[1] if "> " in line else line.lstrip("+ ")
        if body.startswith(command + " ") or body == command:
            hits.append(line)
    return hits


def assert_disabled_features_do_not_spawn(shell_name: str, directory: Path, socket_path: Path) -> list[str]:
    failures: list[str] = []
    case_directory = directory / f"{shell_name}-disabled"
    case_directory.mkdir()
    panel_id = str(uuid.uuid4()).upper()
    environment = base_environment(case_directory, socket_path, panel_id, watch=False)
    prompt = prompt_function(shell_name)
    script = (
        f"{xtrace_on(shell_name)}\n"
        f'source "{integration_path(shell_name)}"\n'
        f"{prompt}\n"
        f"{prompt}\n"
    )
    result = run(shell_name, script, environment, case_directory)

    leaked = active_pwd_files(environment)
    if leaked:
        failures.append(
            f"{shell_name}: created {[p.name for p in leaked]} with CMUX_NO_GIT_WATCH=1"
        )
    for command in ("/bin/rm", "/usr/bin/mktemp"):
        hits = trace_mentions_command(result.stderr, command)
        if hits:
            failures.append(
                f"{shell_name}: spawned {command} on a prompt with git/PR watching off:\n  "
                + "\n  ".join(hits[:6])
            )
    return failures


def assert_stale_pr_cache_is_still_cleared(shell_name: str, directory: Path, socket_path: Path) -> list[str]:
    case_directory = directory / f"{shell_name}-stale-pr-cache"
    case_directory.mkdir()
    panel_id = str(uuid.uuid4()).upper()
    environment = base_environment(case_directory, socket_path, panel_id, watch=False)
    cache_files = [Path(f"/tmp/cmux-pr-cache-{panel_id}.{suffix}") for suffix in PR_CACHE_SUFFIXES]
    try:
        for path in cache_files[:2]:
            path.write_text("stale\n", encoding="utf-8")
        run(
            shell_name,
            f'source "{integration_path(shell_name)}"\n{prompt_function(shell_name)}\n',
            environment,
            case_directory,
        )
        remaining = [path.name for path in cache_files if path.exists()]
        if remaining:
            return [f"{shell_name}: left stale PR cache files behind: {remaining}"]
        return []
    finally:
        for path in cache_files:
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def assert_git_watch_still_records_active_pwd(shell_name: str, directory: Path, socket_path: Path) -> list[str]:
    case_directory = directory / f"{shell_name}-git-watch"
    case_directory.mkdir()
    panel_id = str(uuid.uuid4()).upper()
    environment = base_environment(case_directory, socket_path, panel_id, watch=True)
    workdir = case_directory / "work"
    workdir.mkdir()
    marker_variable = "_CMUX_GIT_ACTIVE_PWD_FILE"
    script = (
        f'source "{integration_path(shell_name)}"\n'
        f'cd "{workdir}"\n'
        f"{prompt_function(shell_name)}\n"
        f'printf "MARKER=%s\\n" "${marker_variable}"\n'
        f'IFS= read -r _cmux_test_recorded < "${marker_variable}" && '
        'printf "RECORDED=%s\\n" "$_cmux_test_recorded"\n'
    )
    result = run(shell_name, script, environment, case_directory)
    match = re.search(r"^MARKER=(.*)$", result.stdout, re.MULTILINE)
    marker = match.group(1) if match else ""
    if not marker:
        return [f"{shell_name}: git watching on, but no active-pwd marker was created"]
    match = re.search(r"^RECORDED=(.*)$", result.stdout, re.MULTILINE)
    if not match:
        return [f"{shell_name}: active-pwd marker {marker} was not readable inside the shell"]
    recorded = match.group(1)
    if os.path.realpath(recorded) != os.path.realpath(workdir):
        return [f"{shell_name}: active-pwd marker recorded {recorded!r}, expected {str(workdir)!r}"]
    return []


def assert_zsh_subshell_cd_does_not_leak_marker(directory: Path, socket_path: Path) -> list[str]:
    """chpwd hooks run in subshells too; `$(cd x && pwd)` in startup files must
    not create a marker that the parent shell never learns about."""
    case_directory = directory / "zsh-subshell-cd"
    case_directory.mkdir()
    environment = base_environment(case_directory, socket_path, str(uuid.uuid4()).upper(), watch=True)
    script = (
        f'source "{ZSH_INTEGRATION}"\n'
        "for i in 1 2 3; do x=$(cd / && pwd); (cd /usr); done\n"
        'print -r -- "PARENT=${_CMUX_GIT_ACTIVE_PWD_FILE}"\n'
        "sleep 0\n"
    )
    run("zsh", script, environment, case_directory)
    leaked = active_pwd_files(environment)
    if leaked:
        return [f"zsh: subshell cd created {[p.name for p in leaked]} before the first prompt"]
    return []


def assert_prompt_survives_err_return(shell_name: str, directory: Path, socket_path: Path) -> list[str]:
    """Outside a repository, resolving HEAD fails; with err_return / set -e the
    prompt hook must still reach its tail (the PR command hint)."""
    case_directory = directory / f"{shell_name}-err-return"
    case_directory.mkdir()
    environment = base_environment(case_directory, socket_path, str(uuid.uuid4()).upper(), watch=True)
    strict = "setopt err_return" if shell_name == "zsh" else ""
    script = (
        f'source "{integration_path(shell_name)}"\n'
        '_cmux_emit_pr_command_hint() { print -r -- "PROMPT_TAIL_REACHED"; }\n'.replace(
            "print -r --", "printf '%s\\n'" if shell_name == "bash" else "print -r --"
        )
        + "cd /\n"
        + f"{strict}\n"
        + f"{prompt_function(shell_name)} || true\n"
    )
    result = run(shell_name, script, environment, case_directory)
    if "PROMPT_TAIL_REACHED" not in result.stdout:
        return [f"{shell_name}: prompt hook stopped early outside a git repository under err_return"]
    return []


def synthetic_ghostty_deferred_init() -> str:
    lines = ["_ghostty_deferred_init() {"]
    for index in range(DEFERRED_FILLER_LINES):
        lines.append(f"  typeset -g _cmux_test_filler_{index}={index}")
    for hook in GHOSTTY_HOOKS:
        lines.append(f"  {hook}() {{")
        lines.append(f"    typeset -g _cmux_test_{hook}_ran=1")
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def assert_zsh_job_table_guard_scans_once(directory: Path) -> list[str]:
    case_directory = directory / "zsh-job-table-guard"
    case_directory.mkdir()
    definition = case_directory / "deferred.zsh"
    definition.write_text(synthetic_ghostty_deferred_init(), encoding="utf-8")
    environment = {
        "HOME": str(case_directory),
        "PATH": "/usr/bin:/bin",
        "TERM": "xterm-256color",
        "TMPDIR": str(case_directory),
        "CMUX_NO_GIT_WATCH": "1",
        "CMUX_NO_PR_WATCH": "1",
    }
    script = (
        f'source "{definition}"\n'
        f'source "{ZSH_INTEGRATION}"\n'
        "unfunction _ghostty_deferred_init\n"
        f'source "{definition}"\n'
        "setopt xtrace\n"
        "_cmux_patch_ghostty_job_table_guard\n"
        "unsetopt xtrace\n"
        "print -r -- \"${functions[_ghostty_deferred_init]}\"\n"
    )
    result = run("zsh", script, environment, case_directory)
    failures: list[str] = []
    for hook in GHOSTTY_HOOKS:
        guard = f"__cmux_{hook}_saved_status"
        if guard not in result.stdout:
            failures.append(f"zsh: job-table guard for {hook} was not inserted")
    body_lines = DEFERRED_FILLER_LINES + 3 * len(GHOSTTY_HOOKS)
    appended = sum(
        1
        for line in result.stderr.splitlines()
        if "_cmux_insert_job_table_guard_after_declaration" in line and "> patched_lines+=" in line
    )
    # One pass appends each body line once plus the inserted guard lines.
    budget = body_lines + 3 * len(GHOSTTY_HOOKS) + 5
    if appended > budget:
        failures.append(
            f"zsh: job-table guard patch walked {appended} lines for a {body_lines}-line "
            f"_ghostty_deferred_init (budget {budget}); it rescans the body once per hook"
        )
    return failures


def main() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-first-prompt-", dir="/tmp") as temp:
        directory = Path(temp)
        socket_path = directory / "cmux.sock"
        # Bound but not listening: `-S` passes, and background sends fail fast.
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(socket_path))
        try:
            for shell_name in ("zsh", "bash"):
                failures += assert_disabled_features_do_not_spawn(shell_name, directory, socket_path)
                failures += assert_stale_pr_cache_is_still_cleared(shell_name, directory, socket_path)
                failures += assert_git_watch_still_records_active_pwd(shell_name, directory, socket_path)
            failures += assert_zsh_job_table_guard_scans_once(directory)
            failures += assert_zsh_subshell_cd_does_not_leak_marker(directory, socket_path)
            failures += assert_prompt_survives_err_return("zsh", directory, socket_path)
        finally:
            listener.close()

    if failures:
        print("FAIL:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("PASS: disabled git/PR watching spawns nothing, enabled paths still work")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
