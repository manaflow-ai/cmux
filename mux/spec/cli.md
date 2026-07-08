# CLI Surface

The generated CLI is `cmux-mux <verb> ...`. The current checked-in binary also has TUI server modes; this file specifies the future generated command verbs that map 1:1 to `commands.md`.

## Global Conventions

### Socket Resolution

The CLI resolves the target session in this order:

| Priority | Source |
| --- | --- |
| 1 | `--socket <path>` |
| 2 | `CMUX_MUX_SOCKET` |
| 3 | `--session <name>` using `$TMPDIR/cmux-mux-<uid>/<session>.sock` |
| 4 | default session `main` using the default socket path |

`--session` and `--socket` are global flags and may appear before or after the verb.

### Output Modes

`--json` prints the exact command result schema from `commands.md`. For stream verbs, `--json` prints one event object per line.

Human output is stable, greppable, and minimal. It must not include colors, tables with box drawing, progress spinners, or localized prose. Commands that mutate state usually print nothing on success. Create commands print the new surface id. Text extraction commands print the extracted text exactly.

### Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Command succeeded |
| `1` | Server returned `ok:false` or a stream ended with a command-level error |
| `2` | CLI usage error, invalid flags, or invalid local argument shape |
| `3` | Connection error, missing socket, auth failure, or transport failure before response |

### Stdin

`send` reads stdin when neither `--text` nor `--bytes` is supplied. Stdin is read to EOF and sent as the `text` field.

Future commands may opt into stdin only when their command block says so. By default commands do not read stdin.

### Id Arguments

Protocol v5 CLI arguments for ids are numeric. Protocol v6 accepts numeric ids and short ids for any `IdRef` parameter. Numeric-looking strings are rejected as ambiguous when short-id mode is active.

### Selector Arguments

The generated CLI requires one of `--index` or `--delta` for `select-tab`, `select-screen`, and `select-workspace`. It rejects the bare form with exit code 2 even though protocol v5 accepts it, because the bare protocol form can only be a no-op or a useless `tree-changed` emitter.

## Verb Table

| Verb | Status | Required flags/args | Optional flags | Human stdout |
| --- | --- | --- | --- | --- |
| `identify` | implemented | none | global flags | one metadata line |
| `ping` | implemented | none | global flags | one liveness line |
| `reload-config` | implemented | none | global flags | none |
| `set-window-title` | implemented | `--title <title>` | global flags | none |
| `clear-window-title` | implemented | none | global flags | none |
| `list-workspaces` | implemented | none | global flags | tree lines |
| `export-layout` | implemented | none | `--screen <id>` | JSON result object |
| `apply-layout` | implemented | `--layout <json>` | `--workspace <id>`, `--name <name>` | screen and pane/surface lines |
| `send` | implemented | `--surface <id>` | `--text <text>`, `--bytes <base64>` | none |
| `read-screen` | implemented | `--surface <id>` | none | screen text |
| `vt-state` | implemented | `--surface <id>` | none | `cols=<n> rows=<n> data=<base64>` |
| `new-tab` | implemented | none | `--pane <id>`, `--cwd <path>`, `--cols <n> --rows <n>` | surface id |
| `new-browser-tab` | implemented | `--url <url>` | `--pane <id>`, `--cols <n> --rows <n>` | surface id |
| `new-workspace` | implemented | none | `--name <name>`, `--cols <n> --rows <n>` | surface id |
| `new-screen` | implemented | none | `--workspace <id>`, `--cols <n> --rows <n>` | surface id |
| `split` | implemented | `--pane <id> --dir right|down` | `--cols <n> --rows <n>` | surface id |
| `set-ratio` | implemented | `--pane <id> --dir right|down --ratio <n>` | none | none |
| `pane-neighbor` | implemented | `--pane <id> --dir left|right|up|down` | none | pane id or `null` |
| `focus-direction` | implemented | `--dir left|right|up|down` | `--pane <id>` | pane id |
| `swap-pane` | implemented | `--pane <id>` plus one of `--dir left|right|up|down`, `--target <id>` | none | none |
| `zoom-pane` | implemented | none | `--pane <id>`, `--mode toggle|on|off` | zoom state line |
| `process-info` | implemented | `--surface <id>` | none | process metadata line |
| `set-default-colors` | implemented | none | `--fg #rrggbb`, `--bg #rrggbb` | none |
| `close-surface` | implemented | `--surface <id>` | none | none |
| `close-pane` | implemented | `--pane <id>` | none | none |
| `close-screen` | implemented | `--screen <id>` | none | none |
| `close-workspace` | implemented | `--workspace <id>` | none | none |
| `rename-pane` | implemented | `--pane <id> --name <name>` | none | none |
| `rename-surface` | implemented | `--surface <id> --name <name>` | none | none |
| `rename-screen` | implemented | `--screen <id> --name <name>` | none | none |
| `rename-workspace` | implemented | `--workspace <id> --name <name>` | none | none |
| `resize-surface` | implemented | `--surface <id> --cols <n> --rows <n>` | none | none |
| `focus-pane` | implemented | `--pane <id>` | none | none |
| `select-tab` | implemented | one of `--index`, `--delta` | `--pane <id>` | none |
| `select-screen` | implemented | one of `--index`, `--delta` | none | none |
| `select-workspace` | implemented | one of `--index`, `--delta` | none | none |
| `move-tab` | implemented | `--surface <id> --pane <id> --index <n>` | none | none |
| `move-workspace` | implemented | `--workspace <id> --index <n>` | none | none |
| `scroll-surface` | implemented | `--surface <id> --delta <n>` | none | none |
| `subscribe` | implemented | none | none in v5 | event JSON lines |
| `attach-surface` | implemented | `--surface <id>` | none | event JSON lines |
| `wait-for` | implemented | `--surface <id> --pattern <regex> --timeout-ms <n>` | none | none |
| `run` | implemented | `-- <argv...>` or `--command <cmd>` | `--pane <id>`, `--new-workspace`, `--cwd <path>`, `--name <name>` | surface id |
| `send-key` | implemented | `--surface <id> <key>...` | none | none |
| `copy` | implemented | `--surface <id> --mode screen|selection|scrollback` | none | text |
| `ids` | implemented | none | `--kind workspace|screen|pane|surface` | id lines |
| `notify` | implemented | `--title <title> --body <body>` | `--level info|warning|error`, `--surface <id>` | notification id |
| `list-agents` | implemented | none | `--surface <id>`, `--state <state>` | agent lines |
| `report-agent` | implemented | `--surface <id> --state <state> --source socket|hook` | `--session <id>` | none |

## Worked Examples

1. Identify a session:

```bash
cmux-mux --session main identify
```

2. Create a workspace and capture the surface id:

```bash
surface=$(cmux-mux new-workspace --name build)
```

3. Send text from an argument:

```bash
cmux-mux send --surface "$surface" --text "cargo test"$'\r'
```

4. Send a script from stdin:

```bash
printf 'printf "ready\\n"\r' | cmux-mux send --surface "$surface"
```

5. Wait for a prompt, then send a command:

```bash
cmux-mux wait-for --surface "$surface" --pattern 'ready' --timeout-ms 5000
cmux-mux send --surface "$surface" --text "echo ok"$'\r'
```

6. Run a tool in a new tab and poll the screen:

```bash
surface=$(cmux-mux run --name server -- python3 -m http.server)
until cmux-mux read-screen --surface "$surface" | rg -q 'Serving HTTP'; do
  sleep 0.2
done
```

7. Split a pane and resize the split:

```bash
new_surface=$(cmux-mux split --pane 2 --dir right)
cmux-mux set-ratio --pane 2 --dir right --ratio 0.65
```

8. Subscribe to events and react to bells:

```bash
cmux-mux subscribe |
  jq -rc 'select(.event == "bell") | .surface' |
  while read -r surface; do
    cmux-mux notify --title "Bell" --body "Surface $surface rang" --surface "$surface"
  done
```

9. Watch agent states from a shell script:

```bash
cmux-mux subscribe |
  jq -rc 'select(.event == "agent-state-changed") | select(.state == "blocked")' |
  while read -r event; do
    surface=$(jq -r '.surface' <<<"$event")
    cmux-mux notify --title "Agent blocked" --body "Surface $surface needs attention" --level warning --surface "$surface"
  done
```

10. Use short ids when protocol v6 is available:

```bash
sid=$(cmux-mux ids --kind surface | awk 'NR == 1 {print $3}')
cmux-mux send-key --surface "$sid" enter
```
