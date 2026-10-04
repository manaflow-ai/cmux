# New tab screen

Status: plan, 2026-10-04. Owner: new tab lead. Lawrence (2026-10-04): "must load instantly (we need
to have pool of 1 prewarmed chrome UI thing) ... pretty much should be the acp chat screen, with
some niceties: `!` and it instantly becomes a terminal; type a URL and it opens; type a prompt and a
dropdown shows claude/codex/opencode; otherwise it does a Google-like search." Inspiration: centered
mark, one large rounded field "Search or type a URL" with a "Tab to switch" hint and a Search | Ask
toggle at its right; below it "Chats | Routines" with "All Chats >" and three recent chat cards (age,
title, last message, or an error card); a "Show suggested tasks" pill at the bottom. Dark, quiet, no
blue. Leo's ideas: pending (asked through the coordinator); section 9 takes them.

Binding: OWNERSHIP-PRINCIPLES.md, skills/cmux-next-feature, spec app-screens.md section 3 (primary
input), keybindings-and-palette.md (R59 dispatcher), decisions UI-STACK, REACT-PAGES (Q3, Q7),
PAGE-SCHEME-CEF.

## 1. What exists (feat-cmux-next c4b5e502139)

- The new tab page is an agent tab (#16620): `AgentTabStore.open(newTab:)` makes a
  `local-agent:` tab; `AgentTabStore.view(for:)` makes its `AgentPaneView` (WKWebView, bundled React
  acpmux page) on first show. The page is `webviews/src/agent-session/acpmux/NewTabPage.tsx` with a
  Terminal | Browser | Agent kind switch, `!`/`?` prefixes that switch the kind, an omnibar
  (`omnibar.ts`: tabs, workspaces, folders, commands, history) and recent sessions.
- Choices leave by the bridge: `tab.open` (terminal or browser replaces the page,
  `PaneController.replaceNewTabPage`), `tab.jump`, `tab.setDefaultKind`; an agent choice stays and
  becomes the chat in place.
- Cmd-T follows `tabs.newTabKind` (default `same-kind`; `page` opens this page). Cmd-L
  (`focusLocation`) opens or focuses the page.
- Cold cost today: every Cmd-T to the page makes a new WKWebView, a new WebContent process, parses
  the whole acpmux bundle, runs React, opens the acpmux WebSocket and then paints. No baseline is
  measured yet (slice N4 measures it first).
- The acpmux host is prewarmed once per app (`AgentTabStore.init` -> `host.prewarm()`); the page is
  not.
- `PageWebView` and `cmux-page://` are not on feat-cmux-next yet (React UIs lead, H1b).

## 2. Instant open: one spare page per window

### 2.1 Engine

WebKit (WKWebView), the engine of the agent pane and of the planned `PageWebView`.

| | WebKit | CEF |
| --- | --- | --- |
| Init | none (system framework) | `CefInitialize` 80-160 ms main thread, lazy by policy (ChromiumWarmup) |
| Spare cost (estimate, N4 measures) | one WebContent process, about 40-70 MB resident | renderer + GPU share, about 100-150 MB, and forces Chromium on users who never browse |
| Key path | NSView first responder, dispatcher (R59) | CEFTab.keyRouter into the dispatcher |

CEF would make the page pay for Chromium start on every launch. The page code stays engine-neutral
(pane protocol), so a CEF host stays possible later.

### 2.2 Pool

- Exactly one spare per main window (`NewTabSparePool`, owned by the window controller; a pure
  state machine `empty -> warming -> ready -> adopted -> empty`, so it is property-tested).
- A spare is a full `AgentPaneView` loaded with a handshake that has `newTab.spare = true`: the
  page renders the new tab UI with an empty context, connects to acpmux (recent chats arrive by
  subscription) and puts focus in its field. It is parked in the window, below the content, at the
  size of the focused pane, `alphaValue = 0`, not hit-testable, hidden from accessibility. A view
  out of the window or `isHidden` is not rendered by WebKit, so its first show would show a blank
  frame. N4 checks this with `debug.window_snapshot` on the first frame.
- Cmd-T (or any open-page path) adopts the spare in the same main-thread turn: reparent into the
  pane, `alphaValue = 1`, make the web view first responder, then push the context
  (`newTab.context`: cwd, location, omnibar, hotkeys, default kind, workspace theme). No load and no
  React mount happen on the open path.
- Re-warm: after an adopt, a new spare starts at the next idle moment (no input for 750 ms, one-shot
  `DemandTimer`, the ChromiumWarmup idle policy; no polling), so its WKWebView creation does not
  land in the user's typing.
- No spare ready (first seconds after launch, after memory pressure): the cold path of today, same
  page; nothing breaks.
- Drop the spare on memory pressure (`DispatchSource.makeMemoryPressureSource`, event-based), on
  window close, and when the bundle source changes (dev server reload). Theme, shortcut,
  customization and preview pushes reach the spare like any open page (it is registered in
  `AgentTabStore`).

### 2.3 Budget and measurement

- Open: Cmd-T key-down to adopted view on screen within one frame (main-thread work for the adopt
  under 16 ms at 60 Hz, under 8 ms target at 120 Hz).
- No lost key: the field holds every key typed after Cmd-T, including a key typed in the same frame.
  The dispatcher's primary input rule covers the gap: a printable key that arrives before the web
  view is first responder goes to the page's field (app-screens.md section 3).
- Measured on the fleet with a tagged build: a debug socket op `debug.new_tab.timing` returns
  `{action_ms, adopted_ms, first_key_ms, spare_state}`; the test sends Cmd-T plus `hello` with no
  delay through the debug socket, then checks field text == `hello` and adopted_ms - action_ms under
  16 ms over 20 runs (p95). Cold-path numbers are recorded beside it as the baseline.

## 3. One field, typed intent

### 3.1 Classification (pure)

`classifyNewTabInput(text, mode) -> Intent` in `webviews/src/agent-session/acpmux/newTabIntent.ts`:

| Input | Intent |
| --- | --- |
| empty / spaces | `none` (Enter does nothing; Up/Down walk recent chats) |
| `!` then anything | `terminal {command: rest}` |
| a URL with scheme (`http`, `https`, `file`, `about`, `cmux`), `localhost[:port][/...]`, an IP[:port], or one token that is a host with a known TLD or a port (`vite.dev/guide`, `foo.local:3000`) | `url {url}` |
| anything else | `prompt {text}` in Ask mode, `search {text}` in Search mode |

The table lives in one fixture file `webviews/test/fixtures/new-tab-intents.json` (about 60 rows:
`!ls`, `! ls`, `!` alone, `github.com`, `localhost:3000`, `127.0.0.1`, `what is a.b`, `fix the
build`, `file:///tmp`, `cmux://session/x`, `node.js` (decision: URL or text, see Q4), IME text,
leading spaces). The bun test reads it; the Swift classifier used by CLI/MCP (`NewTabIntent` in
CmuxNextApp, reusing `suggestionEngine.resolver` for URL rules) reads the same file in its Swift
test. Two implementations, one table: the page needs a synchronous answer per keystroke, and the CLI
must work with no page.

### 3.2 Field behavior

- `!` typed into an empty field converts the tab into a terminal at once: the page sends
  `newTab.submit {intent: terminal, command: ""}` on that key; Swift opens a terminal tab in the
  workspace default folder (the selected tab's cwd, else the workspace's folder) and closes the page
  when the terminal exists. Keys typed after `!` and before the terminal has focus are sent as
  `newTab.typeAhead {seq, text}`; Swift queues them on the pending terminal and types them in order
  when its surface exists. Pasted `!cmd` types `cmd` without a newline (the user presses Return in
  the terminal; a paste never runs a command by itself).
- A URL intent: Enter opens it in place of the page (browser tab on `browser.defaultEngine`).
- Plain text: the dropdown under the field shows, in this order for Ask mode: one row per agent from
  the acpmux catalog (installed harnesses: Claude Code, Codex, OpenCode, ...; CodeRouter models when
  the coderouter lead exposes them in the catalog), then "Search the web for ..." (the browser's
  search engine through the existing resolver), then matching open tabs, workspaces, history. Search
  mode puts the search row first and the agents after it.
- Tab toggles Search | Ask (Shift-Tab too); the toggle at the field's right shows the mode; Up/Down
  move the highlight; Enter picks the highlighted row; Escape clears the field, then closes the
  dropdown.
- Picking an agent row starts the ACP chat in place with that prompt (the existing becomes-chat
  path, with `harness` set).
- Remembered per user: the last mode and the last agent picked. Proposal (Q3): app-local client
  view state persisted next to `NewTabKindMemory` (not a settings write per pick), with optional
  settings `newTab.defaultMode` and `newTab.defaultAgent` that win when set.

## 4. Below the field

- "Chats | Routines" tab pair. Chats: three most recent acpmux sessions as cards (age, title, last
  message; a failed session shows its error card with the error text), "All chats >" opens the
  session search (`palette.searchChats`, the existing page path). Data: the page's acpmux
  subscription (acpmux is the daemon of agent sessions; no polling).
- Routines: the automations list from the automations lead's ops when they exist; the tab is hidden
  until then (no empty placeholder tab).
- "Show suggested tasks" pill: collapsed by default; source to be decided with Leo's ideas (Q5).
  Hidden until a source exists.
- Visual: the shared backdrop (page background is the surface token from `WebTheme`, transparent
  over a see-through window; one fill, R48), Ghostty-derived colors, no blue, `appearance.borders =
  none` gives no lines, Reduce Motion and Reduce Transparency respected, English and Japanese.
- Prototypes: the current Terminal | Browser | Agent page stays as variant A; the new design is
  variant B; Debug Settings `newTab.layout = a|b` (DEV/NIGHTLY). Lawrence picks after dogfood;
  the loser is deleted.

## 5. One action path

- Catalog action `newTab.submit {text, mode?, agent?, row?}`: classify (Swift `NewTabIntent`, the
  same table), then open terminal / browser / agent chat. Surfaces: the page (through
  `action.run` with arguments; today the bridge passes an id only, N5 adds arguments), palette
  ("New Tab: ..." typed entry), CLI `cmux new-tab [TEXT] [--ask|--search] [--agent ID] [--json]`,
  MCP tool from the catalog, mux agent tools. Automation origin never steals focus (the tab opens
  without selection unless origin user).
- `newTab.page` (exists) opens the screen; `focusLocation` (Cmd-L) unchanged.
- `check-action-surfaces.sh` gets the new action with every surface.

## 6. Ownership

- Client view state (which page tab, spare pool, field text, mode memory): the Swift app, one window
  each. Agent sessions: acpmux. Terminal and browser tabs: their existing owners through existing
  ops. No new daemon entity, so no cmux-tui window is needed for N1-N6.
- The agent tab kind is still session-local in the app (`LocalAgentTab`), so a new tab page does not
  survive relaunch. Unchanged by this plan.

## 7. Slices (red test commit first in each)

| # | Slice | Owner area | Gate |
| --- | --- | --- | --- |
| N1 | `newTabIntent.ts` + fixture table; Swift `NewTabIntent` + table test on the same fixture | webviews, CmuxNextApp | bun test, Swift test (cmux-mini-6) |
| N2 | Variant B page UI: field, Search/Ask toggle, dropdown with agent rows from the catalog, search row, chat cards, error card, l10n en/ja, Debug Settings `newTab.layout` | webviews, CmuxNextSettings | bun tests (rows, keyboard reducer, cards), width check 320/400/800/1400 px, tsc, bundle `--check` |
| N3 | `!` instant terminal with type-ahead queue | webviews, CmuxNextAgentPane bridge, CmuxNextApp | bun test (keys after `!` go to typeAhead in order), Swift test (queue types in order after surface exists), fleet: Cmd-T `!echo hi` read-screen shows `echo hi` |
| N4 | Spare pool: `newTab.spare` handshake, `newTab.context` push, `NewTabSparePool` state machine, park/adopt, idle re-warm, memory-pressure drop, `debug.new_tab.timing` | CmuxNextAgentPane, CmuxNextApp | Swift property test of the pool, fleet timing test (section 2.3), first-frame snapshot, memory sample of one spare |
| N5 | `newTab.submit` catalog action, CLI, MCP, palette, bridge arguments, remembered mode/agent | CmuxNextActions, CmuxNextApp, Rust CLI only through the existing catalog generator | action-surfaces check, CLI round trip on a tagged build |
| N6 | Cmd-T default (Q1) and docs | CmuxNextSettings, docs | default-matches-docs test |
| N7 | Move the page host to `PageWebView` + `cmux-page://cmux.agent/` when the React UIs lead lands H1b; keys through the dispatcher | CmuxNextAgentPane | after H1b; same tests |

N1 and N2 start now (webviews only). N4 needs a fleet build for every measurement.

## 8. Questions (through the coordinator)

- Q1: Should Cmd-T open this screen by default (`tabs.newTabKind` default `page` instead of
  `same-kind`)? Lawrence's "load instantly" suggests yes. Proposal: yes.
- Q2: `!` behavior: convert on the `!` key itself (proposal, matches "instantly becomes a
  terminal"), or switch the field to command mode and convert on Enter (today's behavior)?
- Q3: "Remembered per user": app-local memory plus optional settings (proposal), or a settings write
  on each pick (syncs through cmux-next.json)?
- Q4: Ambiguous single tokens like `node.js` or `readme.md`: URL only with a known public TLD
  (proposal: `.js` and `.md` are TLDs but common file names, so treat them as text unless a scheme,
  `www.` or a path follows), or always a URL?
- Q5: Suggested tasks: what source (Leo's ideas, git status of the cwd, open PRs, failed CI)?
- Q6: Keep variant A as the prototype baseline, or delete the Terminal | Browser | Agent switch now?

## 9. Leo's ideas

Pending.
