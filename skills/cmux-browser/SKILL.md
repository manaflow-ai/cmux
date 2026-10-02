---
name: cmux-browser
description: "End-user browser automation with cmux. Use when you need to open sites, inspect or interact with browser surfaces, wait for page state, and extract data without stealing focus."
---

# Browser Automation with cmux

Use this skill to open a page in cmux, read it, and fill or click elements from
a script or agent. Every command below targets a browser tab by id, so nothing
depends on which tab is visibly focused.

## Read the CLI contract first

Check the binary that will actually run before giving an exact command:

```bash
cmux browser --help
cmux --help
```

There are two kinds of browser in cmux, with different ids:

| Id | Owner | Commands |
| --- | --- | --- |
| `tab_…` (or `page` for the focused tab) | the cmux app shows the page | `cmux browser tab_… navigate URL`, `snapshot`, `click`, `fill`, `eval`, … |
| `browser_…` | the cmux-tui daemon | `cmux browser browser_… navigate --url URL`, `key`, `text`, `show`, `close` |

In the app, use the `tab_…` form. Page commands accept a tab id or any unique
prefix of one. `page` means the focused browser tab; use it only when the user
asked about the tab they are looking at.

## Open a browser tab

```bash
cmux --json tab create browser --url https://example.com
```

The result carries the new tab's `tab_…` id. Add `--workspace S --screen S
--pane S` to place it in a pane other than the caller's, and `--name N` to name
it. The app also has UI actions that open a browser in the focused place:
`cmux tab new-browser`, `cmux browser split-right`, `cmux browser split-down`.
Check their arguments with `cmux action describe "tab new-browser"` before use.

## Find an existing browser tab without changing focus

`list` and `show` are read-only; they never select a workspace, pane or tab.

```bash
cmux --json tab list \
  | jq -r '.. | objects | select(.content_kind? == "browser") | [.id, .pane_id, .name] | @tsv'
```

Keep the `tab_…` id and target it explicitly. See
[references/surface-discovery.md](references/surface-discovery.md) for other
workspaces and matching by URL.

## Core workflow

```bash
TAB="$(cmux --json tab create browser --url https://example.com | jq -r '.. | .id? // empty | select(startswith("tab_"))' | head -n1)"
[ -n "$TAB" ] || { printf '%s\n' 'tab create did not return a tab id' >&2; exit 1; }
cmux browser "$TAB" state
cmux browser "$TAB" snapshot --interactive
cmux browser "$TAB" fill e1 "hello"
cmux browser "$TAB" click e2
cmux browser "$TAB" snapshot --interactive
```

`state` prints the tab's URL and title. Selectors are CSS selectors or snapshot
refs (`e3` or `@e3`). Re-snapshot after navigation, a modal opening or closing,
or any large DOM change, because refs go stale.

## Waiting

Waits are not supported yet: there is no command that blocks until a selector,
text, URL or load state appears, and `navigate` returns as soon as the load
starts. After a scripted `navigate`, the templates mark the old document with
`eval`, then poll `eval` a bounded number of times until a new document reports
`document.readyState === "complete"`. Do not poll `eval` in an open-ended loop
for anything else. Take a new `snapshot` when the page is ready, and if an
element is missing, report that instead of retrying blindly.

## What the CLI does not cover yet

These old `cmux browser` features have no command in the new CLI: waits,
cookies, local and session storage, saved state, console and error capture,
network routing, dialogs, frames, downloads, screenshots to a file, video,
trace and screencast, geolocation, offline and viewport emulation, hover,
double click, check, select, scroll, key presses on app tabs, `identify`,
profiles and proxies.

Some have UI actions that act on the focused browser and return no data:
`cmux browser screenshot-page`, `browser screenshot-section`,
`browser toggle-developer-tools`, `browser show-javascript-console`,
`browser delete-site-data`, `browser import-data`, `browser new-profile`,
`browser toggle-design-mode`, `browser toggle-focus-mode`,
`browser toggle-react-grab`. List them with `cmux action list --noun browser`.
Page zoom of an app browser tab is `cmux tab <tab_…> zoom in|out|reset`, which
runs the app's zoom action on the tab's pane (the tab must be the one its pane
shows); the CLI never writes the browser tab record.

## Troubleshooting

If `snapshot` or `eval` fails on a complex page, check where the page is first,
then read text by selector:

```bash
cmux browser "$TAB" state
cmux browser "$TAB" text body
```

`not_found` means the tab id or selector does not exist (list the tabs again).
`ambiguous` means a tab prefix matches more than one tab (use the full id).
`Tab … is not a browser tab of this app` means the id is a terminal tab or a
daemon browser; use `cmux browser browser_… …` for the latter. If the CLI and
this skill disagree, trust `cmux browser --help` and refresh the skill; do not
invent a target.

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

Never commit home-directory skill copies, credentials or page contents from
authenticated tabs.

## Deep-dive references

| Reference | When to Use |
|-----------|-------------|
| [references/surface-discovery.md](references/surface-discovery.md) | Find and target an existing browser tab without focus changes |
| [references/commands.md](references/commands.md) | Every supported browser command, and what was removed |
| [references/snapshot-refs.md](references/snapshot-refs.md) | Ref lifecycle and stale-ref troubleshooting |
| [references/authentication.md](references/authentication.md) | Login and 2FA with the supported commands |
| [references/session-management.md](references/session-management.md) | Several tabs at once; saved state was removed |
| [references/video-recording.md](references/video-recording.md) | Recording was removed; what to capture instead |
| [references/proxy-support.md](references/proxy-support.md) | Proxy behavior |

## Ready-to-use templates

| Template | Description |
|----------|-------------|
| [templates/form-automation.sh](templates/form-automation.sh) | Navigate a given tab and snapshot for a form fill |
| [templates/authenticated-session.sh](templates/authenticated-session.sh) | Open a dashboard in a given tab and detect a login redirect |
| [templates/capture-workflow.sh](templates/capture-workflow.sh) | Save a snapshot and page state of a given tab |
