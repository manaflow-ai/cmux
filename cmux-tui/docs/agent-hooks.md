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

`status` reports each provider on its own row. A provider whose config cannot
be read gets `state: unavailable`, `reason: unreadable` and the cause in
`detail`; the other providers still answer and the command exits 0. A failed
install or uninstall names each cause in its message.

Hook reports outrank the screen-detection plugin for 30 s, with one
exception: a blocked state ends when the screen proves the dialog gone, after
the hook reported it. The proof is one plugin process seeing the dialog and
then not (a restarted plugin starts with no such proof), or the plugin seeing
the agent's own idle prompt (a dismissal faster than its scan). Claude Code
sends no hook when a permission dialog is dismissed with Esc, so the screen is
the only evidence that the agent stopped waiting.

One agent's hooks run one after another, but each hands its event to the
session on its own connection, and the session serves each connection on its
own thread, so the journal can take a `Stop` before the prompt that came
first. Each event carries when its hook started, from the machine the hook
runs on: its monotonic clock (`boot_id`, `monotonic_ns`) and its wall clock
(`observed_at_ms`, ms since the epoch). The agent's state, in the agent list
and in the roster that the sidebar, tab badges and attention jump read,
follows the latest-started event of its session: an event of the same
session that started earlier than the latest applied one is kept in the
journal but does not change the state. One session runs on one machine, so
the monotonic clock decides, however far apart the events are; a wall clock
step does not change the order. Two events with the same monotonic value
keep journal order. An event of another boot (a resume after a reboot)
applies, even if its clock reads less. The session's start and end, and an
event that opens a dialog, a question or a plan review, always apply
(parallel subagents of one session can each open one, and it stays open
until answered). An error report is a state like any other: a late one does
not replace a newer state. The latest stamp is stored with the agent's hook
state, so the order holds across a session restart.

The monotonic clock is `CLOCK_MONOTONIC`, one system-wide clock per boot. On
macOS that is `mach_continuous_time`, which counts while the Mac sleeps. An
event with no monotonic stamp (an older hook helper, or a platform that gives
no boot id) applies in journal order: the wall clock (`observed_at_ms`) is
kept for the record and does not order events.

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

At startup the server writes `claude` and `codex` shims to a folder of its
own build, `$XDG_DATA_HOME/cmux-tui/builds/<key>/shims` (default
`~/.local/share/cmux-tui/builds/<key>/shims`), and puts that folder first on
each terminal's `PATH` and in `CMUX_TUI_AGENT_SHIMS`. The key is a hash of the
build's resolved executable path, so two installs on one machine (the npm
package, the app, a dev build) never run each other's wrapper, and two
daemons of one build share the folder. The server also points each
terminal's `CMUX_TUI_HOOK` at its own build's helper: the `cmux-tui-hook`
beside its executable, else `builds/<key>/bin/cmux-tui-hook`, a launcher that
runs the executable's hook mode. The shared `cmux-tui/bin/cmux-tui-hook` that
`agent hook install` writes is not used for these terminals. The shim runs
`cmux-tui agent claude-wrapper`, which:

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
once. The wrapper keeps a `CMUX_TUI_HOOK` it inherits when that is an
absolute path to an executable file other than the shared installed helper
(the terminal's own build helper, or one you set for a launch). Otherwise it
uses its own build's helper. When it cannot write that helper, its hooks call
`cmux-tui agent hook emit` instead. If `CMUX_TUI_HOOK` still names a working
helper in that case, the installed hooks run as well and each event is
delivered twice.

### Claude started by full path or by a launcher

The shim only covers a `claude` found on `PATH`. A launcher that runs Claude
by its full path (`sr2 claude` when a login shell has put `~/.local/bin`
ahead of the shim, a version manager's shim, an alias to the full path, or a
typed `/path/to/claude`) skips it. For those launches each terminal also
names this build's Claude Code plugin in `CLAUDE_CODE_PLUGIN_DIRS`, which
Claude Code 2.1 reads under any config directory and beside any
`--settings`:

- The server writes the plugin to
  `$XDG_DATA_HOME/cmux-tui/builds/<key>/claude-plugin` and appends that
  folder to the `CLAUDE_CODE_PLUGIN_DIRS` the server inherited. Folders of
  other cmux-tui plugins are dropped (found by their manifest, or by the
  `cmux-tui/builds/<key>/claude-plugin` place, which also finds the folder
  of a build deleted since), so a server started in another build's
  terminal does not load two.
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
  starts (`claude -p` in a Bash call) would report to the same terminal
  through the plugin, the installed hooks or the shim's hooks. So the copy
  of the hooks that reports `SessionStart` (whichever it is) appends
  `export CMUX_TUI_CLAUDE_OWNER=<terminal>/<session>/<pid>` to Claude Code's
  `CLAUDE_ENV_FILE` (creating it). `<terminal>` is the hook's route, which
  can also be a tmux route. `<pid>` is `CLAUDE_PID`, the Claude Code
  process; without a numeric `CLAUDE_PID` the claim is
  `<terminal>/<session>`. Claude Code 2.1.319 sources that file before each
  Bash tool command, and not for its hooks. Every copy of the Claude hooks
  reports nothing in a Claude whose environment names its terminal, a
  session other than its own and another Claude process (or no process), so
  the terminal's session, state and journal stay the outer Claude's. Such a
  Claude also gets no session context. The claiming Claude's own hooks never
  stand down, so `/clear` keeps reporting even if a later Claude Code lets
  hooks see that file.
- A Claude that a hook, an MCP server or a teammate starts does not source
  that file, so it has no claim. Its events still reach the journal; the
  daemon keeps the terminal's session and state on the first live session.
  Before the hooks write a claim or give the session context, they check
  whether the terminal has another agent:
  - A `SessionStart` with source `clear` or `resume` is the terminal's agent.
    Claude Code 2.1.319 ends the old session with `SessionEnd` first, in
    the same process, and the row may not show that end yet. A Claude that
    a hook started and that clears or resumes gets the session context.
  - Else the hook reads its terminal's agent row (one `agent.list`
    request), after the event is handed to the daemon. A live hook session
    other than its own means another agent's Claude: it writes no claim and
    gets no session context. When the read fails or times out, the hook acts
    as before, so the terminal's own agent is never silenced by a daemon
    that does not answer in time.
  - The `SessionStart` hook writes the claim whether or not the daemon took
    the event, so a Claude that starts while the daemon is down still claims
    its terminal (its read fails, so it counts as the agent). Claude Code
    kills the hook at its 5 s timeout: the hand-off waits at most 4.25 s
    and never past 4.5 s after the hook started, and the read ends no later
    than 4.5 s after the hook started. With no time left the
    hook makes no read and acts as when the read fails.
- Limit: a Claude that ended without `SessionEnd` (a crash or `kill -9`)
  leaves a live row. The next Claude started by hand in that terminal then
  gets no session context and writes no claim until the screen detector
  replaces the row.
- Limit: the first live session takes the row. A nested Claude whose start
  reaches the daemon before its parent's (a `SessionStart` hook or MCP
  server that starts one at once), or one that outlives its parent, holds
  the row.
- Limit: a claim on a tmux route names the terminal that showed the tmux
  session at `SessionStart`. After the session is attached in another
  terminal, the agent's events report there, but its claim still names the
  first terminal. A Claude that a tool command then starts is not claimed
  for the new terminal: its hooks report there and only the agent row check
  and the first-live-session rule keep the terminal the agent's. The next
  `SessionStart` of the agent (`/clear`, `/resume`, compaction) writes a
  claim for the new terminal.
- These rely on each Claude Code process setting its own `CLAUDE_PID` for
  its hooks (2.1.319 does). A nested Claude that passes on its parent's
  `CLAUDE_PID`, or that runs the agent's own session id (`claude -p
  --continue` from a hook), counts as the terminal's agent.
- A Claude started with `cmux agent start` from a tool command runs in its
  own terminal and reports there. The shim's fallback when no hook helper is
  found (`cmux-tui agent hook emit`) records events only and does not read
  the claim or the row; the terminal keeps its first live session.
- The wrapper removes the plugin from the folders it passes on, because its
  `--settings` already carries the same hooks. Other plugin folders stay.
- `CMUX_TUI_CLAUDE_HOOKS_DISABLED=1` turns the plugin's hooks off. Set in the
  server's environment, it also keeps the folder out of new terminals.
- Claude Code refuses to start while `CLAUDE_CODE_PLUGIN_DIRS` names a folder
  under an organization policy with `disableSideloadFlags`. The server adds no
  folder when this machine's managed settings, managed preferences, or the
  cached remote settings of the server's Claude config directory set that
  policy. A policy that only Anthropic's server delivers, and that is not
  cached there, is not seen; Claude then names `CLAUDE_CODE_PLUGIN_DIRS` in
  its error, and unsetting it in the terminal starts Claude without the
  plugin.
- Claude Code versions without `CLAUDE_CODE_PLUGIN_DIRS` ignore it; for them
  only the shim adds hooks.

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
cmux-tui journal. Native cmux mirrors now subscribe to that transport for
agent badges; the cmux-tui wrapper itself does not provide those badges.

## Session context

Claude Code and Codex started through the shims, and Claude Code started any
other way in a terminal that carries the Claude Code plugin, learn where they
run when their session starts: that they run in a cmux-tui terminal, the
ids of the session, workspace, screen, pane, tab and terminal, that `current`
names the session's focused object rather than their own pane, and that
`skill show` prints the agent guide. The text names the cmux-tui binary that spawned the
pane by its absolute path (for example `/opt/cmux/cmux-tui skill show`),
because the `cmux` on PATH can be another program, such as the cmux app's CLI
when cmux-tui runs in a cmux app terminal. The text reaches the model as the
`SessionStart` hook's `additionalContext`:

- The Claude wrapper adds one more `SessionStart` hook after the session's
  hook groups, `cmux-tui agent session-context`, run by the cmux-tui binary
  that spawned the pane. A binary path that is not UTF-8 drops only this
  hook; the session's other hooks stay. A Claude that skipped the shim gets
  the same hook from the terminal's Claude Code plugin (see
  [Claude started by full path or by a
  launcher](#claude-started-by-full-path-or-by-a-launcher)).
- The Codex wrapper's own `SessionStart` hook (the one that carries
  `CMUX_TUI_HOOK_ROUTE=launch`) prints the context after it hands the event
  to the journal, and prints `{}` only when the helper fails, so Codex reads
  one JSON object.

Hooks installed with `agent hook install` add no context, so no agent gets it
twice. The read takes at most 1.5 s; a session that does not answer leaves
only the terminal id in the text.

## Shell startup files and the shim

The shim only works while its directory stays ahead of the real `claude` and
`codex` on `PATH`. Startup files often prepend a directory that holds them
(commonly `export PATH="$HOME/.local/bin:$PATH"` in `~/.zshrc`, `~/.bashrc`,
or `config.fish`). The server therefore exports the shim directory as
`CMUX_TUI_AGENT_SHIMS`, and the shell integration moves it back to the front
of `PATH`: zsh and fish before each command line runs, bash once after its
startup files and again at each prompt (after the prompt hooks the startup
files added). Only that directory moves; the rest of `PATH` keeps its order,
and the wrappers still start the first `claude` or `codex` after the shim.
Shells started without the integration (`CMUX_TUI_SHELL_INTEGRATION=none`,
Apple's `/bin/bash`, or a nested shell typed at the prompt) keep the old
behavior, and an alias or function named `codex` or `claude` still runs
instead of the shim. For Claude, the terminal's Claude Code plugin and
`cmux agent hook install claude` cover those cases too.
`CMUX_TUI_CODEX_HOOKS_DISABLED=1` and `CMUX_TUI_CLAUDE_HOOKS_DISABLED=1`
leave the agents unchanged.

Codex needs the shim. Codex 0.162 runs hooks in a shared app-server daemon
that keeps the environment of whichever shell started it, so an installed
hook there cannot tell which terminal the session belongs to. The installed
cmux hook posts nothing when it runs under that daemon (an
`app-server --managed-daemon` ancestor), rather than posting every Codex
session's events to the terminal that started the daemon. For the same
reason the wrapper adds no hooks when it runs below that daemon (a tool
command of a daemon-hosted session). The wrapper's hooks carry their own
route and are unaffected. Codex itself runs a launch with
`-c` overrides in embedded mode, without the shared daemon, and the startup
notice says so.
