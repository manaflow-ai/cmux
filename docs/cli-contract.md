# cmux CLI Contract

This document is the compatibility contract for migrating `CLI/cmux.swift` to
Swift ArgumentParser. The migration should preserve command names, aliases,
global flags, exit behavior, socket routing, and no-socket help behavior unless
a PR explicitly calls out an intentional contract change.

The current implementation is a hand-rolled parser. This spec is deliberately
written around user-visible behavior so the implementation can change behind it.

## Migration Rules

- Keep `cmux --help`, `cmux -h`, `cmux --version`, and `cmux -v` working without
  connecting to the cmux socket.
- Keep documented `cmux <command> --help` probes working without a socket where
  they already do.
- Keep `--socket`, `--password`, `--json`, `--id-format`, and `--window` as
  global options before the command.
- Keep UUIDs, refs such as `workspace:2`, and indexes accepted wherever the
  command accepts a window, workspace, pane, surface, or tab handle.
- Keep text output stable for scripting commands unless a command already
  documents JSON as the scripting interface.
- Keep hidden/internal commands available until their callers have migrated.

## Global Invocation

| Form | Contract |
| --- | --- |
| `cmux <path>` | Open a directory or file path in cmux. Relative paths resolve from the current working directory. |
| `cmux [global-options] <command> [options]` | Run a named command. |
| `cmux --help`, `cmux -h` | Print top-level usage without a socket. |
| `cmux --version`, `cmux -v`, `cmux version` | Print version summary without a socket. |

Global options:

| Option | Contract |
| --- | --- |
| `--socket <path>` | Override the socket path for this invocation. |
| `--password <value>` | Use an explicit socket password. Takes precedence over `CMUX_SOCKET_PASSWORD`. |
| `--json` | Prefer machine-readable JSON output for commands that support it. |
| `--id-format <refs\|uuids\|both>` | Select handle format in JSON and supported text output. |
| `--window <id\|ref\|index>` | Route the command through a specific window when supported. |

Environment:

| Variable | Contract |
| --- | --- |
| `CMUX_SOCKET_PATH` | Primary socket path override. |
| `CMUX_SOCKET` | Compatibility socket path override. |
| `CMUX_SOCKET_PASSWORD` | Socket password fallback when `--password` is absent. |
| `CMUX_WORKSPACE_ID` | Default workspace context inside cmux terminals. |
| `CMUX_SURFACE_ID` | Default surface context inside cmux terminals. |
| `CMUX_TAB_ID` | Default tab context for tab commands. |

## Top-Level Commands

| Command | Contract |
| --- | --- |
| `welcome` | Print the welcome screen. |
| `shortcuts` | Open Settings to Keyboard Shortcuts. |
| `disable-browser` | Disable cmux browser creation and link interception until re-enabled. |
| `enable-browser` | Re-enable cmux browser creation and link interception. |
| `browser-status` | Print whether cmux browser creation and link interception are enabled. |
| `restore-session` | Restore the previously saved cmux session. |
| `feedback` | Open feedback UI or submit feedback with `--email`, `--body`, and repeated `--image`. |
| `feed` | Open the keyboard-first Feed TUI or manage persisted Feed workstream history. |
| `themes` | List, set, clear, or interactively pick Ghostty themes. |
| `claude-teams` | Launch Claude Code with cmux/tmux-style agent team integration. |
| `omo` | Launch OpenCode with oh-my-openagent integration. |
| `omx` | Launch Oh My Codex with cmux pane integration. |
| `omc` | Launch Oh My Claude Code with cmux pane integration. |
| `hooks` | Install, uninstall, and run agent hook integrations under one namespace. |
| `codex` | Compatibility alias for installing or uninstalling Codex hooks. |
| `ping` | Check socket connectivity. |
| `capabilities` | Print server capabilities as JSON. |
| `auth` | Manage auth status, login, and logout through the app. |
| `vm`, `cloud` | Manage cloud VMs. `cloud` is an alias for `vm`. |
| `rpc` | Call a raw v2 socket method with optional JSON params. |
| `identify` | Print server identity and caller context. |
| `list-windows` | List windows. |
| `current-window` | Print the selected window ID. |
| `new-window` | Create a new window. |
| `focus-window` | Focus a window by handle. |
| `close-window` | Close a window by handle. |
| `move-workspace-to-window` | Move a workspace into a target window. |
| `reorder-workspace` | Reorder a workspace inside a window. |
| `workspace-action` | Run workspace context-menu actions from the CLI. |
| `list-workspaces` | List workspaces. |
| `new-workspace` | Create a workspace, optionally with cwd, command, description, and layout. |
| `ssh` | Open an SSH-backed workspace. |
| `remote-daemon-status` | Print bundled remote daemon version, asset, checksum, and cache status. |
| `new-split` | Split from a surface in a direction. |
| `list-panes` | List panes in a workspace. |
| `list-pane-surfaces` | List surfaces in a pane. |
| `tree` | Print a window, workspace, pane, and surface tree. |
| `focus-pane` | Focus a pane. |
| `new-pane` | Create a pane with terminal or browser content. |
| `new-surface` | Create a surface inside a pane. |
| `close-surface` | Close a surface. |
| `move-surface` | Move a surface to another pane, workspace, window, or index. |
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
| `read-screen` | Read terminal text from a surface. |
| `send` | Send text to a terminal surface. |
| `send-key` | Send one key to a terminal surface. |
| `send-panel` | Send text to a panel/surface. |
| `send-key-panel` | Send one key to a panel/surface. |
| `notify` | Send a notification to a workspace/surface. |
| `list-notifications` | List queued notifications. |
| `clear-notifications` | Clear queued notifications. |
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
| `ssh-session-end` | Internal helper that clears remote SSH session state. |
| `__tmux-compat` | Internal tmux compatibility dispatcher. |

## Command Families

Auth subcommands:

| Command | Contract |
| --- | --- |
| `auth status` | Print signed-in state. Supports `--json`. |
| `auth login` | Begin sign-in through the app and wait for completion. |
| `auth logout` | Clear the current session. |

VM subcommands:

| Command | Contract |
| --- | --- |
| `vm ls`, `vm list` | List VMs. |
| `vm new`, `vm create` | Create a VM. Supports `--image`, `--provider`, `--detach`, and `-d`. |
| `vm shell`, `vm attach` | Open an interactive shell for an existing VM. |
| `vm rm`, `vm destroy`, `vm delete` | Destroy a VM. |
| `vm ssh`, `vm ssh-info` | Print SSH connection info. |
| `vm ssh-attach` | Internal attach helper. |
| `vm exec` | Run a shell command inside a VM. |

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

tmux compatibility commands:

| Command | Contract |
| --- | --- |
| `capture-pane` | Read pane text. |
| `resize-pane` | Resize a pane with direction flags. |
| `pipe-pane` | Pipe pane text to a shell command. |
| `wait-for` | Signal or wait on a named synchronization point. |
| `swap-pane` | Swap two panes. |
| `break-pane` | Move a pane into a new workspace. |
| `join-pane` | Join a pane into another pane. |
| `next-window`, `previous-window`, `last-window` | Move workspace selection. |
| `last-pane` | Focus the last pane. |
| `find-window` | Find a workspace by title or content. |
| `clear-history` | Clear terminal scrollback. |
| `set-hook` | Manage tmux-compat hook definitions. |
| `popup` | Placeholder, currently unsupported. |
| `bind-key`, `unbind-key`, `copy-mode` | Placeholders, currently unsupported. |
| `set-buffer` | Set a tmux-compat buffer. |
| `paste-buffer` | Paste a tmux-compat buffer. |
| `list-buffers` | List tmux-compat buffers. |
| `respawn-pane` | Send a restart command to a surface. |
| `display-message` | Print or display a message. |

Browser subcommands:

| Command | Contract |
| --- | --- |
| `browser open`, `browser open-split`, `browser new` | Create or open a browser surface. |
| `browser goto`, `browser navigate` | Navigate to a URL. |
| `browser back`, `browser forward`, `browser reload` | Navigate browser history or reload. |
| `browser url`, `browser get-url` | Print current URL. |
| `browser focus-webview`, `browser is-webview-focused` | Focus or query webview focus. |
| `browser snapshot` | Print a DOM snapshot. |
| `browser eval` | Evaluate JavaScript. |
| `browser wait` | Wait for selector, text, URL, load state, or JS predicate. |
| `browser click`, `browser dblclick`, `browser hover`, `browser focus`, `browser check`, `browser uncheck`, `browser scroll-into-view` | Run element interaction. |
| `browser type`, `browser fill` | Type into or set an input. |
| `browser press`, `browser key`, `browser keydown`, `browser keyup` | Send keyboard input. |
| `browser select` | Select an option. |
| `browser scroll` | Scroll page or element. |
| `browser screenshot` | Save a screenshot. |
| `browser get` | Read URL, title, text, HTML, value, attr, count, box, or styles. |
| `browser is` | Check visible, enabled, or checked state. |
| `browser find` | Find by role, text, label, placeholder, alt, title, testid, first, last, or nth. |
| `browser frame` | Select frame context. |
| `browser dialog` | Accept or dismiss dialogs. |
| `browser download` | Wait for or save downloads. |
| `browser cookies` | Get, set, or clear cookies. |
| `browser storage` | Get, set, or clear local/session storage. |
| `browser tab` | Create, list, switch, or close browser tabs. |
| `browser console`, `browser errors` | List or clear console messages and errors. |
| `browser highlight` | Highlight an element. |
| `browser state` | Save or load browser state. |
| `browser addinitscript`, `browser addscript`, `browser addstyle` | Inject scripts or CSS. |
| `browser viewport` | Set viewport size. |
| `browser geolocation`, `browser geo` | Set geolocation. |
| `browser offline` | Toggle offline state. |
| `browser trace` | Start or stop trace capture. |
| `browser network` | Route, unroute, or list requests. |
| `browser screencast` | Start or stop screencast. |
| `browser input`, `browser input_mouse`, `browser input_keyboard`, `browser input_touch` | Send low-level input. |
| `browser identify` | Identify browser surface context. |

Hook subcommands:

| Command | Contract |
| --- | --- |
| `hooks setup` | Install hooks for all supported agents whose binaries are on `PATH`. Supports `--agent <name>` and `--yes`. |
| `hooks uninstall` | Remove hooks for all supported agents. Supports `--agent <name>` and `--yes`. |
| `hooks <agent> install` | Install hooks for one supported agent. `opencode` also supports `--project` for the project-local Feed plugin. |
| `hooks <agent> uninstall` | Remove hooks for one supported agent. |
| `hooks claude <event>` | Handle Claude Code hook events. `claude-hook <event>` remains as the main-compatibility alias. |
| `hooks codex <event>` | Handle Codex hook events. `codex install-hooks` remains as the main-compatibility installer alias. |
| `hooks feed --source <agent>` | Convert agent hook events into Feed context. |
| `hooks <agent> <event>` | Generic hook surface for `opencode`, `cursor`, `gemini`, `copilot`, `codebuddy`, `factory`, and `qoder`. |

## No-Socket Help Probes

The following probes are executable contract checks. They must exit 0 and print
the expected text without connecting to a cmux socket.

<!-- cli-contract-help-probes:start -->
- `cmux --help` -> `cmux - control cmux via Unix socket`
- `cmux ping --help` -> `Usage: cmux ping`
- `cmux capabilities --help` -> `Usage: cmux capabilities`
- `cmux auth --help` -> `Usage: cmux auth <status|login|logout>`
- `cmux vm --help` -> `Usage: cmux vm <new|ls|rm|exec|shell|attach|ssh> [args...]`
- `cmux cloud --help` -> `Usage: cmux cloud <new|ls|rm|exec|shell|attach|ssh> [args...]`
- `cmux rpc --help` -> `Usage: cmux rpc <method> [json-params]`
- `cmux help --help` -> `Usage: cmux help`
- `cmux welcome --help` -> `Usage: cmux welcome`
- `cmux shortcuts --help` -> `Usage: cmux shortcuts`
- `cmux disable-browser --help` -> `Usage: cmux disable-browser [--json]`
- `cmux enable-browser --help` -> `Usage: cmux enable-browser [--json]`
- `cmux browser-status --help` -> `Usage: cmux browser-status [--json]`
- `cmux restore-session --help` -> `Usage: cmux restore-session`
- `cmux feedback --help` -> `Usage: cmux feedback`
- `cmux feed --help` -> `Usage: cmux feed tui [--opentui|--legacy]`
- `cmux hooks --help` -> `Usage: cmux hooks setup [--agent <name>] [--yes|-y]`
- `cmux codex --help` -> `Usage: cmux codex <install-hooks|uninstall-hooks>`
- `cmux themes --help` -> `Usage: cmux themes`
- `cmux omo --help` -> `Usage: cmux omo [opencode-args...]`
- `cmux omx --help` -> `Usage: cmux omx [omx-args...]`
- `cmux omc --help` -> `Usage: cmux omc [omc-args...]`
- `cmux identify --help` -> `Usage: cmux identify`
- `cmux list-windows --help` -> `Usage: cmux list-windows`
- `cmux current-window --help` -> `Usage: cmux current-window`
- `cmux new-window --help` -> `Usage: cmux new-window`
- `cmux focus-window --help` -> `Usage: cmux focus-window --window <id|ref|index>`
- `cmux close-window --help` -> `Usage: cmux close-window --window <id|ref|index>`
- `cmux move-workspace-to-window --help` -> `Usage: cmux move-workspace-to-window`
- `cmux move-surface --help` -> `Usage: cmux move-surface`
- `cmux reorder-surface --help` -> `Usage: cmux reorder-surface`
- `cmux reorder-workspace --help` -> `Usage: cmux reorder-workspace`
- `cmux workspace-action --help` -> `Usage: cmux workspace-action --action <name>`
- `cmux tab-action --help` -> `Usage: cmux tab-action --action <name>`
- `cmux rename-tab --help` -> `Usage: cmux rename-tab`
- `cmux new-workspace --help` -> `Usage: cmux new-workspace`
- `cmux list-workspaces --help` -> `Usage: cmux list-workspaces`
- `cmux ssh --help` -> `Usage: cmux ssh <destination>`
- `cmux new-split --help` -> `Usage: cmux new-split`
- `cmux list-panes --help` -> `Usage: cmux list-panes`
- `cmux list-pane-surfaces --help` -> `Usage: cmux list-pane-surfaces`
- `cmux tree --help` -> `Usage: cmux tree`
- `cmux focus-pane --help` -> `Usage: cmux focus-pane`
- `cmux new-pane --help` -> `Usage: cmux new-pane`
- `cmux new-surface --help` -> `Usage: cmux new-surface`
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
- `cmux capture-pane --help` -> `Usage: cmux capture-pane`
- `cmux resize-pane --help` -> `Usage: cmux resize-pane`
- `cmux pipe-pane --help` -> `Usage: cmux pipe-pane`
- `cmux wait-for --help` -> `Usage: cmux wait-for`
- `cmux swap-pane --help` -> `Usage: cmux swap-pane`
- `cmux break-pane --help` -> `Usage: cmux break-pane`
- `cmux join-pane --help` -> `Usage: cmux join-pane`
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
- `cmux send --help` -> `Usage: cmux send`
- `cmux send-key --help` -> `Usage: cmux send-key`
- `cmux send-panel --help` -> `Usage: cmux send-panel`
- `cmux send-key-panel --help` -> `Usage: cmux send-key-panel`
- `cmux notify --help` -> `Usage: cmux notify`
- `cmux list-notifications --help` -> `Usage: cmux list-notifications`
- `cmux clear-notifications --help` -> `Usage: cmux clear-notifications`
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
- `cmux open-browser --help` -> `Legacy alias for 'cmux browser open'`
- `cmux navigate --help` -> `Legacy alias for 'cmux browser navigate'`
- `cmux browser-back --help` -> `Legacy alias for 'cmux browser back'`
- `cmux browser-forward --help` -> `Legacy alias for 'cmux browser forward'`
- `cmux browser-reload --help` -> `Legacy alias for 'cmux browser reload'`
- `cmux get-url --help` -> `Legacy alias for 'cmux browser get-url'`
- `cmux focus-webview --help` -> `Legacy alias for 'cmux browser focus-webview'`
- `cmux is-webview-focused --help` -> `Legacy alias for 'cmux browser is-webview-focused'`
- `cmux markdown --help` -> `Usage: cmux markdown open <path>`
<!-- cli-contract-help-probes:end -->

## No-Socket Negative Help Probes

The following probes must not print help. They protect argument forwarding after
`--`, where a forwarded `--help` token belongs to the command payload.

<!-- cli-contract-negative-help-probes:start -->
- `cmux vm exec demo -- --help` !> `Usage: cmux vm`
<!-- cli-contract-negative-help-probes:end -->

## Current Help Caveats

These are current contracts to preserve until a follow-up PR intentionally
changes them:

- `cmux help` currently routes through the socket dispatch path. Use
  `cmux --help` or `cmux help --help` for no-socket help.
- `cmux version --help` currently prints the version summary because `version`
  is handled before subcommand help dispatch.
- `cmux claude-teams --help` is handled by the command launcher, not by the
  pre-socket help dispatcher.
- `cmux remote-daemon-status --help` currently prints status because the command
  runs before subcommand help dispatch.

## ArgumentParser Migration Sequence

1. Keep this contract file and `tests/test_cli_contract_help.py` green.
2. Add Swift ArgumentParser as a dependency without changing behavior.
3. Introduce a parse-only facade that maps ArgumentParser command structs onto
   existing `CMUXCLI` runner methods.
4. Move one command family at a time into small files, starting with no-socket
   commands (`version`, `themes`, hook installers), then socket commands, then
   browser and tmux compatibility.
5. After each family moves, run the contract probes plus targeted socket tests in
   GitHub Actions.
6. When all command families are migrated, remove the manual global parser and
   legacy helper code that no longer owns behavior.
