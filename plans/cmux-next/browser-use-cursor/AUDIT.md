# Agent browser use in cmux-next: audit (2026-10-19)

Base: origin/feat-cmux-next ce6670c4e68. Earlier work reused: a79d2d772db (agent cursor, keystroke
caption, `browser.showAgentCursor`), worktree `agent-input-overlay`, report
`~/fun/cmux-worktrees/p1369-the-browser-must-show-the-agent-s-cursor-REPORT.md` (never checked in a
running app).

## How agents drive a cmux-next browser tab

| Path | Engines | Input kind | Draws agent cursor |
|---|---|---|---|
| `cmux browser tab_… click/fill/type/press/hover/scroll/select/check` (`browser.page.*`, `cmux-tui/crates/cmux-tui/src/cli/app/page.rs`, `BrowserPageService*.swift`) | WebKit, CEF | synthetic page-script events (untrusted) | yes, via `BrowserPageEngine.announce` → `AppPageInputCursor`; all CLI agents share session `cmux-browser-cli` |
| Browser REPL (MCP `browser_repl_*`, `cmux-browser-host eval`, skill cmux-browser) `engine: cef/webkit` | WebKit, CEF | trusted (NSEvent / CDP) | yes, gate → `automation.input` frame → `AgentCursorInputBridge` (lease holder only) |
| Browser REPL `auto`/`headless` (default) | headless Chromium | CDP | no (no window) |
| Daemon `cmux browser browser_… key/text/mouse/wheel` (TUI Chrome surfaces) | daemon Chrome | CDP | no (not an app tab) |
| Dev CDP port (`CMUX_NEXT_CEF_EXTRA_SWITCHES=remote-debugging-port`, DEBUG only) | CEF | CDP | no |
| Computer use (cua helper) | screen | OS events | own screen-level cursor, not the in-app overlay |
| `debug.agent_cursor.demo` | any | injected | yes (debug only) |

No public CDP port; Playwright `connectOverCDP` is not used anywhere.

## Cursor pipeline

`automation.input` v1 (`schemas/automation-input/event.schema.json`) → `AgentCursorInputBridge`
(schema check, lease check, seq gaps) → `AgentCursorPublisher` (vendored `Packages/Shared/CmuxAgentCursor`)
→ `AgentCursorWindowSlot` → `AgentCursorOverlayModel` → `AgentCursorLayerHost` / `AgentCursorLayer`.

- Motion: `GlideMotion`, smootherstep travel + spring settle as one keyframe animation (no timer).
- Click ripple: yes (click kinds). Typing caption beside the arrow: yes, masked for secret fields.
- Agent name label: **missing** (plan `plans/cmux-next/agent-cursor.md` calls for a pill; only color differs).
- Hit testing: carrier view returns nil from `hitTest`, not an accessibility element; it sits in the
  overlay panel above Chromium child windows.
- User input: pauses a REPL lease (cursor becomes an outline). CLI session has no lease, never paused.
- Setting `browser.showAgentCursor` (default on, user-only).

## Action coverage

| Action | CLI `browser.page.*` | REPL (cef/webkit) |
|---|---|---|
| click, hover, press, type, fill | yes, cursor | yes, cursor |
| scroll | yes; cursor only with a selector | `mouse.wheel`, cursor |
| select / check | yes, cursor | `selectOption`: no cursor |
| drag and drop | missing | `dragTo` (`input.drag`): no cursor |
| upload / file chooser | missing | `setInputFiles`: no cursor |
| download | missing | yes |
| new tab / popup | new-tab, select, close | `tabs.open`, `popup` event |
| iframes / shadow DOM | missing (top document only) | yes |
| dialogs | missing | yes (`DialogBroker`); HTTP auth stays the person's on purpose |
| waits | selector, text, url, load-state, function | waitForSelector/LoadState/Event |
| screenshot | page, element, full page (no overlay) | yes (no overlay) |
| a11y snapshot with refs | `[ref=eN]` / `@eN` (no shadow DOM/iframes) | yes |

Overlay screenshots: only `debug.window_snapshot` (DEBUG builds) composites the window, Chromium
child windows and the overlay panel. Page screenshots never include the cursor.

## Gaps (ranked)

1. No end-to-end proof: no test drives real input and checks the cursor; never seen in a running app.
2. No agent name label on the cursor.
3. Every CLI agent is one session (`cmux-browser-cli`): one color, no name.
4. CLI page scroll with no selector, scroll-into-view draw nothing.
5. REPL `dragTo`, `selectOption`, `setInputFiles` draw nothing; a drag event's end point (`to`) is
   ignored by the geometry (cursor stays at the press point).
6. CLI verbs: no drag, upload, dialogs, downloads, iframes, shadow DOM (REPL covers these).
7. Daemon `browser_…`, headless REPL, dev CDP port and cua draw nothing in the app.

## Existing tests

Swift: AgentCursorTypingTests, AgentKeystrokeCaptionTests, AgentCursorIdleHideTests,
AgentCursorPresenceColorTests, BrowserPageAgentInputTests, BrowserPageInputTests, BrowserPageWaitTests,
BrowserPageTabsTests, BrowserPageCookiesTests; shared package glide/palette/publisher vectors.
Rust cmux-browser-host: automation_input, gate_typing, provider input tests. Live scripts:
`agent-cursor-visual-check.py` (human watches), `agent-cursor-visibility-live.py` (resolver JSON only).
No dogfood scenario covers browser use.
