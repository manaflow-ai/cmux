# Deep links

cmux supports focus-only links for existing UI objects:

```text
cmux://workspace/<workspace-uuid>
cmux://workspace/<workspace-uuid>/pane/<pane-uuid>
cmux://workspace/<workspace-uuid>/surface/<surface-uuid>
```

Focus links do not execute commands and do not require confirmation. Workspace
and surface links use restart-stable identifiers when copied from cmux. Pane
identifiers are valid only for the current app session.

`cmux://run` runs one shell command in a newly created local terminal after the
user reviews and approves the complete execution plan. `command` and `cwd` are
required. `cwd` must resolve to an existing directory. cmux passes `command`
unchanged inside a guarded script, so shell operators and agent CLI arguments
work. Ghostty owns process construction and launches the fixed
`/bin/zsh -dflc` adapter through its embedded shell contract. Existing-surface
commands, input, environment variables, tmux startup commands, and workspace
environment variables are not inherited by reviewed-command terminals. The
zsh adapter disables user-controlled startup files before checking the
directory identity. The root-owned macOS `/etc/zshenv` remains a trusted system
boundary.

Create a workspace:

```text
cmux://run?command=claude%20--resume&cwd=/Users/me/project
```

Create a tab in an existing pane:

```text
cmux://run?command=codex&cwd=/Users/me/project&placement=surface&workspace=<workspace-uuid>&pane=<pane-uuid>
```

Create a split next to an existing surface:

```text
cmux://run?command=npm%20test&cwd=/Users/me/project&placement=pane&workspace=<workspace-uuid>&surface=<surface-uuid>&direction=right
```

`placement` accepts only these parameter combinations:

- `workspace` is the default and rejects `workspace`, `pane`, `surface`, and
  `direction` target parameters.
- `surface` requires `workspace` plus exactly one `pane` or `surface` anchor.
  It rejects `direction`.
- `pane` requires `workspace`, exactly one `pane` or `surface` anchor, and a
  `direction` value of `left`, `right`, `up`, or `down`.

cmux rejects duplicate or unknown parameters, ambiguous targets, hidden control
characters, remote workspaces, missing directories, concurrent run requests,
and targets that change after approval. Approval binds the directory's
filesystem identity as well as its canonical path. The shell checks that
identity after entering the directory and before running the command, so a
same-path directory replacement fails closed. Canonical-path and filesystem-
identity lookup run in one bounded verifier process, and cmux retains its only
verifier permit until that exact process exits. A stalled filesystem cannot
leave approval handling blocked indefinitely. A run link cannot reuse a terminal,
inject environment variables or input, run without focus, or receive a callback.
The user must approve every command. cmux does not remember approval for raw
shell commands because mutable scripts and shell expansion make command or
directory allowlists unsafe.
