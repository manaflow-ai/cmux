# Browser Surface Discovery

Page commands need a browser tab id (`tab_…`). Find it with read-only list
commands; never focus a workspace just so `page` points at the right tab.

## Caller context

`current` selectors resolve to the session's active workspace, screen and
pane (what the user sees), not the caller's. The caller's own terminal is
`$CMUX_TUI_TERMINAL_ID`:

```bash
cmux --json workspace current show
cmux --json pane current show
cmux --json pane current tab list
```

If the user switches workspaces, `current` follows them. Use ids for stable targets.

## Browser tabs in any workspace

`tab list` returns each tab's `content_kind` and `content_id`. This filter
prints only ids and names, not page URLs:

```bash
cmux --json tab list \
  | jq -r '.. | objects | select(.content_kind? == "browser") | [.id, .pane_id, .name] | @tsv'
```

For one workspace, scope the list: `cmux --json workspace ws_… screen current pane current tab list`.
Pick the tab by the workspace or pane the user named.

To match a URL the user gave, read each candidate's state and keep a unique
match. This prints only the tab id:

```bash
MATCH_URL="${BROWSER_URL:?set BROWSER_URL without logging it}"
MATCHES=()
for TAB in $(cmux --json tab list | jq -r '.. | objects | select(.content_kind? == "browser") | .id'); do
  if [[ "$(cmux --json browser "$TAB" state | jq -r '.. | .url? // empty' | head -n1)" == "$MATCH_URL" ]]; then
    MATCHES+=("$TAB")
  fi
done
if [[ ${#MATCHES[@]} -ne 1 ]]; then
  printf '%s\n' 'no unique browser tab for that URL; give workspace or pane context' >&2
  exit 1
fi
TAB="${MATCHES[0]}"
```

Daemon browsers (`browser_…`) are listed by `cmux browser list`.

## Inspect the chosen tab

```bash
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive
```

These do not focus the tab or its workspace. Avoid `cmux tab … focus`,
`cmux pane … focus` and `cmux workspace … focus` unless the user asked to
change visible focus.

## Stale ids and help drift

Tab ids are stable across app and daemon restarts, but a closed tab's id stops
resolving. If an id is rejected, list the tabs again; never fall back to `page`
or a guessed id.

When installed documentation and the binary disagree, refresh the contract
before continuing:

```bash
cmux browser --help
npx --yes skills@1.5.23 add manaflow-ai/cmux --global --yes --skill cmux-browser --agent claude-code codex --copy
```
