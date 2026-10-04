# cmux next: history (pages, locations, layout, closed items, commands, agent sessions)

Written 2026-09-30 for the user request "we need forward and back history
stuff … redesign history from first principles … default keyboard shortcuts
should be for navigating history in browser tabs/panes, we need bespoke
shortcut for it. cmd shift p action too. and cmux://history type page too.
think about layout history, agent session id history (via hooks), browser
history". Branch `feat-cmux-next-history`.

## 1. What "history" means here

History answers three questions, and each needs a different mechanism:

| Question | Mechanism | Model |
| --- | --- | --- |
| "Take me back" (one step) | Back / Forward | a cursor in an ordered list |
| "What did I do?" (browse) | the history page, the palette, `cmux history list` | a merged, filtered, grouped timeline |
| "Bring it back" (undo a loss) | Reopen, Resume, Undo Layout | a typed entry that knows how to restore itself |

The old app mixed them: one "focus history" list tried to be all three, and
browser history lived only in the engine. cmux-next keeps **one logical
journal of typed entries**, but every entry kind has exactly one owner, and
the owner is the process that knows the fact first. The app never keeps a
second writable copy (architecture.md 1). The history UI is a read-side
merge over the owners, like the daemon's own read models over its session
journal (cmux-tui/spec/session-journal.md).

## 2. Entry kinds and owners

| Kind | Fact | Owner (writes) | Store | Retention | Restore action |
| --- | --- | --- | --- | --- | --- |
| `page` | a finished main-frame navigation: URL, title, time, browser profile, tab | the daemon history module `cmux-history` (R62, decided 2026-10-04; react-pages.md 2.2); the app reports each visit with `cmux.history.visit.record` | per browser profile, SQLite in the daemon state dir (until H3 lands: app-local `BrowserProfiles/<profile>/History.sqlite`) | 90 days, at most 100,000 visits per profile | Open (current tab, new tab) |
| `location` | where the user was: window, space, machine, workspace, screen, pane, tab (the "where was I" trail) | the app, from each window's settled focus | home session personal projection `history.trail` (≤ 1 MiB CAS document) | 200 entries | Go Back / Go Forward, Go To |
| `closed` | a closed tab, screen or workspace with what reopens it (kind, pane, index, cwd, URL, engine, terminal id) | the app observes the daemon trees (a tab gone while its workspace lives); later the daemon (`closed-history-v1`) | memory (25 tabs, 20 screens) | session of the app; terminals reopen live within the daemon's 30 s reap grace, else a new shell in the same directory | Reopen |
| `layout` | a structural layout change on a screen (split, column resize, swap, zoom, tab move) | the daemon (`layout-undo-v1`, 32 entries per screen, memory) | daemon | daemon lifetime | Undo Layout Change |
| `command` | a finished shell command: command line, cwd, exit status, start, duration, terminal | the daemon (it parses OSC 133 prompt marks for every terminal, with or without the app) | the session journal, kind `terminal.command.finished` (capability `terminal-command-journal-v1`) | the journal's retention (never silently deleted) | Run Again (new tab, same machine and cwd), Copy |
| `agent` | an agent session: provider (Claude Code, Codex, …), session id, cwd, terminal, workspace, started, last activity, ended | the daemon (hook ingress, `agent.session.*` / `agent.turn.*` journal kinds, `session-journal-v1`) | the session journal | the journal's retention | Resume (`claude --resume <id>`, `codex resume <id>`) in a new tab on the same machine and cwd |

Why these owners:

- Page visits move to the daemon history module (R62, decided 2026-10-04,
  react-pages.md 2.2): the CLI, MCP and TUI read page history with no app
  running. The module keeps its own SQLite file per profile, so the 1 MiB
  projection limit does not apply. The browser in the app still observes
  each navigation first and reports it with `cmux.history.visit.record`. The
  engines stay the source of each tab's own back/forward list (with scroll
  and form state).
- The location trail is personal state (data-model.md 1.2c): two Macs that
  attach to one build box keep separate trails. A projection survives app
  relaunch and daemon restart and costs no daemon change.
- Commands and agent sessions are machine facts. They happen on the machine
  whose daemon runs the terminal, also when no app is attached (a TUI or
  phone client, or the app quit with terminals kept). The session journal
  already stores agent hook events durably with their terminal, tab, pane and
  workspace subjects, so agent history needs no new daemon state. The app
  reads each connected session's journal and merges the results.

## 3. Identity, federation, privacy

- Every entry id is qualified: `<session>:<kind>:<id>` (data-model.md 1.3;
  the home session may omit its prefix). A trail entry stores the qualified
  workspace key, pane id and tab id plus the last title, so the history page
  can name a location whose machine is offline.
- An entry on a machine that is not connected shows greyed with the machine
  name. Go Back skips it (it cannot focus it) but keeps it; the entry comes
  back when the machine reconnects.
- Incognito windows (REWRITE.md round 4) record nothing durable: no page
  visits, no trail entries in the projection. Their trail entries live in
  memory only and go when the window closes. The daemon still journals agent
  and command events of their terminals (the daemon does not know about
  incognito); the app hides entries whose workspace belongs to an incognito
  window while it is open.
- No typed text: the trail stores ids and titles, never terminal input or
  form data. A command line is the one exception and is opt-out
  (`history.terminalCommands`, default on): the daemon records it as
  `sensitive` (Unix-socket clients only, never WebSocket or relays), capped
  at 1 KiB, and never records commands typed at a password prompt (no OSC
  133 `C` mark is emitted there).
- Clear history (palette, page, CLI) works per kind and time range: last
  hour, today, 7 days, 4 weeks, all. Pages clear per browser profile (the
  profile of the focused tab, or all profiles). The daemon journal is
  append-only by contract ("size pressure cannot silently delete history"),
  so clearing commands or agent sessions writes a per-session tombstone time
  into the personal projection `history.hidden`; the app hides older
  entries. Real deletion is `session delete` or the journal's export-and-forget
  policy, which stays a daemon operation.

## 4. Two navigation axes

Browsers and editors disagree about Back because they answer different
questions. cmux has both, on separate keys.

### 4.1 Page history (per browser tab)

The engine's back/forward list of one tab. Defaults, all tier 2
(content: only when a page, its address bar or find bar has the keyboard):

| Action | Default |
| --- | --- |
| `browserBack` | Cmd-[ |
| `browserForward` | Cmd-] |

Browsers also map Cmd-Left / Cmd-Right to Back / Forward. The registry has one
default chord per action, so those stay with the page (and the Simulator's
rotate actions) until descriptors take alias chords; a user can bind them.

The toolbar Back and Forward buttons open a menu of that tab's entries on
long press or right-click. WebKit lists `backForwardList`; Chromium
needs a fork call for the entry list and go-to-index (`cmux_tab_navigation_entries`,
`cmux_tab_go_to_entry`, next fork API). Until then a Chromium tab's menu lists
the tab's recorded visits and goes back step by step.

### 4.2 Location history (global, "where was I")

A jumplist: an ordered list of
locations across panes, tabs, workspaces, screens, windows and machines with
one cursor.

| Action (id kept as the cmux.json key) | Title | Default | Tier |
| --- | --- | --- | --- |
| `focusHistoryBack` | Go Back | Ctrl-Cmd-Left | 1 (navigation) |
| `focusHistoryForward` | Go Forward | Ctrl-Cmd-Right | 1 |
| `focusHistoryLast` | Go to Last Location | none | 1 |
| `recentlyFocused` | Location History… | none | palette page |

Chord choice. Ctrl-Cmd-Left/Right is Xcode's Go Back/Forward, so Mac users
already know it for this meaning. Checked against: macOS (Ctrl-Left/Right
switch Spaces, Ctrl-Cmd-F full screen, Ctrl-Cmd-Q lock, Ctrl-Cmd-Space
characters; Ctrl-Cmd-arrows are free), the standard browser chords (no
Ctrl-Cmd-arrow chord; BrowserChordTable unchanged), cmux (free; Ctrl-Cmd-[ / ] stay
Previous/Next Workspace, Ctrl-Shift-HJKL resize panes), Ghostty (macOS
default `super+ctrl+left/right = resize_split`; tier 1 wins in a terminal,
and cmux's own resize keys remain). Rejected: Cmd-[ / Cmd-] (now page history,
the user's rule), Ctrl-Cmd-[ / ] (workspaces), Ctrl-- / Ctrl-Shift-- (Ctrl-Shift-- is Ctrl-_, undo in readline, zsh and Emacs, which tier 1 would
steal from every terminal), Ctrl-Opt-arrows (Rectangle's defaults).

Cmd-[ / Cmd-] act only in a browser context (user 2026-09-30, "consistency
is most important for keyboard shortcuts"). In a terminal or any other
context they do nothing: cmux consumes them, so neither Ghostty's
`super+[` keybind nor the shell gets them (focus.md section 5).

Rules:

1. A location is `(window, workspace, pane, tab)` plus the machine and space it
   belongs to. A page navigation inside one tab is not a new location (that is
   4.1). A focus change inside the same tab (address bar, find bar, DevTools)
   is not one either.
2. Recording: after a window's focus coordinator settles, if its resolved
   location differs from the trail's current entry, the app appends it. Any
   source counts (mouse, keyboard, palette, CLI, notification jump, drag
   drop), because the point is to return from a jump, and jumps come from
   everywhere. Only the key window (else the last active one) records, so a
   CLI change in a background window records only when it brings that window
   forward.
3. Coalescing: when the current entry was entered less than 750 ms before the
   next one, the next one replaces it. Holding Ctrl-Tab across ten tabs, or
   stepping through workspaces, records only where the user stopped. Times
   come from the event, so the rule is pure and needs no timer.
4. Duplicates: appending a location that equals the entry before the current
   one keeps both (A B A is a real path), but the list never holds the same
   location twice in a row.
5. Go Back moves the cursor to the newest older entry that can be focused now
   (its tab exists on a connected machine, in a window that is not closed),
   skipping the others without dropping them. It focuses that location through
   the same path as a palette tab switch: the window is ordered front (made
   key only when the app is active), the space switches, the workspace, screen,
   pane and tab are selected. The focus change it causes is not recorded
   (the trail compares the settled location with the pending target and
   absorbs a match; any other settled location clears the pending target).
6. A new location recorded while the cursor is not at the end drops the
   entries after the cursor (browser semantics).
7. A closed tab's entries stay in the trail as dead entries until they age
   out. The history page lists them with Reopen when the closed-items log
   still holds the tab.
8. The trail is app-wide, not per window: Go Back may move to another window.
   Per-pane directional history
   (focus.md 4a) is separate and unchanged.
9. Persistence: the trail is written to the projection one second after the
   last change (one `DemandTimer`), with CAS; on launch it loads before the
   first focus is recorded. Incognito entries are never written.

Mouse: the side buttons (button 4 and 5) and the two-finger swipe follow the
same split, page history over a page and location history elsewhere
(follow-up; needs `debug.mouse` coverage first).

### 4.3 Existing actions mapped

| Old | New |
| --- | --- |
| `focusHistoryBack` / `Forward` "Focus Back/Forward", Cmd-[ / Cmd-], unbuilt | Go Back / Go Forward on the trail, Ctrl-Cmd-Left/Right |
| `focusHistoryLast` "Focus Last", unbuilt | Go to Last Location: toggles between the current and the previous entry (Alt-Tab for locations) |
| `recentlyFocused` "Recently Focused…", unbuilt | Location History… (palette page of the trail) |
| `recentlyClosed` "Recently Closed…", unavailable | Recently Closed… (palette page of the closed-items log) |
| `reopenClosedTab` Cmd-Shift-T | unchanged, reads the closed-items log |
| `palette.browserClearHistory`, unavailable | Clear Browser History (the focused tab's profile) |
| `workspace.selectLastUsed` Ctrl-Cmd-` | unchanged (workspace recency, not the trail) |

## 5. Surfaces

### 5.1 `cmux://history`

A built-in page shown in a browser tab. The app renders it natively (AppKit
host, SwiftUI list, colors from the tab's theme scope), not as HTML, so no web
page can script it, it opens instantly, and it needs no engine: it works in
fleet builds without Chromium. The tab record keeps the URL `cmux://history`
(frontend browser record), so the page survives relaunch.

- Open it with Show History (Cmd-Y, tier 2 in a page; and
  from the palette, menu and CLI in any context), by typing `cmux://history`
  in an address bar, or `cmux open cmux://history`. It opens in a new tab
  beside the focused tab, or selects the window's existing history tab. Typed
  into an address bar of a blank or New Tab page, it replaces that page.
- Layout: a search field (focused on open), filter chips (All, Pages,
  Locations, Commands, Agents, Closed), then entries grouped by day, each
  with icon, title, detail (URL, cwd, workspace, machine) and time. Group by
  day (default), workspace or machine.
- Actions: Return or double-click opens the entry (page: in this tab;
  location: Go To; command: Run Again; agent: Resume; closed: Reopen).
  Context menu: Open in New Tab, Reopen, Resume Agent Session, Copy URL,
  Copy Command, Copy Session ID, Remove from History, Remove All from This
  Site, Clear… (range menu).
- Navigating from the page to a web URL turns the tab into a real browser tab
  of the default engine.

### 5.2 Palette (Cmd-Shift-P)

Actions: Go Back, Go Forward, Go to Last Location, Show History, Search
History…, Location History…, Recently Closed…, Resume Agent Session…, Clear
History…, Clear Browser History, Undo Layout Change. Search History opens a
palette page over every entry kind (fuzzy, newest first for an empty query,
secondary actions per row as on the page). Resume Agent Session lists agent
sessions only; Recently Closed lists closed items only.

### 5.3 CLI

```
cmux history list [--kind page|location|closed|command|agent] [--limit N] [--json]
cmux history search <text> [--kind …] [--limit N] [--json]
cmux history back | forward
cmux history reopen [<entry id>]
cmux history resume <agent session id>
cmux history clear [--kind …] [--range hour|today|week|month|all]
```

`list` and `search` are the control method `history.list {kind?, text?,
limit?}` (read-only, answered from the history snapshot off the main actor).
The verbs are registry actions (`history.back` is `focusHistoryBack`'s
`cliName`), so the palette, menu and CLI run one handler.

### 5.4 Context menus

Tab: Reopen Closed Tab. Browser Back/Forward buttons: entry menus (4.1).
Workspace row: Location History for This Workspace. Terminal: Recent
Commands (this terminal), Resume Agent Session (this terminal).

## 6. Daemon work (cmux-tui, behind capabilities)

| Capability | Change | Status |
| --- | --- | --- |
| `session-journal-v1` | agent sessions: already journaled; the app reads `session.journal.subscribe {start:"beginning", follow:false, kinds:["agent.session.*"]}` on a short-lived connection, then re-reads from its cursor after each `agent-changed` event (event driven, no polling) | exists |
| `terminal-command-journal-v1` | the terminal host reports OSC 133 `B`/`C`/`D` marks (prompt end, command start, command end with exit code) to the daemon; the daemon appends `terminal.command.finished {command (sensitive, ≤ 1 KiB, the screen text between the B and C marks), cwd, exit_code, started_at_ms, duration_ms}` with the terminal subject; `history.terminalCommands:false` in `set-client-info` stops recording for that client's sessions | proposed |
| `layout-undo-v1` | Undo Layout Change calls `undo-layout {pane}` and confirms when the daemon answers `confirmation_required` | exists |
| `closed-history-v1` | a daemon list of closed tabs and workspaces (so the TUI, the phone and a relaunched app can reopen them), and a close grace for workspaces like tabs have | proposed |

## 7. Implementation map

- `CmuxNextHistory` (new module, pure, no AppKit, no daemon): `HistoryEntry`
  and kinds, `LocationTrail` (the reducer of 4.2), `HistoryQuery` and
  `HistorySearch`, `HistoryDayGrouping`, `HistoryRange`, `AgentSessionFold`
  (journal records to sessions), `BrowserVisitLog` (SQLite, an actor off the
  main thread).
- App: `LocationTrailService` (records from `FocusCoordinator.settledObserver`,
  runs Go Back/Forward, persists), `HistoryService` (merges the owners into a
  snapshot for the page, the palette and `history.list`), `HistoryHandlers`
  (actions), `HistoryPageTab` (the `cmux://history` `BrowserTab`), palette
  pages through `PaletteSources`.

## 8. Not decided here

- Syncing page history between Macs: out of scope.
- A per-workspace trail filter as a second pair of keys: the palette's
  Location History for This Workspace covers it until dogfood asks.

## 9. Status (2026-10-01)

Built: the location trail with Go Back / Go Forward (Ctrl-Cmd-Left/Right)
and its app wiring test; Cmd-[ / Cmd-] only in browser contexts, consumed
elsewhere (focus.md section 5); durable page visits per browser profile
(a reload of a tab its connection found already there, or of a tab this
process already made a page for, is not a visit; every tab created later
records its first visit); agent sessions from the session journal with
Resume; closed tabs, screens and workspaces; `cmux://history`; palette
pages (Search History, Location History, Recently Closed, Command History,
Resume Agent Session); `cmux history list|search` and the action verbs;
Clear History hides of journal entries persisted in `history.hidden`, per
kind; Back/Forward button entry menus (right-click, long press) for WebKit,
and for Chromium from fork API 14.

Terminal command history (user decision 2026-09-30: off by default):
cmux-tui `terminal-command-journal-v1` (`set-terminal-command-history`,
`shell.command.finished` from producer `cmux_shell`) and the app setting
`history.terminalCommands`. The capability is in the app's
`optional` list; builds bundle the same-tree daemon, which serves it.

Not built: mouse side buttons and swipe for either axis; a daemon list of
closed workspaces (`closed-history-v1`; the app lists what it saw close).
