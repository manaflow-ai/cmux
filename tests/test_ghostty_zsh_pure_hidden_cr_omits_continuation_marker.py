#!/usr/bin/env python3
"""
Regression: Pure-style prompts that use `\n%{\r%}` must not get an explicit
OSC 133 continuation marker injected between the hidden carriage return and the
visible prompt line.

Ghostty already marks the next row as a prompt continuation when a newline
arrives while prompt mode is active. Injecting `OSC 133;P;k=s` after Pure's
hidden carriage return creates a second prompt-start boundary inside the same
logical prompt redraw, which matches the Theo/Prezto Pure duplication repro.
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


PROMPT_START = b"\x1b]133;P;k=i\x07"
PROMPT_CONTINUATION = b"\x1b]133;P;k=s\x07"

_PURE_HIDDEN_CR_ZSHRC = r"""
setopt prompt_percent promptsubst nopromptcr nopromptsp
prompt_newline=$'\n%{\r%}'

typeset -g CMUX_TOP='%F{4}%~%f'
typeset -g CMUX_LAST_PROMPT=''
typeset -gi CMUX_ASYNC_DONE=0
typeset -g CMUX_ASYNC_FD=''

cmux_render_prompt() {
  local cleaned_ps1=$PROMPT
  if [[ $PROMPT = *$prompt_newline* ]]; then
    cleaned_ps1=${PROMPT##*${prompt_newline}}
  fi

  PROMPT="${CMUX_TOP}${prompt_newline}${cleaned_ps1:-%F{5}❯%f }"

  local expanded_prompt="${(S%%)PROMPT}"
  if [[ ${1:-} == precmd ]]; then
    print
  elif [[ $CMUX_LAST_PROMPT != $expanded_prompt ]]; then
    zle && zle .reset-prompt
  fi
  typeset -g CMUX_LAST_PROMPT=$expanded_prompt
}

cmux_async_ready() {
  emulate -L zsh
  local fd="${1:-$CMUX_ASYNC_FD}"
  if [[ -n $fd ]]; then
    zle -F "$fd"
    exec {fd}<&-
  fi
  CMUX_ASYNC_FD=''

  (( CMUX_ASYNC_DONE )) && return
  CMUX_ASYNC_DONE=1
  CMUX_TOP='%F{4}%~%f %F{242}main%f%F{218}*%f'
  cmux_render_prompt async
}

precmd() {
  CMUX_ASYNC_DONE=0
  cmux_render_prompt precmd
}

cmux_line_init() {
  if (( !CMUX_ASYNC_DONE )) && [[ -z $CMUX_ASYNC_FD ]]; then
    exec {CMUX_ASYNC_FD}< <(
      sleep 0.05
      printf 'ready\n'
    )
    zle -F "$CMUX_ASYNC_FD" cmux_async_ready
  fi
}

zle -N zle-line-init cmux_line_init
PROMPT='%F{5}❯%f '
""".lstrip()


def _capture_session(env: dict[str, str], zsh_path: str, workdir: Path) -> bytes:
    master, slave = pty.openpty()
    proc = subprocess.Popen(
        [zsh_path, "-d", "-i"],
        cwd=str(workdir),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=env,
        close_fds=True,
    )
    os.close(slave)

    output = bytearray()
    start = time.time()
    phase = 0
    try:
        while time.time() - start < 4.5:
            readable, _, _ = select.select([master], [], [], 0.2)
            if master in readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                if not chunk:
                    break
                output.extend(chunk)

            elapsed = time.time() - start
            if phase == 0 and elapsed > 1.2:
                os.write(master, b"\n")
                phase = 1
            elif phase == 1 and elapsed > 2.8:
                os.write(master, b"exit\n")
                phase = 2
    finally:
        try:
            proc.wait(timeout=5)
        finally:
            os.close(master)

    return bytes(output)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "ghostty" / "src" / "shell-integration" / "zsh"
    resources_dir = root / "ghostty" / "src"

    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing Ghostty zsh wrapper at {wrapper_dir}")
        return 0

    zsh_path = shutil.which("zsh")
    if zsh_path is None:
        print("SKIP: zsh not installed")
        return 0

    base = Path(tempfile.mkdtemp(prefix="cmux_ghostty_pure_hidden_cr_"))
    try:
        home = base / "home"
        home.mkdir(parents=True, exist_ok=True)
        (home / ".zshrc").write_text(_PURE_HIDDEN_CR_ZSHRC, encoding="utf-8")

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["TERM"] = "xterm-256color"
        env["ZDOTDIR"] = str(wrapper_dir)
        env["GHOSTTY_ZSH_ZDOTDIR"] = str(home)
        env["GHOSTTY_RESOURCES_DIR"] = str(resources_dir)
        env.pop("GHOSTTY_SHELL_FEATURES", None)
        env.pop("GHOSTTY_BIN_DIR", None)

        output = _capture_session(env, zsh_path, root)

        prompt_start_count = output.count(PROMPT_START)
        prompt_continuation_count = output.count(PROMPT_CONTINUATION)

        if prompt_start_count < 2:
            print(
                "FAIL: expected Ghostty zsh integration to emit prompt-start markers "
                f"for the Pure-style prompt, saw {prompt_start_count}"
            )
            return 1

        if prompt_continuation_count != 0:
            print(
                "FAIL: hidden-CR Pure-style prompt emitted explicit continuation markers "
                f"({prompt_continuation_count})"
            )
            return 1

        print("PASS: Pure-style hidden-CR prompt redraws without explicit continuation markers")
        return 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
