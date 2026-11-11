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

Hook reports outrank the screen-detection plugin for 30 s, with one
exception: a blocked state ends when the screen proves the dialog gone, after
the hook reported it. The proof is one plugin process seeing the dialog and
then not (a restarted plugin starts with no such proof), or the plugin seeing
the agent's own idle prompt (a dismissal faster than its scan). Claude Code
sends no hook when a permission dialog is dismissed with Esc, so this proof,
or the agent's own status report (OSC 7501 `blocked`, then `idle` or
`working`), is the only evidence that the agent stopped waiting.

One agent's hook events reach the session in the order its hooks ran: each
hook queues its event behind the agent's earlier ones. A hook that cannot
queue (no private queue directory, a full disk, or a platform without the
queue) sends its event on its own connection, and the session serves each
connection on its own thread, so the journal can then take a `Stop` before
the prompt that came first. Each event carries when its hook started
(`observed_at_ms`, from the clock of the machine the hook runs on). The
agent's state, in the agent rows and in the roster that the sidebar, tab
badges and attention jump read, follows the latest-started event of its
session: an event of the same session that started earlier than the latest
applied one, by at most 5 s (the reorder window), is kept in the journal
but does not change the state. The session's start and end, and an event
that shows a dialog, a question, a plan review or an error, always apply.
Limits: two events that start in the same millisecond keep journal order;
an event that started more than 5 s earlier applies (a clock stepped back);
for an agent on a remote host, a step of that host's clock within 5 s can
drop the state of the event after it until the agent's next event.

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

### Claude started by full path or by a launcher

The shim only covers a `claude` found on `PATH`. A launcher that runs Claude
by its full path (`sr2 claude` when a login shell has put `~/.local/bin`
ahead of the shim, a version manager's shim, an alias to the full path, or a
typed `/path/to/claude`) skips it. For those launches each terminal also
names this build's Claude Code plugin in `CLAUDE_CODE_PLUGIN_DIRS`, which
Claude Code 2.1 reads under any config directory and beside any
`--settings`:

- The server writes the plugin to
  `$XDG_DATA_HOME/cmux-tui/builds/<build>/claude-plugin` and appends that
  folder to the `CLAUDE_CODE_PLUGIN_DIRS` the server inherited. Folders of
  other cmux-tui plugins are dropped (found by their manifest, or by the
  `cmux-tui/builds/<build>/claude-plugin` place, which also finds the folder
  of a build deleted since), so a server started in another build's terminal
  does not load two. An acpmux daemon started in a terminal drops them from
  the environment of its agents, which run in no terminal.
- The plugin's hooks are the installed hooks plus the `SessionStart` session
  context. They run `CMUX_TUI_HOOK`, or this build's helper when a launcher
  removed that variable.
- Claude Code does not merge plugin hooks with settings hooks. When the user
  settings of the config directory Claude runs with already hold the hooks
  from `agent hook install claude`, the plugin's copy of each such event does
  nothing.
- Limit: when Claude is started with `--setting-sources` that leaves `user`
  out, the installed copy does not load, but the plugin's copy still does
  nothing beside it (no hook tells the plugin which settings loaded). That
  terminal then gets no hook events, so `agent list` shows no hook state for
  it (only what screen detection finds). Remove the installed hooks
  (`agent hook uninstall claude`) or keep `user` in the sources to get the
  plugin's hooks.
- Claude Code gives its tool commands its environment: the plugin folder,
  `CMUX_TUI_HOOK` and the terminal's variables. A Claude that a tool command
  starts (`claude -p` in a Bash call) would report to the same terminal and
  take the messages queued for the terminal's agent, through the plugin, the
  installed hooks or the shim's hooks. So the copy of the hooks that reports
  `SessionStart` (whichever it is) appends
  `export CMUX_TUI_CLAUDE_OWNER=<terminal>/<session>` to Claude Code's
  `CLAUDE_ENV_FILE` (creating it), which Claude Code sources before each Bash
  tool command. Every copy of the Claude hooks does nothing in a Claude whose
  environment names its terminal and another session, so the terminal's
  session, last reply and messages stay the outer Claude's. A Claude started
  with `cmux agent start` from a tool command runs in its own terminal and
  reports there. The shim's fallback when no hook helper is found
  (`cmux-tui agent hook emit`) records events only, delivers no messages, and
  does not read the claim; the terminal keeps its first live session.
- The wrapper removes the plugin from the folders it passes on, because its
  `--settings` already carries the same hooks. Other plugin folders stay.
- `CMUX_TUI_CLAUDE_HOOKS_DISABLED=1` turns the plugin's hooks off. Set in the
  server's environment, it also keeps the folder out of new terminals.
- Claude Code refuses to start while `CLAUDE_CODE_PLUGIN_DIRS` names a folder
  under an organization policy with `disableSideloadFlags`. The server adds no
  folder when this machine's managed settings, managed preferences, or cached
  remote settings set that policy. A policy that only the server delivers,
  and that this machine has not cached, is not seen; Claude then names
  `CLAUDE_CODE_PLUGIN_DIRS` in its error, and unsetting it in the terminal
  starts Claude without the plugin.
- Claude Code versions without `CLAUDE_CODE_PLUGIN_DIRS` ignore it; for them
  only the shim adds hooks.

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

cmux-next has no `ssh-tmux` mirrored workspace. An SSH machine runs cmux-tui
on the host, so Claude there starts through this wrapper and gets the full
`CLAUDE_EVENTS` set, the same as a local session. The `ssh-tmux` mirror, which
uses tmux's control transport rather than the cmux-tui journal, exists only in
the classic app, and it reports agent badges through its own tmux
subscription (`docs/investigations/remote-agent-status-sidebar.md`).

## Shell startup files and the shim

The shim only works while its directory stays ahead of the real `claude` and
`codex` on `PATH`. Startup files often prepend a directory that holds them
(commonly `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`, `~/.bashrc`,
or `config.fish`). The server therefore exports the shim directory as
`CMUX_TUI_AGENT_SHIMS`, and the shell integration moves it back to the front
of `PATH`: zsh and fish before each command line runs, bash once after its
startup files and again at each prompt (after the prompt hooks the startup
files added). Both integrations do this: the daemon's (appended to Ghostty's
scripts) and the cmux-next app's (`Resources/cmux-cli-path`, which wraps the
shells the app integrates itself). Only that directory moves; the rest of
`PATH` keeps its order, and the wrappers still start the first `claude` or
`codex` after the shim. Shells started without the integration
(`CMUX_TUI_SHELL_INTEGRATION=none`, Apple's `/bin/bash`, or a nested shell
typed at the prompt) keep the old behavior, and an alias or function named
`codex` or `claude` still runs instead of the shim. For Claude,
`cmux agent hook install claude` covers those cases too.
`CMUX_TUI_CODEX_HOOKS_DISABLED=1` and `CMUX_TUI_CLAUDE_HOOKS_DISABLED=1` leave
the agents unchanged.

Codex needs the shim. Codex 0.162 runs hooks in a shared app-server daemon
that keeps the environment of whichever shell started it, so an installed
hook there cannot tell which terminal the session belongs to. The installed
cmux hook posts nothing when it runs under that daemon (an
`app-server --managed-daemon` ancestor), rather than posting every Codex
session's events to the terminal that started the daemon. For the same
reason the wrapper adds no hooks when it runs below that daemon (a tool
command of a daemon-hosted session). The wrapper's hooks carry their own
route (`CMUX_TUI_HOOK_ROUTE=launch`) and are unaffected. Codex itself runs a
launch with `-c` overrides in embedded mode, without the shared daemon, and
the startup notice says so.
