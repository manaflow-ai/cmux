---
name: cmux-browser
description: "End-user browser automation with cmux. Use when you need to open sites, inspect or interact with browser surfaces, wait for page state, and extract data without stealing focus."
---

# Browser Automation with cmux

## Read the CLI contract first

Check the binary that will actually run before giving an exact command:

```bash
cmux browser --help
cmux --version
```

There are two deliberately different command shapes:

- **Create a browser surface** with `open`, `open-split`, or `new`. These commands may be workspace-scoped and do not need a surface handle.
- **Use an existing surface** with every surface-bound navigation, inspection, interaction, tab, state, or diagnostic command. Pass the handle explicitly with `--surface <handle>` or as the first positional token.

Prefer the flag form in scripts because it makes the target unmissable:

```bash
SURFACE="surface:7" # use a ref returned by discovery; do not guess an index
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" get-url       # accepted alias
cmux browser --surface "$SURFACE" snapshot --interactive
cmux browser --surface "$SURFACE" snapshot -i   # accepted alias
cmux browser --surface "$SURFACE" url            # accepted alias
cmux browser --surface "$SURFACE" tab list
cmux browser --surface "$SURFACE" click e1 --snapshot-after
```

The positional form is equivalent (`cmux browser "$SURFACE" get url`). `url` and
`get-url` are accepted URL aliases, and the short interactive snapshot flag is
accepted when a surface is already present; use `get url` and
`snapshot --interactive` in new documentation so the target and operation are
clear. Surface-bound operations have no unscoped form. The current CLI's
explicitly global browser verbs (`open`, `open-split`, `new`, `identify`,
`import`, `profile`, `profiles`, `react-grab`, `reactgrab`, `devtools`,
`dev-tools`, `focus-mode`, `design-mode`, `zoom`, and `history`) may omit the
handle and use caller/workspace routing; do not infer a target from visible
focus for any other verb.

## Find an existing browser surface without changing focus

`identify`, `tree`, and list commands are read-only and do not select a
workspace, pane, or browser. Do not infer that the visually focused surface is
the one the user wants.

First inspect the caller context (useful for the default workspace):

```bash
cmux identify --json
```

To discover browser surfaces in the caller or another workspace/window, use the
all-window tree. It includes parent refs, so a browser in a different workspace
can be targeted directly without selecting that workspace:

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

The filtered output is `window`, `workspace`, `pane`, and `surface` refs. Keep
the `surface` ref, then target it explicitly:

```bash
SURFACE="surface:N" # copied from the filtered tree output
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" snapshot --interactive
```

If the user gives a URL or title instead of a workspace/pane, match that
metadata locally and emit only the unique surface ref. This never prints the
matched URL or title:

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

For one known workspace, `cmux --json list-pane-surfaces --workspace
<workspace>` is a smaller read-only query. Raw tree/list payloads can contain
page URLs and titles; filter or redact them before logging or pasting them.
Never use a focus/select command merely to discover a surface.

## Core workflow

Open (or create) a surface without stealing focus, capture the returned ref,
then use that ref for every existing-surface operation:

```bash
OPEN_JSON="$(cmux --json browser open https://example.com --focus false)"
SURFACE="$(printf '%s' "$OPEN_JSON" | jq -r '.surface_ref // .surface_id // empty')"
[ -n "$SURFACE" ] || { printf '%s\n' 'browser open did not return a surface ref' >&2; exit 1; }
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser --surface "$SURFACE" snapshot --interactive
cmux browser --surface "$SURFACE" fill e1 "hello"
cmux browser --surface "$SURFACE" click e2 --snapshot-after
cmux browser --surface "$SURFACE" snapshot --interactive
```

The `open` response contains the new surface ref; in a script, extract it from
the JSON response instead of printing the full response. If `get url` is empty
or `about:blank`, navigate first instead of waiting on load state. Re-snapshot
after navigation, modal open/close, or any major DOM change because refs go
stale.

## Wait

```bash
cmux browser --surface "$SURFACE" wait --selector "#ready" --timeout-ms 10000
cmux browser --surface "$SURFACE" wait --text "Success" --timeout-ms 10000
cmux browser --surface "$SURFACE" wait --url-contains "/dashboard" --timeout-ms 10000
cmux browser --surface "$SURFACE" wait --load-state complete --timeout-ms 15000
cmux browser --surface "$SURFACE" wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

## Viewport sizing (WKWebView)

`cmux browser --surface "$SURFACE" viewport <width> <height>` sets an exact
logical viewport from 1 to 4096 CSS pixels. The page is aspect-fitted inside
its existing pane, so pane layout and focus stay unchanged, and screenshots use
the requested logical dimensions. `viewport reset` returns to native pane
sizing.

Close or detach the browser inspector first: its inspector-managed split layout
cannot be combined with viewport emulation, and opening or redocking an
attached inspector resets emulation to native sizing. Large viewport and
page-zoom combinations are bounded; the command returns structured
`maximum_page_zoom` details and leaves the viewport unchanged when the
combination exceeds WKWebView render limits.

## Limits (WKWebView)

Offline emulation, trace/screencast recording, network route
interception/mocking, and low-level raw input injection return `not_supported`;
they depend on Chrome/CDP-only APIs. Use `click`, `fill`, `press`, `scroll`,
`wait`, and `snapshot` instead.

## Troubleshooting `js_error`

Some complex pages reject the JavaScript behind `snapshot --interactive` and
`eval`. Recover by checking whether the page actually navigated, then fall
back to raw text or HTML:

```bash
cmux browser --surface "$SURFACE" get url
cmux browser --surface "$SURFACE" get text body
cmux browser --surface "$SURFACE" get html body
```

If it still fails, navigate to a simpler intermediate page and retry from
there. If the CLI and this skill disagree, refresh help (`cmux browser
--help`) and refresh the installed skill before continuing; do not invent an
implicit target.

## Skill distribution and refresh

The repository copies are the source of truth: `.claude/skills/cmux-browser`
and `.agents/skills/cmux-browser` point at `skills/cmux-browser`. Do not edit a
mirror by hand. The supported Vercel installer (pinned here to the reviewed
`skills` 1.5.23 release) refreshes both global Claude Code and Codex discovery
roots and copies the complete skill (including references and templates):

```bash
# From this checkout while developing the skill:
npx --yes skills@1.5.23 add . --global --yes --skill cmux-browser --agent claude-code codex --copy

# From the published repository after the change is merged:
npx --yes skills@1.5.23 add manaflow-ai/cmux --global --yes --skill cmux-browser --agent claude-code codex --copy
```

Restart an agent session after a refresh if it cached the previous document.
The repository's `skills.sh` remains available for a Codex-only destination;
pass its `--dest` explicitly when that is the installation path:

```bash
./skills.sh --dest "$HOME/.codex/skills" --skill cmux-browser
```

Never commit home-directory skill copies, credentials, cookies, or saved browser
state.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/surface-discovery.md](references/surface-discovery.md) | Find and target an existing browser surface without focus changes |
| [references/commands.md](references/commands.md) | Full command mapping, aliases, `agent-browser` equivalents, viewport error codes |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login/OAuth/2FA patterns and state save/load |
| [references/session-management.md](references/session-management.md) | Multi-surface isolation and state persistence |
| [references/video-recording.md](references/video-recording.md) | Recording status and practical alternatives |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior in WKWebView and workarounds |

## Ready-to-use templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Snapshot/ref form fill loop (requires an explicit surface) |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Login once, save/load state (requires an explicit surface) |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Navigate and capture snapshots/screenshots (requires an explicit surface) |
