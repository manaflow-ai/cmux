# Chiefs drive the browser on the right

Status: design and first implementation, 2026-10-20. Owner: the "Chiefs drive right browser" agent.
Ask (Lawrence, 2026-10-20): "make sure that you, as the chief agent, and all chief agents,
including cloud ones, are able to operate a browser on the right, specifically the one on the
right", with "a good balance between subagents and the chief actually doing all the computer
use/browser use stuff by itself".

Related: [automation-lease.md](automation-lease.md) (the lease contract of the browser host and
the CUA host), [agent-cursor.md](agent-cursor.md) and
[browser-use-cursor/AUDIT.md](browser-use-cursor/AUDIT.md) (a143's named cursor), the
`beside_caller` rule in `ControlCaller.swift`, and the Chief prompt's Home rule
(`Native/OptChat/optchat-chief/src/prompt.rs`).

## 1. What worked before this change

Measured on the NIGHTLY app (1.0.0-nightly.3934935376001), Home workspace
`ws_ff05a52717606064c4c7f6bfc926ef4d`, chat dock `pane_ae19…` (column 0, left dock), right column
`pane_0f51…` (column 1).

| Step | Local Chief | Cloud Chief (Freestyle VM, `mac` over port 7420) |
| --- | --- | --- |
| Open a tab in the right column (`cmux browser open URL --pane <pane>`) | works, no focus change | works with the bundled CLI only (below) |
| `cmux browser <tab_…> state/snapshot/click` | works | works with the bundled CLI only |
| `cmux browser <tab_…> screenshot` on a tab the column does not show | fails: `snapshotUnavailable` (the page is not drawn) | same; and `mac` returns stdout as UTF-8 text, so a PNG must go through `--out FILE` plus `base64` |
| Find "the browser on the right" | by hand: read the Home block or `snapshot.get`, pick a pane, pick a tab | the same, by hand |
| Two agents on one tab | nothing stops it | nothing stops it |
| The agent's cursor | `--agent NAME` (a143), else `Claude` from `CLAUDECODE` | no name (no agent env through `mac`) unless `--agent` |

Traps:

- The page verbs (snapshot, click, fill, screenshot) take the `tab_…` id; a `browser_…` id with
  a page verb such as `state` answers `usage.invalid`.
- On this Mac a login shell's `cmux` is `~/.local/bin/cmux`, an old uv-installed classic CLI
  (`cmux 0.1.0 (ec4cbd4…)`), which has no page verbs. The `mac` gate runs `/bin/zsh -lc`, so a
  Cloud Chief must call the app's bundled CLI by path:
  `'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux'`.
- `browser.page.state` answered `about:blank` for a tab that had loaded example.com, right after
  the open; the next call was right. Read state after a `wait --load-state complete`.

## 2. One target: `cmux browser right`

```
cmux browser right navigate https://example.com --agent "Chief"
cmux browser right snapshot --interactive --agent "Chief"
cmux browser right click e3 --agent "Chief"
cmux browser right screenshot --out /tmp/page.png --agent "Chief"
cmux browser right release --agent "Chief"
```

Every page verb (`cmux browser page --help`) takes `right` where it takes a `tab_…`. The CLI first
asks the app `browser.page.right {agent, url?}` for the tab, then runs the verb on it
(`browser.page.<verb> {tab, …}`). The app decides, from its own topology:

1. The column: the Home workspace (`kind: home`), the pane holding the chat (`home-dock` page),
   and the first scrolling column right of it (`ControlCallerLocation.besidePane`, the same rule
   `beside_caller` uses). Never the dock. No such column: `not_found` with `dock_pane`, so the
   caller makes it once (`cmux pane <dock_pane> split --right --viewport-width 0.5`).
2. The tab, in order: the agent's own tab in that column (one it opened there); else, for a verb
   that does not navigate, a tab there it already drives (live lease), then the browser tab the column shows (else its last browser tab); else a
   new tab opened in that column through the `openBrowser` action with `focus: false`.
   Since 2026-10-20 ([agent-browser-passkey-DESIGN.md](agent-browser-passkey-DESIGN.md) 3.1): the
   shown tab is the person's. Read verbs (the CLI sends `verb`) get it without a lease; any other
   verb gets `user_tab` unless the person handed the tab over (`--take`). A new agent tab opens
   unselected while the person's focus is in that column.
3. A navigation (`url`) by an agent without its own tab there opens a new tab with that URL (the
   answer says `navigated: true` and the CLI does not load it twice). A Chief never navigates the
   user's own tab away.
4. The lease: the tab goes to the agent (`BrowserTabLeases`, one step, so two agents asking at once
   never both get it). Another agent's live lease answers `lease_held` with `holder`. A lease
   lapses 5 minutes after the agent last used the tab; `release` drops it at once.

Focus: nothing here moves keyboard focus or switches the window's workspace. Opening a tab makes
it the column's shown tab, which is the point: the user sees what the Chief does.

Cursor: the verb carries `--agent NAME` (or `CMUX_AGENT_NAME`), so a143's cursor shows the
Chief's name on every click, type and scroll. Chiefs pass their display name ("Chief", "Cloud
Chief").

### Cloud Chiefs

A Cloud Chief reaches the Mac only through its `mac` command (a184's gate on port 7420: tailnet
ACL, `tailscale whois`, bearer token, audit log). The verb is the same command run there:

```
mac -- "'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' browser right navigate https://example.com --agent 'Cloud Chief'"
mac -- "'/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux' browser right screenshot --out - --agent 'Cloud Chief' | base64"
```

No new port, no ACL change, no new credential: the gate already runs commands as the user, and
the app socket answers that user. The lease keeps a Cloud Chief and the local Chief from driving
one tab: the second one gets `lease_held`, or its own tab when it navigates.

### MCP

The cmux MCP server still keeps `browser.page.*` out (`EXCLUDED_APP_METHODS`: "a later phase sets
their policy"). Chiefs drive the browser through the CLI from their shell, which every harness
has. An MCP `browser_right` tool is the follow-up once the page-command MCP policy lands; it
should call the same `browser.page.right` method, so the rule stays in one place.

## 3. Balance: the Chief or a subagent

The Chief is the user's conversation. Each browser step it takes is a tool call in a turn the
user waits on, and its context fills with page snapshots. A subagent has its own context, its
own workspace the user can watch, and reports once.

| The Chief does it itself | A subagent does it |
| --- | --- |
| Short and interactive: look something up, show a page, check one value | Long: more than about 8 actions, or more than a few pages |
| The user is watching and wants to see it now | Multi-page flows, forms across pages, crawling, comparing many pages |
| Under about 8 actions, one site, no sign-in | Sign-in-heavy flows (the user still does the sign-in itself) |
| Showing a result the subagent produced | Repetitive work (the same steps per item), anything that needs retries |

Rules:

1. The Chief drives only the browser on the right (`cmux browser right`). A subagent drives its
   own tab, opened beside its own chat (the `beside_caller` column), or a workspace of its own.
2. Never two agents on one tab. The lease enforces it for `right`; the prompt rule ("Never drive
   a tab another agent drives") covers tabs addressed by id.
3. Sign-ins, payments and passwords stay with the user (person.md: credential steps ask first).
   An agent may import sign-ins only through `cmux browser import-cookies`, which the user
   allows in the app.
4. When a Chief hands a flow to a subagent, the task names the start URL and what to report; the
   subagent shows its final page in its own column, and the Chief may open the result on the
   right for the user.

The rule is in the Chief instructions the Chief host loads (`prompt.rs`, the Home rule, for both
the MCP and the CLI harness) and, shortened, in every subagent's instructions.

## 4. Tests

- `BrowserPageRightTests` (CmuxNextControlTests): the shown tab is the target; another agent gets
  `lease_held`; a navigation by another agent opens its own tab in the right column with
  `focus: false`, never in the dock; with no right column nothing opens; `release` frees the tab.
- `cli/app/right_tests.rs` (cmux-tui): the CLI resolves then runs the verb on that tab; a new
  tab that already loads the URL is not loaded twice; `lease_held` runs no verb; `release`.
- `optchat-chief/tests/right_column_prompt.rs`: every Chief prompt names `cmux browser right`,
  `--agent`, the 8-action bound, the hand-off and `lease_held`; every prompt carries the
  one-driver rule once.

## 5. Open

- Leases cover `browser right` only. Verbs on a `tab_…` id do not check them; folding the lease
  into every page verb belongs with the browser host's lease (automation-lease.md), which also
  pauses on user input.
- `screenshot` of a tab the column does not show fails (`snapshotUnavailable`); `right` mostly
  targets the shown tab, but an agent's own tab may be behind another tab the user selected.
- The Chief host could set `CMUX_AGENT_NAME` to the Chief's display name, so `--agent` is not
  needed.
- MCP tool (section 2).
- Cloud Chief instructions (cmuxterm-hq `tools/cloud-chief`) should name the bundled CLI path;
  a184 owns them.
