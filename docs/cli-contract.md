# cmux CLI Contract

This is the user-visible contract of the `cmux` command in cmux-next. The CLI is
the Rust cmux-tui binary, shipped in the app as `Contents/Resources/bin/cmux`
with `cmux-tui` and `acpmux` as symlinks to it. The design is
[plans/cmux-next/cli.md](../plans/cmux-next/cli.md); the grammar source of truth
is `cmux-tui/crates/cmux-tui/src/cli.rs`, `cli/command.rs` and `cli/app.rs`, and
the protocol is [resource-api-v2.md](../cmux-tui/spec/resource-api-v2.md).

The Swift CLI (`CLI/cmux.swift`) is deleted. There is no compatibility with its
verbs, flags, `workspace:N` style refs or the v1 text protocol. See
[Removed](#removed) for replacements.

## Invocation

| Form | Contract |
| --- | --- |
| `cmux` | Open the TUI: attach to the session, or start it. |
| `cmux attach [START OPTIONS]` | Attach the TUI to a session. |
| `cmux [GLOBAL OPTIONS] <scope> <action>` | Run a control command. Commands are noun-first. |
| `cmux acp …` | Agent sessions through acpmux (see [`cmux acp`](#cmux-acp)). |
| `cmux --help`, `cmux help`, `cmux help <scope>`, `cmux <scope> --help` | Print help without a socket. `cmux help start` and `cmux help shorthands` print the startup and shorthand grammar. |
| `cmux -V`, `cmux --version` | Print the version without a socket. |
| `acpmux …` | The same binary started through the `acpmux` symlink runs acpmux directly. |

Hyphenated action-first commands (`cmux new-workspace`, `cmux send-key`) are
usage errors with exit code 2, unless the app has an action with that CLI name
(see [App actions](#app-actions)). A small tmux-style shorthand set
(`ls`, `list-windows`, `list-panes`, `new-window`, `split-window`, `select-pane`,
`select-window`, `rename-window`, `capture-pane`, `send-keys`) lowers to the
resource grammar; `cmux help shorthands` lists it.

Global options, accepted before the scope:

| Option | Contract |
| --- | --- |
| `--socket <path>` | Connect to an exact local session socket. |
| `--session <name>` | Route through a named local session. |
| `--all-sessions` | Run a list (`… list`) on every local session; each record gains `session`. |
| `--machine <value>` | Constrain machine-scoped requests. |
| `--app-socket <path>` | Connect to an exact app control socket (app scopes only). |
| `--json` | Print one JSON result object. |
| `--jsonl` | Print one JSON value per result or event. |
| `--quiet` | Suppress successful output. |
| `-h`, `--help` | Show command help. |

`--socket`, `--session`, `--machine` and `--app-socket` also take the
`--flag=value` form.

`--socket` is a daemon session socket. The remote commands (`connect`, `ssh`,
`forward`, `rpc`) reach a ROUTE and refuse `--socket`. A tagged app's
`/tmp/cmux-debug-<tag>.sock` is the app control socket: pass it with
`--app-socket` to an app verb (`cmux --app-socket <path> app identify`).
To call one app control method of a DEV or tagged build (for example a
`debug.*` read), use `app call`:

```text
cmux --app-socket /tmp/cmux-debug-<tag>.sock app call debug.surfaces '{}'
```

`app call METHOD [JSON_OBJECT]` first asks the app `system.identify` and
refuses (exit 1, `app.call_debug_only`) any app that is not a debug build
(`com.cmuxterm.app.debug[.<tag>]`). The params are sent as given, with the
CLI's `origin` (`cli` or `script`) over any `origin` in the JSON, so
person-only operations stay refused. JSON that is not one object is a usage
error (exit 2); the app's own error passes through with its code (exit 1).
Inside a tagged app's terminal, or through `CMUX_TAG=<tag>
scripts/cmux-debug-cli.sh`, the socket is found without `--app-socket`.

Every command acts on one session. Without `--socket`, `--session` or
`--all-sessions`, lists and bulk commands act only on the session the CLI
finds (see [Discovery](#discovery)), so a script that lists and then closes
never reaches another session. `--all-sessions` is accepted only by list
reads and reaches the local sessions this user runs (the runtime directory's
`<name>.sock` files and the bundling app's session); sessions the app reaches
over SSH or on Cloud machines have no CLI transport yet.

## Output and exit codes

Human output follows the selected locale (English and Japanese; acpmux output is
English only). Results go to stdout and diagnostics to stderr.

| Exit | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Operation failure (the request ran and failed, or `screen wait` timed out). |
| 2 | Usage error (`usage.invalid`). |
| 3 | Transport failure (no session or app socket, unreachable, broken reply). |

`cmux acp` keeps acpmux's own exit codes (for example `acp wait` exits 2 when a
permission is waiting and 3 on timeout).

## Owners and routing

Each command goes to the owner of its object.

| Owner | Scopes | Works with the app closed |
| --- | --- | --- |
| cmux-tui daemon (`cmux.protocol/2`) | `machine`, `session`, `client`, `workspace`, `screen`, `pane`, `tab`, `terminal`, `browser` (daemon-owned `browser_…`), `notification`, `notify`, `agent`, `room`, `closed`, `sidebar`, `pairing`, `projection`, `provider`, `raw` | yes |
| app control socket (JSON lines, `{"id","method","params"}`) | `app`, `window`, `action`, `settings`, `events`, `browser page`/`browser tab_…` page commands, and any `<noun> <verb>` that is an app action CLI name | no |
| acpmux daemon | `acp` | yes (started on demand) |

The mux grammar is tried first. Only words it rejects, and that the running app
reports as an action, run as an app action.

## Discovery

Inside a cmux terminal the CLI finds everything from the environment the app and
daemon inject, so no flags are needed.

| Variable | Contract |
| --- | --- |
| `CMUX_SOCKET_PATH` | App control socket. Wins over the derived path. |
| `CMUX_BUNDLE_ID` | App bundle id; derives the app socket and daemon session. |
| `CMUX_TAG` | Tagged dev build; derives `/tmp/cmux-debug-<tag>.sock`, session `cmux-app-<tag>` and acpmux home `~/.acpmux/tags/<tag>`. |
| `CMUX_TUI_SOCKET` | Daemon session socket. |
| `CMUX_TUI_TERMINAL_ID` | The caller's terminal (`term_…`). `cmux notify` and `agent hook emit` default to it. `current` selectors do not use it. |
| `ACPMUX_HOME` | acpmux state directory. Wins over the tag rule. |

App socket order: `--app-socket`, then `CMUX_SOCKET_PATH`/`CMUX_BUNDLE_ID`/`CMUX_TAG`,
then the app bundle that contains the executable (`CFBundleIdentifier` and
`LSEnvironment.CMUX_TAG`). The path table mirrors the app's `ControlSocketPath`:
release uses `~/.local/state/cmux/cmux.sock`, nightly/rc/staging use
`/tmp/cmux-<channel>.sock`, and a tagged debug build uses
`/tmp/cmux-debug-<tag>.sock`.

<<<<<<< HEAD
| Command | Contract |
| --- | --- |
| `welcome` | Print the welcome screen. |
| `guide`, `--skill` | Print the same short Markdown guide to workspace, terminal, browser, computer-use, and Cloud methods. Works without the app, a socket, network access, or sign-in. `--json` returns `{topic: "cmux", format: "markdown", content: "..."}`. |
| `docs` | Print canonical docs URLs, raw GitHub resources, and useful commands for a topic. |
| `settings` | Open Settings, print cmux.json paths, or print settings docs. |
| `config` | Validate cmux.json syntax, print config references, or reload config. |
| `shortcuts` | Open Settings to Keyboard Shortcuts. |
| `disable-browser` | Disable cmux browser creation and link interception until re-enabled. |
| `enable-browser` | Re-enable cmux browser creation and link interception. |
| `browser-status` | Print whether cmux browser creation and link interception are enabled. |
| `socket-status` | Print effective automation socket mode and managed source without connecting to the socket; `--json` also reports configured mode, forced-value status, and socket-path observation (`live_enforcement` is intentionally `not_observed`). Works when the listener is off or cmux is not running. |
| `agent-hibernation` | Enable or disable routine Agent Hibernation. |
| `restore` | Replace the CLI with a process restored from structured surface state. |
| `fork` | Replace the CLI with a provider fork process restored from structured surface state. |
| `restore-session` | Restore the previously saved cmux session; `--from <channel\|path>` reopens another install's saved session (full trust) or an exported file (untrusted: no automatic resume of custom commands, SSH, or environment from the file) as additional windows, and `--export <path> [--force]` writes this install's saved session to a file. Both require cmux to be running. |
| `open` | Open files, directories, or URLs in cmux. Files and web pages take focus only when run interactively; run by an agent or script they open in the background. `--focus <true\|false>` and `--no-focus` override. |
| `feedback` | Open feedback UI or submit feedback with `--email`, `--body`, and repeated `--image`. |
| `feed` | Open the keyboard-first Feed TUI or manage persisted Feed workstream history. |
| `themes` | List, set, clear, or interactively pick Ghostty themes. |
| `import` | Import font, colors, cursor, Option-as-Alt, padding, opacity/blur and scrollback from iTerm2, Terminal, Alacritty, Kitty, WezTerm or a Warp theme into cmux's own Ghostty config and a generated theme. With no terminal, lists detected terminals (and prompts in a TTY). `--dry-run` prints the diff without writing; writing asks for confirmation in a TTY and otherwise (scripts, pipes, `--json`) requires `--yes`; `--path <file>` overrides detection; `--json` prints the plan. Never writes `~/.config/ghostty/config` or the source terminal's files. Works without a running app. |
| `claude-teams` | Launch Claude Code with cmux/tmux-style agent team integration. |
| `codex-teams` | Launch Codex with cmux-managed subagent panes. |
| `omo` | Launch OpenCode with oh-my-openagent integration. |
| `omx` | Launch Oh My Codex with cmux pane integration. |
| `omc` | Launch Oh My Claude Code with cmux pane integration. |
| `hooks` | Install, uninstall, and run agent hook integrations under one namespace. |
| `codex` | Compatibility alias for installing or uninstalling Codex hooks. |
| `ping` | Check socket connectivity. |
| `capabilities` | Print server capabilities as JSON. |
| `events` | Stream reconnectable cmux events as newline-delimited JSON. |
| `automation` | Manage config-backed event rules: `list`, `show <id>`, dry-run `test <id> --event <json>`, `enable`, `disable`, `logs`, and `reload`. Rules live in `~/.cmuxterm/automations.json`; actions are dispatched by the running app. |
| `glaeda` | Emit one caller-neutral `glaeda-external-execution-request/v1` and validate/correlate one bounded Glaeda receipt. `request` and `observe` are local data operations and do not require a running cmux socket. They carry exact Git source plus caller correlation only; CMUX workspace/UI and provider placement stay outside the request. |
| `sessions [list]` | List saved agent session records without requiring a running cmux socket. Filters: `--agent <name>`, `--session <id>`, `--workspace <id>`, `--surface <id>`, `--cwd <text>`. Overrides: `--state-dir <path>`, `--codex-home <path>`. Text output defaults to 100 results; `--limit <n>` takes a positive integer and `--all` removes the limit. Supports `--json`. Records also report metadata for matching cmux-owned scratch roots (`scratch_owned`, byte count, file count, and root path); unmarked directories are never scanned. |
| `session move <session-id> --to <ssh-destination\|local>` | Move a stopped Claude Code session between this Mac and an SSH host and resume it there. Refuses while a Claude process for the session runs on either side. Carries the cwd's git checkout (a snapshot commit of the working tree on top of HEAD at `refs/agent-move/<id>`, HEAD on the same branch when it is safe, plus modified, deleted and untracked non-ignored files; adds a worktree when the repository exists on the destination but the path does not; refuses when the destination has its own uncommitted changes or its branch has commits HEAD lacks), then the transcript, its session directory, file history, and the project memory directory (merged both ways, newest wins, nothing deleted). When the destination home is not the same directory at the same path, paths under the home are mapped and the project is re-slugged. Opens a `cmux ssh` workspace (or a local workspace for `--to local`) that resumes the session with its recorded launcher (on a host, cmux-owned launchers such as `claude-teams` fall back to the plain agent command), and clears the old local surface's resume binding. `--from` defaults to where the last move put the session (`~/.cmuxterm/agent-moves/<id>.json`). Flags: `--name`, `--no-code`, `--port`, `--identity`, `--ssh-option`, `--no-focus`. |
| `auth` | Manage auth status, login, logout, and the selected team through the app. |
| `coderouter`, `cr` | `cmux coderouter <status|machines|claude>` manages the team's coderouter model plane through the app (sign-in state, per-machine usage, the team's Claude upstream accounts). Every other `cmux coderouter ...` verb and all of `cmux cr ...` exec the CodeRouter CLI unchanged with the `CMUX_*`/`CMUXD_*` environment stripped: `coderouter` or `cr` on PATH first, then the official installer's `~/.coderouter/bin/coderouter` (`$CODEROUTER_INSTALL/bin` when set), never with a network call. When neither exists and stdin and stderr are terminals, cmux shows the documented installer `curl -fsSL https://cmux.com/coderouter/install.sh | sh`, says what it does (checksum-verified binary into `~/.coderouter/bin`, PATH line in the shell profile), asks once (`Install CodeRouter now? [y/N]`), and after `y` fetches the script, runs it with `sh`, and execs the new install with the original arguments. Any other outcome (non-interactive, declined, download or installer failure) prints that install command on stderr and exits 127. |
| `vm`, `cloud` | Manage cloud VMs and their HTTPS publications. `cloud` is an alias for `vm`. |
| `cloud guide`, `cloud --skill` (also `vm guide`, `vm --skill`) | Print the same short Cloud guide without connecting to the app. `--json` returns `{topic: "cloud", format: "markdown", content: "..."}`. This does not install a skill or start an agent; `vm prompt` and its existing `vm skill` alias keep that behavior. |
| `remotes`, `remote` | Manage remote Macs in the team device registry so they appear in the iOS app's device list. `remote` is an alias for `remotes`. |
| `rpc` | Call a raw v2 socket method with optional JSON params. |
| `identify` | Print server identity and caller context. |
| `list-windows` | List windows. |
| `current-window` | Print the selected window ID. |
| `new-window` | Create a new window. |
| `focus-window` | Focus a window by handle. |
| `close-window` | Close a window by handle. |
| `resize-window` | Resize a window by handle, keeping its top-left corner fixed; prints the resulting frame size. With no `--width`/`--height`, reads the size without changing it. Does not steal focus. |
| `window displays` | List connected displays (name, index, main flag). |
| `window display <name\|index>` | Move the instance's window(s) onto a display by name (exact, substring) or index, preserving size. Does not steal focus. With `--window`, targets that window; otherwise moves all main windows. `--list` aliases `window displays`. |
| `window default-display [<name>\|--clear]` | Set, show (no arg), or clear (`--clear`) the shared, cross-tag default display that DEBUG dev builds open new windows on, stored in `~/.config/cmux/cmux.json` under `app.devWindowDisplay`. No running app required; applied at window creation. Also settable in Debug > Debug Windows > Dev Window Display. |
| `move-workspace-to-window` | Move a workspace into a target window. |
| `reorder-workspace` | Reorder a workspace inside a window. |
| `reorder-workspaces` | Atomically reorder workspaces inside pinned and unpinned groups. |
| `workspace-action` | Run workspace context-menu actions from the CLI. |
| `workspace` | Namespace for workspace verbs: `list`, `create`, `env`, `close`, `rename`, `select`, `status`, `reconnect`, `disconnect`, `group`. `workspace status` prints the workspace's todo lifecycle status (effective, inferred, override); `workspace status set <todo\|working\|needs-attention\|review\|done\|auto>` pins a manual lane (`auto` clears it; a pinned lane auto-clears once the inferred lane changes). `workspace env` prints a workspace's configured environment variables (see [Workspace environment variables](#workspace-environment-variables)); pass `--mask` to redact the values. `workspace reconnect` manually reconnects a remote (SSH) workspace — including one whose automatic reconnect suspended because the host was unreachable — and `workspace disconnect` stops its remote connection. `env`, `reconnect`, and `disconnect` accept a positional workspace handle or `--workspace <id\|ref\|index>`, defaulting to the caller's workspace, then the selected one. |
| `todo` | Per-workspace checklist namespace: `add "text" [--state <pending\|in-progress\|completed>] [--origin <user\|agent>]`, `list`, `check <index\|id>`, `uncheck <index\|id>`, `start <index\|id>` (in-progress), `edit <index\|id> "text"`, `rm <index\|id>`, `clear`, `set ['<json>']` (atomic replace from a JSON item array, inline or piped on stdin), `open` (open or focus the workspace's todo pane). Targets the caller's workspace by default with `--workspace <id\|ref\|index>` override; `<index>` is the 1-based number printed by `todo list`. Items cap at 50 per workspace. See [Workspace todos](#workspace-todos). |
| `comments` | Diff review comments namespace: `list` (alias `ls`) `[--repo <path>] [--all] [--json]` — read-only listing of review comments saved from the diff viewer for one git repository (default: the repository containing the current directory). Pending comments only by default; `--all` includes comments already delivered to an agent through a TextBox submission. Backed by the socket v2 method `comments.list`. |
| `review` | Read local adversarial-review receipts from the repository Git metadata without connecting to the cmux socket. `list` enumerates runs newest first; `show [<id\|latest>]` prints one receipt; `findings [<id\|latest>] [--all]` prints surfaced findings and hides refuted/suppressed findings by default. All subcommands accept `--repo <path>` and `--json`. |
| `vault` | Vault session-index namespace: `sessions [--agent <id>] [--folder <path>] [--limit <n>]` lists indexed agent sessions newest first; `search <query>` searches them with `agent:`/`repo:`/`ws:`/`before:`/`after:` operators; `checkpoints --agent <id> --session <id>` lists a session's checkpoint timeline (derived turn checkpoints + manual ones); `checkpoint … [--name <text>]` creates a manual checkpoint (capturing the workspace git HEAD when available); `fork … (--checkpoint <id> \| --turn <n>) [--open]` forks a new session from a checkpoint and prints the new session id (plus its resume command when one is available) (`--open` also opens it in a new workspace). Backed by the socket v2 methods `vault.sessions`, `vault.search`, `vault.checkpoints`, `vault.checkpoint`, and `vault.fork`; all support `--json`. |
| `recover` | `recover [--query <text>] [--session <id>] [--limit <n>] [--focus]` discovers local Claude recovery records through `sr recover`; an exact `--session` creates a new workspace running `sr codex` with bounded continuation context. `--json` lists records without launching. |
| `move-tab-to-new-workspace` | Move a tab or surface into a newly created workspace. |
| `list-workspaces` | List workspaces. |
| `new-workspace` | Create a workspace, optionally with cwd, command, description, layout, and per-workspace environment variables (`--env KEY=VALUE` repeatable, `--env-file <path>`). See [Workspace environment variables](#workspace-environment-variables). `--command <text>` runs in the initial interactive shell; see [Initial terminal command](#initial-terminal-command). |
| `ssh` | Open an SSH-backed workspace. Switches to it only when run interactively (`--focus [true\|false]`, `--focus=<bool>` and `--no-focus` override; `ssh-tmux` takes the same flags). Preserves the caller's live `SSH_AUTH_SOCK` for app-launched OpenSSH processes so `ForwardAgent yes` from ssh_config works normally. Supports `-A` / `--forward-agent` to request forwarding and `-a` / `--no-forward-agent` to disable forwarding for a workspace. Agent forwarding remains opt-in because forwarded agents can be used by processes on the remote host while the SSH session is active. |
| `local-tmux` | Opt in to a user-owned local tmux server. `start`, `attach`, `list`, `status`, `detach`, `close`, and `cleanup` preserve and manage named sessions independently of the cmux GUI; `cleanup` previews stale records unless `--prune` is supplied. `list`, `status`, `detach`, `close`, `cleanup`, and `attach --headless` work without a running cmux control socket. This preserves live processes across cmux lifecycle events, not a machine shutdown or reboot; use a remote tmux owner for continuity while the Mac is offline. See [`docs/local-tmux.md`](local-tmux.md). |
| `tmux attach` | Compatibility alias for `local-tmux attach`. |
| `remote-daemon-status` | Print bundled remote daemon version, asset, checksum, and cache status. |
| `ssh-session-list` | List persisted SSH PTY sessions for one remote workspace or all remote workspaces. Supports `--json`. |
| `ssh-session-attach` | Create a local terminal surface that reattaches to an existing persisted SSH PTY session. |
| `ssh-session-cleanup` | Close one or all persisted SSH PTY sessions. Supports `--json`. |
| `new-split` | Split from a surface in a direction. `--command <text>` starts a command in the new terminal; see [Initial terminal command](#initial-terminal-command). |
| `list-panes` | List panes in a workspace. |
| `list-pane-surfaces` | List surfaces in a pane. |
| `tree` | Print a window, workspace, pane, and surface tree. |
| `top` | Print process/resource usage for cmux windows, workspaces, panes, and surfaces. |
| `focus-pane` | Focus a pane. |
| `new-pane` | Create a pane with terminal or browser content. `--command <text>` is accepted for terminal panes only; see [Initial terminal command](#initial-terminal-command). |
| `new-surface` | Create a surface inside a pane. `--command <text>` is accepted for terminal surfaces only; see [Initial terminal command](#initial-terminal-command). |
| `close-surface` | Close a surface. |
| `move-surface` | Move a surface to another pane, workspace, window, or index. |
| `split-off` | Move a surface into a new split without changing focus by default. |
| `reorder-surface` | Reorder a surface within its pane. |
| `tab-action` | Run horizontal tab context-menu actions. |
| `rename-tab` | Rename a tab. Compatibility wrapper for `tab-action rename`. |
| `drag-surface-to-split` | Move a surface into a split direction. |
| `refresh-surfaces` | Ask the app to refresh terminal surfaces. |
| `reload-config` | Ask cmux to reload configuration. |
| `surface-health` | Print terminal surface health information. |
| `debug-terminals` | Print debug terminal state. |
| `trigger-flash` | Trigger a visual flash on a workspace or surface. |
| `list-panels` | List panels. Compatibility alias over pane/surface data. |
| `focus-panel` | Focus a panel. Compatibility alias over surface focus. |
| `close-workspace` | Close a workspace. |
| `select-workspace` | Select a workspace. |
| `rename-workspace`, `rename-window` | Rename a workspace. `rename-window` is a compatibility alias. |
| `current-workspace` | Print current workspace information. |
| `read-selection` | Read the active selection from a terminal, file preview, Markdown, or browser surface. Plain output includes available source context; `--json` returns the complete socket response. |
| `read-screen` | Read terminal text from a surface. `--selection` is a text-only compatibility alias for `read-selection`. |
| `send` | Send text to a terminal surface as keystrokes (`surface.send_text`). `--paste`, before the text, sends it unchanged through the Cmd+V paste path (`terminal.paste`) instead, like `cmux paste`. Without `--paste`, large multi-line text prints a hint on stderr recommending it. |
| `send-key` | Send one key to a terminal surface. |
| `paste` | Paste text from an argument or stdin into a terminal surface through the Cmd+V paste path (`terminal.paste`). The CLI sends the text unchanged; Ghostty brackets it when the program enabled bracketed paste (otherwise newlines become Enter) and replaces unsafe control bytes with spaces. `--submit` presses the agent-aware submit key afterwards. Local socket only: `terminal.paste` is not on the `cmux ssh` relay allowlist. |
| `send-panel` | Send text to a panel/surface. |
| `send-key-panel` | Send one key to a panel/surface. |
| `notify` | Send a notification to a workspace/surface and return its notification id; `--clear` clears the resolved caller/target scope. Supports `--id-format refs\|uuids\|both` for human-readable handles. |
| `list-notifications` | List queued notifications, including `created_at` and `tab_title`. |
| `dismiss-notification` | Remove one notification, or remove already-read notifications with `--all-read`. |
| `mark-notification-read` | Mark one notification, a workspace/surface scope, or all notifications read. |
| `open-notification` | Focus the notification's workspace/surface and mark it read. |
| `jump-to-unread` | Focus the latest unread notification. |
| `clear-notifications` | Clear queued notifications, optionally scoped to a workspace, surface, and `--window` context. |
| `right-sidebar` | Control right sidebar visibility, mode, focus, and state reads. |
| `set-status` | Set a sidebar status pill. |
| `clear-status` | Remove a sidebar status pill. |
| `list-status` | List sidebar status pills. |
| `set-progress` | Set sidebar progress. |
| `clear-progress` | Clear sidebar progress. |
| `log` | Append a sidebar log entry. |
| `clear-log` | Clear sidebar log entries. |
| `list-log` | List sidebar log entries. |
| `sidebar-state` | Dump sidebar metadata state. |
| `claude-hook` | Compatibility alias for Claude Code hook events from stdin JSON. |
| `set-app-focus` | Override app focus state for tests. |
| `simulate-app-active` | Trigger app-active handling for tests. |
| `browser` | Run browser automation commands. |
| `open-browser` | Legacy alias for `browser open`. |
| `navigate` | Legacy alias for `browser navigate`. |
| `browser-back` | Legacy alias for `browser back`. |
| `browser-forward` | Legacy alias for `browser forward`. |
| `browser-reload` | Legacy alias for `browser reload`. |
| `get-url` | Legacy alias for `browser get-url`. |
| `focus-webview` | Legacy alias for `browser focus-webview`. |
| `is-webview-focused` | Legacy alias for `browser is-webview-focused`. |
| `markdown` | Open a markdown file in a formatted viewer panel with live reload. |
| `vm-pty-attach` | Internal VM PTY attach command. |
| `vm-ssh-attach` | Hidden compatibility alias for older VM workspaces. |
| `vm-pty-connect` | Internal helper that connects to a VM PTY from a config file. |
| `ssh-pty-attach` | Internal helper used by SSH terminal startup scripts to bridge a local terminal surface to a remote PTY session. |
| `ssh-session-end` | Internal helper that clears remote SSH session state. |
| `__tmux-compat` | Internal tmux compatibility dispatcher. |
=======
Daemon socket order: `--socket`/`--session`, `CMUX_TUI_SOCKET`, then (macOS) the
app's session `cmux-app` or `cmux-app-<tag>` under the per-user Darwin temp
directory, then cmux-tui's `main` session.
>>>>>>> origin/feat-cmux-next

acpmux home: `ACPMUX_HOME`, else `~/.acpmux/tags/<tag>` under `CMUX_TAG`, else
`~/.acpmux` (shared with a standalone acpmux).

## Selectors

Every instance selector accepts:

1. a public id: `ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`, `browser_…`,
   `split_…`, `notification_…`, `agent_…`. Ids are persisted and survive app and
   daemon restarts;
2. `current`;
3. an exact name. `name:<value>` forces name interpretation and is required for
   names equal to `current`, names shaped like ids, and names containing `_`.

For a `current` or name selector, missing structural ancestors default to
`current`, so `cmux pane current split --right` means the session's active
workspace, screen and pane (what the user sees), not the caller's. To act on
the caller's own terminal, pass `$CMUX_TUI_TERMINAL_ID`. An id selector needs no ancestors. Nested forms name the chain
explicitly: `cmux workspace api screen current pane current split --down`.

A selector id, or an id given to `--workspace`, `--screen`, `--pane`, `--tab`,
`--tabs`, `--terminal`, `--browser`, `--split`, `--target` or `--other-*`, may
carry its session: `build-box:ws_…` routes the command to the local session
`build-box`, as `--session build-box` would. Ids from two sessions in one
command, or a qualifier with `--socket` or a different `--session`, are usage
errors. App actions take unqualified ids.

Zero matches return `selector.not_found`; more than one returns
`selector.ambiguous` with every candidate id. A supplied ancestor that does not
contain the target returns `selector.wrong_parent`. Resolution and mutation use
one snapshot, so a failed request never partially mutates.

`terminal <id> keep on|off` accepts only a `term_…` id.

## Daemon scopes

The grammar below is the `cmux <scope> --help` text. Flags in `[OPTIONS]` are
listed by that scope's help.

### workspace

```text
cmux workspace list
cmux workspace create [--name <value>] [--empty] [--ephemeral] [--correlation-key <value>]
cmux workspace <selector> show|focus|close
cmux workspace <selector> rename --name <value>
cmux workspace <selector> update [--title <value>|--clear-title] [--color <value>|--clear-color] [--icon <value>|--clear-icon]
cmux workspace <selector> move --index <n>
cmux workspace <selector> run [--on-exit <close|keep>] [--cwd <path>] [--name <value>] -- <argv...>
cmux workspace <selector> run [--on-exit <close|keep>] shell <script>
cmux workspace <selector> layout apply --layout <json>
cmux workspace <selector> screen ...
cmux workspace [<selector>] status list
cmux workspace status list --all
cmux workspace [<selector>] status set <key> <text> [--icon <value>] [--color <value>]
cmux workspace [<selector>] status clear [<key>]
cmux workspace [<selector>] progress set <0..1>|--indeterminate [--label <value>]
cmux workspace [<selector>] progress clear
cmux workspace [<selector>] log append <text> [--level info|progress|success|warning|error] [--source <value>]
cmux workspace [<selector>] log list [--limit <1..200>]
cmux workspace [<selector>] log clear
cmux workspace placement list
cmux workspace group list [--room <room>]
cmux workspace group create --name <value> [--color <token|#hex>] [--room <room>] [--index <n>] [--collapse]
cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color] [--room <room>] [--collapse|--expand]
cmux workspace group <group> delete|move --index <n>
cmux workspace group <group> add --workspace <selector> [--index <n>]
cmux workspace group remove --workspace <selector>
```

Without a selector, `status`, `progress` and `log` target the caller's
workspace (the one that holds `$CMUX_TUI_TERMINAL_ID`) inside a cmux terminal,
else `current`; with `--socket` or `--session` they target that session's
`current`. Text that starts with a dash goes after `--`. `--ephemeral` creates
an incognito workspace that the session closes at its next start. Workspace
groups and their order are personal state of this Mac's home session.

Rooms and groups (workspace, tab, screen and saved tab groups) take their id or
their exact name. The CLI reads the list on the request's connection and sends
the id, so a retry with `--idempotency-key` repeats the same request; a name
two records share is `selector.ambiguous` with their ids.

### screen

```text
cmux screen list
cmux screen create [--name <value>] [--correlation-key <value>]
cmux screen <selector> show|focus|close
cmux screen <selector> rename --name <value>
cmux screen <selector> pin|unpin
cmux screen <selector> update [--pinned <bool>] [--color <value>|--clear-color] [--icon <value>|--clear-icon]
cmux screen <selector> move --index <n>
cmux screen <selector> layout export
cmux screen <selector> layout undo [--confirm-close] [--confirmation-token <value>]
cmux screen <selector> pane ...
cmux screen group list [--workspace <selector>]
cmux screen group create --screens <screen_id,...> [--name <value>] [--color <color>]
cmux screen group <group> show|ungroup
cmux screen group <group> update [--name <value>] [--color <color>] [--collapse|--expand]
cmux screen group <group> add --screens <screen_id,...>
cmux screen group remove --screens <screen_id,...>
```

Pinned screens sort first and leave their group. Group colors are `grey`,
`blue`, `red`, `yellow`, `green`, `pink`, `purple`, `cyan` and `orange`.

### pane

```text
cmux pane list
cmux pane create [--cwd <path>]
cmux pane <selector> show|focus|close
cmux pane <selector> rename --name <value>
cmux pane <selector> split [--right|--down] [--ratio <value>] [--viewport-width <fraction>] [--cwd <path>]
cmux pane <selector> focus direction <left|right|up|down>
cmux pane <selector> neighbor <left|right|up|down>
cmux pane <selector> swap --other-workspace <sel> --other-screen <sel> --other-pane <sel>
cmux pane <selector> zoom [--enabled <bool>]
cmux pane <selector> split ratio set --split <split_id> --ratio <value>
cmux pane <selector> viewport width set --columns <value>
cmux pane <selector> run [--on-exit <close|keep>] [--cwd <path>] [--name <value>] -- <argv...>
cmux pane <selector> tab ...
```

`split` defaults to `--right`.

### tab

```text
cmux tab list
cmux tab <selector> show|focus|close
cmux tab <selector> rename --name <value>
cmux tab <selector> move --workspace <sel> --screen <sel> --pane <sel> --index <n>
cmux tab create terminal [--cwd <path>] [--name <value>] [--workspace <sel>] [--screen <sel>] [--pane <sel>]
cmux tab create browser --url <value> [--name <value>] [--workspace <sel>] [--screen <sel>] [--pane <sel>]
cmux tab <selector> terminal|browser ...
cmux tab <selector> pin|unpin
cmux tab <selector> zoom <0.25..5>|reset|in|out
cmux tab <selector> update --zoom <0.25..5>|--clear-zoom
cmux tab <selector> update --icon <value>|--clear-icon
cmux tab group list [--pane <pane_id>]
cmux tab group create --tabs <tab_id,...> [--name <value>] [--color <color>]
cmux tab group <group> show|ungroup|close
cmux tab group <group> update [--name <value>] [--color <color>] [--collapse|--expand]
cmux tab group <group> add --tabs <tab_id,...> [--index <n>]
cmux tab group remove --tabs <tab_id,...>
cmux tab group <group> move [--pane <pane_id>] [--index <n>]
cmux tab group <group> save [--room <room>]
cmux tab group saved list [--room <room>]
cmux tab group saved <saved> reopen [--pane <pane_id>]
cmux tab group saved <saved> delete
cmux tab group <group> split|column|new-workspace|unsave [OPTIONS]
```

On a terminal tab, zoom is its font scale, which the daemon stores
(`tab.update`). On a browser tab it is the page zoom, which the app that hosts
the page owns: the CLI runs the app's Zoom In, Zoom Out or Actual Size action
on the tab's pane (the tab must be the one its pane shows) and never writes the
browser tab record; an exact value is refused there. Pinned tabs sort first
and leave their group. Tab group verbs are `tab_group.*` and
`saved_tab_group.*` operations; `split`, `column`, `new-workspace` and `unsave`
have no `cmux.protocol/2` operation yet and still use private daemon commands.
Saved tab groups are personal and belong to a room (default: the default room).

### terminal

```text
cmux terminal list
cmux terminal <selector> show
cmux terminal <selector> write [--text <value>|--bytes-base64 <base64>]
cmux terminal <selector> keys <key...>
cmux terminal <selector> mouse <down|up|move|wheel> --row <n> --column <n> [--button <b>] [--delta-rows <n>] [--modifiers <list>]
cmux terminal <selector> focus <in|out>
cmux terminal <selector> screen read
cmux terminal <selector> screen wait --pattern <regex> [--timeout-ms <n>]
cmux terminal <selector> state read
cmux terminal <selector> history read [--before <n>] [--limit <n>] [--styled]
cmux terminal <selector> history clear
cmux terminal <selector> output read [--after <offset>] [--max-bytes <n>]
cmux terminal <selector> copy [--mode screen|selection|scrollback]
cmux terminal <selector> process show
cmux terminal <selector> process wait [--timeout-ms <n>]
cmux terminal <selector> viewport scroll --delta-rows <n>
cmux terminal <selector> move|project --workspace <sel> --screen <sel> --pane <sel> --index <n>
cmux terminal <selector> attach [--read-only]
cmux terminal <selector> close
cmux terminal <term_id> keep on|off
```

`write` sends text as typed, with no implied newline; without `--text` or
`--bytes-base64` it reads stdin. `keys` takes key chords joined with `+`:
modifiers `ctrl`, `alt` (or `option`), `shift`; keys `enter`, `tab`, `backtab`,
`escape`, `backspace`, `delete`, `insert`, `up`, `down`, `left`, `right`,
`home`, `end`, `pageup`, `pagedown`, `space`, `f1` to `f24`, or one character.
Example: `cmux terminal current keys ctrl+c enter`.

`screen wait` prints its result either way and exits 1 when the timeout passes
without a match.

### browser (daemon-owned)

```text
cmux browser list
cmux browser <selector> show|back|forward|reload|activate|close
cmux browser <selector> navigate --url <value>
cmux browser <selector> key --key <name> [--kind down|up|press] [--modifiers <list>]
cmux browser <selector> text --text <value>
cmux browser <selector> mouse --kind <down|up|move> --x-px <n> --y-px <n> --pointer-frame-seq <n> [--button <b>] [--click-count <n>]
cmux browser <selector> wheel --delta-x <n> --delta-y <n> --x-px <n> --y-px <n> --pointer-frame-seq <n>
cmux browser <selector> attach
```

These address `browser_…` resources. App browser tabs use the page commands in
[App scopes](#app-scopes).

### notification and notify

```text
cmux notification list [--limit <n>]
cmux notification create --title <value> --body <value> [--subtitle <value>] [--level info|success|warning|error] [--terminal <term_id>]
cmux notification clear [--terminal <term_id>]
cmux notification ack --client <id> <notification_id...>
cmux notify [--title <value>] [--subtitle <value>] [--body <value>] [--surface <term_id|current>] [--workspace <ws_id|current>]
cmux notify --clear [--surface <term_id|current>|--workspace <ws_id|current>]
```

`cmux notify` targets the caller's terminal (`CMUX_TUI_TERMINAL_ID`) unless
`--surface` names another terminal or `--workspace` asks for a session-level
row. The title defaults to `Notification`. `--clear` needs a scope. `--reply` is
refused. `--window` and `--id-format` are accepted and ignored.

### agent

```text
cmux agent list [--terminal <term_id>] [--state working|blocked|idle|done|unknown]
cmux agent report --terminal <term_id> --state <state> --source hook|socket [--source-session <id>]
cmux agent hook install|uninstall|status [provider...]
cmux agent hook emit --source <agent> --event <native-event> [--terminal <term_id>] [--payload-json <json>]
cmux agent plugin list
cmux agent plugin install <git-url> [--name <value>] [--force]
cmux agent plugin use|update|remove <name-or-id>
cmux agent plugin use --builtin
```

Hook providers are `codex`, `claude` (also `claude-code`), `gemini`, `opencode`
and `pi`. `hook emit` reads the native payload from stdin when
`--payload-json` is absent and defaults `--terminal` to `CMUX_TUI_TERMINAL_ID`.
Agents run through `cmux acp` need no hooks.

### room

```text
cmux room list
cmux room create --name <value> [--color <value>] [--icon <value>] [--theme <value>] [--index <n>]
cmux room <room> update [--name <value>] [--color|--icon|--theme <value>] [--clear-color|--clear-icon|--clear-theme]
  [--browser-profile <id>|--clear-browser-profile] [--default-session <id>|--clear-default-session]
cmux room <room> delete [--move-to <room>]
cmux room <room> move --index <n>
cmux room <room> follow --sessions <session,...>
cmux room <room> pin --workspace <selector>
cmux room unpin --workspace <selector>
```

Rooms are personal views of this Mac's home session. A room shows the
workspaces pinned to it and the unpinned workspaces of the sessions it follows.
`--sessions` is the complete follow set (`""` follows none). A workspace is
pinned to at most one room, so `unpin` names only the workspace.

### closed

```text
cmux closed list
cmux closed <closed_id> reopen
```

The session keeps recently closed tabs, screens and workspaces. A tab reopens in
its pane (else the focused pane of its workspace), a screen in its workspace, a
workspace as a new workspace.

### Other daemon scopes

```text
cmux machine list
cmux machine <selector> show
cmux session list
cmux session <selector> open|show|snapshot|ping|shutdown
cmux client list
cmux client <selector> show|detach
cmux sidebar view show|attach|input|reload [OPTIONS]
cmux sidebar plugin list|install|use|update|remove
cmux pairing request list
cmux pairing request <selector> respond <accept|reject>
cmux projection show [--projection-id <selector>]
cmux projection put --projection <json> [--projection-id <selector>]
cmux raw operation <dotted.name> [--params-json <object>] [--mutation --idempotency-key <value>] [--stream]
```

`cmux session --help` lists the journal, config, window title and terminal
defaults verbs. `raw command` is an unsafe internal escape with no
compatibility promise.

## App scopes

These need a running app.

```text
cmux app ping|identify|capabilities
cmux window list
cmux action list [--category <c>] [--noun <n>] [--available]
cmux action describe <id>
cmux action run <id> [--target <id>] [--<arg> <value>] [--arg name=value] [--wait] [--interactive]
cmux settings get [<path>]
cmux settings set <path> <value> [--confirm]
cmux settings reset <path> [--confirm]
cmux settings unset <path> [--confirm]
cmux events [--after <seq>] [--name <n>]... [--category <c>]... [--no-heartbeats]
```

`settings set` parses the value as JSON when it parses, else as a string.
`unset` is an alias of `reset`. A key only the person may change answers
`setting_user_only` (exit 1) with a hint. `--confirm` asks the person at the
Mac on a native sheet and waits for the answer with no client deadline; a
declined sheet prints "declined in cmux" and exits 1. `--` ends the options:
`cmux settings set <path> -- --confirm` sets the string "--confirm".
`events` streams JSON lines until interrupted.

Browser page commands address a browser tab the app hosts, by `tab_…` id or
`page` for the focused tab:

```text
cmux browser <tab_…|page> navigate <url>
cmux browser <tab_…|page> back|forward|reload|state
cmux browser <tab_…|page> eval <script>
cmux browser <tab_…|page> snapshot [--selector <css>] [--max-depth <n>] [--interactive]
cmux browser <tab_…|page> click|focus|text|value <selector>
cmux browser <tab_…|page> fill|type <selector> <text>
```

A `<selector>` is a CSS selector or a snapshot ref (`e3`, `@e3`).

### App actions

Every action in the app's registry is also a verb under its CLI name:
`cmux app new-window`, `cmux pane flash-focused`,
`cmux workspace move-to-window --target ws_…`. Arguments are
`--<argument> <value>` per the action's schema; `--target`, `--wait` and
`--interactive` work as in `action run`. `cmux action list` lists the names and
`cmux action describe <id>` shows the arguments and targets.

## `cmux coderouter`

```text
cmux coderouter status [--team <id>]
cmux coderouter machines [--team <id>]
cmux coderouter claude list [--team <id>]
cmux coderouter claude add oauth-token|api-key [--label <l>] [--stdin] [--team <id>]
cmux coderouter claude add bedrock [--label <l>] [--region <r>] [--model <claude>=<bedrock>]... [--team <id>]
cmux coderouter claude remove|disable|enable <account> [--team <id>]
cmux coderouter claude clear [--team <id>]
cmux coderouter <other verb> ...          # the bundled CodeRouter CLI
cmux cr ...                               # the bundled CodeRouter CLI
```

The owned verbs go to the app (`auth.status`, `coderouter.claude_upstream.get|add|update|remove|clear`,
`coderouter.machines`), which calls CodeRouter as the signed-in user and bounds
each call at 20 s. `claude add` reads its secret from `CLAUDE_CODE_OAUTH_TOKEN` or
`ANTHROPIC_API_KEY`, from stdin (`--stdin`, or any stdin that is not a
terminal), or from a hidden prompt; a secret on the command line is refused.
Bedrock reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`.
`<account>` is the id, label or masked identifier. Every other `coderouter`
verb and all of `cr` exec `Contents/Resources/bin/coderouter` of the app bundle
that contains this `cmux`, with every `CMUX_*` variable removed; arguments and
the exit code pass through.

## `cmux acp`

```text
cmux acp                                  # acpmux TUI
cmux acp ls [--status <s>] [--pending] [--tag <t>]
cmux acp new ...                          # also run, exec
cmux acp send <session> [<prompt>|-]
cmux acp attach [<session>] [--plain]
cmux acp wait [<session>...] [--timeout <s>] [--all]
cmux acp ensure|last|pending|history|compare|preset|defaults|guide ...
cmux acp session <info|cancel|stop|rename|fork|set|allow|deny|export|import|tail> ...
cmux acp daemon <run|status|shutdown|config|harnesses|reload|models|schema> ...
cmux acp host <add|ls|rm|setup> ...
cmux acp web [--no-open] [--rotate-token]
cmux acp stdio [-m HARNESS[/MODEL]] [--policy P] [--effort E] [--preset P]
cmux acp open <name> [--pane <id>]
```

`cmux acp --help` and `cmux acp <verb> --help` are authoritative. `stdio` is an
ACP agent on stdin/stdout for editors (Zed: `"command": "cmux", "args": ["acp",
"stdio", "-m", "claude"]`). `open` runs `cmux acp attach <name>` in a new tab of
the pane (`pane <id|current> run`).

## Removed

The Swift CLI verbs have these replacements. "None" means no equivalent exists
yet.

| Old | Replacement |
| --- | --- |
| `workspace:N`, `pane:N`, `surface:N`, `tab:N` refs, `--id-format` | Public ids (`ws_…`, `pane_…`, `tab_…`, `term_…`), `current`, or exact names. |
| v1 text commands, `--password` | None. The daemon speaks `cmux.protocol/2`; the app socket speaks JSON lines. |
| `new-workspace` | `cmux workspace create [--name N]`, or `cmux workspace new` (app action). |
| `list-workspaces`, `list-panes`, `list-pane-surfaces`, `tree` | `cmux workspace list`, `cmux pane list`, `cmux tab list`, `cmux terminal list`, `cmux session <sel> snapshot`. |
| `identify`, `current-workspace` | `cmux app identify`; `cmux workspace current show`, `cmux terminal current show`. |
| `select-workspace` | `cmux workspace <sel> focus`. |
| `new-split` | `cmux pane current split --right|--down`. |
| `new-pane`, `new-surface` | `cmux pane create`, `cmux tab create terminal|browser`. |
| `close-surface`, `close-workspace` | `cmux tab <sel> close`, `cmux terminal <sel> close`, `cmux workspace <sel> close`. |
| `rename-workspace`, `rename-tab` | `cmux workspace <sel> rename --name N`, `cmux tab <sel> rename --name N`. |
| `send` | `cmux terminal <sel> write --text T`. |
| `send-key` | `cmux terminal <sel> keys <chord...>`. |
| `read-screen` | `cmux terminal <sel> screen read`, `history read`. |
| `notify` | `cmux notify` (same core flags; `--reply` refused) or `cmux notification create`. |
| `trigger-flash` | `cmux pane flash-focused` (app action). |
| `browser open|goto|snapshot|click|fill|type|eval|get url` | Page commands `cmux browser <tab_…|page> …`; new tabs with `cmux tab create browser --url U`. |
| `browser wait`, cookies, storage, screenshots, downloads, console, network, frames, dialogs | None. |
| `set-status`, `clear-status` | `cmux workspace [<sel>] status set <key> <text>`, `status clear [<key>]`. (`cmux workspace set-status` is the workspace todo status action, not a status entry.) |
| `log`, `set-progress`, `clear-progress` | `cmux workspace [<sel>] log append <text>`, `progress set <0..1>`, `progress clear`. |
| `sidebar-state` | `cmux workspace [<sel>] status list`. |
| `todo` | None as a CLI verb; the app actions under `cmux action list --noun workspace` cover the checklist. |
| `claude-hook`, `codex-hook`, `hooks …` | `cmux agent hook install|uninstall|status|emit`. |
| `--workspace build-box:workspace:N`, `list-workspaces --all-sessions` | `build-box:ws_…` qualified ids and `--all-sessions` on lists (local named sessions only). |
| `agent message`, `agent inbox` | None yet. The inbox belongs to the session host that runs the recipient's terminal and has no daemon operation. |
| `markdown open`, `themes`, `vm`, `cloud` verbs, `glaeda`, `current` | None, except the app actions `cmux action list` reports (for example `cmux cloud new-machine`). |
