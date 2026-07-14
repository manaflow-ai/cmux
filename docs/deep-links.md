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
unchanged to `/bin/zsh -lc`, so shell operators and agent CLI arguments work.

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

`placement` is `workspace` by default. A `surface` placement requires one
`pane` or `surface` anchor. A `pane` placement also requires `direction` with
the value `left`, `right`, `up`, or `down`.

cmux rejects duplicate or unknown parameters, ambiguous targets, hidden control
characters, remote workspaces, missing directories, concurrent run requests,
and targets that change after approval. A run link cannot reuse a terminal,
inject environment variables or input, run without focus, or receive a callback.
The user must approve every command. cmux does not remember approval for raw
shell commands because mutable scripts and shell expansion make command or
directory allowlists unsafe.
