# cmux shell completions

Tab-completion for the `cmux` CLI in **bash**, **zsh**, and **fish**.

> **These files are generated. Do not edit them by hand.**
> They are produced by [`scripts/generate-cli-completions.py`](../scripts/generate-cli-completions.py)
> from the `topLevelCommandNames` registry and the `usage()` help text in
> `CLI/CMUXCLI+CommandSuggestions.swift` and `CLI/cmux.swift`.
> `tests/test_cli_completions_contract.py` (run in CI) fails if a command is
> added without regenerating, so completions stay in sync automatically.

## What completes

- All top-level commands (`cmux <Tab>`)
- Per-command flags (`cmux send --<Tab>`)
- First-level subcommands (`cmux auth <Tab>` → `login logout status`)
- Enum flag values (`cmux diff --source <Tab>` → `unstaged staged branch last-turn`)

## Install

### bash

```bash
# one-off for the current shell
source /path/to/cmux/completions/cmux.bash

# persistent: copy into a bash-completion directory, e.g.
cp completions/cmux.bash "$(brew --prefix)/etc/bash_completion.d/cmux"
```

### zsh

```zsh
# put cmux.zsh on your fpath, e.g.
cp completions/cmux.zsh "$(brew --prefix)/share/zsh/site-functions/_cmux"
# then restart zsh (or run: autoload -U compinit && compinit)
```

### fish

```fish
cp completions/cmux.fish ~/.config/fish/completions/cmux.fish
```

## Regenerate

```bash
scripts/generate-cli-completions.py --write
```

By default the generator reads the command registry from
`CLI/CMUXCLI+CommandSuggestions.swift` and the `usage()` heredoc from
`CLI/cmux.swift`, so no built binary is required. To regenerate against a built
binary instead:

```bash
scripts/generate-cli-completions.py --write --cmux-bin /path/to/cmux
```
