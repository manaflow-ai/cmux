# Browser Surface Discovery

Existing-surface browser commands always need an explicit surface handle. Find
the handle with read-only topology commands; never select or focus a workspace
just to make an implicit target work.

## Caller workspace

Start with the context of the terminal that launched the agent:

```bash
cmux identify --json
cmux tree --workspace "${CMUX_WORKSPACE_ID:-}" --json
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
when the user supplied enough context to disambiguate it. Do not print or store
raw authenticated-page metadata unnecessarily.

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
contract before continuing:

```bash
cmux browser --help
cmux --version
npx skills add manaflow-ai/cmux --global --yes --skill cmux-browser --agent claude-code codex --copy
```

An already-running agent may have cached the old skill; start a fresh session
after the install when needed.
