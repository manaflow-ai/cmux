# Shell integration

cmux ships a small shell integration that the terminal loads automatically into
every interactive shell it spawns. It powers several behaviors that feel
"built in" but actually depend on the shell cooperating:

- **New tabs / splits / windows inherit the current working directory.** The
  integration reports the shell's cwd to cmux (OSC 7 / `report_pwd`), and cmux
  uses the last reported directory as the starting directory for the next
  terminal you open.
- **Scrollback is restored after you quit and relaunch.** On a clean quit cmux
  captures each terminal's scrollback; on relaunch the integration replays the
  saved buffer into the new shell (see [issue #2823][2823]).
- **Shell activity state is reported** (`prompt` vs. `command-running`). cmux
  uses this to decide when it is safe to persist scrollback and to show
  accurate close-confirmation prompts.

If the integration does not load, all three quietly stop working: new tabs open
in your home directory, terminal contents are lost across restarts, and cmux
falls back to less reliable heuristics for close confirmation.

## How it loads

The integration files live in the app bundle and are pointed to by the
`CMUX_SHELL_INTEGRATION_DIR` environment variable that cmux sets for every
spawned shell:

- `cmux-bash-integration.bash`
- `cmux-zsh-integration.zsh`

The mechanism differs per shell:

| Shell | How cmux injects the integration |
| --- | --- |
| **bash** | cmux exports a `PROMPT_COMMAND` *bootstrap* (`cmux-bash-bootstrap.bash`, marked with `__cmux_bash_bootstrap_marker__`). On the first prompt the bootstrap sources `cmux-bash-integration.bash`, then installs the real prompt hook by **prepending** to `PROMPT_COMMAND`. |
| **zsh** | cmux injects via `ZDOTDIR` (a wrapper `.zshenv`). It restores your real `ZDOTDIR`, sources your normal startup files, then loads `cmux-zsh-integration.zsh`, which registers hooks with `add-zsh-hook precmd/preexec/chpwd` (additive). |

Both paths are designed to **compose with** your existing prompt setup, not
replace it.

## How it can break

### bash: overwriting `PROMPT_COMMAND` (the common case)

bash's integration rides on `PROMPT_COMMAND`. If your `~/.bashrc` /
`~/.bash_profile` **assigns** `PROMPT_COMMAND` instead of appending to it, you
wipe out cmux's bootstrap and the integration never loads:

```bash
# ❌ Clobbers cmux's bootstrap — integration never loads.
PROMPT_COMMAND='history -a; printf "\033]0;%s\007" "$PWD"'
```

Two safe alternatives:

```bash
# ✅ Append, preserving whatever was already there (including cmux's bootstrap).
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

```bash
# ✅ Or source the integration directly, last, so it composes onto your prompt.
if [ -n "${CMUX_SHELL_INTEGRATION_DIR:-}" ] \
   && [ -r "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash" ]; then
    source "${CMUX_SHELL_INTEGRATION_DIR}/cmux-bash-integration.bash"
fi
```

The direct-source form is the most robust: it survives both a clobbered
`PROMPT_COMMAND` and prompt frameworks (e.g. `bash-git-prompt`) that wrap
`PROMPT_COMMAND` in a way that can defeat the bootstrap marker. The
`CMUX_SHELL_INTEGRATION_DIR` guard means the block is a no-op outside cmux, so
the same dotfile stays safe in other terminals.

### zsh: yes, an analogous risk exists — but it's rarer

zsh does **not** use `PROMPT_COMMAND`, so the bash failure above does not apply.
zsh loads the integration through `ZDOTDIR` and registers prompt hooks with
`add-zsh-hook`, which appends to `precmd_functions` / `preexec_functions`. That
is much harder to clobber by accident. The analogous ways to break it are:

- **Reassigning the hook arrays** in `~/.zshrc` after cmux has loaded, e.g.
  `precmd_functions=(my_hook)` (assignment, not append). Use
  `add-zsh-hook precmd my_hook` or `precmd_functions+=(my_hook)` instead.
- **Overriding `ZDOTDIR`** in a way that prevents cmux's wrapper `.zshenv` from
  running. cmux preserves a user-provided `ZDOTDIR` (`CMUX_ZSH_ZDOTDIR`) and
  restores it, so normal `ZDOTDIR` usage is fine.
- **Explicitly disabling it** with `CMUX_SHELL_INTEGRATION=0`.

So the headline — "PROMPT_COMMAND overriding breaks it" — is bash-specific, but
the underlying principle is shared: **add to the shell's prompt/hook mechanism;
never replace it.**

## Troubleshooting

Open a **fresh** terminal in cmux (existing shells don't re-read your dotfiles),
then check whether the integration loaded:

```bash
# bash
type -t _cmux_restore_scrollback_once   # → "function" when loaded, empty when not

# zsh
typeset -f _cmux_restore_scrollback_once >/dev/null && echo loaded || echo missing
```

If it reports missing/empty, the integration did not load. Re-check your
`PROMPT_COMMAND` (bash) or hook arrays (zsh) using the guidance above, then open
another fresh terminal and re-test. With the integration loaded you should see:

1. A new tab/split inherits the current shell's directory.
2. Terminal contents come back after Cmd-Q + relaunch.

[2823]: https://github.com/manaflow-ai/cmux/issues/2823
