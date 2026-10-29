---
name: cmux-browser
description: "Browser automation in cmux: the Playwright-style browser REPL (waits, screenshots, cookies with undo, storage, history, incognito tabs, downloads) and per-tab CLI commands. Use to open sites, read or drive browser tabs, and extract data without stealing focus."
---

# Browser Automation with cmux

Use this skill to open a page in cmux, read it, and fill or click elements from
a script or agent. Every command below targets a browser tab by id, so nothing
depends on which tab is visibly focused.

## Pick the surface

For anything beyond one click or fill, use the browser REPL: persistent
JavaScript with a Playwright `page`, locators, waits, screenshots, cookies,
storage, downloads, history and incognito tabs. Reach it in this order:

1. MCP tools `browser_repl_eval`, `browser_repl_open`, `browser_repl_list`,
   `browser_repl_reset`, `browser_repl_close`, `browser_repl_guide` from the
   `cmux` MCP server. cmux attaches that server to every agent session it
   starts; `"mcp": {"enabled": false}` in `~/.config/cmux/cmux-next.json` turns
   it off.
2. The bundled CLI, from the app's `Contents/Resources/bin`:
   `cmux-browser-host eval --session NAME 'await page.goto("https://example.com"); snapshot()'`
   (also `list`, `close --session NAME`, `guide`). `cmux browser repl` is
   the planned name for the same thing.

Read [references/repl-guide.md](references/repl-guide.md) (the REPL's own
guide) before the first call. What it gives you that the per-tab commands
below do not:

- Tabs: `tabs.list()` reads every tab without waking it; `tabs.open(url, {
  incognito: true })` opens a tab that keeps no cookie, history or state;
  `session.configure({ incognito: true })` makes every later tab of the
  session incognito.
- History: `tabs.history({ query, from, to, limit })` searches cmux browser
  history (read-only). Deleting and reopening history entries are the user's
  app actions (`cmux action list --noun history`); do not run them unless the
  user asked.
- Cookies: `page.context().clearCookies()` clears the tab's site and returns
  `{ restoreIds }`; `page.context().restoreCookies(result)` puts them back.
  The cleared cookies stay in an encrypted backup. You may restore from a
  backup; you never delete one (only the person can, from the app).
- Sign-ins from the person's own browser: `cmux browser import-cookies --from
  chrome:Work --domain github.com --reason "Open the PR review page signed in"`
  copies that browser profile's cookies into a cmux browser profile. You must
  pass `--reason` with what you will do with them; the person sees your chat
  (by name), your reason and your latest message in a consent panel and must
  click Allow before anything is read. Ask only for the sites you need. A Deny
  or no answer within 3 minutes fails the command; do not ask again unless the
  person tells you to. Never print cookie values. See
  [references/authentication.md](references/authentication.md).
- Remote tabs (a page that runs on another machine) use the same tab ids and
  the same REPL calls once that machine's browser host serves them
  (`plans/cmux-next/remote-tab.md`); never assume a remote tab shares this
  Mac's cookies.
- Input never takes the user's focus. The app shows your input with the cmux
  agent cursor; it does not move the user's pointer.

For native macOS apps (not web pages) the tool is cmux Computer Use (the
`cmux-cua` skill), for a task that needs an app on the Mac; never `osascript`.

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

`navigate` returns as soon as the load starts. `wait` blocks until one
condition holds, then returns; do not poll with `eval`.

```bash
cmux browser "$TAB" wait "#results"
cmux browser "$TAB" wait --url-contains /dashboard --timeout-ms 15000
cmux browser "$TAB" wait --text "Saved"
cmux browser "$TAB" wait --load-state complete
```

The default timeout is 5000 ms (at most 120 s). On `timeout`, take a
`snapshot` and report what the page shows instead of retrying blindly. In the
REPL, use its Playwright waits (`page.waitForURL`, `locator.waitFor`).

## Screenshots

```bash
cmux browser "$TAB" screenshot --out page.png
cmux browser "$TAB" screenshot --selector "#chart" --out chart.png
cmux browser "$TAB" screenshot --full-page --out full.png
```

Without `--out` the PNG goes to a new file in the temporary directory and the
command prints its path; `--out -` writes the PNG to stdout.
A tab whose workspace is not on screen is captured too: its page is started
in the background, never focused. For an agent, `cmux window screenshot` paints a
browser page black and `cmux pane|tab screenshot` refuses one
([cmux skill](../cmux/SKILL.md)): only the REPL's `page.screenshot()` hides
the secrets a page shows.

## What the per-tab CLI does not cover

The per-tab commands have no saved state, console
capture, dialogs, downloads, recording or proxies. The REPL has all of them (see "Pick the surface"). Viewport and
device emulation is a tab verb (`cmux tab <tab_…> emulate`; see `cmux tab --help`).
Network routing, geolocation and offline emulation and `identify` have no agent
surface yet.

Some have UI actions that act on the focused browser and return no data:
`cmux browser screenshot-page`, `browser screenshot-section`,
`browser toggle-developer-tools`, `browser show-javascript-console`,
`browser delete-site-data`,
`browser toggle-design-mode`, `browser toggle-focus-mode`,
`browser toggle-react-grab`. List them with `cmux action list --noun browser`.
Page zoom of an app browser tab is `cmux tab <tab_…> zoom in|out|reset`, which
runs the app's zoom action on the tab's pane (the tab must be the one its pane
shows); the CLI never writes the browser tab record.

## Browser profiles

A browser profile has its own cookies, local storage, IndexedDB, cache and
permissions. Make a new, empty one for an agent's sign-ins, open tabs in it,
or move a tab into it. Each command is also an MCP tool: `browser_profile_list`,
`browser_profile_create`, `browser_profile_open` and `browser_tab_set_profile`.

```bash
cmux --json browser profile list                         # browser_profiles[]: id, name, color, icon, index
cmux --json browser profile create --name "Research"     # value.browser_profile.id
cmux --json browser profile open https://example.com --profile Research   # value.tab_id
cmux --json browser tab "$TAB" set-profile --profile Research
cmux --json tab "$TAB" show                              # extra.browser_profile_id
```

`open` takes an http or https URL. Without `--engine webkit|cef` the tab opens
in the person's default engine setting; `--pane <pane_…>` picks the pane (else
the focused one) and `--background true` keeps the pane's selected tab.

A profile is named by its id or its exact name. `set-profile` keeps the tab (same id and
position): the daemon moves the tab record and the app reloads the page at the
same URL in the target profile's store. The back/forward list and session
storage stay with the old profile, and the reload loses unsaved form input.
Agents may move any tab, also the person's. Do not move a tab into the
person's own profile unless they asked for it.

Agents cannot delete browser profiles, not even the ones they made. Only a
person deletes one (Settings, the palette or the menu, then the confirmation
sheet). The CLI and MCP have no delete command, and the daemon's
`delete-browser-profile` refuses every agent, script and CLI call.

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
| [references/repl-guide.md](references/repl-guide.md) | The browser REPL: globals, snapshot, dialogs, cookies, incognito, history |
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
