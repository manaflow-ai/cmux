# Agent hooks

Coding agents report their state (working, waiting for input, done) to the
session through hooks. `cmux agent hook install [provider...]` writes hook
entries into each provider's own config, and every cmux-tui terminal exports
`CMUX_TUI_SOCKET` and `CMUX_TUI_HOOK` so those entries reach the session that
owns the terminal. Agents load hooks at start, so restart an agent after
installing.

```bash
cmux agent hook install claude
cmux agent hook status
```

## Agents in a tmux session started elsewhere

An agent can run in a tmux session whose server was started outside
cmux-tui, for example by a launcher over SSH, and be viewed by running
`tmux attach` in a cmux-tui terminal. Its panes have no `CMUX_TUI_HOOK`, so
the installed hook commands fall back to the installed `cmux-tui-hook` helper
whenever `TMUX` is set. On Linux the helper finds the tmux clients of the
pane's session (or a session grouped with it), prefers the one whose current
window shows the pane and then the most recently active one, and reads the
session socket and terminal id from that client's environment. The event goes
to that terminal, so its agent status appears where the session is attached.
Each event is routed on its own, so after the session moves to another
terminal the next event reports there. A pane that has the session's
variables, including one in a tmux server started from a cmux-tui terminal,
keeps using them. Agents started before the hooks were installed or updated
pick this up on their next start.

## Claude Code without an install

Claude Code started in a cmux-tui terminal gets the session's hooks even when
`agent hook install claude` never ran, or when a launcher points it at another
config directory and passes its own `--settings` (for example a proxy or
account-switching launcher).

At startup the server writes a `claude` shim to
`$XDG_DATA_HOME/cmux-tui/shims/claude` (default
`~/.local/share/cmux-tui/shims/claude`) and puts that directory first on each
terminal's `PATH`. The shim runs `cmux-tui agent claude-wrapper`, which:

1. Finds the next `claude` on `PATH`, skipping the shim.
2. Folds every `--settings` argument, inline JSON or a file, into one private
   file under `~/.local/share/cmux-tui/claude-settings/` together with the
   session's hook groups. Claude Code applies only the last `--settings` flag,
   so merging keeps the launcher's settings. Objects merge key by key and
   arrays, including hook groups, are concatenated.
3. Starts that `claude` with the merged file and with the shim removed from
   `PATH`.

The merged file sets `preferredNotifChannel` to `notifications_disabled`,
because the session's notifications replace Claude's own. Files are named by a
hash of their content, kept at mode `0600` in a `0700` directory, and removed
after seven days without a launch that uses them.

The wrapper leaves Claude unchanged when:

- the terminal has no live session socket or terminal id (outside cmux-tui),
- `CMUX_TUI_CLAUDE_HOOKS_DISABLED=1` is set,
- the command is informational or management (`--version`, `--help`,
  `mcp`, `doctor`, `update`, and similar),
- Claude was already started through the wrapper (a launcher that resolves
  `claude` again does not get a second set of hooks), or
- a `--settings` argument cannot be read. It prints one line and starts
  Claude without the hooks.

A launcher that is itself named `claude` and sits earlier on PATH than the
real Claude receives the merged `--settings`. If it then adds a `--settings`
of its own, that later flag wins and the hooks are dropped. Launchers with
another name that look up `claude` on PATH are not affected.

With `agent hook install claude` also in place and its `cmux-tui-hook`
helper present, both copies use the same command, and Claude Code runs it
once. When the wrapper finds no helper (neither the installed copy nor one
beside the cmux-tui binary), its hooks call `cmux-tui agent hook emit`
instead. If `CMUX_TUI_HOOK` still names a working helper in that case, the
installed hooks run as well and each event is delivered twice.

## Codex without an install

Codex started through the `codex` shim gets the same journal hooks without a
Codex config edit. The shim runs `cmux-tui agent codex-wrapper`, which passes
the socket and terminal id inside every hook command. This is required when
Codex reuses an app-server: the daemon can start a hook after the original
shell has gone away, so it cannot inherit that shell's `CMUX_TUI_SOCKET`.
The launch flags trust only these generated session hooks and disable the
installed cmux copies for that invocation, leaving user hooks and their trust
settings unchanged. `exec`, `resume`, and `fork` sessions are covered;
management commands and informational flags pass through.

The wrapper also works in an SSH workspace where the host received the
standalone cmux-tui binary. If the wrapper is launched in a tmux pane without cmux
variables, it resolves the attached Linux tmux client using the same route as
the installed helper, then binds hooks to that terminal for the launch. An
already-running tmux server may not have the shim on PATH; start Codex through
`cmux-tui agent codex-wrapper` in that case. Restart Codex after moving its
session to a different cmux-tui terminal. Set
`CMUX_TUI_CODEX_HOOKS_DISABLED=1` to skip injection. Codex 0.162 can select
embedded mode when given launch-time config; this does not repair a shared
daemon's authorization for direct `cmux notify` calls.

`ssh-tmux` mirrored workspaces use tmux's control transport rather than the
cmux-tui journal and currently have no agent-status subscription, so this
wrapper does not add badges to those mirrors.

## Shell startup files can bypass the shim

The shim only works while its directory stays ahead of the real `claude` on
`PATH`. A login or interactive shell startup file that prepends a directory
holding `claude` (commonly `export PATH="$HOME/.local/bin:$PATH"` in
`~/.zshrc`, `~/.bashrc`, or `~/.profile`) moves the real binary in front, and
that terminal starts Claude without the session's hooks. Append that directory
instead, or run `cmux agent hook install claude` so hooks load from Claude's
own config.
