# cmux Workspace Command Reference

Use these commands from a cmux terminal; the CLI reads the session from the environment. Selectors are a public id (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`), `current` (the caller's own; `focused` is the one the person looks at), or an exact name. `--json` prints one result object, `--jsonl` one object per result or event. `cmux <scope> --help` prints each scope's grammar.

## Context

```bash
cmux app identify              # the app: bundle, tag, socket
cmux app capabilities
cmux app ping
cmux workspace list            # reaches the cmux-tui daemon
cmux terminal "$CMUX_TUI_TERMINAL_ID" show --json
```

## Windows and workspaces

```bash
cmux window list
cmux app new-window

cmux workspace list --json
cmux workspace create --name task
cmux workspace create --name empty --empty
cmux workspace new --name task --cwd "$PWD" --command "npm run dev"   # app action
cmux workspace ws_… show
cmux workspace ws_… focus
cmux workspace ws_… rename --name "new name"
cmux workspace ws_… update --title "API" --color "#336699" --icon server.rack
cmux workspace ws_… update --clear-title
cmux workspace create --name scratch --ephemeral   # incognito, closed at the next session start
cmux workspace ws_… move --index 0
cmux workspace ws_… close
cmux workspace ws_… run -- cargo test
cmux workspace move-to-window --target ws_…   # app action
```

`workspace create` makes the workspace in the daemon. `workspace new` is the app's New Workspace action with its arguments; `cmux action describe "workspace new"` lists them.

## Panes and tabs

```bash
cmux pane list --json
cmux tab list --json
cmux terminal list --json

cmux pane pane_… neighbor right --json      # the pane to its right: add tabs there
cmux pane pane_… split --right -- npm run dev   # only when no pane is there; keeps focus
cmux pane pane_… split --down --cwd "$PWD" --shell 'tail -f logs/dev.log'
cmux pane pane_… split --right --focus     # moves focus: only when the user asked
cmux pane pane_… run --name tests -- npm test
cmux pane pane_… run shell 'tail -f logs/dev.log'
cmux tab create terminal --pane pane_… --cwd "$PWD" --name shell
cmux tab create browser --pane pane_… --url http://localhost:3000

cmux pane pane_… focus
cmux pane pane_… focus direction left
cmux pane pane_… zoom --enabled true
cmux pane pane_… close
cmux tab tab_… rename --name logs
cmux tab tab_… move --workspace ws_… --screen screen_… --pane pane_… --index 0
cmux tab tab_… pin
cmux tab tab_… zoom 1.25            # browser page zoom or terminal font scale; `zoom reset`
cmux tab tab_… close
```

## Tab and screen groups

Groups take their id or exact name.

```bash
cmux tab group create --tabs tab_…,tab_… --name agents --color green
cmux tab group list --json
cmux tab group agents update --collapse
cmux tab group agents add --tabs tab_…
cmux tab group remove --tabs tab_…
cmux tab group agents move --pane pane_… --index 0
cmux tab group agents save --room Work      # personal saved group
cmux tab group saved list
cmux tab group saved <saved> reopen --pane pane_…
cmux tab group agents ungroup               # or close (closes its tabs)

cmux screen screen_… pin
cmux screen screen_… update --color blue --icon star
cmux screen screen_… move --index 0
cmux screen group create --screens screen_…,screen_… --name infra
cmux screen group infra update --collapse
```

## Workspace status, progress and log

```bash
cmux workspace status set build "tests running"
cmux workspace progress set 0.5 --label tests
cmux workspace log append "done" --level success
cmux workspace status list --json
```

Without a selector they target the caller's workspace. See the skill for more.

## Closed history

```bash
cmux closed list --json
cmux closed <closed_id> reopen
```

## Input and output

```bash
cmux terminal term_… write --text $'echo hello\n'
cmux terminal term_… keys enter
cmux terminal term_… keys ctrl+c
cmux terminal term_… screen read
cmux terminal term_… history read --limit 200
cmux terminal term_… screen wait --pattern 'ready' --timeout-ms 30000
cmux terminal term_… process wait --timeout-ms 600000
```

`write` sends text literally; it adds no Enter. Key chords join modifiers with `+` (`ctrl+c`, `shift+tab`). `screen wait` exits 1 when the timeout passes without a match.

## Waiting for other agents

Wait instead of polling `cmux agents snapshot`:

```bash
cmux agents wait --until idle --target term_… --timeout 60       # its agent stops working
cmux agents wait --until dialog [--target term_…|request_…] --timeout 60
cmux agents wait --until text --target term_… --text 'tests passed' --timeout 60
cmux agents wait --until text --target tab_… --text '^done [0-9]+$' --regex
```

It prints `{until, matched, waited_seconds, match, state}` and exits 1 when the timeout (default 30 s, at most 120 s) passes without a match, as `screen wait` does. `match.state` says how an idle agent stopped (`idle`, `done`, `blocked`, or `closed`). A terminal, tab or agent id no owner knows exits with `selector.not_found`; a dialog target that is not such an id (a request id, a chat session) may name a dialog that has not appeared yet, so it waits. The MCP tool `agents_wait` takes the same arguments.

To react to whatever changes next, long-poll events and keep the cursor:

```bash
cmux agents events --timeout 0 --json                    # a cursor from now (next_after)
cmux agents events --after evc1_… --timeout 60 --json    # the events since, or the first one
cmux agents events --after evc1_… --kind dialog --kind agent
```

It prints `{events, next_after, timed_out}` and exits 0 either way; pass `next_after` back as `--after` for no gaps or duplicates. Kinds are `dialog`, `notification`, `tab`, `workspace` and `agent`; a `reset` event means the daemon restarted or the cursor had to start over, so read `cmux agents snapshot` again. Dialogs and agent chat states are read every second, so one that opens and resolves between two reads is missed, and their baseline is the first app read that answers. Without `--json` it prints one line per event and the cursor on stderr. The timeout is at most 60 s. The MCP tool `agents_events` takes the same arguments.

## Notifications and attention

```bash
cmux notify --title "Done" --body "Task complete"      # attached to the caller terminal
cmux notification create --title "Done" --body "Task complete" --level info
cmux notification list --json
cmux notification clear --terminal "$CMUX_TUI_TERMINAL_ID"
cmux pane flash-focused                                  # app action
```

## Not supported

Sidebar status, progress and log (`set-status`, `set-progress`, `log`, `sidebar-state`), `surface-health`, `drag-surface-to-split`, and `reorder-surface` have no equivalent in cmux-next. `cmux docs` is now a different, catalog-backed help command. `cmux workspace set-status --target ws_… --status done` sets only the workflow status.

## Settings and actions

```bash
cmux settings get
cmux settings get diff.layout
cmux settings set diff.layout split
cmux settings reload-configuration     # app action
cmux action list --noun workspace
cmux action describe "workspace new"
```
