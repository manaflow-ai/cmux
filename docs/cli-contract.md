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
| `--all-sessions` | Run a list (`… list`) on every local session; each record gains `session`. A person only: an agent caller gets `origin.forbidden`. |
| `--machine <value>` | Constrain machine-scoped requests. |
| `--app-socket <path>` | Connect to an exact app control socket (app scopes only). |
| `--json` | Print one JSON result object. |
| `--jsonl` | Print one JSON value per result or event. |
| `--quiet` | Suppress successful output. |
| `-h`, `--help` | Show command help. |

`--socket`, `--session`, `--machine` and `--app-socket` also take the
`--flag=value` form.

A command that streams (every `stream_open` operation: `session events`,
`session journal subscribe`, `terminal attach`) has no single JSON result:
`--json` on one fails with `cli.use_jsonl`, exit 2, before anything connects.
Its message and `details.command` name the same command with `--jsonl`.

`cmux identify` with no cmux app to ask (a headless session, or `--session` or
`CMUX_TUI_SOCKET` naming a session no app owns) answers from the session
daemon: `session`, `machine`, `socket_path`, `caller` (found only in a cmux
terminal), `app_connected: false`, `app: null` and `app_error` (why no app
answered), exit 0. `--socket` and `--app-socket` still name the app socket.

`--socket` is a daemon session socket. The remote commands (`connect`, `ssh`,
`forward`, `rpc`) reach a ROUTE and refuse `--socket`. A tagged app's
`~/.local/state/cmux/cmux-debug-<tag>.sock` is the app control socket: pass it with
`--app-socket` to an app verb (`cmux --app-socket <path> app identify`).
To call one app control method of a DEV or tagged build (for example a
`debug.*` read), use `app call`:

```text
cmux --app-socket ~/.local/state/cmux/cmux-debug-<tag>.sock app call debug.surfaces '{}'
```

`app call METHOD [JSON_OBJECT]` first asks the app `system.identify` and
refuses (exit 1, `app.call_debug_only`) any app that is not a debug build
(`com.cmuxterm.app.debug[.<tag>]`). The params are sent as given, with the
CLI's `origin` (`cli` or `script`) over any `origin` in the JSON, so
person-only operations stay refused. JSON that is not one object is a usage
error (exit 2); the app's own error passes through with its code (exit 1).
Inside a tagged app's terminal, or through `CMUX_TAG=<tag>
scripts/cmux-debug-cli.sh`, the socket is found without `--app-socket`.

`app remote-views [--tab <tab>]` works with every build: it reads the app's
`remote_view.state`, one row per Cloud desktop tab (or the one `--tab`
names) with `tab`, `url`, `confirm` (the tab still asks for Connect),
`viewer` (`rd`, `vnc` or `mock`), `connected` (streaming), `control`
(`person` after the person's Take over, else `agent`) and `session` (the
stream's state, mode and frame counts). It carries no credential and no
screen content. Connect and Take over stay the person's clicks in the pane.

`app mac-screens [--tab <tab>]` works with every build: it reads the app's
`mac_screen.state`, one row per Mac Screen tab showing one of your devices
(or the one `--tab` names) with `tab`, `device_id`, `device`, `phase`
(`connecting`, `connected`, `failed`, `ended`, null with no session),
`connected`, `has_frame`, `path`, `connect_started_at` (ISO 8601) and
`first_frame_ms` (connect start to the first decoded frame on screen), `fps`,
`target_fps`, `rtt_ms`, `frames_decoded`, `frames_dropped` (frames the other
Mac numbered that never showed), `frame`, and `rtt_ms_window`,
`frame_interval_ms` and `present_ms` (decoded to shown) as `{count, p50, p95,
max}` over the last 60 round trips and 120 frames. It is read-only: it never
connects, disconnects or sends input, and carries no credential or screen
content.

`app chat perf --tab <tab> [--seconds <1-60>]` works with every build: the
app's `agent.chat.perf` runs the chat page's own capture for that many
seconds (default 5) and returns `{tab, seconds, duration_ms, measured,
unmeasured_reason, visibility, frames, long_tasks, layout_shift, records}`:
frame intervals (p50/p95/p99/max, frames over 33 and 50 ms), long animation
frames (or long tasks) with their top scripts' invoker and URL, non-input
layout shift, and for each record the selected chat receives, its time from
arrival to the first painted frame and its apply time, by kind (`tool_call`,
`tool_call_update`, `agent_message_chunk`, `other`, `all`). It never focuses,
selects, shows or un-occludes the tab; a hidden or covered page draws no
frames, so `measured` is false with `unmeasured_reason` `page_hidden` or
`no_frames`. Nothing in the page measures outside a capture. A tab that is
not an agent chat is `invalid_params`; a chat whose page this launch never
made is `unavailable`.

`app machines [--no-refresh]` works with every build: it reads the app's
`machine.list`, the right sidebar's Machines section as the person sees it,
`{machines: [{id, name, kind, isLocal, linkState, online, serverState,
joined}]}`. `kind` is `local`, `cloud`, `ssh`, `server` or `joined`;
`linkState` is `connected`, `connecting`, `offline` or `paused`; `joined` is
the hub's row (`id`, `state`, `meshPeerId`, `joinTokenId`, `platform`,
`hostname`, `lastHeartbeat`) or null. A machine reached through the hub alone
has the id `joined:<id>`, which `cmux action run machine.reconnect --target
machine:<id>` takes. It reads `cmux machine list` once first unless
`--no-refresh`.

`app join-line [--mint] [--name <name>] [--no-open]` works with every build:
it calls the app's `device.join_line`, Add Device's "Any machine" way. It
opens the card on that way unless `--no-open`; `--mint` presses Make Line
(New Line after an expiry or a failure) and waits for the line, never over a
line still showing. The reply is `{shown, way, offersInvite, phase}` with
`phase` `idle`, `minting`, `showing`, `joined`, `expired`, `failed` or
`unavailable`; `showing` adds `line`, `joinTokenId`, `expiresAt`,
`secondsLeft` and `name`, `joined` adds the machine and its checks (no line),
`failed` adds `failure`. The line carries a single-use token: the CLI prints
it and nothing logs it. It is refused with Cloud turned off.

Every command acts on one session. Without `--socket`, `--session` or
`--all-sessions`, lists and bulk commands act only on the session the CLI
finds (see [Discovery](#discovery)), so a script that lists and then closes
never reaches another session. `--all-sessions` is accepted only by list
reads and reaches the local sessions this user runs (the runtime directory's
`<name>.sock` files and the bundling app's session); sessions the app reaches
over SSH or on Cloud machines have no CLI transport yet.
`--all-sessions` is refused for an agent caller (`ACPMUX_SESSION_ID`,
`CMUX_CHIEF_OWNER_SOCKET` or `CMUX_AGENT_PRINCIPAL` set: an acpmux session, a
Chief turn, an acpmux event hook): it exits 1 with `origin.forbidden`
(`details.reason` `agent_caller`, `details.marker` the variable) and reads no
session. This keeps a person's other apps on a shared host out of an agent's
answers. It is not a sandbox: the OS boundary is still the user, and naming a
session explicitly (`--socket`, `--session`, `<session>:<id>`) still works.
`cmux chief new`, `cmux chief edit` and `cmux chief delete` are refused for
an agent caller with the same code, reason and marker (`details.refused` names
the refused word), for every field of every Chief. A Chief changes its own
profile only with its `profile` tool on its own bound connection.
`cmux chief list` stays open. `cmux chief engine` with a change
(`details.refused` `engine`), `cmux chief stop` (`stop`), `cmux chief
shutdown` (`shutdown`), `/model`, `/effort` and Ctrl+C in the chat (a note,
no call), `cmux raw operation` or `cmux raw command` naming a `chief.*` write
(`details.refused` the operation), and the app actions `home.newChief`,
`home.archiveChief`, `home.deleteChief`, `home.stopChief` and `home.stopAllAgents` (by id or CLI
name; `details.refused` the name given) are refused the same way, before any
connection.
`cmux chief engine` with no change and the `chief.engine.get`,
`chief.profile.list`, `chief.profile.get` and `chief.profile.avatar.get`
reads stay open. An action alias other than the id or CLI name is not
checked. This check is cooperative, like
the one above: the daemon cannot yet tell a Chief turn's unbound connection
from the person's.

## Output and exit codes

Human output follows the selected locale (English and Japanese; acpmux output is
English only). Results go to stdout and diagnostics to stderr.

| Exit | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Operation failure (the request ran and failed). |
| 2 | Usage error (`usage.invalid`). |
| 3 | Transport failure (no session or app socket, unreachable, broken reply). |
| 124 | A wait timed out: `screen wait`, `process wait`, `wait --until`, `send --wait`, `run`, `agents wait`, `status wait`. Its result says `timed_out: true`. On a Cloud machine, a timed-out `process wait` exits 124 only for a caller that sets `CMUX_CALLER_READS_WAIT_124=1` (the current guest adapter does); for any other it still exits 0 and says `timed_out: true`, so an older adapter keeps working. |

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
| `CMUX_TAG` | Tagged dev build; derives `~/.local/state/cmux/cmux-debug-<tag>.sock`, session `cmux-app-<tag>` and, with the bundle id, the acpmux home `~/.acpmux/builds/<build key>`. |
| `CMUX_TUI_SOCKET` | Daemon session socket. |
| `CMUX_TUI_TERMINAL_ID` | The caller's terminal (`term_…`). `cmux notify` and `agent hook emit` default to it, and `current` selectors resolve to its tab, pane, screen and workspace. |
| `ACPMUX_HOME` | acpmux state directory. Wins over the tag rule. |

App socket order: `--app-socket`, then `CMUX_SOCKET_PATH`/`CMUX_BUNDLE_ID`/`CMUX_TAG`,
then the app bundle that contains the executable (`CFBundleIdentifier` and
`LSEnvironment.CMUX_TAG`). The path table mirrors the app's `ControlSocketPath`:
release uses `~/.local/state/cmux/cmux.sock`, nightly/rc/staging use
`~/.local/state/cmux/cmux-<channel>.sock`, and a tagged debug build uses
`~/.local/state/cmux/cmux-debug-<tag>.sock`. Every one but release keeps a
symlink at its old `/tmp` name (`/tmp/cmux-debug-<tag>.sock`) for tools that
still use it; the CLI takes the old name when only it exists (an app from
before the move), and a path too long for `sun_path` stays at the old name.

<<<<<<< HEAD
Daemon socket order: `--socket`/`--session`, `CMUX_TUI_SOCKET`, then (macOS) the
app's session `cmux-app` or `cmux-app-<tag>` under the per-user Darwin temp
directory, then cmux-tui's `main` session.
=======
| Command | Contract |
| --- | --- |
| `completion <bash\|zsh\|fish>` | Print a shell completion script without connecting to cmux. |
| `welcome` | Print the welcome screen: the logo, the restored v0.64.25 shortcut list (never the user's bindings), and a pointer to `cmux shortcuts` for editing. Works without the app or a socket. |
| `sudo` | Run one command through the cmux privileged helper, prompting through the app rather than a terminal. Exits with the command's own exit code. |
| `help` | Print top-level usage, or one task-focused group of commands with `help <topic>`. Works without a socket. |
| `version` | Print the running CLI's version, build, and commit. Works without the app, a socket, or sign-in. |
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
| `chief` | Chief, the home agent. `home` and `memory` are file-only (work without the app or a socket): `home` prints the Chief home; `memory add <text\|->` saves one fact (refuses secret-looking text), `memory list`, `memory forget <id>`, and `memory path` print or change `<home>/memory/memory.jsonl` and name `person.md` and `instructions.md`. The home is `CMUX_CHIEF_HOME`, else `~/.cmux/chief/<bundle id>` from `CMUX_BUNDLE_ID` or the app that contains the CLI. All support `--json`. |
| `chief open` | Show Chief Home in the caller's window, or `--window <id\|ref>` (`chief.open`, an explicit focus-intent method like `workspace.select`). |
| `chief dispatch` | Start one coding agent on one task in one new workspace (`workspace.create`, then `surface.wait_text_change` with `--wait-working`). `--agent codex\|claude` (default `codex`, run as `codex --yolo`; `claude` runs as `claude`; `--agent-arg <arg>` appends, repeatable), `--name <title>` (default: the task's first line; the description stays empty), `--cwd <dir>`, or `--worktree <repo> [--branch <name>]`, which first runs `git -C <repo> worktree add -b <branch> -- <repo>-<slug>` without a shell (slug and default branch from the title; refuses an existing path). The task is the words after `--`, or `--prompt-file <path\|->` (`-` reads stdin); it is written to a 0600 file in a fresh private temp directory, and the new terminal types only ` /bin/sh '<dir>/launch.sh'`, which reads the task, deletes the directory and `exec`s the agent with the task as one argv word, so quotes, `$` and newlines are never shell-parsed. Being argv, the task is visible to `ps` while the agent runs. Focus follows `--focus`/`--no-focus`, else `defaultFocusForUserOpen` (background when run by an agent). `--wait-working [--timeout <s>]` (default 60, max 600; `--timeout` implies it) waits on the terminal's output (no polling) until Codex's `Working (…)` row or a Claude Code spinner row with a timer or "esc to interrupt"; a trust, bypass-mode or sign-in screen is reported, never answered. Prints `OK <workspace ref> <status> [reason]`; `--json` gives `workspace_id`, `workspace_ref`, `surface_id`, `surface_ref`, `agent`, `title`, `cwd`, `worktree`, `branch`, `status` (`working`, `started` when not waited for, `failed`), `evidence` and `reason` (`timeout`, `trust_prompt`, `sign_in`, `agent_not_found`). A failed wait exits 1 after printing. |
| `chief send` | Send a message to Chief (`chief.send`). Without `--from` it is the user's message, sent through the same store path as typing in Home; with `--from <name>` it posts a report from an agent of that name, which Chief answers unless `--no-reply`. `--conversation <id>` picks a conversation (default: the default Chief's); `-` reads the text from stdin. Prints `OK <message id>`, or `Queued` when Chief is not connected yet. |
| `chief status` | Harness, model, effort, unread count, conversation count, working conversations and the Chief home (`chief.status`). `--json` for the payload. |
| `chief conversations` | List Chief conversations, pinned first, then newest (`chief.conversations`): id, unread, flags, title, preview. |
| `chief read` | Print the newest messages of a conversation as `<time> <author>: <text>` (`chief.read`, `--limit <n>`, default 20, max 200); `--json` gives `author`, `author_kind`, `text`, `at` and `parts` kinds. |
| `chief stop` | Stop Chief's running reply in a conversation (`chief.stop`). |
| `chief approve` | Answer Chief's approval card (`chief.approve`): `[<request id>]` (default: the newest waiting card), `--deny`, or `--choice <option>`; default Allow. Prints `OK <request id> <choice>`. The same answer as the card's buttons. DEBUG builds only: a release build returns `not_available`, so no socket client (the Chief's own shell included) can answer the cards that gate the Chief's commands. |
| `chief answer` | Answer Chief's question card (`chief.answer`) with the same answer its button sends: `[<message id>]` (default: the newest waiting card), `--choice <option>` once per item (an option's label or id, case-insensitive), `--text <text>` for an Other field. An item no choice names keeps its preselected first option. Prints `OK <message id>` and the answer lines. DEBUG builds only: a release build returns `not_available`. |
| `omo` | Launch OpenCode with oh-my-openagent integration. |
| `omx` | Launch Oh My Codex with cmux pane integration. |
| `omc` | Launch Oh My Claude Code with cmux pane integration. |
| `hooks` | Agent hook integrations under one namespace: `setup` and `uninstall` (both take an optional agent name), `help`, the per-agent `install` and `uninstall` actions (`cmux hooks codex install`), and the per-agent hook actions the installed hooks call back into. |
| `setup-hooks`, `uninstall-hooks` | Compatibility aliases for `hooks setup` and `hooks uninstall`, kept for hook setup docs and scripts written before `cmux hooks`. |
| `codex` | Compatibility alias for installing or uninstalling Codex hooks. |
| `ping` | Check socket connectivity. |
| `capabilities` | Print server capabilities as JSON. |
| `iroh-diag` | Print this host's Iroh Connection Report: the same data as Settings > Networking > Connection Report. |
| `events` | Stream reconnectable cmux events as newline-delimited JSON. |
| `automation` | Manage config-backed event rules: `list`, `show <id>`, dry-run `test <id> --event <json>`, `enable`, `disable`, `logs`, and `reload`. Rules live in `~/.cmuxterm/automations.json`; actions are dispatched by the running app. |
| `glaeda` | Emit one caller-neutral `glaeda-external-execution-request/v1` and validate/correlate one bounded Glaeda receipt. `request` and `observe` are local data operations and do not require a running cmux socket. They carry exact Git source plus caller correlation only; CMUX workspace/UI and provider placement stay outside the request. |
| `current` | Print bounded current-work facts (`--limit <1...200>`, `--json`). Read-only: it does not refresh machines, read transcripts, or change any work item. See [Glaeda execution exchange and current-work ownership](#glaeda-execution-exchange-and-current-work-ownership). |
| `sessions [list]` | List saved agent session records without requiring a running cmux socket. Filters: `--agent <name>`, `--session <id>`, `--workspace <id>`, `--surface <id>`, `--cwd <text>`. Overrides: `--state-dir <path>`, `--codex-home <path>`. Text output defaults to 100 results; `--limit <n>` takes a positive integer and `--all` removes the limit. Supports `--json`. Records also report metadata for matching cmux-owned scratch roots (`scratch_owned`, byte count, file count, and root path); unmarked directories are never scanned. |
| `session-debug` | Alias for `sessions debug`, kept for older debug scripts. Works without a socket. |
| `session restore [--list] [--session <id>]...` | Recover stopped Claude sessions from the agent journal. `--list` inspects candidates; repeatable `--session` selects exact ids. Without ids, restore acts only after an unexpected quit. Requires a running cmux, but help works without a socket. Each restored session opens in its own background workspace and resumes through its recorded launcher. |
| `session move <session-id> --to <ssh-destination\|local>` | Move a stopped Claude Code session between this Mac and an SSH host and resume it there. Refuses while a Claude process for the session runs on either side. Carries the cwd's git checkout (a snapshot commit of the working tree on top of HEAD at `refs/agent-move/<id>`, HEAD on the same branch when it is safe, plus modified, deleted and untracked non-ignored files; adds a worktree when the repository exists on the destination but the path does not; refuses when the destination has its own uncommitted changes or its branch has commits HEAD lacks), then the transcript, its session directory, file history, and the project memory directory (merged both ways, newest wins, nothing deleted). When the destination home is not the same directory at the same path, paths under the home are mapped and the project is re-slugged. Opens a `cmux ssh` workspace (or a local workspace for `--to local`) that resumes the session with its recorded launcher (on a host, cmux-owned launchers such as `claude-teams` fall back to the plain agent command), and clears the old local surface's resume binding. `--from` defaults to where the last move put the session (`~/.cmuxterm/agent-moves/<id>.json`). Flags: `--name`, `--no-code`, `--port`, `--identity`, `--ssh-option`, `--no-focus`. |
| `auth`, `login`, `logout` | `auth <status\|login\|logout\|team>`, with `status` the default; `team` carries `list`, `use`, and `create`. Sign-in and sign-out run through the app, and `login` waits for the browser round trip. `login` and `logout` are top-level aliases for `auth login` and `auth logout`. |
| `billing` | `billing checkout --plan <go\|pro\|max> [--no-open]` prints the plan's checkout URL and opens it in the browser. `--no-open` and `--json` print without opening. |
| `ai-accounts` | Manage the team's uploaded AI provider accounts. `list` (alias `ls`) takes `--team <id>`; `upload <claude\|codex\|anthropic-key\|openai-key>` takes `--label`, `--team`, `--validate`, and, for the key providers only, `--key <value>` (otherwise `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` is read from the invoking shell); `remove <id>` needs the account id. Any other provider name is rejected. |
| `coderouter`, `cr` | `cmux coderouter <status\|machines\|claude\|agent>` manages the team's coderouter model plane through the app (sign-in state, per-machine usage, the team's Claude upstream accounts). Every other `cmux coderouter ...` verb and all of `cmux cr ...` exec the CodeRouter CLI unchanged with the `CMUX_*`/`CMUXD_*` environment stripped: `coderouter` or `cr` on PATH first, then the official installer's `~/.coderouter/bin/coderouter` (`$CODEROUTER_INSTALL/bin` when set), never with a network call. When neither exists and stdin and stderr are terminals, cmux shows the documented installer `curl -fsSL https://cmux.com/coderouter/install.sh | sh`, says what it does (checksum-verified binary into `~/.coderouter/bin`, PATH line in the shell profile), asks once (`Install CodeRouter now? [y/N]`), and after `y` fetches the script, runs it with `sh`, and execs the new install with the original arguments. Any other outcome (non-interactive, declined, download or installer failure) prints that install command on stderr and exits 127. |
| `vm`, `cloud` | Manage cloud VMs and their HTTPS publications. `cloud` is an alias for `vm`. |
| `agent` | Runs `vm agent`, accepting one extra spelling it does not: a leading agent name (`claude`, `codex`, `opencode`, `pi`) is rewritten to `--agent <name>` and the rest of the line becomes the prompt. Any other leading word is passed through unchanged, so `vm agent`'s own `--agent` form works here too. |
| `vpn` | Control the system-wide Network Extension tunnel, which exists so *other* apps on this Mac can reach the team's Cloud machines; cmux's own terminals, Ports, and Desktop use a separate user-space hub and do not need it. `up` (alias `on`) and `down` (alias `off`) require a build with a signed Network Extension and fail with an explanation otherwise; `status` (the default) always reports both tunnels; `revoke` removes this Mac's access to the Cloud network entirely, not just the system-wide route. |
| `cloud guide`, `cloud --skill` (also `vm guide`, `vm --skill`) | Print the same short Cloud guide without connecting to the app. `--json` returns `{topic: "cloud", format: "markdown", content: "..."}`. This does not install a skill or start an agent; `vm prompt` and its existing `vm skill` alias keep that behavior. |
| `remotes`, `remote` | Manage remote Macs in the team device registry so they appear in the iOS app's device list. `remote` is an alias for `remotes`. |
| `mobile` | Mobile client settings: `set-font <points>` sets the iOS terminal font size for a surface or workspace, and `compatible-tags [list\|set <tags...>\|add <tags...>\|remove <tags...>\|clear]` manages the sibling Mac dev tags this Mac grants to its paired development phones, so a DEV iPhone build can pair with more than its exact-tag Mac. |
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
| `workspace-group` | Sidebar workspace group namespace: `list`, `create`, `rename`, `ungroup`, `delete`, `collapse`, `expand`, `pin`, `unpin`, `add`, `remove`, `set-anchor`, `set-color`, `set-icon`, `move`, `focus`, `new-workspace`. `delete` only closes the grouped workspaces when `--close-workspaces` is passed; without it, it ungroups them exactly like `ungroup`. Both accept `--remove-generated-anchor`. |
| `todo` | Per-workspace checklist namespace: `add "text" [--state <pending\|in-progress\|completed>] [--origin <user\|agent>]`, `list`, `check <index\|id>`, `uncheck <index\|id>`, `start <index\|id>` (in-progress), `edit <index\|id> "text"`, `rm <index\|id>`, `clear`, `set ['<json>']` (atomic replace from a JSON item array, inline or piped on stdin), `open` (open or focus the workspace's todo pane). Targets the caller's workspace by default with `--workspace <id\|ref\|index>` override; `<index>` is the 1-based number printed by `todo list`. Items cap at 50 per workspace. See [Workspace todos](#workspace-todos). |
| `comments` | Diff review comments namespace: `list` (alias `ls`) `[--repo <path>] [--all] [--json]` — read-only listing of review comments saved from the diff viewer for one git repository (default: the repository containing the current directory). Pending comments only by default; `--all` includes comments already delivered to an agent through a TextBox submission. Backed by the socket v2 method `comments.list`. |
| `pr` | Attach, replace, or clear a pull-request link for the caller's workspace: `cmux pr <url\|number>` or `cmux pr clear`, with optional `--workspace` and `--window` selectors. Validates the repository and pull-request metadata before changing the sidebar, preserves the link through watcher refreshes, and does not change focus. |
| `review` | Read local adversarial-review receipts from the repository Git metadata without connecting to the cmux socket. `list` enumerates runs newest first; `show [<id\|latest>]` prints one receipt; `findings [<id\|latest>] [--all]` prints surfaced findings and hides refuted/suppressed findings by default. All subcommands accept `--repo <path>` and `--json`. |
| `vault` | Vault session-index namespace: `sessions [--agent <id>] [--folder <path>] [--limit <n>]` lists indexed agent sessions newest first; `search <query>` searches them with `agent:`/`repo:`/`ws:`/`before:`/`after:` operators; `checkpoints --agent <id> --session <id>` lists a session's checkpoint timeline (derived turn checkpoints + manual ones); `checkpoint … [--name <text>]` creates a manual checkpoint (capturing the workspace git HEAD when available); `fork … (--checkpoint <id> \| --turn <n>) [--open]` forks a new session from a checkpoint and prints the new session id (plus its resume command when one is available) (`--open` also opens it in a new workspace). Backed by the socket v2 methods `vault.sessions`, `vault.search`, `vault.checkpoints`, `vault.checkpoint`, and `vault.fork`; all support `--json`. |
| `recover` | `recover [--query <text>] [--session <id>] [--limit <n>] [--focus]` discovers local Claude recovery records through `sr recover`; an exact `--session` creates a new workspace running `sr codex` with bounded continuation context. `--json` lists records without launching. |
| `move-tab-to-new-workspace`, `detach-tab` | Move a tab or surface into a newly created workspace. `detach-tab` is an alias. |
| `list-workspaces` | List workspaces. |
| `new-workspace` | Create a workspace, optionally with cwd, command, description, layout, and per-workspace environment variables (`--env KEY=VALUE` repeatable, `--env-file <path>`). See [Workspace environment variables](#workspace-environment-variables). `--command <text>` runs in the initial interactive shell; see [Initial terminal command](#initial-terminal-command). |
| `layout` | Saved workspace layouts: `save <name> [--workspace <ref>] [--overwrite] [--description <text>]`, `list [--json]`, `get <name>`, `open <name> [--cwd <dir>] [--focus <true\|false>]`, `delete <name>`. |
| `ssh` | Open an SSH-backed workspace. `ssh <destination> [--name <title>] [--port <n>] [--identity <path>] [-A\|-a] [--ssh-option <opt>]... [--window <id\|ref\|index>] [--transport <ssh\|mosh>] [--focus\|--no-focus] [--command <text> \| -- <remote-command-args>]`. `--ssh-option` adds one `ssh -o` option and may repeat; `--command` runs its text once in the first remote terminal after the shell starts; `--transport mosh` carries only the interactive terminal over Mosh and falls back to SSH when Mosh is missing on either side; arguments after `--` are passed to the remote command and cannot be combined with `--command`. Switches to it only when run interactively (`--focus [true\|false]`, `--focus=<bool>` and `--no-focus` override; `ssh-tmux` takes the same flags). Preserves the caller's live `SSH_AUTH_SOCK` for app-launched OpenSSH processes so `ForwardAgent yes` from ssh_config works normally. Supports `-A` / `--forward-agent` to request forwarding and `-a` / `--no-forward-agent` to disable forwarding for a workspace. Agent forwarding remains opt-in because forwarded agents can be used by processes on the remote host while the SSH session is active. |
| `mosh` | Open an SSH-backed workspace that uses Mosh as the interactive transport, while SSH stays the management lane. Takes the same arguments as `ssh`. |
| `mosh-tmux` | Open a Mosh-backed workspace whose terminal creates or attaches to one named remote tmux session (`--session <name>`, default `main`), surviving workspace reconnect and session restore. Every other workspace and SSH bootstrap flag matches `mosh`, but it takes no remote command arguments after `--`; without Mosh on the host, the same tmux profile runs over SSH. |
| `ssh-tmux` | Mirror a remote host's tmux sessions into the current window over SSH tmux control mode (`tmux -CC`): each session becomes a workspace, each window a tab, each pane a split. `ssh-tmux <destination> [list\|ls [--json] \| attach <session>] [--port <n>] [--identity <path>] [--socket-name <name>] [--name <title>] [--no-focus]`. `list`/`ls` discovers sessions without opening a workspace; `--json` emits the socket response; `attach <session>` mirrors only the named existing session and fails if it is missing. With no subcommand, the historical whole-server mirror remains the default. `--socket-name <name>` mirrors the tmux server started with `tmux -L <name>` instead of the default server: every remote tmux command, including the control-mode attach, carries `-L <name>`, and the name is part of the host's connection identity, so two windows can mirror two servers on one host without sharing a connection. Names are 1-64 ASCII letters, digits, `.`, `_` or `-`, cannot start with `-`, cannot be `.` or `..`. Only a non-default name reaches tmux: `--socket-name default` names tmux's default server, so cmux sends no `-L` for it, exactly as when the flag is omitted. A named server is treated as the default one is when it has nothing to mirror: with no subcommand cmux starts one session on it, so a name that matches no running server starts a new server rather than failing, while `list` reports no sessions and `attach <session>` fails. |
| `local-tmux` | Opt in to a user-owned local tmux server. `start`, `attach`, `list`, `status`, `detach`, `close`, and `cleanup` preserve and manage named sessions independently of the cmux GUI; `cleanup` previews stale records unless `--prune` is supplied. `list`, `status`, `detach`, `close`, `cleanup`, and `attach --headless` work without a running cmux control socket. This preserves live processes across cmux lifecycle events, not a machine shutdown or reboot; use a remote tmux owner for continuity while the Mac is offline. See [`docs/local-tmux.md`](local-tmux.md). |
| `tmux attach` | Compatibility alias for `local-tmux attach`. |
| `local-zellij` | Opt in to zellij sessions in a private socket directory. `start`, `attach`, `list`, `status`, and `close` manage named sessions independently of the cmux GUI; clients attach with `--on-force-close detach`, so closing a surface detaches instead of ending the session. `list`, `status`, `close`, `start --detached`, and `attach --headless` work without a running cmux control socket. See [`docs/local-zellij.md`](local-zellij.md). |
| `remote-daemon-status` | Print bundled remote daemon version, asset, checksum, and cache status. |
| `ssh-session-list` | List persisted SSH PTY sessions for one remote workspace (`--workspace <id\|ref\|index>`, default `$CMUX_WORKSPACE_ID`) or every active remote workspace (`--all-workspaces`). Supports `--json`. |
| `ssh-session-attach` | Create a local terminal surface that reattaches to an existing persisted SSH PTY session. `ssh-session-attach --session-id <id> [--workspace <id\|ref\|index>] [--pane <id\|ref\|index> \| --split <left\|right\|up\|down> [--surface <id\|ref\|index>]] [--focus <true\|false>]`. `--pane` puts the new surface in that pane; `--split` opens a new split instead, beside `--surface`, and cannot be combined with `--pane`; the attached surface is focused unless `--focus false`. Supports `--json`. |
| `ssh-session-cleanup` | Close persisted SSH PTY sessions: one (`--session-id <id>`) or all (`--all`) in one remote workspace (`--workspace <id\|ref\|index>`, default `$CMUX_WORKSPACE_ID`) or in every active remote workspace (`--all-workspaces`). Supports `--json`. |
| `new-split` | Split from a surface in a direction. `--command <text>` starts a command in the new terminal; see [Initial terminal command](#initial-terminal-command). |
| `list-panes` | List panes in a workspace. |
| `list-pane-surfaces` | List surfaces in a pane. |
| `tree` | Print a window, workspace, pane, and surface tree. |
| `top` | Print process/resource usage for cmux windows, workspaces, panes, and surfaces. |
| `memory` | Print the app's own memory use separately from the recursive RSS of terminal child processes, so a heavy child process does not read as an app leak. |
| `focus-pane` | Focus a pane. |
| `new-pane` | Create a pane with terminal or browser content. `--command <text>` is accepted for terminal panes only; see [Initial terminal command](#initial-terminal-command). |
| `new-surface` | Create a surface inside a pane. `--command <text>` is accepted for terminal surfaces only; see [Initial terminal command](#initial-terminal-command). `--profile <name\|uuid>` is accepted for browser surfaces only and selects the cmux browser profile, like `new-pane`. |
| `close-surface` | Close a surface. |
| `move-surface` | Move a surface to another pane, workspace, window, or index. |
| `split-off` | Move a surface into a new split without changing focus by default. |
| `reorder-surface` | Reorder a surface within its pane. |
| `tab-action` | Run horizontal tab context-menu actions. |
| `rename-tab` | Rename a tab. Compatibility wrapper for `tab-action rename`. |
| `drag-surface-to-split` | Move a surface into a split direction. |
| `canvas` | Canvas layout namespace: `info`, `mode`, `set-frame`, `align`, `reveal`, `overview`, `zoom`, `join`, `break`, `select-tab`, `set-viewport`, `new-pane`. Most take a required argument: `mode`, `align`, and `zoom` a direction or mode word, `set-frame` numeric `--x --y --width --height`, `set-viewport` numeric `--x --y` and an optional numeric `--zoom`, `join` a target. `set-frame`, `join`, `break`, and `select-tab` need a surface, positionally or with `--surface <id\|ref>`; `reveal` takes one optionally, and `align` takes none, because its positional is the align command. `new-pane` takes an optional `--type terminal\|browser\|simulator\|chief`. `--workspace <ref>` scopes the whole namespace. An unknown option, an option without a value, or an extra argument is rejected before any request is sent. |
| `refresh-surfaces` | Ask the app to refresh terminal surfaces. |
| `surface-resume` | Read or change a surface's agent resume binding: `show` (the default, alias `get`), `set`, `clear`. `set` requires the command to run, as `--shell <command>` or `-- <argv...>`; a bare word after `--shell` is rejected rather than appended. Also spelled `surface resume`. |
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
| `record` | Record a cmux window or a region of one to an mp4 or gif (`window.record.*`). `start` returns a recording id and the output path, `stop` closes the clip, `status` reports progress, `note` adds a caption drawn into later frames, `list` shows the current and recent recordings. One recording at a time; a recording stops itself at `--max-seconds`. The clip appears at its path when the recording ends, so an existing file there is replaced only once there is a finished clip to replace it with, and a recording that never closes leaves the path alone. Local socket only: `window.record.*` is not on the `cmux ssh` relay allowlist. |
| `shot`, `screenshot` | Screenshot a cmux window or a region of one to a png or a jpeg (`window.screenshot`). Prints the pixel size, the byte count and the output path. `--region` takes the same four window-point numbers as `cmux record --region`, `--caption` draws a caption into the image, and `--quality` applies to jpeg only. Only cmux's own windows are captured, so no Screen Recording permission is involved and this works in a Release build and inside CI. The image is encoded beside the output path and moved into place, so an existing file there is replaced only once there is a complete image to replace it with. Local socket only: `window.screenshot` is not on the `cmux ssh` relay allowlist. |
| `send` | Send text to a terminal surface as keystrokes (`surface.send_text`). `--paste`, before the text, sends it unchanged through the Cmd+V paste path (`terminal.paste`) instead, like `cmux paste`. Without `--paste`, large multi-line text prints a hint on stderr recommending it. Refuses to type over an agent prompt draft or into an open dialog unless `--force` comes before the text; see [Draft guard](#draft-guard). |
| `send-key` | Send one key to a terminal surface. Refuses to send into an open agent dialog unless `--force`. |
| `agent message` | Send a message to the agent in another workspace or surface (`agent.message.send`). Delivered through the recipient's agent hooks, never as keystrokes. `--reply-to <id>` answers a received message; `-` reads the text from stdin. |
| `agent inbox` | List agent messages newest first (`agent.message.list`); `--mark-read` marks the listed messages read. |
| `agent messages [on\|off\|status] [<target>] [--workspace]` | Turn agent messages off or on for one surface (default: the caller's) or, with `--workspace`, a whole workspace (`agent.message.settings`). Turning them off refuses new messages to it and fails the ones already queued. The app-wide switch is `agentMessages.enabled`. |
| `paste` | Paste text from an argument or stdin into a terminal surface through the Cmd+V paste path (`terminal.paste`). The CLI sends the text unchanged; Ghostty brackets it when the program enabled bracketed paste (otherwise newlines become Enter) and replaces unsafe control bytes with spaces. `--submit` presses the agent-aware submit key afterwards. Refuses to paste over an agent prompt draft or into an open dialog unless `--force`. Authenticated remote-workspace relays may use `terminal.paste` only with an exact owned workspace/surface and `submit_key` `none` or `return`; the relay cannot use window/focus fallback selectors or arbitrary submit keys. |
| `send-panel` | Send text to a terminal surface. Same draft guard and `--force` as `send`. |
| `send-key-panel` | Send one key to a terminal surface. Same dialog guard and `--force` as `send-key`. |
| `notify` | Send a notification to a workspace/surface and return its notification id; `--clear` clears the resolved caller/target scope. `--desktop <true\|false>` (also `--desktop=<value>`) sets the notification's `desktop` effect before notification hooks run, sent as `effects: {"desktop": <value>}` on the create request: `false` records the entry in the Notifications panel, sidebar badge and pane ring without a native banner; `true` is the default and changes nothing; hooks can still override it; it has no effect with `--clear`. Supports `--id-format refs\|uuids\|both` for human-readable handles. |
| `list-notifications` | List queued notifications, including `created_at` and `tab_title`. |
| `dismiss-notification` | Remove one notification, or remove already-read notifications with `--all-read`. |
| `mark-notification-read` | Mark one notification, a workspace/surface scope, or all notifications read. |
| `open-notification` | Focus the notification's workspace/surface and mark it read. |
| `jump-to-unread` | Focus the latest unread notification. |
| `jump-to-last-prompt` | Focus the surface where you last submitted an agent prompt. |
| `clear-notifications` | Clear queued notifications, optionally scoped to a workspace, surface, and `--window` context. |
| `left-sidebar` | Show, hide, focus, and read the left (workspace) sidebar. |
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
| `codex-hook` | Compatibility alias for Codex hook events from stdin JSON, kept for hooks installed before `cmux hooks`. Outside a cmux terminal, with no `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` and no `--surface`/`--workspace`, it prints `{}` and exits so an old installed hook cannot fail a shell. Hidden from help. |
| `feed-hook` | Compatibility alias for Feed hook events from stdin JSON, kept for hooks installed before `cmux hooks`. Requires `--source <name>`. Outside a cmux terminal, with no `CMUX_SURFACE_ID`/`CMUX_WORKSPACE_ID` and no `--surface`/`--workspace`, it prints `{}` and exits so an old installed hook cannot fail a shell. Hidden from help. |
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
| `diff` | Open a diff in a viewer panel: a patch file (or `-` for stdin), or a git source via `--source`, `--repo`, `--base`, `--branch`, `--branch-base`, `--staged`, `--unstaged`, `--path`, `--cwd`, `--session`, `--last-turn`, or `--agent-session`. A patch file and a git source cannot be combined. `--title`, `--layout`, and `--font-size` control presentation; the panel opens in the background unless `--focus true`. Targets `--window`, `--workspace`, and `--surface`, defaulting to the caller's surface. Supports `--json`. |
| `diff-viewer-server` | Start the local HTTP server that backs diff viewer panels for one `--root <path>`; the directory must pass the diff viewer permission checks. Runs in the foreground and needs no socket. |
| `project` | `project open <path>` opens an `.xcodeproj` or `.xcworkspace` in the project pane. |
| `simulator` | Drive the iOS Simulator behind a surface (`--surface <id\|ref\|index>`), waiting for each correlated Simulator-worker result: `select` (alias `select-device`), `type`, `tap`, `gesture` (aliases `multitouch`, `multi-touch`), `swipe`, `button`, `rotate`, `ca`, `memory-warning` (alias `memory_warning`), `event-log` (alias `events`), `tools`, `camera`, `permissions`, `ui`, `accessibility` (alias `ax`), `foreground`, plus the Web Inspector set `targets`, `attach`, `send`, `highlight`, and `release`. |
| `ios` | Accepts every `simulator` subcommand unchanged, plus `list` (iOS surfaces), `context` (the caller's iOS surface, `--udid` for the identifier alone), and `screenshot`. |
| `vm-pty-attach` | Internal VM PTY attach command. |
| `vm-ssh-attach` | Hidden compatibility alias for older VM workspaces. |
| `vm-pty-connect` | Internal helper that connects to a VM PTY from a config file. |
| `ssh-pty-attach` | Internal helper used by SSH terminal startup scripts to bridge a local terminal surface to a remote PTY session. |
| `ssh-session-end` | Internal helper that clears remote SSH session state. |
| `__tmux-compat` | Internal tmux compatibility dispatcher. |
| `report_pwd`, `report_git_branch`, `report_pr_action` | Internal shell integration entrypoints that forward one piece of sidebar metadata from a terminal's shell hooks and print the app's reply. |
| `simulate-sidebar-drag` | Internal test helper that replays a sidebar drag; requires `--window`, `--from`, and `--to`, with optional `--duration-ms` and `--steps`. |
| `vm-tui-connect` | Internal helper that replaces itself with the cmux-tui client for one machine. Requires `--config <file>`, a one-shot JSON config it deletes as it reads. |
| `__owned-process-supervisor` | Internal supervisor that spawns the executable named by its first argument with the rest of the line as that program's arguments, with the supervisor's own stdin inherited by the target. Its lease is the process that launched it: when that process exits, or the supervisor is sent `SIGTERM`, `SIGINT` or `SIGHUP`, it sends `SIGTERM` to the target's process group and `SIGKILL` one second later. Never run by hand. |
| `__codex-teams-app-server-supervisor` | Internal supervisor for `codex-teams` app servers. Same spawn and group termination as `__owned-process-supervisor`, but the lease is the lifetime of its inherited descriptors rather than its parent process, so it holds its own stdin and opens `/dev/null` as the target's. Never run by hand. |
| `__codex-teams-watch` | Internal watcher backing `codex-teams` panes. Requires `--workspace-id`, `--surface-id`, and `--app-server-url`; also takes `--codex-path`, `--launch-path`, `--max-auto-depth`, and `--owner-pid` (it exits with that process). |
| `__sidebar_footer_icon_balance` | Internal debug verb that opens the sidebar footer icon balance window and prints `OK`. Present in debug builds only; a release build reports an unknown command. |
| `__internal_flags` | Internal debug verb that opens the app's internal flags window and prints `OK`. It does not print the flag state to stdout. |
| `__restore-lease-watch` | Internal watcher that takes one process id and exits when that process does, releasing the agent restore launch lease. Exits 64 without a usable pid. |
| `__sigpipe-probe` | Internal probe that re-runs the CLI to check SIGPIPE disposition; the optional first argument selects the mode (`spawn` by default). |
| `__sigpipe-stdin-pipe-probe` | Internal probe that writes 1 MiB to a shell which closes stdin, checking that a broken input pipe does not kill the CLI. Prints `ok`. |
| `__sigpipe-inspect` | Internal probe printing this process's SIGPIPE disposition as JSON, to stdout or to `--out <path>`. |
| `__ssh-terminal-exit-prompt` | Internal helper that holds a disconnected SSH terminal open until a keypress, used by SSH terminal exit scripts. |
| `__ssh-pty-flush-input` | Internal helper that discards pending terminal input before an SSH PTY hands the terminal back. Takes no arguments. |
| `__diff-viewer-refs` | Internal diff viewer helper listing candidate base refs for `--repo <path>`, with `--base`, `--token`, and `--suggested-only`. The repository must be in the diff viewer allow-list. |
| `__diff-viewer-branch` | Internal diff viewer helper regenerating one branch comparison; requires `--group`, `--repo`, and `--base`, with an optional `--token`. |
| `__debug-tmux-compat-env` | Internal debug probe printing the environment a tmux compatibility agent would be launched with, resolved against the socket this command was pointed at. |
| `__cmux-sudo-runner` | Internal sudo broker entrypoint that runs one approved sudo manifest under its own process-tree deadline. Takes a request id and a base64 manifest, and checks that its parent is the enclosing app; exits 2 on any other argument shape. Only the broker invokes it. |
| `__cmux-sudo-privileged-executor` | Internal sudo broker entrypoint re-entered as root after sudo authenticates. Takes exactly four arguments (reviewed byte count, absolute deadline, display name, control token) and exits 126 unless it is running as root. Only the broker invokes it. |
>>>>>>> origin/main

acpmux home: `ACPMUX_HOME`, else the home of the CLI's build (`CMUX_BUNDLE_ID` and
`CMUX_TAG`, else the app bundle around the CLI; schemas/build-identity/vectors.json):
`~/.acpmux` for NIGHTLY (`com.cmuxterm.app.nightly`) and outside any app (shared
with a standalone acpmux), `~/.acpmux/builds/<build key>` for every other build.

## Selectors

Every instance selector accepts:

1. a public id: `ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`, `browser_…`,
   `split_…`, `notification_…`, `agent_…`. Ids are persisted and survive app and
   daemon restarts;
2. `caller` or `current`, the caller's own object, or `focused`, the one the
   person looks at;
3. an exact name. `name:<value>` forces name interpretation and is required for
   names equal to `current`, names shaped like ids, and names containing `_`.

For a `caller`, `current` or name selector, missing structural ancestors
default to `current` (for `focused`, to `focused`). `caller` and `current` are
the caller's own place: from a cmux terminal (`$CMUX_TUI_TERMINAL_ID`) the CLI
reads the tab, pane, screen and workspace that hold it; from an agent chat
(`$CMUX_AGENT_SESSION`) or a Chief turn it asks the app that owns the daemon
where the chat is. So `cmux pane current split --right` splits the caller's
own pane even while the person looks at another workspace, and
`cmux tab create terminal` from a terminal with no `--workspace`, `--screen` or
`--pane` opens in the caller's pane. `caller` fails without a caller; `current`
is then the session's active object, as it is outside cmux and with
`--socket`, `--session` or `--machine`. `focused` is the app's focused
workspace, screen and pane, and the daemon's active ones without an app that
owns the daemon. An id selector needs no ancestors. Nested forms name the chain
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
cmux workspace <selector> run [--on-exit <close|keep|shell>] [--cwd <path>] [--name <value>] -- <argv...>
cmux workspace <selector> run [--on-exit <close|keep|shell>] shell <script>
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

<<<<<<< HEAD
```text
cmux status wait KEY [--target <ws_…>|current] [--until settled|cleared|state=<s>] [--timeout <500ms|30s|5m>|--timeout-ms <n>]
=======
`cmux current --json` and **Find Work** continue to read the same bounded,
read-only projection of work already owned by CMUX, as described in
[Current work](current-work.md). When an existing owner records its normal
lifecycle change, that ordinary CMUX projection reflects it. The execution
transport, machine placement, physical attempt, and recovery truth remain with
their existing owners rather than being duplicated into a second CMUX ledger.

## Draft Guard

Before writing, `send`, `send-panel` and `paste` (and `send --paste`) ask the
app for `surface.input_state` and refuse when an agent's prompt holds text
someone is typing, or when a question or permission dialog is open in an
agent. `send-key` and `send-key-panel`, and `send` of text that only presses
Enter, refuse only for an open dialog: `cmux send "text"` followed by
`cmux send-key enter` leaves the sent text in the prompt, and the key has to
go through. Surfaces without an agent are never blocked. A refusal writes nothing, prints the reason on stderr
and exits non-zero. `--force`, before the text or key, skips the check. When
the app can't answer `surface.input_state` (an older build, or a `cmux ssh`
relay, which doesn't forward it) the commands write as before.

`surface.wait_text_change` is a v2 worker-lane socket method that waits for a
terminal's text to change. It takes the `surface.read_text` params, plus
`after_revision` (a `revision` from an earlier reply) and `timeout_ms` (0 to
600000, default 30000). Without `after_revision` it answers at once. Otherwise
it answers when the text differs from that revision or the timeout passes,
with the `surface.read_text` payload plus `revision` and `changed` (`false`
only at the timeout). The app wakes the wait on the terminal's own output, so
a caller loops read, decide, wait without sleeping. A terminal that is not
running yet is waited for rather than reported. A `cmux ssh` relay does not
forward it.

`surface.input_state` is a v2 worker-lane socket method. It takes
`surface_id`, or the usual workspace selectors for that workspace's focused
surface, and returns:

| Field | Meaning |
| --- | --- |
| `state` | `empty`, `draft`, `dialog`, or `unknown` when no agent prompt is on screen. Read from the active screen (not the scrolled viewport): Claude Code's and Codex's input rows, ignoring faint placeholder text, and key hints such as "Esc to cancel" below the input row. |
| `draft_length` | Characters in the draft, when `state` is `draft`. The text itself is not returned. |
| `agent` | Whether an agent reports lifecycle state for the surface. |
| `lifecycle` | The agent's lifecycle: `unknown`, `running`, `idle` or `needsInput`. |
| `waiting_on_human` | `lifecycle` is `needsInput`. Informational: it can stay set after an interrupt or an API error, so it does not block on its own. |
| `blocks_typing` | Typing text now could disturb a human: a draft or a dialog, on a surface that runs an agent. |
| `terminal` | Whether the surface is a terminal. |

## Surface Selection Contract

`surface.read_selection` is a v2 worker-lane socket method advertised by
`system.capabilities` and printed by `cmux capabilities`. It accepts the usual
surface routing selectors (`window_id`, `workspace_id`, `surface_id`,
`terminal_id`, `tab_id`, and `pane_id`) without focusing a window, workspace,
pane, or surface.

Successful responses use one shape across surface kinds:

```json
{
  "has_selection": true,
  "kind": "filepreview",
  "text": "let answer = 42",
  "base64": "bGV0IGFuc3dlciA9IDQy",
  "file_path": "/Users/me/project/Answer.swift",
  "line_range": { "start": 7, "end": 7 },
  "workspace_id": "...",
  "workspace_ref": "workspace:1",
  "surface_id": "...",
  "surface_ref": "surface:2",
  "window_id": "...",
  "window_ref": "window:1"
}
>>>>>>> origin/main
```

`cmux status wait` blocks until the status entry `KEY` of the workspace holds
`--until`, then prints `{workspace_id, key, cleared, entry}`. `settled`, the
default, returns when the entry is gone (cleared, its owner ended or its TTL
passed) or shows `success` (exit 0), or shows `error` (exit 1); a key with no
entry is settled at once. `cleared` waits for the entry to go, and `state=<s>`
(`busy`, `waiting`, `success`, `error` or `info`) for that state. It follows the
session's event stream instead of polling, and a passed timeout exits 124 with
`wait.timeout`, also when the daemon stops answering.

Rooms and groups (workspace, tab, screen and saved tab groups) take their id or
their exact name. The CLI reads the list on the request's connection and sends
the id, so a retry with `--idempotency-key` repeats the same request; a name
two records share is `selector.ambiguous` with their ids.

### screen

```text
cmux screen list
cmux screen create [--workspace <selector>] [--name <value>] [--focus] [--correlation-key <value>] [--shell <script> | -- <argv...>]
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
cmux screen group <group> update [--name <value>] [--color <color>] [--icon <icon>|--clear-icon] [--collapse|--expand]
cmux screen group <group> add --screens <screen_id,...>
cmux screen group remove --screens <screen_id,...>
```

<<<<<<< HEAD
`screen create` keeps the focused screen unless `--focus` is given.

Pinned screens sort first and leave their group. Group colors are `grey`,
`blue`, `red`, `yellow`, `green`, `pink`, `purple`, `cyan` and `orange`.

### pane

```text
cmux pane list
cmux pane create [--cwd <path>] [--shell <script> | -- <argv...>]
cmux pane <selector> show|focus|close
cmux pane <selector> rename --name <value>
cmux pane <selector> split [--right|--down] [--ratio <value>] [--viewport-width <fraction>] [--cwd <path>]
cmux pane <selector> focus direction <left|right|up|down>
cmux pane <selector> neighbor <left|right|up|down>
cmux pane <selector> swap --other-workspace <sel> --other-screen <sel> --other-pane <sel>
cmux pane <selector> zoom [--enabled <bool>]
cmux pane <selector> split ratio set --split <split_id> --ratio <value>
cmux pane <selector> viewport width set --columns <value>
cmux pane <selector> run [--on-exit <close|keep|shell>] [--cwd <path>] [--name <value>] -- <argv...>
cmux pane <selector> move --to-pane <sel> [--split right|down|left|up] [--focus]
cmux pane <selector> move --to-tab <sel> [--focus]
cmux pane <selector> move --to-workspace <sel> [--name <value>] [--focus]
cmux pane <selector> move --new-screen|--new-tab [--name <value>] [--focus]
cmux pane <selector> tab ...
=======
## Command Families

Sessions output:

`cmux sessions [list]` reads saved hook state from disk and never connects to a
cmux socket. By default the listing includes records that are active for a
workspace or surface, restorable, launch-backed, or transcript-backed. Passing
`--all`, or any record filter (`--session`, `--workspace`, `--surface`,
`--cwd`), includes every record that matches the filters. `--json` prints one
object with:

| Field | Contract |
| --- | --- |
| `state_dir` | Hook state directory the session stores were read from. |
| `default_codex_home` | Codex home used for transcript checks. |
| `total_matches` | Number of matching records, counted before `--limit` is applied. |
| `limit` | Applied result limit, or `null` when `--all` removes it. |
| `stores` | Per-agent hook store files that were read: `agent`, `path`, `exists`, `session_count`. |
| `sessions` | The limited result set of session records. |

Agent session recovery:

`cmux session restore --list` asks the running app for journal-backed recovery
candidates, excluding sessions that are still running or already open. It lists
the agent kind, session id, cwd, and resume command without opening a workspace.
In JSON, records also include the prior workspace id and last-activity timestamp.

Without `--list`, each repeatable `--session <id>` selects an exact candidate;
explicit ids may be restored after a normal quit. Without an id, recovery runs
only when the previous cmux exit was unclean. Each restored session opens in a
separate, unselected workspace titled from its cwd (or agent kind), then resumes
through its recorded launcher. Some terminals start immediately; the remainder
start on the workspace's first visit. Listing and recovery require a running
cmux socket; `cmux session restore --help` does not.

Auth subcommands:

| Command | Contract |
| --- | --- |
| `auth status` | Print signed-in state. Supports `--json`. |
| `auth login` | Begin sign-in through the app and wait for completion. |
| `auth logout` | Clear the current session. |
| `auth team list`, `auth team use <team-id>`, `auth team create <name>` | List teams, select one, or create one. |
| `auth team members [--team <id>]` | Roster, pending invitations, invite links and seat usage of the active (or named) team. |
| `auth team invite <email>... [--role admin\|member] [--team <id>]` | Invite by email; the server sends the email. Pro and Max teams hold 3 members. |
| `auth team link [--expires-days 1\|7\|30] [--max-uses N] [--team <id>]` | Print a reusable member-only invite link (shown once). |
| `auth team revoke-invite <id> [--link] [--team <id>]` | Revoke a pending email invitation, or an invite link with `--link`. |
| `auth team remove <user-id> [--team <id>]` | Remove a member, or leave the team with your own user id. |

My Devices connects opted-in Macs on the same account through authenticated Iroh v2 sessions. It runs only while Cloud Machines is enabled. Fresh installations leave both discovery and access to this Mac off. The Cloud sidebar's My Devices menu and **Settings › Remote & Devices › Devices** expose **Discover other Macs** and **Make this Mac discoverable** independently; both write the same preferences. Turning off incoming Mac access disconnects incoming Mac sessions; turning off discovery stops this installation’s outgoing device connections. Existing iPhone pairing remains separately opt-in. Turning Cloud Machines off stops My Devices discovery, connections, and hosting. My Devices requires no Tailscale setup, pairing link, or address entry.

The corresponding preferences are `devices.discovery.enabled`, `devices.incomingAccess.enabled`, and `devices.sidebar.hiddenMacIDs`. Hiding a physical Mac affects its sidebar rows across build tags, preserves pairing and existing panes, and can be reversed in Settings › Devices. Use `surface ls`, `surface open`, and `surface new-terminal` for discovered Mac resources; the cloud-only `vm workspace` commands remain VM operations.

VM subcommands:

| Command | Contract |
| --- | --- |
| `vm ls`, `vm list` | List VMs. |
| Focus on open | Verbs that open a workspace or pane (`vm new`, `vm base open\|reset`, `vm fork`, `vm restore`, `vm shell`/`attach`, `vm ssh`, `vm tui`, `vm open`, `vm workspace new\|open`, `vm agent`, `vm dev`, `vm layout apply --open`, `surface open`, `surface new-terminal`, `surface new-display`) take `--focus [true\|false]`, `--focus=<bool>` and `--no-focus`, and always send an explicit `focus`. Without a flag they focus only when run interactively (a terminal on stdin and stdout, no coding-agent environment) and stay in the background when run by an agent or script; `CMUX_FOCUS_NEW=1\|0` overrides the detection. The `vm.*`/`surface.*` socket methods default `focus` to false, and a pane opened without focus is marked unread. |
| `cloud domains [list]`, `vm domains [list]` | List the account's VM-port publications (`vm.publication_list`). `--json` returns `{publications: [...]}`. |
| `cloud domains zones`, `vm domains zones` | List custom domains owned by the account (`vm.domain_list`); `--json` returns `{domains: [...]}`. |
| `cloud domains verify <domain>`, `vm domains verify <domain>` | Start or complete ownership/certificate verification for a custom zone (`vm.domain_verify`). The first call prints the DNS checklist; add the records and rerun it. A publication hostname resolves to its zone; generated cmux names need no verification. |
| `cloud domains publish <vm> <port> [--domain <hostname>] [--access personal\|team\|public] [--team <id>]`, `vm domains publish …` | Create one HTTPS publication (`vm.publication_create`). Generated names need no DNS setup. `personal` is owner-only (default), `team` requires the selected team id, and `public` allows anyone with the URL. |
| `cloud domains access <hostname> <personal\|team\|public> [--team <id>]`, `vm domains access …` | Change an existing publication's viewer policy (`vm.publication_update`); the first argument is a publication hostname or id, not a VM id. |
| `cloud domains rm <hostname>`, `vm domains rm …` | Remove a publication (`vm.publication_delete`). |
| `vm tree [<machine>\|local] [--refresh] [--json]` | The surface catalog (`surface.catalog`), rendered Finder-style: **This Mac** first (its terminals grouped by the local workspace showing them, then its browsers), then every cloud machine — Workspaces, Ports, VNC Displays (one row per screen), and a final Terminals section containing every machine-owned terminal. Workspace folders include their terminal, browser, and display layout; a canonical `browser/port:<n>` resource is also listed in the machine's Ports folder. Every line carries an address `vm open` or `surface open` accepts. `--refresh` re-syncs every provider first. `--json` prints the catalog payload with `cloud_states` (`sync_mode`: `journaled` or `snapshot_only`, cursor `(generation, revision)`, freshness, and pending writes) and resources with exact `remote_views: [{tab_id, workspace: {id, name, index, focused}, screen_id?, pane_id?, name?, index?, focused?, screen_index?, pane_index?}]`. A snapshot-only VM remains readable but rejects revision-fenced rename writes until its daemon is upgraded. Same as `surface ls`. |
| `vm workspace new <machine> [--name <name>] [--focus\|--no-focus] [--json]` | `vm.workspace_new`: creates a cmux-tui workspace on the machine (its ⌘N, with a first terminal) and opens it as a new local workspace. Prints `OK workspace=<local id> remote_workspace=<ws id> machine=<id>`. |
| `vm workspace open <machine> <workspace> [--here] [--tabs] [--workspace <local>] [--pane <id\|ref> [--left\|--right\|--up\|--down]] [--focus\|--no-focus] [--json]` | `vm.workspace_open`: the machine workspace's terminals, browsers and pinned displays as a new local workspace, one pane each (what clicking the sidebar row does). `<workspace>` is the `ws_…` id or an unambiguous workspace name, resolved exactly like the sidebar row (every view of every terminal counts); the payload's `remote_workspace_id` is the resolved id. An existing workspace with nothing in it opens nothing and answers `Nothing to open: … cmux vm open <machine>/<ws> starts a terminal there`. `--here`/`--tabs`/`--pane`+side instead project the group into an existing local workspace (`here: true` + the `surface open` destination params; one pane at the destination, the rest as tabs) — the sidebar's "Open All Here" / "Open All in New Tabs" / drop on a pane edge. |
| `vm prompt [--json]` / `vm prompt --open <agent>` (alias `skill`) | `vm.cloud_prompt` / `vm.cloud_agent_open`: installs the bundled cmux-cloud skill file at `~/.config/cmux/skills/cmux-cloud.md` and prints the kickoff prompt for any agent (the Machines panel's "Copy Cloud Prompt"), or opens a local terminal running claude\|codex\|opencode\|pi with it ("Open Cloud Agent"). |
| `vm workspace rename <machine> <workspace-id> <name> [--json]` | `vm.workspace_rename`: renames the cmux-tui workspace (the sidebar row's "Rename…") through the catalog's machine-scoped rename lane. |
| `vm tab rename <machine> <tab-id> <name> [--json]` | `vm.tab_rename`: renames one exact cmux-tui tab placement through the catalog's machine-scoped rename lane. Pass `""` as `<name>` to clear that tab's custom label and restore its generated title. Use the tab id from `vm tree --json`; the daemon revision fence prevents overwriting a concurrent rename. |
| `vm workspace close <machine> <workspace-id> [--json]` | `vm.workspace_close`: closes the cmux-tui workspace; its terminals keep running in the Terminals pool (CLI-only; the sidebar's "Close Workspace…" is `vm workspace rm`). |
| `vm workspace rm <machine> <workspace-id> [--json]` (alias `delete`) | `vm.workspace_delete`: kills every terminal viewed in the workspace, then closes it (the sidebar row's "Close Workspace…" and its hover ×). Prints how many terminals were closed. |
| `vm terminal close <machine> <terminal-id> [--json]` | `vm.terminal_close`: ends a terminal on the machine; an exited terminal is removed through its tab. |
| `vm terminal send <machine> <terminal-id> [text] [--keys <k1,k2,…>] [--json]` (alias `write`) | `vm.terminal_write {id, terminal_id, text?, keys?}`: types `text` into the machine terminal exactly as given (no newline), then presses the named keys (`enter`, `tab`, `escape`, `up`, …; chords join with `+`: `ctrl+c`) — cmux-tui `terminal <id> write --text` / `keys`. Headless: no pane is attached or focused. |
| `vm terminal read <machine> <terminal-id> [--json]` (alias `screen`) | `vm.terminal_read {id, terminal_id}`: the terminal's visible screen (`text`; `--json` adds `rows`, `cols`, `cursor_row`, `cursor_col`, `cursor_visible`) — cmux-tui `terminal <id> screen read`. |
| `vm terminal wait <machine> <terminal-id> --pattern <regex> [--timeout <seconds>] [--json]` | `vm.terminal_wait {id, terminal_id, pattern, timeout_ms?}`: blocks until the screen text matches (default 30 s) — cmux-tui `terminal <id> screen wait`. Prints `OK matched …`; exits 1 with a bounded timeout diagnostic that does not include terminal text. |
| `vm terminal rename <machine> <terminal-id> <name> [--json]` | `vm.terminal_rename`: names the terminal's daemon tab view(s) (the sidebar's Rename…) through the same machine-scoped rename lane; every client shows the name in place of the PTY title, and the daemon persists it. Pass `""` to clear the custom label on every placement. A zero-view pool terminal has no tab to name. |
| `vm new`, `vm create` | Create a VM: the devbox with devtools, the coding agents and a screen (TigerVNC + openbox + noVNC on 6901). The CLI always sends the machine **kind** `desktop` and the backend maps kind and size to the image its deployment supports (one snapshot ladder serves both kinds, so a request that names `base` gets the same machine); `--desktop` / `--base` / `--no-desktop` are accepted for older scripts and change nothing. `--image <id>` is the explicit override and is the only way an image id leaves the client. Supports `--size <4g\|8g\|16g\|24g\|32g\|64g>`, `--name <label>` (display label, applied via `vm.rename` after create), `--provider`, `--workspace`, `--detach`, and `-d`. Pro and Team can create through 16g (8 vCPU); 24g and 32g (12 and 16 vCPU) and 64g (32 vCPU) require Max. Without `--detach`, opens a plain terminal on the machine through the shared open path (see `vm shell`). The Machines panel's ＋ opens the New Machine sheet (size, plan meter) whose Create runs this same command. |
| `vm base open`, `vm base reset` | Open (creating on first use) or reset the persistent Base machine, the same devbox with a screen; `--base` / `--desktop` are accepted for older scripts and change nothing, and an existing Base keeps its image. The app's Cloud VM button shows the Set Up Base sheet only when no Base exists yet. |
| `vm shell`, `vm attach` | Open an interactive shell for an existing VM. Every cloud open (`vm shell` / `vm new` / `vm fork` / `vm restore` / `vm base open` / `vm base reset`, the Machines panel, the sidebar cloud button) uses the machine's private cmux-tui route through the app's user-space WireGuard hub. The first open gets one enrollment invitation from `vm.cmux_remote_info`; a known device reconnects with its pinned daemon fingerprint and cached private route, without a connection-time control-plane request. The app then uses `workspace.create` or `workspace.cloud_vm_terminal_ready`, `workspace.cloud_vm_bind`, and `surface.new_terminal {machine, open: true, workspace_id, focus, name: "shell"}`. There is no public WebSocket or automatic SSH fallback. `cmux vm ssh` remains an explicit diagnostic command. |
| `vm stats <id>`, `vm top <id>` | Print CPU, memory, and disk for the machine right now; a sleeping machine reports `asleep` and is not woken. |
| `vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]` | Grow an existing machine in place. CPU is 1–32 vCPUs, memory is 4–64 GiB in whole GiB, and disk is 4–256 GiB in 4 GiB steps. Pro and Team stop at 16 GiB / 8 vCPU; Max permits 24 GiB / 12 vCPU, 32 GiB / 16 vCPU, and 64 GiB / 32 vCPU. The server enforces account plan ceilings and reserves shared CPU and memory capacity transactionally before provider work. |
| `vm network <id> [set --mode <full\|allowlist\|none> [--dns <on\|off>] \| set --policy <json> \| add-domain <domain>... \| remove-domain <domain>... \| add-range <cidr> [--port <n>] [--protocol <tcp\|udp>] [--note <text>] \| remove-range <cidr> [--port <n>] [--protocol <tcp\|udp>] \| preset <add\|remove> <preset-id>...]` | Show or change the machine's outbound network policy. Changes apply live without a restart; `--json` returns `{policy, presets, requiredDomains, agentUpdateDomains, applied}`. |
| `vm agent-updates <id> [latest\|image]` | Show or change whether the machine keeps its coding agents (Claude Code, Codex, OpenCode, Pi, agent-browser) up to date. `latest` installs, on attach and at most once a day, each agent's newest GitHub release that has been public for 3 days, verified against its sha256 digest (never a downgrade, never npm); `image` (the default) keeps the image's versions. Updates reach only `api.github.com`, `github.com` and GitHub's release-asset host, which every network mode allows; a `note` appears only if a policy blocks one of them. `--json` returns `{id, agent_updates, note?}`. `vm new --agent-updates <latest\|image>` chooses at create. |
| `vm desktop <id>`, `vm vnc <id>` | Open the private VM desktop through the authenticated userspace hub in a browser pane. noVNC and websockify use one loopback forward; no system VPN setup is required. |
| `vm rename <id> <label>`, `vm rename <id> --clear` | Set or clear a display label; the machine id stays its address. |
| `vm rm`, `vm destroy`, `vm delete` | Destroy a VM. |
| `vm ssh` | Open a cmux-managed SSH workspace for an existing VM. |
| `vm ssh-info` | Print SSH connection info. |
| `vm ssh-attach` | Internal attach helper. |
| `vm exec [--timeout <seconds>] <machine> -- <command...>` | Run one command inside a VM and print its stdout/stderr. A remote command failure returns a nonzero status. `--timeout` is 1–900 whole seconds (default 30). Each argv element is shell-quoted faithfully; use `-- sh -c '<script>'` for shell syntax. |
| `vm tui <id>` | Open the FULL cmux-tui client (its own workspaces/panes/tabs) in a pane — every other open gives a plain terminal instead; dials the machine's trusted-carrier listener over the private network, so no device enrollment or approval happens (hidden helper, used only by this command: `vm-tui-connect --config <file>` execs the local cmux-tui client in the pane). |
| `vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <4g\|8g\|16g\|24g\|32g\|64g\|MB>] [--timeout <seconds>] [--wait] [--output] -- <command...>` | Run a command without naming a machine: reuses an idle machine the router provisioned earlier (persisted in `~/.cmuxterm/vm-run-pool.json`, labeled `agent-pool`), wakes a sleeper, or provisions a fresh one. `--machine` selects a machine directly; `--new` forces a fresh pool machine and `--size` chooses its memory. `--sync` pushes the cwd first, `--pull` fetches results, and the remote exit code passes through. It always blocks until the command finishes and prints its output; `--wait` and `--output` are accepted for compatibility with `vm agent` and do not change that behavior. `--timeout` defaults to 600 seconds, with a 15-minute maximum. |
| `vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes] [--allow-large]`<br>`vm push <id> <local-path> [remote-path] --watch [--interval <seconds>] [--exclude <pattern>]... [--no-default-excludes] [--allow-large]`<br>`vm push --secret <id> <local-file> [remote-path] [--mode <octal>]`<br>`vm upload` (alias for all three forms) | Copy a local file or directory onto a VM with SCP over the userspace WireGuard connection. The client pins the guest host key, verifies SHA-256, and packs directories as tarballs. `--exclude` is repeatable; `--no-default-excludes` disables the built-in exclusions. SCP input above 500 MB requires `--allow-large` for the initial transfer. Each SCP transfer is limited to a 256 MiB file or compressed tarball, including watch syncs; `--allow-large` does not bypass this limit. `--watch` repeats the transfer when files change, polling every `--interval` seconds (default 1); subsequent syncs do not repeat the 500 MB input check. The separate `--secret` form delivers one file up to 256 KiB through the machine's cmux-tui link with mode 600 by default; it cannot combine with `--watch`, `--exclude`, or `--no-default-excludes`. `--mode` belongs to `--secret`, and `--interval` belongs to `--watch`. |
| `vm pull <id> <remote> [local]`, `vm download` | Copy a file or directory from a VM to local disk over the exec channel. |
| `vm wait <id>` | Block until the VM reports a ready status; `--wake` also runs a trivial exec so a sleeping machine is awake, `--timeout <seconds>` bounds the wait. |
| `vm open <id> <port> [--print]` | Open the canonical machine-port browser resource. HTTP uses an authenticated loopback forward; HTTPS keeps its private host and certificate identity. `url` and `private_url` identify the private URL. Copying does not create a forward. `--print` remains the explicit control-plane URL request. |
| `vm open <target> [--workspace <id\|ref\|index>] [--focus\|--no-focus]` | Open a tree address. `<machine>` is the machine's shell (exactly `vm shell <machine>`). `<machine>/<ws>` (a `ws_…` id or workspace name) opens that cmux-tui workspace's focused/first live terminal, or starts one there when it is empty (`surface.new_terminal {machine, remote_workspace_id, open: true}`). `<machine>/<ws>/<term_…>` opens one terminal (`surface.project {resource: "<machine>/terminal/<term_…>", workspace_id?, focus?}`), reusing the pane that already shows it (`reused: true`). `<machine>/<ws>/<term_…>/<tab_…>` opens that terminal's exact tab placement (`surface.project {…, remote_tab_id}`); it is the address `vm tree` prints for each tab when one terminal occupies several tabs of a pane, and the tab must belong to that workspace. `<machine>:desktop` is `vm desktop`. `<machine>:port/<n>` is the port form. Prints `OK surface=… workspace=… terminal=…`; `--json` prints the socket payload. Anything else is a usage error. |
| `vm route [--cwd <dir>] [--new] [--provision] [--size <4g\|8g\|16g\|24g\|32g\|64g\|MB>] [--json]` | Print the machine `vm run` / `vm agent` would use for a directory and why (the router's own policy: the machine bound to the directory, then an awake idle pool machine, then a sleeper), without running anything. When routing would provision a fresh machine it prints that and stops unless `--provision` is passed. Pro and Team allow through 16g; Max also allows 24g, 32g, and 64g. |
| `vm agent --agent <claude\|codex\|opencode\|pi> [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--focus\|--no-focus] [--remote-workspace <ws>] [--wait] [--output] [--timeout <seconds>] [--new] [--size <4g\|8g\|16g\|24g\|32g\|64g\|MB>] [--json] -- <prompt or args...>` | Start a coding agent on a cloud machine chosen like `vm run` (or pinned with `--machine`), as a detached terminal in the machine's cmux-tui session (`surface.new_terminal {machine, command, cwd, name, open, focus}`, opened beside the caller's own workspace and pane when run inside cmux; the command is a login shell that puts `/root/.npm-global/bin` first). A bare prompt uses the agent's one-shot form (`claude -p`, `codex exec`, `opencode run`, `pi -p`); flag- or subcommand-led args pass through. `--sync` pushes the directory to `work/<basename>` first and starts the agent there. Pro and Team allow through 16g; Max also allows 24g, 32g, and 64g. `--remote-workspace` chooses a workspace on the machine instead of the detached pool. By default, prints the terminal, workspace, and `vm open <machine>/<ws>/<term>` reattach address and exits once the terminal starts. `--wait` waits for the agent process to exit and passes through its exit code; `--output` implies waiting and prints its terminal output. `--timeout` requires `--wait` or `--output` and bounds only the wait (whole seconds; 0 or omitted means no limit); a timeout or Ctrl-C stops waiting without stopping the detached agent. |
| `surface ls [<machine>\|local] [--refresh] [--json]` | The surface catalog, exactly `vm tree` (This Mac and every cloud machine). |
| `surface open <resource> [--workspace <id\|ref\|index>] [--pane <id\|ref>] [--left\|--right\|--up\|--down\|--tab] [--new] [--focus\|--no-focus] [--json]` | Put one surface in a pane through the single open path (`surface.project {resource, workspace_id?, pane_id?, direction?, placement?, reuse?, focus?}` → `{surface_id, workspace_id, reused, resource}`). `<resource>` is `<machine>/<kind>/<key>` from `surface ls --json` (`local/terminal/<uuid>`, `<m>/terminal/<term_…>`, `<m>/display/display:1`, `<m>/browser/port:<n>`). Reuses the pane already showing the resource unless `--new`; `--pane` + a side splits that pane on that side, `--tab` adds a tab to it, otherwise the workspace's focused pane; a local terminal moves to the destination (it is shown once). Prints `OK surface=… workspace=… resource=… [reused=true]`. |
| `surface new-terminal --machine <id\|local> [--cwd <dir>] [--name <name>] [--remote-workspace <ws_…>] [--workspace <id\|ref\|index>] [--no-open] [--focus\|--no-focus] [--json] [-- <command...>]` | Create a terminal on a machine through its provider (`surface.new_terminal {machine, command?, cwd?, name?, remote_workspace_id?, open?, workspace_id?, …}` → `{resource, terminal_id, machine, remote_workspace_id, workspace_id?, surface_id?}`) and open it as a pane unless `--no-open`. Cloud terminals land in the machine's cmux-tui session (`--remote-workspace` picks the workspace); local ones are a new shell on This Mac. |
| `surface new-display --machine <cloud-id> [--workspace <id\|ref\|index>] [--no-open] [--focus\|--no-focus] [--json]` | Create a VNC display on a cloud machine through the guest display helper (`surface.new_display {machine, open?, workspace_id?, focus?}` → the created display resource, plus `workspace_id` / `surface_id` when opened). Opens the display in the selected workspace unless `--no-open`; local display creation is rejected. When the display is created but cannot be opened, the result has `projection_failed: true`, `open: false` and a `projection_error`; the exit status is still 0 because the display exists. A concurrent creation on the same machine fails with code `busy`. |
| `vm tools <id>`, `vm tool-inspector <id>` | Inspect installed tools inside the VM. |
| `vm ports <id>` | Show listening TCP ports inside the VM. |
| `vm handoff <id>` | Print a short attach handoff block. |
| `vm promote-template <id>` | Promote the VM into a reusable template. |

Surface resume bindings (`surface resume` and `surface-resume`):

| Command | Contract |
| --- | --- |
| `surface resume set [--workspace <id\|ref\|index>] [--surface <id\|ref\|index>] [--window <id\|ref\|index>] [--name <name>] [--kind <kind>] [--checkpoint <id>\|--checkpoint-id <id>] [--source <source>] [--cwd <path>] (--shell <command>\|-- <argv...>)` | Store a restart command for the selected terminal surface (`surface.resume.set`). `--checkpoint-id` takes precedence over `--checkpoint`; `--source` defaults to `cli`, and `--cwd` defaults to `$PWD` or the current directory. `--shell` takes one complete command string; the `-- <argv...>` form also stores a structured launch command. |
| `surface resume [show\|get] [--json] [--workspace <id\|ref\|index>] [--surface <id\|ref\|index>] [--window <id\|ref\|index>]` | Read the binding (`surface.resume.get`); `show` is the default and `get` is an alias. Plain output is the command, `No resume binding` if absent, or `null` if the public binding hides a private routed command. `--json` prints the public socket payload, including `resume_binding` and surface/workspace identifiers. |
| `surface resume clear [--workspace <id\|ref\|index>] [--surface <id\|ref\|index>] [--window <id\|ref\|index>] [--checkpoint <id>\|--checkpoint-id <id>] [--source <source>]` | Clear the binding (`surface.resume.clear`). Optional checkpoint and source values guard the clear so a different binding is not removed; `--checkpoint-id` takes precedence over `--checkpoint`. The response includes `cleared` and the resulting `resume_binding`. |

The selectors default to the caller's `CMUX_SURFACE_ID` or `CMUX_WORKSPACE_ID` when applicable; `--window` supplies context for refs and indexes. These bindings record how to resume a surface; `session restore` and `restore` perform recovery. `surface --help` and `surface-resume --help` print the same family help without a socket.

Canvas subcommands:

`cmux canvas` drives a workspace's freeform canvas layout over the v2
`canvas.*` methods. Every subcommand accepts `--workspace <id|ref|index>`,
resolved in the CLI before the request is sent; `CMUX_WORKSPACE_ID` is not
consulted. Without `--workspace`, the app targets the workspace that owns the
named surface, otherwise the selected workspace of the active window. A surface
is named positionally or with `--surface <id|ref|index>`, and `--surface` wins
when both are given. Every `--option` consumes the following token as its value,
so a flag's value is never read as a positional. The subcommand word and the
`mode`, `align`, `zoom` and `--type` arguments are lowercased before they are
checked. Socket canvas verbs never animate.

| Command | Contract |
| --- | --- |
| `canvas info [--workspace <id\|ref\|index>] [--json]` | `canvas.info`: the workspace's layout `mode` (`canvas` or `splits`) and its `panes` back to front, each with the pane's surface id and ref, `x`, `y`, `width`, `height`, `focused`, the ids and refs of the surfaces it hosts as tabs, and the selected one. `magnification` and `viewport_center` (`x`, `y`) are present only in canvas mode with an attached viewport. Works in either layout mode. The text form prints only `OK workspace:<n>`; read the layout with `--json`. |
| `canvas mode <canvas\|splits\|toggle>` | `canvas.set_mode`. Works in either layout mode and replies with the resulting `mode`. Any other word is a usage error before the request is sent. |
| `canvas set-frame <surface> --x <n> --y <n> --width <n> --height <n>` | `canvas.set_frame`: place one pane at an explicit canvas frame. All four values are required and numeric (usage error otherwise); the app rejects a non-positive width or height with `invalid_params`. |
| `canvas align <tidy\|align-left\|align-right\|align-top\|align-bottom\|equalize-widths\|equalize-heights\|distribute-horizontally\|distribute-vertically>` | `canvas.align`: run one alignment, distribution or tidy command over the workspace's panes. The CLI lowercases the word and forwards it unchecked; the app rejects an unknown one with `invalid_params` naming the accepted set. |
| `canvas reveal [<surface>]` | `canvas.reveal`: scroll a pane into view without moving focus. Without a surface, the focused pane; `invalid_state` (`No focused pane to target (pass surface_id)`) when the workspace has none. |
| `canvas overview` | `canvas.overview`: toggle the fit-all overview zoom. |
| `canvas zoom <in\|out\|reset>` | `canvas.zoom`: step the viewport magnification. Any other word is a usage error before the request is sent. |
| `canvas set-viewport --x <n> --y <n> [--zoom <n>]` | `canvas.set_viewport`: center the viewport on a canvas point and optionally set its magnification. `--x` and `--y` are required and numeric; `--zoom` must be numeric and the app rejects a non-positive value with `invalid_params`. |
| `canvas new-pane [--type terminal\|browser\|simulator\|chief]` | `canvas.new_pane`: create a free-floating pane, `terminal` by default, and focus it. Any other `--type` is a usage error. The reply adds `surface_id` and `surface_ref`, so the text form prints `OK surface:<n>`. |
| `canvas join <surface> <target>`, `canvas join <surface> --target <target>` | `canvas.join`: move `<surface>` into the pane that hosts `<target>` as a tab, then focus the moved surface. Both must be canvas panes of the workspace. |
| `canvas break <surface>` | `canvas.break`: tear a surface out of its multi-tab pane into its own pane, focus it and scroll it into view. |
| `canvas select-tab <surface>` | `canvas.select_tab`: select a surface as its pane's visible tab and move keyboard focus to it. |

Every subcommand except `info` and `mode` requires the workspace to be in canvas
layout and otherwise fails with `invalid_state`
(`Workspace is not in canvas layout (run canvas.set_mode first)`). A surface
that is not a canvas pane of the resolved workspace fails with `not_found`
(`Canvas pane not found`) carrying the `surface_id`. On success the text form
prints `OK`, plus the handles noted above; `--json` prints the reply, which
always carries the resulting `mode`.

Project subcommands:

| Command | Contract |
| --- | --- |
| `project open <path> [--workspace <id\|ref\|index>] [--window <id\|ref\|index>] [--focus <true\|false>] [--json]` | `project.open`: open a project pane for `<path>` as a new tab in the workspace's focused pane. The CLI expands `~` and resolves a relative path from the current directory; the app requires the path to exist (`not_found`, `Project not found at <path>`) and does not check its extension, though the pane expects an `.xcodeproj` or `.xcworkspace`. Without `--workspace` or `--window`, `CMUX_WORKSPACE_ID` is used when set. The app selects the workspace (bringing its window forward) before opening; `--focus` defaults to `true`, accepts `1`/`true`/`yes`/`on` and `0`/`false`/`no`/`off` (anything else is a usage error), and `--focus false` adds the tab without moving focus. A workspace with no focused pane fails with `not_found` (`No focused pane to open project in`). Prints `OK surface=<handle> pane=<handle> project=<path>`; `--json` prints `window_id`, `workspace_id`, `pane_id`, `surface_id` and `path`. |
| `project <path>` | Accepted as `project open <path>` when `<path>` is the only argument left after the options. A first word other than `open` (matched case-insensitively) followed by further arguments is a usage error (`Unknown project subcommand: <word>`); `project` alone is a usage error naming the `open` form. |

`cmux project` has no pre-socket usage text; see [Current Help Caveats](#current-help-caveats).

Remotes subcommands:

| Command | Contract |
| --- | --- |
| `remotes list`, `remotes ls` | List the team's registered remotes (name, deviceId, routes, tag, last seen). Supports `--json`. |
| `remotes add <name>` | Register or update a remote with one or more `--route <host:port>`. Supports `--tag` and `--json`. Idempotent on `<name>` (re-adding updates routes). The host must be a Tailscale address the phone can authenticate to (CGNAT `100.64.x.x`-`100.127.x.x` or `*.ts.net`); loopback, plain LAN IPs, and bare hostnames are rejected. |
| `remotes remove <name-or-deviceId>` | Remove a remote you registered. Aliases `rm`, `delete`. Supports `--json`. |

CodeRouter subcommands (cmux-owned; anything else passes through to the CodeRouter CLI, which `cmux cr` offers to install when the machine has none):

| Command | Contract |
| --- | --- |
| `coderouter status` | Sign-in state (`auth.status`), selected team, and the team's Claude upstream accounts. Supports `--team <id>` and `--json`. |
| `coderouter machines` | 30-day coderouter usage per Cloud machine from `GET /api/coderouter/vm-usage/team`: vmId, display name, total tokens, API-equivalent USD, plus a total line. Alias `machine`. Supports `--team <id>` and `--json` (raw team-usage payload). |
| `coderouter claude list` | Every Claude upstream account of the team: id, kind, masked identifier, label, health (`active`, `disabled`, `cooling down Ns <failure code>`), last use. Aliases `ls`, `show`, `get`, `status`. Supports `--team <id>` and `--json`. |
| `coderouter claude add oauth-token` | Add a Claude Code OAuth token (`sk-ant-oat01-...`, from `claude setup-token`) as one more account. In a terminal, cmux runs `claude setup-token` and parses its output automatically. It also reads `CLAUDE_CODE_OAUTH_TOKEN`, stdin with `--stdin` or a non-TTY stdin, or a hidden terminal prompt; never from argv. `--label <s>` names it. A non-`sk-ant-oat01-` value is rejected before the socket is used. Prints the masked identifier and account id only. `set` is an alias of `add`. Supports `--team <id>` and `--json`. |
| `coderouter claude add api-key` | Same intake (`ANTHROPIC_API_KEY`, `--stdin`, hidden prompt) for an Anthropic API key (`sk-ant-...`, not `sk-ant-oat`). |
| `coderouter claude add bedrock` | Amazon Bedrock credentials from `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional `AWS_SESSION_TOKEN`; `--region <r>` (default `AWS_REGION` / `AWS_DEFAULT_REGION`); repeatable `--model <claude-id>=<bedrock-id>`. |
| `coderouter claude remove <account>` | Remove one account. `<account>` is the id, or a label or masked identifier that matches exactly one account (ambiguity is an error naming the count). Idempotent. Aliases `rm`, `delete`. |
| `coderouter claude disable <account>`, `coderouter claude enable <account>` | Take an account out of routing, or put it back, via `coderouter.claude_upstream.update`. Same selector rules as `remove`. |
| `coderouter claude clear` | Remove every Claude upstream account of the team (`No Claude upstream accounts were set.` when none). Aliases `remove-all`, `unset`. Supports `--team <id>` and `--json`. |

Socket methods: `coderouter.claude_upstream.get|add|update|remove|clear` (`set` is an alias of `add`), `coderouter.machines`. Sign-in failures surface as the `auth_required` code, like `vm`.

Theme subcommands:

| Command | Contract |
| --- | --- |
| `themes` | In a TTY, open the interactive picker. Outside a TTY, list themes. |
| `themes list` | List available themes and current light/dark defaults. |
| `themes set <theme>` | Set the same theme for light and dark appearance. |
| `themes set --light <theme>` | Set the light appearance theme. |
| `themes set --dark <theme>` | Set the dark appearance theme. |
| `themes clear` | Remove the cmux theme override. |

Workspace and tab action names:

| Command | Actions |
| --- | --- |
| `workspace-action` | `pin`, `unpin`, `rename`, `clear-name`, `set-description`, `clear-description`, `move-up`, `move-down`, `move-top`, `close-others`, `close-above`, `close-below`, `mark-read`, `mark-unread`, `set-color`, `clear-color` |
| `tab-action` | `rename`, `clear-name`, `close-left`, `close-right`, `close-others`, `new-terminal-right`, `new-browser-right`, `reload`, `duplicate`, `pin`, `unpin`, `mark-unread` |

### Workspace environment variables

A workspace can carry a set of user-defined environment variables that every
shell spawned in it inherits.

Setting them:

- CLI: `cmux new-workspace --env KEY=VALUE [--env ...] [--env-file <path>]`
  (and the same flags on `cmux workspace create`). `--env` is repeatable;
  `--env-file` reads `KEY=VALUE` lines (blank lines and `#` comments ignored, an
  optional leading `export ` stripped). When both are given, `--env` overrides a
  value from a file.
- Project config (`cmux.json`): an `env` object on a workspace definition, e.g.
  `{ "name": "Build", "cwd": ".", "env": { "AWS_PROFILE": "prod" } }`.
- Socket: the `workspace_env` param on `workspace.create`.

Inspecting them: `cmux workspace env [<handle>] [--mask] [--json]` prints the
configured set. `--mask` redacts the values so secrets are not echoed in full.
The env set is intentionally omitted from `workspace list` output so a plain
listing never leaks secrets.

Semantics:

- **Inheritance.** The variables apply to the workspace's initial shell and to
  every pane, surface, and split created later in that workspace — no per-pane
  re-export. They are also re-applied to every shell recreated on session
  restore.
- **Persistence.** They are stored on the workspace in the session manifest, so
  they survive app restart, daemon restart, and session restore.
- **Precedence.** Workspace env overlays the inherited process environment. It is
  applied as the shell's startup environment, so it is visible to login-shell
  init files (`~/.zprofile`, `~/.zshrc`) as they run, but any `export` those
  files perform for the same key wins for the interactive session (they run after
  the variable is seeded). An explicit per-surface environment (a layout
  `surfaces[].env`, SSH startup env) overrides the workspace value for that
  surface.
- **Protected `CMUX_*` variables.** Workspace env can never override the managed
  variables cmux injects (e.g. `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`,
  `CMUX_SOCKET_PATH`, `CMUX_SOCKET_PASSWORD`) or the terminal identity variables
  (`TERM`, `COLORTERM`, `TERM_PROGRAM`); those keys are protected at spawn time
  and silently win.
- **Secrets.** Values may be secrets. They are never logged, are masked by
  `--mask`, and are kept out of `workspace list`. Prefer `--env-file` so secrets
  do not land in shell history. Note that values stored in the session manifest
  live on disk in plaintext.

### Initial terminal command

`new-workspace`, `new-split`, `new-pane`, and `new-surface` accept
`--command <text>` (also `--command=<text>`; a value is required).

- CLI: the text is sent to the v2 socket as `initial_input` with one trailing
  Enter (`\r`) appended. Command text is preserved literally, including quotes,
  `&&`, pipes, and `$VARS`, which the new shell interprets.
- Socket: `initial_input` on `workspace.create`, `surface.split`, `pane.create`,
  and `surface.create` (including Dock placement). The value is delivered raw at
  spawn time as the terminal's initial input, so socket clients append their own
  Enter keystroke.

Semantics:

- **Interactive shell stays alive.** The terminal spawns its normal interactive
  shell and the text is typed into it, so the shell remains after the command
  exits. This differs from the pre-existing `initial_command` socket param,
  which replaces the shell with a one-shot process; `initial_command` is
  unchanged.
- **Terminal-only.** The CLI rejects `--command` when `--type` is explicitly
  non-terminal (`browser`, `simulator`, `agent-session`), and the socket
  rejects `initial_input` with `invalid_params` when `type` is present and not
  `terminal`. A null `type` is treated as omitted (terminal).
- **Blank input is ignored.** Empty or whitespace-only text is dropped and no
  `initial_input` is sent.
- **Layouts win.** `new-workspace --layout` ignores `--command`; layout surfaces
  define their own commands. Without `--layout`, the command is injected at
  spawn and no follow-up `surface.send_text` is issued.
- **Remote tmux mirrors fail closed.** A mirrored remote-tmux workspace rejects
  creation requests carrying `initial_input` instead of dropping the command.
  A split next to a cloud-projected pane with explicit `initial_input` stays
  local.

tmux compatibility commands:

| Command | Contract |
| --- | --- |
| `capture-pane` | Read pane text, targeting `--workspace`, `--surface`, or `--window`; `--scrollback` includes history and `--lines <n>` returns its last lines. |
| `resize-pane` | Resize `--pane` in a workspace/window with `-L`, `-R`, `-U`, or `-D` and optional `--amount <n>`. |
| `pipe-pane` | Pipe the selected surface's text to `--command <shell-command>` or a trailing shell command. Accepts workspace, surface, and window selectors. |
| `wait-for` | Wait on a named synchronization point with optional `--timeout <seconds>`, or signal it with `-S`/`--signal`. |
| `swap-pane` | Swap required `--pane` and `--target-pane` selectors, optionally scoped by workspace/window and `--focus <true\|false>`. |
| `break-pane` | Move the selected pane/surface into a new pane context; accepts workspace/window selectors and `--focus <true\|false>` or `--no-focus`. |
| `join-pane` | Join the selected pane/surface into required `--target-pane`; accepts workspace/window selectors and `--focus <true\|false>` or `--no-focus`. |
| `next-window`, `previous-window`, `last-window` | Move workspace selection. |
| `last-pane` | Focus the last pane. |
| `find-window` | Find a workspace by title or content. |
| `clear-history` | Clear terminal scrollback. |
| `set-hook` | Manage tmux-compat hook definitions. |
| `popup` | Placeholder, currently unsupported. |
| `bind-key`, `unbind-key`, `copy-mode` | Placeholders, currently unsupported. |
| `set-buffer` | Set a tmux-compat buffer to the given text exactly; reads stdin when no text (or `-`) is given. |
| `paste-buffer` | Paste a tmux-compat buffer. `--bracketed` sends it through the Cmd+V paste path (`terminal.paste`, local socket only) instead of keystrokes. |
| `list-buffers` | List tmux-compat buffers. |
| `respawn-pane` | Send a restart command to a surface. |
| `display-message` | Print or display a message. |

Browser subcommands:

| Command | Contract |
| --- | --- |
| `browser open`, `browser open-split`, `browser new` | Create or open a browser surface. |
| `browser goto`, `browser navigate` | Navigate to a URL. |
| `browser back`, `browser forward`, `browser reload` | Navigate browser history or reload. |
| `browser react-grab toggle` | Toggle React grab for the selected browser surface; `--return-to <terminal-surface>` routes the result back to a terminal. |
| `browser devtools toggle`, `browser devtools console` | Toggle Web Inspector or show the browser console for an optional `--surface`. |
| `browser focus-mode enter`, `browser focus-mode exit`, `browser focus-mode toggle` | Change focus mode for an optional `--surface`; `on` and `off` are also accepted. |
| `browser design-mode enable`, `browser design-mode disable`, `browser design-mode toggle`, `browser design-mode status` | Change or read design mode for an optional `--surface`; bare `design-mode` reads status. |
| `browser zoom in`, `browser zoom out`, `browser zoom reset`, `browser zoom <factor>` | Change page zoom for an optional `--surface`; a numeric factor sets absolute zoom. |
| `browser history clear --force` | Permanently clear the default browser profile's history, like the View menu action; `--yes` also confirms. |
| `browser url`, `browser get-url` | Print current URL. |
| `browser focus-webview`, `browser is-webview-focused` | Focus or query webview focus. |
| `browser snapshot` | Print a DOM snapshot. |
| `browser eval` | Evaluate JavaScript. |
| `browser repl` | Run JavaScript with a Playwright `page` API against the workspace's browser panes in a persistent session; `browser repl guide` prints the guide. |
| `browser wait` | Wait for selector, text, URL, load state, or JS predicate. |
| `browser click`, `browser dblclick`, `browser hover`, `browser focus`, `browser check`, `browser uncheck`, `browser scroll-into-view` | Run element interaction. |
| `browser type`, `browser fill` | Type into or set an input. |
| `browser press`, `browser key`, `browser keydown`, `browser keyup` | Send keyboard input as `--key <key>` or positional `<key>` using Playwright/W3C names such as `Enter`, `Tab`, `Escape`, `ArrowLeft`, and `Space`. Supported keys are replayed through native WebKit input so browser default behavior (including contenteditable caret movement and scrolling) runs; opaque key tokens retain a page-event compatibility fallback. `Space`, `Spacebar`, and `space` emit DOM key `" "` with code `"Space"`; raw `--key ' '` is also accepted. Use `keydown`/`keyup` around a supported modifier to hold it across a subsequent key action. |
| `browser select` | Select an option. |
| `browser scroll` | Scroll page or element. |
| `browser screenshot` | Save a screenshot. |
| `browser get` | Read URL, title, text, HTML, value, attr, count, box, or styles. |
| `browser is` | Check visible, enabled, or checked state. |
| `browser find` | Find by role, text, label, placeholder, alt, title, testid, first, last, or nth. |
| `browser frame` | Select frame context. |
| `browser dialog` | Accept or dismiss dialogs. |
| `browser download list` | List newest-first downloads for one browser surface; supports `--limit <1...25>` and JSON output. The response includes stable IDs, filenames, actual paths when known, status, bytes when known, and path existence. Listing is repeatable and does not consume `browser.download.wait`. |
| `browser download [wait]` | Wait for or save a download, preserving the existing path and timeout options. |
| `browser profiles` | List, add, rename, clear, or delete cmux browser profiles. `clear` refuses to wipe active profiles unless `--force` is passed. |
| `browser import` | Open the browser import wizard. In detected coding-agent environments, defaults to non-interactive cookie import; pass `--interactive` to force the wizard. Non-interactive import supports `--from`, `--profile`, `--all-profiles`, `--to-profile`, `--create-profile`, and `--domain`. |
| `browser cookies` | Get, set, or clear cookies; `set` accepts `--http-only` to keep the cookie hidden from page JavaScript. `clear` requires an explicit scope such as `--url`, `--domain`, `--name`, or `--all`, and returns the removed count as `cleared` in JSON output. |
| `browser storage` | Get, set, or clear local/session storage. |
| `browser tab` | Create, list, switch, or close browser tabs. |
| `browser console list`, `browser console clear` | List or clear console messages for the selected browser surface. |
| `browser errors list`, `browser errors clear` | List or clear browser errors for the selected surface. |
| `browser highlight` | Highlight an element. |
| `browser state` | Save or load browser state. |
| `browser addinitscript`, `browser addscript`, `browser addstyle` | Inject scripts or CSS. |
| `browser viewport <width> <height>` | Emulate an exact logical viewport from 1×1 through 4096×4096 CSS pixels. WKWebView aspect-fits the page inside its current pane without resizing the pane or changing focus; screenshots use the emulated dimensions. |
| `browser viewport reset` | Restore native viewport sizing so the page follows its pane dimensions. |
| `browser geolocation`, `browser geo` | Set geolocation. |
| `browser offline` | Toggle offline state. |
| `browser trace` | Start or stop trace capture. |
| `browser network` | Route, unroute, or list requests. |
| `browser screencast` | Start or stop screencast. |
| `browser input`, `browser input_mouse`, `browser input_keyboard`, `browser input_touch` | Send low-level input. |
| `browser identify` | Identify browser surface context. |

`browser screenshot` reports `screenshot_mismatch` when conservative DOM/pixel
attestation still disagrees after its retry, `timeout` when capture cannot
complete within its bounded budget or another capture is already in progress,
and `internal_error` for other failures. Clients may retry `timeout` and
`screenshot_mismatch`; cmux does not return the suspect image.

`browser viewport` changes the selected browser surface only. On WKWebView, the
requested logical size becomes `window.innerWidth`/`window.innerHeight` and the
page is uniformly scaled to fit inside the existing pane. The pane layout and
other surfaces do not move. Visible screenshots are normalized to exactly those
CSS-pixel dimensions, independent of the display backing scale. JSON results
report `mode`, effective `width` and `height`, displayed size, `scale`,
`presentation`, and `pane_resized`. `reset` reports the actual native CSS
viewport, including the current page zoom.

cmux bounds the combined viewport and page-zoom render geometry to 8192 points
per dimension and 33,554,432 points of area. If the current zoom would exceed
that bound, `browser.viewport.set` leaves the current viewport unchanged and
returns `invalid_params` with
`reason: viewport_zoom_render_geometry_too_large`, `requested_page_zoom`, and
`maximum_page_zoom`. While emulation is active, browser zoom commands also stop
at that maximum. A visible attached browser inspector owns the same layout;
close or detach it before changing the viewport. In that state the v2 method
returns `invalid_state` with `reason: attached_browser_inspector`. Opening or
redocking an attached inspector while emulation is active resets the viewport to
native sizing before WebKit takes ownership of the split geometry.

Hook subcommands:

| Command | Contract |
| --- | --- |
| `hooks setup` | Install hooks for all supported agents whose binaries are on `PATH`. Supports `--agent <name>`, positional agent filters such as `cmux hooks setup rovo`, and `--yes`. `cmux hooks setup kiro --global` writes the Kiro CLI V3 global hook file instead of the `cmux` agent config. |
| `hooks uninstall` | Remove hooks for all supported agents. Supports `--agent <name>`, positional agent filters such as `cmux hooks uninstall rovo`, and `--yes`. `cmux hooks uninstall kiro --global` removes cmux's entries from the Kiro CLI V3 global hook file. |
| `hooks <agent> install` | Install hooks for one supported agent. `opencode` also supports `--project` for the project-local Feed plugin, and `kiro` supports `--global` for the Kiro CLI V3 global hook file. |
| `hooks <agent> uninstall` | Remove hooks for one supported agent. `kiro` supports `--global`. |
| `hooks claude <event>` | Handle Claude Code hook events. `claude-hook <event>` remains as the main-compatibility alias. |
| `hooks codex <event>` | Handle Codex hook events. `codex install-hooks` remains as the main-compatibility installer alias. |
| `hooks feed --source <agent>` | Convert agent hook events into Feed context. |
| `hooks <agent> <event>` | Generic hook surface for `grok`, `opencode`, `pi`, `amp`, `cursor`, `gemini`, `kimi`, `kiro`, `rovodev`, `copilot`, `codebuddy`, `factory`, and `qoder`. Kiro also handles `inbox-drain` and `inbox-stop` for [agent messages](agent-messages.md). |

Kimi hook setup targets the config file `kimi doctor` reports. Without a reported path, it takes the first of `${KIMI_CODE_HOME:-~/.kimi-code}/config.toml` (Kimi Code CLI) and `${KIMI_SHARE_DIR:-~/.kimi}/config.toml` (Kimi CLI 1.49 and earlier) that already exists as a file, then the first whose directory exists, and the Kimi Code CLI path when neither directory exists. Setup refreshes, but never removes, a cmux marker block already present in the other location; `hooks kimi uninstall` removes the block from both.

Left sidebar commands:

| Command | Contract |
| --- | --- |
| `left-sidebar toggle`, `left-sidebar show`, `left-sidebar hide` | Change left-sidebar visibility without printing on success and without bringing the window forward. If the workspace list had keyboard focus, `hide` returns focus to the selected panel, as ⌘B does. `hide` also keeps a sidebar that a narrow window collapsed from coming back when the window widens. |
| `left-sidebar focus` | Show the left sidebar if needed, bring its window forward, and focus the workspace list. |
| `left-sidebar mode` | Print JSON with `visible`. A sidebar collapsed because the window is too narrow reports `false`. |
| `--workspace <id\|ref\|index>` | Target the window containing a workspace. Refs and indexes resolve before the V1 socket command is sent. |
| `--window <id\|ref\|index>` | Target a window. Refs and indexes resolve before the V1 socket command is sent. Without `--workspace` or `--window`, the command acts on the window ⌘B would. |

Right sidebar commands:

| Command | Contract |
| --- | --- |
| `right-sidebar toggle`, `right-sidebar show`, `right-sidebar hide` | Change right-sidebar visibility without printing on success. |
| `right-sidebar focus` | Focus the current right-sidebar mode. |
| `right-sidebar set <files\|find\|vault\|sessions\|feed\|dock\|cloud\|devices>` | Show the right sidebar, switch mode, and focus it unless `--no-focus` is passed. |
| `right-sidebar files`, `right-sidebar find`, `right-sidebar vault`, `right-sidebar sessions`, `right-sidebar feed`, `right-sidebar dock`, `right-sidebar cloud`, `right-sidebar devices` | Short aliases for `right-sidebar set <mode>` with focus. `cloud` (aliases `machines`, `vms`) is the Cloud machines panel; `mode` reports it as `machines`. `devices` (aliases `device`, `macs`) opens the same Cloud panel and reports `machines`. While Cloud Machines is enabled, the My Devices menu independently controls `devices.discovery.enabled` (Discover other Macs) and `devices.incomingAccess.enabled` (Make this Mac discoverable). |
| `right-sidebar mode` | Print JSON with `visible` and `mode`. |
| `--workspace <id\|ref\|index>` | Target the window containing a workspace. Refs and indexes resolve before the V1 socket command is sent. |
| `--window <id\|ref\|index>` | Target a window. Refs and indexes resolve before the V1 socket command is sent. |
| `--no-focus` | Only valid with `set`; switches mode without moving focus. |

Custom sidebar commands:

| Command | Contract |
| --- | --- |
| `sidebar validate [name]` | Validate all custom sidebars, or one named sidebar, under `~/.config/cmux/sidebars`. |
| `sidebar reload [name]` | Validate all custom sidebars, then request a reload for every valid one. |
| `sidebar select <name>` | Validate and activate one custom sidebar in the sidebar picker. |
| `sidebar open <name>` | Validate and open one custom sidebar as a normal Bonsplit pane tab, preferring the right-side split from the focused surface. |

Docs topics:

| Command | Contract |
| --- | --- |
| `docs` | List docs topics without a socket. |
| `docs settings` | Print the configuration docs URL, raw schema URL, cmux.json paths, backup reminder, and reload command. |
| `docs shortcuts` | Print shortcut docs and raw shortcut data resources. |
| `docs api` | Print API docs and raw CLI contract resources. |
| `docs browser` | Print browser automation docs and raw browser skill resources. |
| `docs capture` | Print the capture skill and command reference for `cmux shot` and `cmux record`. Aliases include `screenshot`, `shot`, `record` and `gif`. |
| `docs agents` | Print agent integration docs and raw integration resources. |
| `docs workflows` | Print the saved-layout lifecycle plus the shipped workflow-example catalog. `--json` exposes stable example ids, task-fit cues, created/configured surfaces, config files, primitives, requirements, instantiation/adaptation guidance, source recipe links, and save-as-layout steps without a socket. Aliases include `templates`, `presets`, `examples`, and `layouts`. |

Settings subcommands:

| Command | Contract |
| --- | --- |
| `settings` | Open the Settings window, launching cmux if needed. |
| `settings open [target]` | Open Settings to an optional target section. |
| `settings path` | Print cmux.json paths, docs URL, schema URL, backup reminder, and reload command without a socket. |
| `settings docs` | Print the same output as `docs settings` without a socket. |
| `settings <target>` | Open Settings to a target section. Supported aliases include `shortcuts`, `json`, `cmux-json`, `browser`, and `automation`. |

Config subcommands:

| Command | Contract |
| --- | --- |
| `config doctor [--path <file>]`, `config check`, `config validate` | Validate JSONC syntax and semantic cmux.json constraints (recognized paths, value types, enums, bounds, nested values, and project/global scope). When `--path` is absent, default discovery checks the primary config, project-level `.cmux/cmux.json` or `cmux.json`, and legacy config files. `--path <file>` may be repeated; `--scope global\|project` overrides scope inference for explicit files. Exits 0 on success and 1 on any error. Supports `--json`. Works without a socket. |
| `config path`, `config paths` | Print cmux.json paths, docs URL, schema URL, backup reminder, and reload command without a socket. |
| `config docs`, `config documentation` | Print the same output as `docs settings` without a socket. |
| `config reload` | Ask the running cmux app to reload configuration. Requires a socket. |
| `config get sidebar-font-size` | Print the effective sidebar text size. |
| `config set sidebar-font-size <points>` | Write the sidebar text size to cmux's editable Ghostty config and reload the running app when available. |
| `config sidebar-font-size [points]` | Get the sidebar text size, or set it when a point size is provided. |
| `config get surface-tab-bar-font-size` | Print the effective workspace tab bar text size. |
| `config set surface-tab-bar-font-size <points>` | Write the workspace tab bar text size to cmux's editable Ghostty config and reload the running app when available. |
| `config surface-tab-bar-font-size [points]` | Get the workspace tab bar text size, or set it when a point size is provided. |
| `config get <key>`, `config set <key> <points>` | Generic get/set for `sidebar-font-size` and `surface-tab-bar-font-size`. |
| `config get <setting.path>` | Print a setting's effective value: the cmux.json value; else the value stored by the Settings window (read from the cmux app's defaults), marked `(set in Settings, not cmux.json)`; else the schema default, marked `(default)`. Rejects paths the schema doesn't declare and non-setting sections (`actions`, `commands`, `ui`, `settingPresets`, ...). `--json` prints `path`, `file`, `value`, `configured`, `source` (`cmux.json`, `settings`, or `default`), and `default`. Works without a socket. |
| `config set <setting.path> <value>` | Write one setting to `~/.config/cmux/cmux.json`. `<value>` is parsed as JSON; text that isn't JSON is stored as a string. The complete result is validated against the schema before anything is written, and comments and unrelated keys are kept. The running app applies the change through its file watcher. Works without a socket. |
| `config unset <setting.path>` | Remove one setting from cmux.json, so the value stored by the Settings window, or else the default, applies. Same validation and preservation as `set`. |
| `config toggle <setting.path>` | Flip a boolean setting, starting from the value cmux is using: the cmux.json value, else the Settings window's value, else the schema default. Refuses non-boolean settings. |
| `config cycle <setting.path> <value> [value...]` | Move a setting to the value after its current one (found the same way as `toggle`), wrapping at the end; a value that isn't listed moves to the first. |
| `config preset <name>` | Apply the partial settings object at `settingPresets.<name>` in one write. Nested objects merge key by key. |

`config set|unset|toggle|cycle|preset` share one mutation path with `"type": "setting"` and `"type": "settingPreset"` actions. Paths split on every `.`, so a key that itself contains `.` (for example a `workspaceGroups.byCwd` entry for `~/src/app.web`) can't be addressed; such a path is refused with an error that says so, and the key has to be edited in cmux.json directly. `--json` prints `ok`, `file`, and `paths`, an array of `{path, changed, value}` objects (`value` is absent after an unset).

`config doctor --json` outputs an object with `ok`, `error_count`,
`findings`, `reload_command`, `docs_url`, and `schema_url`. Each finding includes
`label`, `display_path`, `path`, `status`, `ok`, `keys`, and, when available,
`message` and `bytes`. A finding that fails semantic validation also includes
`issues`, an array of objects with a `path` string (a JSON path into the file
such as `$.app.appearance`) and a localized `message` string. `issues` is absent
when there are none.

Events command:

| Option | Contract |
| --- | --- |
| `--after <seq>`, `--after-seq <seq>` | Subscribe to retained events after a sequence number. |
| `--cursor-file <path>` | Read the starting sequence from a file and update it after every event. |
| `--name <event>` | Filter by event name. Repeatable. |
| `--category <name>` | Filter by category. Repeatable. |
| `--reconnect` | Reconnect and resume from the last received sequence until interrupted. |
| `--limit <n>` | Exit after printing `n` event frames. |
| `--no-ack` | Suppress the initial ack frame in stdout. |
| `--no-heartbeat`, `--no-heartbeats` | Suppress heartbeat frames in stdout. |

`events.stream` is a v2 socket method advertised by `capabilities`. The first
response frame is an `ack`; sequence resume metadata lives under `ack.resume` as
`after_seq`, `oldest_seq`, `latest_seq`, `next_seq`, and `gap`. Event frames
carry a process-local monotonic `seq` and a stable `id` for dedupe. Clients
should persist `seq` after processing each event and reconnect with that value.
See [events.md](events.md) for the full protocol and event catalog. Every emitted event is also appended to
`~/.cmuxterm/events.jsonl`, including model lifecycle events for window
creation, close, focus, key-window state, workspace selection, pane focus, and
surface selection, focus, creation, or closure. The stream is bounded: cmux keeps
4,096 replay events in memory, caps each encoded event frame at 16 KiB, closes
slow subscribers after 1,024 pending events, and rotates `events.jsonl` with one
16 MiB archive at `events.jsonl.1`.

## Control-socket admission and deadlines

The app never lets one control command block the others. Every accepted
connection gets a real reply, and a stalled main thread turns into a
structured error instead of a hung or `EPIPE` connection
([#13369](https://github.com/manaflow-ai/cmux/issues/13369)):

| Reply | When | Client behavior |
| --- | --- | --- |
| `overloaded` (`data.retryable: true`, `data.retry_after_ms`, `data.reason`) | The connection pool had no live or pending slot (`pool_saturated`), the request waited longer than 15 s for a slot (`pending_expired`), too many unauthenticated peers were being read (`preauthorization_saturated`), the accept buffer between the listener and the pool was full (`accept_buffer_full`), or the app is stopping (`server_stopping`). The command never ran. | Direct control-socket requests retry within their response timeout, honoring `retry_after_ms`. Relay-backed requests (`cmux ssh`) surface the error without retrying. |
| `timeout` (`data.stage: "main_actor"`, `data.deadline_ms: 10000`, `data.retryable`) | The command's hop onto the main thread did not complete within 10 s (for example the main thread is stalled in a modal dialog or a long synchronous turn). `retryable: true` means the hop was withdrawn before the command ran; `false` means it had started and its result is unknown. | Print the error; retry only when `retryable` is true. |

The v1 line protocol reports the same conditions as
`ERROR: overloaded retry_after_ms=<n> reason=<reason>` and
`ERROR: timeout retryable=<bool> <message>`.

`surface.resume.set` never waits on the user and never presents approval UI
(#13704). A proposal that still needs the "Allow Resume Command?" decision is
stored without auto-resume trust and the reply carries `approval_required:
true`; the user approves it from the terminal's context menu or in
**Settings > Terminal > Resume Commands**.

## Workspace todos

Each workspace carries a persisted checklist plus a todo lifecycle status,
shared by the sidebar row, the checklist popover, the todo pane, `cmux todo`
/ `cmux workspace status`, and the `workspace.todo.*` / `workspace.status.*`
socket verbs (all funnel through the same mutation entry points).

Agent policy: the checklist and manual status pins belong to the user.
Coding agents must not create, edit, complete, remove, or replace checklist
items, and must not `set`/`cycle` the status, unless the user explicitly
asks them to manage that surface — a request to manage checklist items or
a request to manage manual status pins. The status lane already tracks
agent activity automatically through inference; agents should keep their
own plans in their internal task tracking.

Item schema (wire and `todo list --json` shape):

| Field | Contract |
| --- | --- |
| `id` | Stable item UUID, assigned at creation and preserved across edits. |
| `text` | Trimmed, non-empty, capped at 500 characters. |
| `state` | `pending`, `in-progress`, or `completed`. |
| `origin` | `user` or `agent`; who created the item. |

Caps and ordering: at most 50 items per workspace. Storage order is the
creation/`set` order and is what `todo list` prints and the wire returns;
the sidebar/popover/pane rendering that floats unchecked items above
completed ones is display-only and never reorders storage.

`cmux todo set` atomically replaces the whole checklist from a JSON array of
`{text, state?, id?, origin?}` objects (inline argument, or piped on stdin;
also accepts `{"items": [...]}`). Items whose `id` matches an existing item
keep that identity and its origin (state updates when given, else stays);
other items are created (`origin` defaults to `user`, `state` to `pending`);
existing items not named are removed. The whole replace is rejected — nothing
mutated — if any text is empty after trimming or the array exceeds 50 items.
The reply is the full resulting list payload. `cmux todo open` (socket:
`workspace.todo.open`) opens or focuses the workspace's todo pane, so a
script can drive the pane as a generic list surface:

```bash
# Mirror a build script's step list into the workspace todo pane.
./plan-steps.sh --json |            # emits [{"text":"lint","state":"completed"}, ...]
  cmux todo set
cmux todo open
>>>>>>> origin/main
```

`split` defaults to `--right`. `move` moves every tab of the pane, in order,
and the emptied pane closes: to the end of another pane (or a new pane split
off it with `--split`), after a tab, or into a new screen in a workspace
(`--new-screen` and its alias `--new-tab`: the pane's own workspace). The
focus stays unless `--focus`; when the moved pane had the focus, it goes with
the tabs. `--json` prints `pane`, `moved_tabs`, `destination` (`workspace`,
`screen`, `pane`, `index`), `created` and `focused_pane`.

### tab

```text
cmux tab list
cmux tab <selector> show|focus|close
cmux tab <selector> rename --name <value>
cmux tab <selector> move --workspace <sel> --screen <sel> --pane <sel> --index <n>
cmux tab create terminal [--cwd <path>] [--name <value>] [--workspace <sel>] [--screen <sel>] [--pane <sel>] [--shell <script> | -- <argv...>]
cmux tab create browser --url <value> [--name <value>] [--workspace <sel>] [--screen <sel>] [--pane <sel>]
cmux tab <selector> terminal|browser ...
cmux tab <selector> pin|unpin
cmux tab <selector> zoom <0.25..5>|reset|in|out
cmux tab <selector> update --zoom <0.25..5>|--clear-zoom
cmux tab <selector> update --icon <value>|--clear-icon
cmux tab group list [--pane <pane_id>]
cmux tab group create --tabs <tab_id,...> [--name <value>] [--color <color>]
cmux tab group <group> show|ungroup|close
cmux tab group <group> update [--name <value>] [--color <color>] [--icon <icon>|--clear-icon] [--collapse|--expand]
cmux tab group <group> add --tabs <tab_id,...> [--index <n>]
cmux tab group remove --tabs <tab_id,...>
cmux tab group <group> move [--pane <pane_id>] [--index <n>]
cmux tab group <group> save [--room <room>]
cmux tab group saved list [--room <room>]
cmux tab group saved <saved> reopen [--pane <pane_id>]
cmux tab group saved <saved> delete
cmux tab group <group> split|column|new-workspace|unsave [OPTIONS]
```

<<<<<<< HEAD
On a terminal tab, zoom is its font scale, which the daemon stores
(`tab.update`). On a browser tab it is the page zoom, which the app that hosts
the page owns: the CLI runs the app's Zoom In, Zoom Out or Actual Size action
on the tab's pane (the tab must be the one its pane shows) and never writes the
browser tab record; an exact value is refused there. Pinned tabs sort first
and leave their group. Tab group verbs are `tab_group.*` and
`saved_tab_group.*` operations; `split`, `column`, `new-workspace` and `unsave`
have no `cmux.protocol/2` operation yet and still use private daemon commands.
Saved tab groups are personal and belong to a room (default: the default room).
=======
<!-- cli-contract-help-probes:start -->
- `cmux --help` -> `cmux - control cmux via Unix socket`
- `cmux --help` -> `open <path-or-url>...`
- `cmux --help` -> `sessions [list] [options]`
- `cmux --help` -> `session restore [--list] [--session <id>]...`
- `cmux help` -> `cmux - control cmux via Unix socket`
- `cmux --help` -> `Start & Resume:`
- `cmux --help` -> `Diagnostics / Advanced:`
- `cmux help start` -> `Start & Resume:`
- `cmux help agents` -> `Agents:`
- `cmux help navigate` -> `Navigate & Arrange:`
- `cmux help inspect` -> `Inspect:`
- `cmux help inspect` -> `review list [--repo <path>] [--json]`
- `cmux help customize` -> `Customize:`
- `cmux help automation` -> `Automation:`
- `cmux help browser` -> `Browser:`
- `cmux help remote` -> `Remote:`
- `cmux help diagnostics` -> `Diagnostics / Advanced:`
- `cmux help diagnostics` -> `socket-status [--json]`
- `cmux help remote` -> `auth <status|login|logout|team>`
- `cmux --help` -> `socket-status [--json]`
- `cmux --help` -> `cmux help <start|agents|navigate|inspect|customize|automation|browser|remote|diagnostics>`
- `cmux help --help` -> `Usage: cmux help [topic]`
- `cmux help unknown-task-topic` -> `cmux - control cmux via Unix socket`
- `cmux --help` -> `cmux guide | cmux --skill`
- `cmux cloud --help` -> `guide | --skill`
- `cmux guide` -> `# cmux guide`
- `cmux --skill` -> `# cmux guide`
- `cmux cloud guide` -> `# cmux cloud guide`
- `cmux cloud --skill` -> `# cmux cloud guide`
- `cmux vm guide` -> `# cmux cloud guide`
- `cmux vm --skill` -> `# cmux cloud guide`
- `cmux guide --help` -> `Usage: cmux guide | cmux --skill [--json]`
- `cmux --skill -h` -> `Usage: cmux guide | cmux --skill [--json]`
- `cmux cloud guide --help` -> `Usage: cmux cloud guide | cmux cloud --skill [--json]`
- `cmux cloud --skill -h` -> `Usage: cmux cloud guide | cmux cloud --skill [--json]`
- `cmux sessions --help` -> `Usage: cmux sessions list [options]`
- `cmux completion --help` -> `Print a shell completion script for cmux.`
- `cmux ping --help` -> `Usage: cmux ping`
- `cmux capabilities --help` -> `Usage: cmux capabilities`
- `cmux events --help` -> `Usage: cmux events [options]`
- `cmux glaeda --help` -> `Usage: cmux glaeda <request|observe> [options]`
- `cmux auth --help` -> `Usage: cmux auth <status|login|logout|team>`
- `cmux vm --help` -> `Usage: cmux vm <base|new|ls|domains|tree|self|status|stats|resize|network|agent-updates|rename|pause|resume|clean|snapshot|fork|restore|rm|run|route|agent|dev|prompt|exec|push|pull|wait|shell|tui|desktop|open|workspace|terminal|tab|layout|env|ports|tools|handoff|promote-template|attach|ssh|ssh-info> [args...]`
- `cmux cloud --help` -> `Usage: cmux cloud <base|new|ls|domains|tree|self|status|stats|resize|network|agent-updates|rename|pause|resume|clean|snapshot|fork|restore|rm|run|route|agent|dev|prompt|exec|push|pull|wait|shell|tui|desktop|open|workspace|terminal|tab|layout|env|ports|tools|handoff|promote-template|attach|ssh|ssh-info> [args...]`
- `cmux vm new --help` -> `Create a Cloud VM.`
- `cmux vm ls --help` -> `List your Cloud VMs`
- `cmux vm ports --help` -> `Show listening TCP ports inside a Cloud VM.`
- `cmux vm domains --help` -> `cmux cloud domains [list]`
- `cmux vm run --help` -> `Usage: cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <4g|8g|16g|24g|32g|64g|MB>] [--timeout <seconds>] -- <command...>`
- `cmux vm run -h` -> `Usage: cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <4g|8g|16g|24g|32g|64g|MB>] [--timeout <seconds>] -- <command...>`
- `cmux cloud run --help` -> `Usage: cmux vm run [--sync] [--pull <remote-path>] [--machine <id>] [--new] [--size <4g|8g|16g|24g|32g|64g|MB>] [--timeout <seconds>] -- <command...>`
- `cmux vm route --help` -> `Usage: cmux vm route [--cwd <dir>] [--new] [--provision] [--size <4g|8g|16g|24g|32g|64g|MB>] [--json]`
- `cmux vm agent --help` -> `Usage: cmux vm agent --agent <claude|codex|opencode|pi> [--machine <id>] [--sync] [--cwd <dir>] [--name <name>] [--no-open] [--focus|--no-focus] [--remote-workspace <ws>] [--wait] [--output] [--timeout <seconds>] [--new] [--size <4g|8g|16g|24g|32g|64g|MB>] [--json] -- <prompt or args...>`
- `cmux vm push --help` -> `Usage: cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes] [--allow-large]`
- `cmux vm upload --help` -> `Usage: cmux vm push <id> <local-path> [remote-path] [--exclude <pattern>]... [--no-default-excludes] [--allow-large]`
- `cmux vm pull --help` -> `Usage: cmux vm pull <id> <remote-path> [local-path]`
- `cmux vm download --help` -> `Usage: cmux vm pull <id> <remote-path> [local-path]`
- `cmux vm wait --help` -> `Usage: cmux vm wait <id> [--timeout <seconds>] [--wake]`
- `cmux vm open --help` -> `Usage: cmux vm open <target> [--workspace <id|ref|index>] [--focus [<true|false>] | --no-focus] [--print]`
- `cmux vm tree --help` -> `Usage: cmux vm tree [<machine>|local] [--refresh] [--json]`
- `cmux vm workspace --help` -> `cmux vm workspace open <machine> <workspace-id>`
- `cmux vm terminal --help` -> `cmux vm terminal close <machine> <terminal-id>`
- `cmux vm prompt --help` -> `cmux vm prompt --open <agent>`
- `cmux vm base --help` -> `cmux vm base reset [--desktop|--base] [--reason <text>]`
- `cmux surface --help` -> `Usage: cmux surface ls [<machine>|local] [--refresh] [--json]`
- `cmux surface --help` -> `cmux surface resume set [flags] -- <argv...>`
- `cmux surface-resume --help` -> `cmux surface resume show [--json] [flags]`
- `cmux remotes --help` -> `Usage: cmux remotes <list|add|remove> [options]`
- `cmux remote --help` -> `Usage: cmux remotes <list|add|remove> [options]`
- `cmux coderouter --help` -> `Usage: cmux coderouter <status|machines|claude|agent> [options]`
- `cmux rpc --help` -> `Usage: cmux rpc <method> [json-params]`
- `cmux comments --help` -> `Usage: cmux comments <subcommand> [options]`
- `cmux review --help` -> `Usage: cmux review <subcommand> [options]`
- `cmux vault --help` -> `Usage: cmux vault <subcommand> [options]`
- `cmux chief --help` -> `Usage: cmux chief <subcommand> [options]`
- `cmux help --help` -> `Usage: cmux help`
- `cmux docs --help` -> `Usage: cmux docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies|completion]`
- `cmux docs completion` -> `cmux completion zsh`
- `cmux docs` -> `Topics:`
- `cmux docs settings` -> `Config files:`
- `cmux docs capture` -> `capture: Screenshot or record a cmux window`
- `cmux docs dock` -> `dock: Custom right-sidebar terminal controls`
- `cmux settings --help` -> `Usage: cmux settings [open [target]|path|docs|<target>]`
- `cmux settings path` -> `Config files:`
- `cmux settings docs` -> `Config files:`
- `cmux config --help` -> `Usage: cmux config <doctor|check|validate|path|paths|docs|documentation|reload|get|set|unset|toggle|cycle|preset|sidebar-font-size|surface-tab-bar-font-size>`
- `cmux config path` -> `Config files:`
- `cmux config docs` -> `Config files:`
- `cmux welcome --help` -> `Usage: cmux welcome`
- `cmux welcome --help` -> `the default shortcuts`
- `cmux welcome` -> `Shortcuts`
- `cmux welcome` -> `cmux shortcuts`
- `cmux shortcuts --help` -> `Usage: cmux shortcuts`
- `cmux disable-browser --help` -> `Usage: cmux disable-browser [--json]`
- `cmux enable-browser --help` -> `Usage: cmux enable-browser [--json]`
- `cmux browser-status --help` -> `Usage: cmux browser-status [--json]`
- `cmux agent-hibernation --help` -> `Usage: cmux agent-hibernation <on|off> [--json]`
- `cmux agent-hibernation --help` -> `cmux agent-hibernation <hibernate|wake> <surface> [--workspace <id|ref|index>] [--json]`
- `cmux restore --help` -> `Usage: cmux restore [--surface <id|ref>] <kind> <checkpoint-id>`
- `cmux fork --help` -> `Usage: cmux fork [--surface <id|ref>] <kind> <checkpoint-id>`
- `cmux restore-session --help` -> `Usage: cmux restore-session`
- `cmux session restore --help` -> `Usage: cmux session restore [--list] [--session <id>]...`
- `cmux open --help` -> `Usage: cmux open <path-or-url>...`
- `cmux feedback --help` -> `Usage: cmux feedback`
- `cmux feed --help` -> `Usage: cmux feed tui [--opentui|--legacy]`
- `cmux hooks --help` -> `Usage: cmux hooks setup [agent] [--agent <name>] [--yes|-y]`
- `cmux codex --help` -> `Usage: cmux codex <install-hooks|uninstall-hooks>`
- `cmux themes --help` -> `Usage: cmux themes`
- `cmux import --help` -> `Usage: cmux import`
- `cmux omo --help` -> `Usage: cmux omo [opencode-args...]`
- `cmux omx --help` -> `Usage: cmux omx [omx-args...]`
- `cmux omc --help` -> `Usage: cmux omc [omc-args...]`
- `cmux identify --help` -> `Usage: cmux identify`
- `cmux list-windows --help` -> `Usage: cmux list-windows`
- `cmux current-window --help` -> `Usage: cmux current-window`
- `cmux new-window --help` -> `Usage: cmux new-window`
- `cmux focus-window --help` -> `Usage: cmux focus-window --window <id|ref|index>`
- `cmux close-window --help` -> `Usage: cmux close-window --window <id|ref|index> [--force]`
- `cmux resize-window --help` -> `Usage: cmux resize-window --window <id|ref|index> [--width <points>] [--height <points>]`
- `cmux move-workspace-to-window --help` -> `Usage: cmux move-workspace-to-window`
- `cmux move-surface --help` -> `Usage: cmux move-surface`
- `cmux split-off --help` -> `Usage: cmux split-off`
- `cmux reorder-surface --help` -> `Usage: cmux reorder-surface`
- `cmux reorder-workspace --help` -> `Usage: cmux reorder-workspace`
- `cmux reorder-workspaces --help` -> `Usage: cmux reorder-workspaces`
- `cmux workspace-action --help` -> `Usage: cmux workspace-action --action <name>`
- `cmux move-tab-to-new-workspace --help` -> `Usage: cmux move-tab-to-new-workspace`
- `cmux tab-action --help` -> `Usage: cmux tab-action --action <name>`
- `cmux rename-tab --help` -> `Usage: cmux rename-tab`
- `cmux new-workspace --help` -> `Usage: cmux new-workspace`
- `cmux new-workspace --help` -> `--command <text>`
- `cmux list-workspaces --help` -> `Usage: cmux list-workspaces`
- `cmux ssh --help` -> `Usage: cmux ssh <destination> [flags] [-- <remote-command-args>]`
- `cmux ssh --help` -> `--name <title>`
- `cmux ssh --help` -> `--port <n>`
- `cmux ssh --help` -> `--identity <path>`
- `cmux ssh --help` -> `-A, --forward-agent`
- `cmux ssh --help` -> `-a, --no-forward-agent`
- `cmux ssh --help` -> `--ssh-option <opt>`
- `cmux ssh --help` -> `--window <id|ref|index>`
- `cmux ssh --help` -> `--transport <ssh|mosh>`
- `cmux mosh --help` -> `Usage: cmux mosh <destination> [flags] [-- <remote-command-args>]`
- `cmux mosh-tmux --help` -> `Usage: cmux mosh-tmux <destination> [--session <name>] [flags]`
- `cmux mosh-tmux --help` -> `--session <name>`
- `cmux ssh --help` -> `--command <text>`
- `cmux ssh --help` -> `--focus                 Switch to the new workspace`
- `cmux ssh --help` -> `--no-focus              Open it in the background`
- `cmux ssh-session-list --help` -> `Usage: cmux ssh-session-list [--workspace <id|ref|index> | --all-workspaces]`
- `cmux ssh-session-attach --help` -> `Usage: cmux ssh-session-attach --session-id <id> [flags]`
- `cmux ssh-session-attach --help` -> `--workspace <id|ref|index>`
- `cmux ssh-session-attach --help` -> `--pane <id|ref|index>`
- `cmux ssh-session-attach --help` -> `--split <left|right|up|down>`
- `cmux ssh-session-attach --help` -> `--surface <id|ref|index>`
- `cmux ssh-session-attach --help` -> `--focus <true|false>`
- `cmux ssh-session-cleanup --help` -> `Usage: cmux ssh-session-cleanup [--workspace <id|ref|index> | --all-workspaces] (--session-id <id> | --all)`
- `cmux new-split --help` -> `Usage: cmux new-split`
- `cmux new-split --help` -> `--command <text>`
- `cmux list-panes --help` -> `Usage: cmux list-panes`
- `cmux list-pane-surfaces --help` -> `Usage: cmux list-pane-surfaces`
- `cmux tree --help` -> `Usage: cmux tree`
- `cmux top --help` -> `Usage: cmux top`
- `cmux focus-pane --help` -> `Usage: cmux focus-pane`
- `cmux new-pane --help` -> `Usage: cmux new-pane`
- `cmux new-pane --help` -> `--command <text>`
- `cmux new-surface --help` -> `Usage: cmux new-surface`
- `cmux new-surface --help` -> `--command <text>`
- `cmux new-surface --help` -> `--profile <name|uuid>`
- `cmux close-surface --help` -> `Usage: cmux close-surface`
- `cmux drag-surface-to-split --help` -> `Usage: cmux drag-surface-to-split`
- `cmux refresh-surfaces --help` -> `Usage: cmux refresh-surfaces`
- `cmux reload-config --help` -> `Usage: cmux reload-config`
- `cmux surface-health --help` -> `Usage: cmux surface-health`
- `cmux debug-terminals --help` -> `Usage: cmux debug-terminals`
- `cmux trigger-flash --help` -> `Usage: cmux trigger-flash`
- `cmux list-panels --help` -> `Usage: cmux list-panels`
- `cmux focus-panel --help` -> `Usage: cmux focus-panel`
- `cmux close-workspace --help` -> `Usage: cmux close-workspace`
- `cmux select-workspace --help` -> `Usage: cmux select-workspace`
- `cmux rename-workspace --help` -> `Usage: cmux rename-workspace`
- `cmux rename-window --help` -> `Usage: cmux rename-workspace`
- `cmux current-workspace --help` -> `Usage: cmux current-workspace`
- `cmux capture-pane --help` -> `Usage: cmux capture-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--scrollback] [--lines <n>]`
- `cmux resize-pane --help` -> `Usage: cmux resize-pane [--pane <id|ref|index>] [--workspace <id|ref|index>] [--window <id|ref|index>] [-L|-R|-U|-D] [--amount <n>]`
- `cmux pipe-pane --help` -> `Usage: cmux pipe-pane [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--command <shell-command> | <shell-command>]`
- `cmux wait-for --help` -> `Usage: cmux wait-for [-S|--signal|-L|-U] <name> [--timeout <seconds>]`
- `cmux swap-pane --help` -> `Usage: cmux swap-pane --pane <id|ref|index> --target-pane <id|ref|index> [--workspace <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>]`
- `cmux break-pane --help` -> `Usage: cmux break-pane [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]`
- `cmux join-pane --help` -> `Usage: cmux join-pane --target-pane <id|ref|index> [--workspace <id|ref|index>] [--pane <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>] [--focus <true|false>] [--no-focus]`
- `cmux next-window --help` -> `Usage: cmux next-window`
- `cmux previous-window --help` -> `Usage: cmux previous-window`
- `cmux last-window --help` -> `Usage: cmux last-window`
- `cmux last-pane --help` -> `Usage: cmux last-pane`
- `cmux find-window --help` -> `Usage: cmux find-window`
- `cmux clear-history --help` -> `Usage: cmux clear-history`
- `cmux set-hook --help` -> `Usage: cmux set-hook`
- `cmux popup --help` -> `Usage: cmux popup`
- `cmux bind-key --help` -> `Usage: cmux bind-key`
- `cmux unbind-key --help` -> `Usage: cmux unbind-key`
- `cmux copy-mode --help` -> `Usage: cmux copy-mode`
- `cmux set-buffer --help` -> `Usage: cmux set-buffer`
- `cmux paste-buffer --help` -> `Usage: cmux paste-buffer`
- `cmux list-buffers --help` -> `Usage: cmux list-buffers`
- `cmux respawn-pane --help` -> `Usage: cmux respawn-pane`
- `cmux display-message --help` -> `Usage: cmux display-message`
- `cmux read-screen --help` -> `Usage: cmux read-screen`
- `cmux record --help` -> `Usage: cmux record [start] [flags]`
- `cmux shot --help` -> `Usage: cmux shot [flags]`
- `cmux send --help` -> `Usage: cmux send`
- `cmux send-key --help` -> `Usage: cmux send-key`
- `cmux agent message --help` -> `Usage: cmux agent message`
- `cmux agent inbox --help` -> `Usage: cmux agent inbox`
- `cmux agent messages --help` -> `Usage: cmux agent messages`
- `cmux paste --help` -> `Usage: cmux paste`
- `cmux send-panel --help` -> `Usage: cmux send-panel`
- `cmux send-key-panel --help` -> `Usage: cmux send-key-panel`
- `cmux notify --help` -> `Usage: cmux notify`
- `cmux list-notifications --help` -> `Usage: cmux list-notifications`
- `cmux dismiss-notification --help` -> `Usage: cmux dismiss-notification`
- `cmux mark-notification-read --help` -> `Usage: cmux mark-notification-read`
- `cmux open-notification --help` -> `Usage: cmux open-notification`
- `cmux jump-to-unread --help` -> `Usage: cmux jump-to-unread`
- `cmux jump-to-last-prompt --help` -> `Usage: cmux jump-to-last-prompt`
- `cmux clear-notifications --help` -> `Usage: cmux clear-notifications`
- `cmux left-sidebar --help` -> `Usage: cmux left-sidebar <command> [flags]`
- `cmux right-sidebar --help` -> `Usage: cmux right-sidebar <command> [flags]`
- `cmux set-status --help` -> `Usage: cmux set-status`
- `cmux clear-status --help` -> `Usage: cmux clear-status`
- `cmux list-status --help` -> `Usage: cmux list-status`
- `cmux set-progress --help` -> `Usage: cmux set-progress`
- `cmux clear-progress --help` -> `Usage: cmux clear-progress`
- `cmux log --help` -> `Usage: cmux log`
- `cmux clear-log --help` -> `Usage: cmux clear-log`
- `cmux list-log --help` -> `Usage: cmux list-log`
- `cmux sidebar-state --help` -> `Usage: cmux sidebar-state`
- `cmux set-app-focus --help` -> `Usage: cmux set-app-focus`
- `cmux simulate-app-active --help` -> `Usage: cmux simulate-app-active`
- `cmux claude-hook --help` -> `Usage: cmux claude-hook`
- `cmux browser --help` -> `Usage: cmux browser`
- `cmux help browser` -> `browser react-grab toggle [--surface <id>] [--return-to <terminal-surface>]`
- `cmux help browser` -> `browser devtools toggle|console [--surface <id>]`
- `cmux help browser` -> `browser focus-mode enter|exit|toggle [--surface <id>]`
- `cmux help browser` -> `browser design-mode enable|disable|toggle|status [--surface <id>]`
- `cmux help browser` -> `browser zoom in|out|reset|<factor> [--surface <id>]`
- `cmux help browser` -> `browser history clear --force`
- `cmux help browser` -> `browser console <list|clear>`
- `cmux help browser` -> `browser errors <list|clear>`
- `cmux browser --help` -> `screenshot [--out <path>] [--json]`
- `cmux browser --help` -> `download list [--limit <1...25>] [--json]`
- `cmux open-browser --help` -> `Legacy alias for 'cmux browser open'`
- `cmux navigate --help` -> `Legacy alias for 'cmux browser navigate'`
- `cmux browser-back --help` -> `Legacy alias for 'cmux browser back'`
- `cmux browser-forward --help` -> `Legacy alias for 'cmux browser forward'`
- `cmux browser-reload --help` -> `Legacy alias for 'cmux browser reload'`
- `cmux get-url --help` -> `Legacy alias for 'cmux browser get-url'`
- `cmux focus-webview --help` -> `Legacy alias for 'cmux browser focus-webview'`
- `cmux is-webview-focused --help` -> `Legacy alias for 'cmux browser is-webview-focused'`
- `cmux markdown --help` -> `Usage: cmux markdown open <path>`
- `cmux --json list-workspaces --help` -> `List workspaces`
- `cmux list-workspaces --json --help` -> `List workspaces`
- `cmux --id-format uuids list-workspaces --help` -> `List workspaces`
- `cmux canvas --help` -> `Usage: cmux canvas <subcommand> [args] [--workspace <id|ref>]`
- `cmux canvas --help` -> `new-pane [--type terminal|browser|simulator|chief]`
<!-- cli-contract-help-probes:end -->
>>>>>>> origin/main

### terminal

```text
cmux terminal list
cmux terminal list --agents
cmux terminal <selector> show
cmux terminal <selector> write [--text <value>|--bytes-base64 <base64>]
cmux terminal <selector> keys <key...>
cmux terminal <selector> mouse <down|up|move|wheel> --row <n> --column <n> [--button <b>] [--delta-rows <n>] [--modifiers <list>]
cmux terminal <selector> focus <in|out>
cmux terminal <selector> screen read [--details]
cmux terminal <selector> screen wait --pattern <regex> [--timeout-ms <n>]
cmux terminal <selector> state read
cmux terminal <selector> history read [--before <n>] [--limit <n>] [--styled]
cmux terminal <selector> history clear
cmux terminal <selector> output read [--after <offset>] [--max-bytes <n>]
cmux terminal <selector> copy [--mode screen|selection|scrollback]
cmux terminal <selector> process show
cmux terminal <selector> process wait [--timeout-ms <n>]
cmux terminal <selector> wait --until idle|prompt|ready [--timeout <500ms|30s|5m>|--timeout-ms <n>]
cmux terminal <selector> send --text <message|-> [--wait idle|prompt|none] [--timeout <5m>] [--settle <3s>] [--force]
cmux terminal <selector> viewport scroll --delta-rows <n>
cmux terminal <selector> move|project --workspace <sel> --screen <sel> --pane <sel> --index <n>
cmux terminal <selector> attach [--read-only]
cmux terminal <selector> close
cmux terminal <term_id> keep on|off
cmux terminal <selector> resume [--cmd <launcher>] [--pane <sel>] [--split <dir>] [--cwd <dir>] [--no-focus] [--no-wait]
```

`screen read` prints the screen's text as it shows (no trailing blank rows);
`--details` prints the whole record (`text`, `cols`, `rows`, `revision`, ...)
in the human form, and `--json` prints the record as before.

`write` sends text as typed, with no implied newline; without `--text` or
`--bytes-base64` it reads stdin. `keys` takes key chords joined with `+`:
modifiers `ctrl`, `alt` (or `option`), `shift`; keys `enter`, `tab`, `backtab`,
`escape`, `backspace`, `delete`, `insert`, `up`, `down`, `left`, `right`,
`home`, `end`, `pageup`, `pagedown`, `space`, `f1` to `f24`, or one character.
Example: `cmux terminal current keys ctrl+c enter`.

Every wait prints its result either way, and a wait whose timeout passed says
`timed_out: true` and exits 124, as timeout(1) does; exit 0 means the wait
ended for its own reason. `screen wait` answers `matched: false`, `timed_out:
true` and `waited_ms` when the timeout passes without a match. `process wait`
answers `outcome` once the process ends (exit 0, whatever the process's own
code), and `state: "pending"`, `timed_out: true` and `waited_ms` when it still
runs at the timeout. `cmux agents wait` prints its receipt (`matched: false`,
`timed_out: true`) and exits 124 when its timeout passes.

`wait --until prompt` returns when the shell sits at its prompt (`extra.prompt`,
from OSC 133 shell integration); `--until idle` when no plain command runs, no
program reports `working` (OSC 7501) and no OSC 9;4 progress is under way. Both
follow the session's event stream instead of polling and print the terminal
record. A passed timeout exits 124 with `wait.timeout`, also when the daemon
stops answering. Both read shell state from OSC 133 marks: in a shell without
integration `--until idle` returns while a command still runs. After the daemon
reattaches to a running terminal host, the prompt and command state come back
only with the shell's next mark. `--until ready` waits until the terminal's
agent can take a message, as `cmux agent start` does (spec/cli.md "Agent start
and resume"): a startup dialog such as Claude's folder-trust question ends it
as `blocked` with `dialog` and `reason` (exit 4). Both `agent start` and
`--until ready` also give the dialog's numbered `options` and, for folder
trust, `accept_keys` and `accept_label` (the option those keys pick); the
`reason` names the terminal and warns when that option also turns approvals
off.

`list --agents` lists the terminals that run a coding agent, from one
`session.snapshot`: the harness (Claude Code, Codex, … from hook or plugin
agent records, else the app of an OSC 7501 status record), its status
(`blocked` when a permission dialog, question or error waits, `done` when a
turn finished and nobody has viewed the terminal yet, `working`, `idle`,
`unknown`, or `ended`), the age of that state, the workspace and the title.
Blocked agents sort first, then done, working, idle, unknown and ended.
Listing never clears `done`; viewing the tab in a client does. `--json` prints
`[{terminal, harness, status, state, title, workspace_id, workspace, cwd,
updated_at_ms, age_ms, source}]`: `status` is the word above (`ended` for an
ended session) and `state` is a deprecated alias that has the same word.

Each `list --agents` row also has `name` (the tab's name when it is an agent
name, see `cmux agent start`), `tab_id`, `tab_name`, `pane_id` and
`last_reply` (the agent's last answer from its hooks, one line of at most 200
characters, kept in daemon memory only; null when unknown), and the human
table starts with a NAME column. `harness` and `source` use one word each:
`claude` (input aliases `claude-code`, `claude_code`, `Claude Code`), `codex`
(`codex-cli`), `opencode`, `gemini`, `amp`; sources `hook`, `plugin` (older
records say `detected`), `socket` and `program_status` (OSC 7501).

`send` talks to the agent or shell in a terminal in one call. It types the
message as one bracketed paste when the terminal has paste mode on (so a
multi-line message stays one message in Claude Code, Codex or a line editor),
presses Enter 300 ms later, and waits. `--wait idle` (default) ends when no
agent record or OSC 7501 status newer than the send says `working`, no command
or OSC 9;4 progress runs, and the screen has not changed for `--settle`
(default 3s); an agent that stops on a dialog ends it as `blocked`.
`--wait prompt` ends when the shell shows its prompt and the screen is still.
`--wait none` returns after Enter. It prints only what the terminal printed
after the message's echo (reading history pages when the reply is longer than
the screen), less the harness's input box and status footer; `--json` prints
`{terminal, harness, bracketed_paste, status, state, timed_out, waited_ms,
anchored, reply, reply_source, output}`. `reply` is the agent's own last
message, whole, from its hooks when they reported it after the send and the
wait ended idle (`reply_source: "hook"`); else it is `output`
(`reply_source: "screen"`). `status` is the word `list --agents` says for the same
turn: `idle`, `done` (the turn finished and the terminal has an unread
notification), `blocked`, `working` (the wait timed out) or `ended` (the
program exited), from a session read after the wait (tried twice; when both
reads fail, a finished turn says `unknown`, never an older read's word); `state`
is the wait's own word (`idle`, `blocked`, `working`,
`exited`). `--timeout` (default 5m) exits 124 with the output so far. A
terminal whose agent waits on a dialog is refused (`agent.waiting_for_input`)
unless `--force`, because the text would answer the dialog. The MCP tools
`agents_terminal_list` and `agents_terminal_send` run the same code.

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
cmux notification create --title <value> --body <value> [--subtitle <value>] [--level info|warning|error] [--terminal <term_id>]
cmux notification clear [--terminal <term_id> | --workspace <ws_id> | --notification <notification_id>]
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
cmux agent list [--terminal <term_id>] [--state working|blocked|done|idle|unknown|ended] [--needs-me]
                [--sort needs-me|recent|none] [--limit <n>] [--counts]
cmux agent report --terminal <term_id> --state working|blocked|idle|ended|unknown --source hook|socket [--source-session <id>]
cmux agent hook install|uninstall|status [provider...]
cmux agent hook emit --source <agent> --event <native-event> [--terminal <term_id>] [--payload-json <json>]
cmux agent plugin list
cmux agent plugin install <git-url> [--name <value>] [--force]
cmux agent plugin use|update|remove <name-or-id>
cmux agent plugin use --builtin
```

`agent list` lists the caller's session: its terminal agents and the acpmux
chats created in its workspaces (`--all-sessions` for every session and every
chat on the machine). Each row's `status` is the word `terminal list --agents`
uses: `blocked`, `done` (idle with an unread notification), `working`, `idle`,
`unknown`, or `ended` for an ended session (as in the `send` receipt; it was
null); `state` is a deprecated alias with the same word, and an acpmux chat's
own status is `acp_status`. A terminal that closed has no agent: the daemon
deletes the agent record with the terminal, so no output lists it, `--state
ended` included (the ended chat stays in `cmux history list --kind agent`).
The CLI still leaves out an ended agent whose terminal the snapshot does not
have (a daemon of an older build kept the records of closed terminals);
`--state ended` shows those rows too, and the text output ends with a line
that says how many rows it left out. `--state` takes those words and
`ended` (`--state done` selected ended sessions before; that is `--state ended`
now). It puts blocked agents first, then done, working, idle, unknown and
ended (`--sort recent|none` for recency or the daemon's order). `agent report --state ended` reports a session
that ended (`--state done` is an old alias of it), and its record says
`ended`. `--json` stays
a bare array of agents; `--json --counts` adds the counts by status, `ended` and
`total`, and `hidden_ended`, the ended agents it left out
(`{"agents": [...], "counts": {...}, "hidden_ended": 0}`).

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
cmux closed <closed_id> delete [--members 0,2]
cmux closed clear [--since-ms <unix ms>] [--before-ms <unix ms>] [--keep-newest <n>]
```

The session keeps recently closed tabs, screens and workspaces. A tab reopens in
its pane (else the focused pane of its workspace), a screen in its workspace, a
workspace as a new workspace. `delete` and `clear` remove groups for good (and
their terminal archives; the journals keep what they already recorded). `delete
--members` removes only those members; `clear --since-ms` removes only the
groups closed at or after that time, `--before-ms` only those closed before it,
and `--keep-newest` every group but the newest n (retention by age and by
count; the app is to apply its closed-history limits through these).

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
cmux action run - [--no-wait] [--no-atomic] < ops
cmux settings get [<path>]
cmux settings set <path> <value> [--confirm]
cmux settings reset <path> [--confirm]
cmux settings unset <path> [--confirm]
cmux settings history
cmux settings undo
cmux settings restore <revision>
cmux settings reset --group <section>|<section.group>
cmux events [--after <seq>] [--name <n>]... [--category <c>]... [--no-heartbeats]
            [--timeout <duration>] [--until <name>|<prefix>*] [--match <path>=<value>]...
```

`settings set` parses the value as JSON when it parses, else as a string.
`unset` is an alias of `reset`. A key only the person may change answers
`setting_user_only` (exit 1) with a hint. `--confirm` asks the person at the
Mac on a native sheet and waits for the answer with no client deadline; a
declined sheet prints "declined in cmux" and exits 1. `--` ends the options:
`cmux settings set <path> -- --confirm` sets the string "--confirm".
`settings history` lists the last 100 changes of the settings file, newest
first, whoever made them (the Settings page, the palette, the CLI, MCP agents,
a hand edit: origin `file`): revision, time, origin and changed keys.
`settings undo` takes back the newest change not yet undone, so repeated undo
walks back one change at a time; `settings restore <revision>` puts the file
back to its text just before that change. Both are changes of their own, so an
undo takes them back too. `settings reset --group <g>` resets every setting of
a Settings section (`appearance`) or of one group in it (`appearance.sidebar`)
in one change; an unknown group lists the groups. These go to the daemon; a
change that touches a key only the person may change is refused for them
(`settings.agent_refused`).
`events` streams JSON lines until interrupted, or until `--timeout` (exit 124,
with a last `{"type":"timeout","timed_out":true}` line in JSON modes); with
`--until`/`--match` it prints the first matching event and exits 0.

`action run -` reads app actions from stdin, a JSON array or one JSON object
per line of `action.run` params (`{"action": "newColumn", "target": "pane:…",
"args": {…}}`), and sends them as ONE `action.batch` request: the app checks
every op before any runs (one bad op runs nothing and names its index), runs
them in order in one main-thread task (one transaction: the person never sees
half of it, and the model publishes once), and answers once. A refusal while
running stops there and says how many ops applied. One transaction holds at
most 64 ops; `--no-atomic` applies a longer list as consecutive transactions,
and without it a longer list is refused (`batch_too_large`). Targets name
objects that exist before the batch. Layout ops the session daemon owns
(`cmux workspace <ws> move`, `cmux tab <id> move|rename`) are not app actions;
send those to the daemon.

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

Move to New Window is `cmux <noun> move-to-new-window --target <id>` for
`tab`, `tab-group`, `pane`, `screen`, `screen-group`, `workspace` and
`workspace-group`; `cmux <noun> move-to-window --new --target <id>` is the
same command. The new window opens beside the old one and takes the focus;
terminals keep running and pages keep their state.

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
