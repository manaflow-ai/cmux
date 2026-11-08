# Browser Surface Discovery

Surface-bound existing-surface browser commands need an explicit surface
handle. The CLI also has a small, explicit global-verb allowlist (for example
`identify`, `devtools`, `design-mode`, `zoom`, `history`, and creation/import
verbs); those commands may omit a handle according to `SKILL.md`. Find a
surface-bound handle with read-only topology commands; never select or focus a
workspace just to make an implicit target work.

## Caller workspace

Start with the context of the terminal that launched the agent:

```bash
cmux identify --json
if [[ -n "${CMUX_WORKSPACE_ID:-}" ]]; then
  cmux tree --workspace "$CMUX_WORKSPACE_ID" --json
else
  # With no caller anchor, use the server's current context after identify.
  cmux tree --json
fi
```

`CMUX_WORKSPACE_ID` is the caller anchor, not necessarily the workspace visible
on screen. If it is unavailable, use `cmux identify --json` and state that the
current server context is being used.

For one known workspace, list its panes/surfaces without selecting it:

```bash
cmux --json list-pane-surfaces --workspace workspace:N
```

## Browser in any workspace or window

`tree --all --json` is the non-focus-changing global inventory. The following
filter prints only topology refs, not page titles or URLs:

```bash
cmux tree --all --json \
  | jq -r '
      .windows[]? as $window
      | $window.workspaces[]? as $workspace
      | $workspace.panes[]? as $pane
      | $pane.surfaces[]?
      | select(.type == "browser")
      | [$window.ref, $workspace.ref, $pane.ref, .ref]
      | @tsv'
```

Pick the surface by the workspace/pane the user named, or by a URL/title only
when the user supplied enough context to disambiguate it. For URL/title-only
context, use this exact-match filter; it emits only the unique surface ref and
does not print the matched metadata:

```bash
MATCH_FIELD="url" # use "title" when matching a page title
MATCH_VALUE="${BROWSER_URL_OR_TITLE:?set BROWSER_URL_OR_TITLE without logging it}"
SURFACE="$(
  cmux tree --all --json |
    jq -r --arg field "$MATCH_FIELD" --arg value "$MATCH_VALUE" '
      [
        .windows[]? as $window
        | $window.workspaces[]? as $workspace
        | $workspace.panes[]? as $pane
        | $pane.surfaces[]?
        | select(.type == "browser")
        | select((if $field == "url" then (.url // "") else (.title // "") end) == $value)
        | .ref
      ] as $matches
      | if ($matches | length) == 1 then $matches[0]
        elif ($matches | length) == 0 then error("no matching browser surface")
        else error("multiple matches; use workspace/pane context")
        end'
)"
if [[ -z "$SURFACE" ]]; then
  printf '%s\n' 'no uniquely matching browser surface; provide workspace/pane context' >&2
  exit 1
fi
cmux browser --surface "$SURFACE" get url
```

Do not print or store raw authenticated-page metadata unnecessarily.

## Inspect the chosen surface

```bash
SURFACE="surface:N"
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" get title
cmux browser --surface "$SURFACE" tab list --json
cmux browser --surface "$SURFACE" snapshot --interactive
```

These inspection commands do not focus the browser or its workspace. Avoid
`select-workspace`, `focus-pane`, `focus-panel`, `focus-webview`, and other
focus-intent verbs unless the user explicitly asked to change visible focus.

## Stale handles and help drift

Surface refs can change when a tab is closed/replaced or a browser is restored.
If a previously valid handle is rejected, run `cmux tree --all --json` again and
reselect from the authoritative topology. Never fall back to a focused surface
or a guessed numeric index.

When installed documentation and the binary disagree, stop and refresh the
contract before continuing. The installer is pinned to the reviewed `skills`
1.5.23 release:

```bash
cmux browser --help
cmux --version
npx --yes skills@1.5.23 add manaflow-ai/cmux --global --yes --skill cmux-browser --agent claude-code codex --copy
```

An already-running agent may have cached the old skill; start a fresh session
after the install when needed.
