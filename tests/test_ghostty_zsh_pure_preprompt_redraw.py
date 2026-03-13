#!/usr/bin/env python3
"""
Regression: Ghostty's zsh integration must not leave stale Pure-style preprompt
lines behind after an async redraw.

Pure does not render its top path/git line as a static multiline PS1. Instead,
it rewrites PROMPT with a special newline sequence and later calls
`zle .reset-prompt` when async git info arrives. Plain zsh redraws that cleanly.
The Ghostty integration currently leaves stale copies of the old top line behind.

This test uses a minimal Pure-like prompt implementation as a control:
- plain zsh must redraw without stale preprompt lines
- Ghostty-integrated zsh must match that behavior
"""

from __future__ import annotations

import os
import pty
import re
import select
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


_MINIMAL_PURE_ZSHRC = r"""
setopt promptsubst nopromptcr nopromptsp
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
  CMUX_TOP='%F{4}%~%f %F{242}main%f%F{218}*%f %F{6}⇣⇡%f'
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

_ANSI_RE = re.compile(rb"\x1b\][^\x07]*\x07|\x1b\[[0-9;?]*[ -/]*[@-~]|\r")


def _capture_session(
    *,
    use_ghostty: bool,
    wrapper_dir: Path,
    resources_dir: Path,
    workdir: Path,
    zsh_path: str,
) -> str:
    base = Path(tempfile.mkdtemp(prefix="cmux_ghostty_pure_preprompt_"))
    try:
        home = base / "home"
        home.mkdir(parents=True, exist_ok=True)
        (home / ".zshrc").write_text(_MINIMAL_PURE_ZSHRC, encoding="utf-8")

        env = dict(os.environ)
        env["HOME"] = str(home)
        env["TERM"] = "xterm-256color"
        env.pop("GHOSTTY_SHELL_FEATURES", None)
        env.pop("GHOSTTY_BIN_DIR", None)
        if use_ghostty:
            env["ZDOTDIR"] = str(wrapper_dir)
            env["GHOSTTY_ZSH_ZDOTDIR"] = str(home)
            env["GHOSTTY_RESOURCES_DIR"] = str(resources_dir)
        else:
            env["ZDOTDIR"] = str(home)
            env.pop("GHOSTTY_ZSH_ZDOTDIR", None)
            env.pop("GHOSTTY_RESOURCES_DIR", None)

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

        cleaned = _ANSI_RE.sub(b"", bytes(output)).decode("utf-8", errors="replace")
        return cleaned
    finally:
        shutil.rmtree(base, ignore_errors=True)


def _stale_preprompt_lines(cleaned: str, path_line: str, async_line: str) -> tuple[int, int]:
    marker = cleaned.find(async_line)
    if marker == -1:
        return (-1, -1)

    tail = cleaned[marker + len(async_line) :]
    return (tail.count(path_line), tail.count(async_line))


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    wrapper_dir = root / "ghostty" / "src" / "shell-integration" / "zsh"
    resources_dir = root / "ghostty" / "src"
    workdir = root

    if not (wrapper_dir / ".zshenv").exists():
        print(f"SKIP: missing Ghostty zsh wrapper at {wrapper_dir}")
        return 0
    zsh_path = shutil.which("zsh")
    if zsh_path is None:
        print("SKIP: zsh not installed")
        return 0

    path_line = f"{workdir}\n"
    async_line = f"{workdir} main* ⇣⇡"

    plain = _capture_session(
        use_ghostty=False,
        wrapper_dir=wrapper_dir,
        resources_dir=resources_dir,
        workdir=workdir,
        zsh_path=zsh_path,
    )
    ghostty = _capture_session(
        use_ghostty=True,
        wrapper_dir=wrapper_dir,
        resources_dir=resources_dir,
        workdir=workdir,
        zsh_path=zsh_path,
    )

    plain_stale, plain_async = _stale_preprompt_lines(plain, path_line, async_line)
    ghostty_stale, ghostty_async = _stale_preprompt_lines(ghostty, path_line, async_line)

    if plain_stale < 0:
        print("FAIL: plain zsh control never rendered the async preprompt line")
        return 1
    if ghostty_stale < 0:
        print("FAIL: Ghostty zsh integration never rendered the async preprompt line")
        return 1

    if plain_stale != 0:
        print(f"FAIL: plain zsh control left stale preprompt lines behind ({plain_stale})")
        return 1

    if ghostty_stale != plain_stale:
        print(
            "FAIL: Ghostty zsh integration left stale preprompt lines behind "
            f"(ghostty={ghostty_stale}, plain={plain_stale}, async_renders={ghostty_async})"
        )
        return 1

    print("PASS: Ghostty zsh integration redraws Pure-style preprompts without stale lines")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
