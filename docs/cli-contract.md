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
| `--machine <value>` | Constrain machine-scoped requests. |
| `--app-socket <path>` | Connect to an exact app control socket (app scopes only). |
| `--json` | Print one JSON result object. |
| `--jsonl` | Print one JSON value per result or event. |
| `--quiet` | Suppress successful output. |
| `-h`, `--help` | Show command help. |

`--socket`, `--session`, `--machine` and `--app-socket` also take the
`--flag=value` form.

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
| cmux-tui daemon (`cmux.protocol/2`) | `machine`, `session`, `client`, `workspace`, `screen`, `pane`, `tab`, `terminal`, `browser` (daemon-owned `browser_…`), `notification`, `notify`, `agent`, `sidebar`, `pairing`, `projection`, `provider`, `raw` | yes |
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

Daemon socket order: `--socket`/`--session`, `CMUX_TUI_SOCKET`, then (macOS) the
app's session `cmux-app` or `cmux-app-<tag>` under the per-user Darwin temp
directory, then cmux-tui's `main` session.

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
cmux workspace create [--name <value>] [--empty] [--correlation-key <value>]
cmux workspace <selector> show|focus|close
cmux workspace <selector> rename --name <value>
cmux workspace <selector> move --index <n>
cmux workspace <selector> run [--on-exit <close|keep>] [--cwd <path>] [--name <value>] -- <argv...>
cmux workspace <selector> run [--on-exit <close|keep>] shell <script>
cmux workspace <selector> layout apply --layout <json>
cmux workspace <selector> screen ...
cmux workspace group list
cmux workspace group create --name <value> [--color <token|#hex>] [--id <id>] [--index <n>] [--collapse]
cmux workspace group <group> update [--name <value>] [--color <value>|--clear-color] [--collapse|--expand]
cmux workspace group <group> delete|move --index <n>
cmux workspace group <group> add --workspace <key|id> [--index <n>]
cmux workspace group remove --workspace <key|id>
```

### screen

```text
cmux screen list
cmux screen create [--name <value>] [--correlation-key <value>]
cmux screen <selector> show|focus|close
cmux screen <selector> rename --name <value>
cmux screen <selector> layout export
cmux screen <selector> layout undo [--confirm-close] [--confirmation-token <value>]
cmux screen <selector> pane ...
```

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
cmux tab group list|create|update|add|remove|move|split|column|new-workspace|ungroup|close|save|unsave
cmux tab group saved list
cmux tab group saved <saved> delete|reopen --pane <id>
```

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
cmux settings set <path> <value>
cmux settings unset <path>
cmux events [--after <seq>] [--name <n>]... [--category <c>]... [--no-heartbeats]
```

`settings set` parses the value as JSON when it parses, else as a string.
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
cmux acp web [--no-open]
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
| `set-status`, `clear-status`, `log`, `set-progress`, `sidebar-state` | None. (`cmux workspace set-status` is the workspace todo status action, not a sidebar pill.) |
| `todo`, `workspace status` | None as CLI verbs; the app actions under `cmux action list --noun workspace` cover the checklist and status. |
| `claude-hook`, `codex-hook`, `hooks …` | `cmux agent hook install|uninstall|status|emit`. |
| `markdown open`, `themes`, `vm`, `cloud` verbs, `glaeda`, `current` | None, except the app actions `cmux action list` reports (for example `cmux cloud new-machine`). |
