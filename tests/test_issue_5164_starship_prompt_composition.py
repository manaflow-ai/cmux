#!/usr/bin/env python3
"""
Regression coverage for https://github.com/manaflow-ai/cmux/issues/5164.

Using Starship as the bash prompt inside a cmux session breaks: Starship's
status line stops updating after the first command. The root cause is the local
macOS bash bootstrap that cmux injects as ``PROMPT_COMMAND`` (see
``Resources/shell-integration/cmux-bash-bootstrap.bash``). The user's startup
files run ``eval "$(starship init bash)"`` *before* the first prompt, which
appends ``starship_precmd`` to ``PROMPT_COMMAND``. If the bootstrap then takes
exclusive ownership of ``PROMPT_COMMAND`` (the old code began with
``unset PROMPT_COMMAND``), ``starship_precmd`` is discarded after running once,
so the prompt freezes.

This test drives the *actual* bootstrap file through real bash with a faithful
Starship stub and asserts that a user-registered ``PROMPT_COMMAND`` hook
survives and keeps running on every prompt. It is deterministic (it models
bash's "evaluate PROMPT_COMMAND before each prompt" loop directly) rather than
relying on a PTY.

It also covers https://github.com/manaflow-ai/cmux/issues/5389: cmux's own
``_cmux_prompt_command`` runs first in ``PROMPT_COMMAND``, so it must hand the
previous command's exit status through unchanged. Otherwise every hook after it
(Starship's ``starship_precmd`` included) sees ``$?`` as 0 and the status module
never shows a failure.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = REPO_ROOT / "Resources/shell-integration/cmux-bash-bootstrap.bash"
INTEGRATION_DIR = REPO_ROOT / "Resources/shell-integration"


def _lean_bootstrap(text: str) -> str:
    """Drop full-line ``#`` comments and blank lines from the bootstrap.

    This mirrors how ``Sources/GhosttyTerminalView.swift`` turns the documented
    bootstrap file into the lean string it exports as ``PROMPT_COMMAND`` (so the
    user never sees a wall of comments in ``$PROMPT_COMMAND``). The two
    implementations must stay in sync.
    """
    kept = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        kept.append(line)
    return "\n".join(kept)

# A faithful-enough stand-in for `starship init bash`: it defines
# starship_precmd (which renders PS1 from `starship prompt`) and appends it to
# PROMPT_COMMAND exactly the way the real starship does for non-bash-preexec
# shells. `starship prompt` emits the cwd plus a monotonic counter so a *stale*
# (no longer re-rendered) prompt is detectable, and the `--status` it was given
# so a clobbered `$?` is detectable.
STARSHIP_STUB = """#!/bin/bash
case "$1" in
  init)
    cat <<'INIT'
STARSHIP_PREEXEC_READY="true"
starship_precmd() {
    local STARSHIP_CMD_STATUS=$?
    PS1="$(starship prompt --status=$STARSHIP_CMD_STATUS)"
    STARSHIP_PREEXEC_READY="true"
}
starship_preexec() { :; }
if [[ "${PROMPT_COMMAND:-}" != *"starship_precmd"* ]]; then
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND+=(starship_precmd)
    else
        PROMPT_COMMAND=${PROMPT_COMMAND:+$PROMPT_COMMAND$'\\n'}"starship_precmd"
    fi
fi
trap 'starship_preexec "$_"' DEBUG
INIT
    ;;
  prompt)
    ctr="$STARSHIP_COUNTER_FILE"
    n=0; [[ -r "$ctr" ]] && n="$(cat "$ctr")"
    n=$((n + 1)); printf '%s' "$n" > "$ctr"
    status="${2#--status=}"
    printf 'SS[cwd=%s n=%s status=%s]$ ' "${PWD##*/}" "$n" "$status"
    ;;
  time)
    printf '0'
    ;;
esac
"""

# Driver: model bash's prompt loop. Inherit the bootstrap as PROMPT_COMMAND (as
# cmux does via the environment), let the user's rc append starship_precmd, then
# render three prompts (with a cd in between) by evaluating PROMPT_COMMAND the
# way bash itself does.
DRIVER = r"""
set +e

# bash inherits the cmux bootstrap as PROMPT_COMMAND from the environment. The
# file already has its doc comments stripped (matching the app's injection).
PROMPT_COMMAND="$(cat "$CMUX_BOOTSTRAP_FILE")"

# The user's startup files run starship init before the first prompt.
if [[ "${CMUX_WITH_STARSHIP:-1}" == "1" ]]; then
    eval "$(starship init bash)"
fi

# Squash newlines so each marker is one line for the test parser.
_emit() { printf '%s<%s>\n' "$1" "${2//$'\n'/<NL>}"; }
_emit PC_AFTER_RC "$PROMPT_COMMAND"

_render() {
    # bash reads PROMPT_COMMAND fresh and executes it before drawing each prompt.
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        local pc; for pc in "${PROMPT_COMMAND[@]}"; do eval "$pc"; done
    else
        eval "$PROMPT_COMMAND"
    fi
}

i=0
while (( i < 3 )); do
    i=$(( i + 1 ))
    (( i == 3 )) && cd "$CMUX_CD_TARGET"
    _render
    _emit "PS1_$i" "$PS1"
    _emit "PC_$i" "$PROMPT_COMMAND"
done
"""


# Driver for issue 5389: render prompts after a succeeding and a failing command
# and record the status each prompt's starship_precmd saw. _render hands the
# caller's `$?` to PROMPT_COMMAND the way bash does before drawing a prompt.
STATUS_DRIVER = r"""
set +e

PROMPT_COMMAND="$(cat "$CMUX_BOOTSTRAP_FILE")"
eval "$(starship init bash)"

_emit() { printf '%s<%s>\n' "$1" "${2//$'\n'/<NL>}"; }
_set_status() { return "$1"; }

_render() {
    local status=$?
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        local pc
        for pc in "${PROMPT_COMMAND[@]}"; do
            _set_status "$status"
            eval "$pc"
            status=$?
        done
    else
        _set_status "$status"
        eval "$PROMPT_COMMAND"
    fi
}

# The first prompt runs the one-shot bootstrap that installs _cmux_prompt_command.
true; _render
_emit PC_READY "$PROMPT_COMMAND"
true; _render; _emit PS1_AFTER_TRUE "$PS1"
false; _render; _emit PS1_AFTER_FALSE "$PS1"
(exit 7); _render; _emit PS1_AFTER_EXIT_7 "$PS1"
"""


def _run_driver(*, with_starship: bool = True, driver: str = DRIVER) -> dict[str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        bin_dir = tmp_path / "bin"
        bin_dir.mkdir()
        starship = bin_dir / "starship"
        starship.write_text(STARSHIP_STUB, encoding="utf-8")
        starship.chmod(0o755)

        cd_target = tmp_path / "cd-target"
        cd_target.mkdir()

        # Inject exactly what the app injects: the bootstrap with doc comments
        # stripped (see _lean_bootstrap / GhosttyTerminalView.swift).
        lean_bootstrap = tmp_path / "bootstrap.bash"
        lean_bootstrap.write_text(
            _lean_bootstrap(BOOTSTRAP.read_text(encoding="utf-8")), encoding="utf-8"
        )

        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("CMUX")
        }
        env.update(
            {
                "LC_ALL": "C",
                "LANG": "C",
                "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}",
                "CMUX_BOOTSTRAP_FILE": str(lean_bootstrap),
                "CMUX_SHELL_INTEGRATION": "1",
                "CMUX_SHELL_INTEGRATION_DIR": str(INTEGRATION_DIR),
                "CMUX_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
                "GHOSTTY_RESOURCES_DIR": "",
                "CMUX_TAB_ID": "tab-test",
                "CMUX_PANEL_ID": "panel-test",
                # No unix socket: _cmux_prompt_command's body early-returns, which
                # keeps this test focused on PROMPT_COMMAND/PS1 composition.
                "CMUX_SOCKET_PATH": "",
                "STARSHIP_COUNTER_FILE": str(tmp_path / "counter"),
                "CMUX_CD_TARGET": str(cd_target),
                "CMUX_WITH_STARSHIP": "1" if with_starship else "0",
            }
        )

        proc = subprocess.run(
            ["/bin/bash", "--noprofile", "--norc", "-c", driver],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if proc.returncode != 0:
            raise AssertionError(
                f"driver bash exited {proc.returncode}\n"
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )

        fields: dict[str, str] = {}
        # Parse line-oriented KEY<...> markers (values are single-line here).
        for line in proc.stdout.splitlines():
            m = re.match(r"^([A-Z0-9_]+)<(.*)>$", line)
            if m:
                fields[m.group(1)] = m.group(2)
        fields["__stdout__"] = proc.stdout
        fields["__stderr__"] = proc.stderr
        return fields


def test_starship_precmd_survives_under_cmux_bash_bootstrap() -> None:
    assert BOOTSTRAP.exists(), f"missing bootstrap file: {BOOTSTRAP}"
    fields = _run_driver()
    debug = (
        f"\n\n--- driver stdout ---\n{fields.get('__stdout__', '')}"
        f"\n--- driver stderr ---\n{fields.get('__stderr__', '')}"
    )

    # Sanity: starship init appended its hook before the first prompt.
    assert "starship_precmd" in fields.get("PC_AFTER_RC", ""), (
        "starship init did not append starship_precmd to PROMPT_COMMAND" + debug
    )

    # cmux must compose, not clobber: after the one-shot bootstrap runs, the
    # user's starship hook must still be present in PROMPT_COMMAND...
    for i in (1, 2, 3):
        pc = fields.get(f"PC_{i}", "")
        assert "starship_precmd" in pc, (
            f"starship_precmd was dropped from PROMPT_COMMAND at prompt {i}; "
            f"cmux took exclusive ownership instead of composing. PROMPT_COMMAND=<{pc}>"
            + debug
        )
        assert "_cmux_prompt_command" in pc, (
            f"cmux's own prompt hook missing from PROMPT_COMMAND at prompt {i}: <{pc}>"
            + debug
        )

    # ...and the rendered prompt must keep updating (starship_precmd actually
    # runs every prompt). A static prompt is the reported symptom: the counter
    # stays at 1 and the cwd never reflects the `cd`.
    ps1_values = [fields.get(f"PS1_{i}", "") for i in (1, 2, 3)]
    assert ps1_values[0] != ps1_values[1] != ps1_values[2], (
        "starship prompt went static across prompts (it stopped re-rendering): "
        f"{ps1_values}" + debug
    )
    assert "n=3" in ps1_values[2], (
        f"starship_precmd did not run on every prompt; final PS1=<{ps1_values[2]}>" + debug
    )
    assert "cwd=cd-target" in ps1_values[2], (
        f"prompt did not pick up the new cwd after cd; final PS1=<{ps1_values[2]}>" + debug
    )


def test_plain_bash_bootstrap_installs_cmux_prompt_command() -> None:
    """No-regression guard: with no user PROMPT_COMMAND hook, the bootstrap must
    still install _cmux_prompt_command (and remove its own marker)."""
    assert BOOTSTRAP.exists(), f"missing bootstrap file: {BOOTSTRAP}"
    fields = _run_driver(with_starship=False)
    debug = (
        f"\n\n--- driver stdout ---\n{fields.get('__stdout__', '')}"
        f"\n--- driver stderr ---\n{fields.get('__stderr__', '')}"
    )
    for i in (1, 2, 3):
        pc = fields.get(f"PC_{i}", "")
        # Assert the observable contract (hook installed, bootstrap removed, no
        # phantom hook) rather than the exact integration-internal string, so this
        # stays green if cmux-bash-integration.bash ever tweaks PROMPT_COMMAND.
        assert "_cmux_prompt_command" in pc, (
            f"plain-bash bootstrap did not install _cmux_prompt_command at prompt {i}: <{pc}>"
            + debug
        )
        assert "__cmux_bash_bootstrap_marker__" not in pc, (
            f"bootstrap marker leaked into PROMPT_COMMAND at prompt {i}: <{pc}>" + debug
        )
        assert "starship_precmd" not in pc, (
            f"unexpected starship hook in plain-bash PROMPT_COMMAND at prompt {i}: <{pc}>"
            + debug
        )


def test_hooks_after_cmux_prompt_command_see_last_exit_status() -> None:
    """Issue 5389: _cmux_prompt_command must not reset `$?` to 0 for the
    PROMPT_COMMAND hooks that run after it (Starship's status module)."""
    assert BOOTSTRAP.exists(), f"missing bootstrap file: {BOOTSTRAP}"
    fields = _run_driver(driver=STATUS_DRIVER)
    debug = (
        f"\n\n--- driver stdout ---\n{fields.get('__stdout__', '')}"
        f"\n--- driver stderr ---\n{fields.get('__stderr__', '')}"
    )

    pc = fields.get("PC_READY", "")
    assert pc.index("_cmux_prompt_command") < pc.index("starship_precmd"), (
        f"expected cmux's hook to run before starship_precmd: <{pc}>" + debug
    )

    expected = {
        "PS1_AFTER_TRUE": "status=0",
        "PS1_AFTER_FALSE": "status=1",
        "PS1_AFTER_EXIT_7": "status=7",
    }
    for key, status in expected.items():
        ps1 = fields.get(key, "")
        assert status in ps1, (
            f"starship_precmd saw the wrong exit status ({key}); expected {status}, "
            f"PS1=<{ps1}>" + debug
        )


if __name__ == "__main__":
    test_starship_precmd_survives_under_cmux_bash_bootstrap()
    test_plain_bash_bootstrap_installs_cmux_prompt_command()
    test_hooks_after_cmux_prompt_command_see_last_exit_status()
    print("PASS: cmux bash bootstrap composes with (and without) user prompt hooks")
