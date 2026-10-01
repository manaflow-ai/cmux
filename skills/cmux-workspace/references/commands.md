# cmux Workspace Command Reference

Use these commands from a cmux terminal; the CLI reads the session from the environment. Selectors are a public id (`ws_…`, `screen_…`, `pane_…`, `tab_…`, `term_…`), `current` (the focused one), or an exact name. `--json` prints one result object, `--jsonl` one object per result or event. `cmux <scope> --help` prints each scope's grammar.

## Context

```bash
cmux app identify              # the app: bundle, tag, socket
cmux app capabilities
cmux app ping
cmux session list
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

cmux pane pane_… split --right
cmux pane pane_… split --down --cwd "$PWD"
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

## Notifications and attention

```bash
cmux notify --title "Done" --body "Task complete"      # attached to the caller terminal
cmux notification create --title "Done" --body "Task complete" --level success
cmux notification list --json
cmux notification clear --terminal "$CMUX_TUI_TERMINAL_ID"
cmux pane flash-focused                                  # app action
```

## Not supported

Sidebar status, progress and log (`set-status`, `set-progress`, `log`, `sidebar-state`), `surface-health`, `drag-surface-to-split`, `reorder-surface`, and `cmux docs` have no equivalent in cmux-next. `cmux workspace set-status --target ws_… --status done` sets only the workflow status.

## Settings and actions

```bash
cmux settings get
cmux settings get app.appearance
cmux settings set app.appearance dark
cmux settings reload-configuration     # app action
cmux action list --noun workspace
cmux action describe "workspace new"
```
