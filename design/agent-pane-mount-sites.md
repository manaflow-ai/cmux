# Where the agent pane loads, and what each load costs

Leo, 2026-11-22: "not just here, but anywhere you'd expect an agent pane to load, and anywhere you wouldn't
expect but it still loads."

One row per place the agent chat (or its code) loads. `Read` says how the row was established: `code` is a
read of the tree at 55298006b48d, `run` is a measurement from the named harness. A cell that says `not
measured` has no number yet; nothing here is estimated.

Harness for every number: `webviews/bench/first-load-after-restart.bench.ts` (production build, stand-in
acpmux, `LINK`, `PAGES`, `CPU` knobs) and `scripts/measure/restart-settled-linux.sh` (the same bench beside
the terminal's reattach). Both run on Linux Chromium: they leave out the app's process start, CEF start and
the Swift host. Mac rows need `scripts/cmux-next/bench_relaunch_reconnect.py` and the `agent_pane.*` marks.

## Mount sites

| # | Surface | Site | Trigger | Loads while unseen? | Cache-first draw | Before | After | Read |
|---|---|---|---|---|---|---|---|---|
| 1 | Mac, restored chat tab, focused | `CmuxNextApp/AgentTabs.swift` `makeView` → `PageWebView(.agent)` | launch | no | saved page JPEG (native layer), then the page's own saved copy, then kept tail | page only, see Baseline: first content 60 ms, settled 458 ms local to 1505 ms throttled; app, CEF and Swift start not measured | | run (page), code (native) |
| 2 | Mac, restored chat tab, other pane | same, behind `AgentTabStore+Launch.swift` `deferAtLaunch` | focused terminal's first frame | waits for the terminal, then loads whether or not looked at | same as 1 | not measured | | code |
| 3 | Mac, chat tab not selected in its pane | `AgentTabs.view(for:)` on first show or on hover (`PaneController+Neighbors.swift`) | show, hover | hover loads it before it shows | same as 1 | not measured | | code |
| 4 | Mac, every agent page under Chromium | `CmuxNextPages/PageWebView.swift` init builds a `PageWKWebView` before the engine is chosen | every page | yes: a WebKit view nobody draws when the engine is CEF | n/a | first view in the process 26 to 43 ms main thread and 3.4 to 4.9 MB; each later one about 1 ms and about 75 KB (stand-in script, air-blue M5 under load average 57 to 85, 5 runs of 20 views; helper processes not checked) | not cut: about 1 ms a page | run |
| 5 | Mac, New Tab spare | `AgentTabs.makeSpare`, `NewTabSparePool` | after first frame; refill 250 ms after an open | yes, parked | n/a | not measured | | code |
| 6 | Mac, chat view under New Tab | `App.tsx` `<Activity mode="hidden">` (`premountsChatView`) | New Tab shown | yes, hidden React tree | n/a | not measured | | code |
| 7 | Mac, hidden chat released and reopened | `CmuxNextHibernation/HiddenChatPages.swift` (60 s idle, 2 kept warm) → `AgentPageHibernation.releasePage` | show after release | n/a | saved frame, except under Chromium where hidden capture is skipped | not measured | | code |
| 8 | Mac, chat switch in one page | `chatSwitch.ts`, `selectSession` | click | no | kept tail (20 chats, 400 events) | not measured | | code |
| 9 | Mac, sub-session tray, Session Info card | `App.tsx` `key={shownSessionId}` | every chat switch | remounts and re-reads each switch | none | not measured | | code |
| 10 | Mac, Home channels and messages | `pages/home-channels`, `pages/home-messages` import `PromptEditor`, `AgentMessageRow`, `Markdown` | Home open | pane code (Milkdown) in a page that is not the pane | their own | not measured | | code |
| 11 | Mac, Cloud or remote chat | `direct.ts` attach through the native relay, `cloudChatRecovery.ts` | open | no | saved copy and kept tail, as 1 | not measured | | code |
| 12 | Browser build | `browser/host.ts`, served by `acpmux web --app` | link opened | no | `sessionStorage` copy only: a fresh browser draws nothing first | not measured | | code |
| 13 | Guest page | `agent-session/guest/main.tsx` | share link | no | `sessionStorage` after joining | not measured | | code |
| 14 | iOS chat | native `AgentChatScreen`; `WorkspaceTabsSource.chatStore()` | navigation; also card, accessory and menu bodies | a store is built for tabs never opened | `AgentTranscriptCache` head file | not measured | | code |
| 15 | iOS Cloud chat | per-chat relay, `AcpmuxHub.transcriptCache == nil` | open | not traced | none | not measured | | code |
| 16 | iOS Feed markdown pool | `WebMarkdownRenderer.prewarm` (2 web views) | Feed open | yes | n/a | not measured | | code |

## Baseline: one restored chat against the terminal

`scripts/measure/restart-settled-linux.sh links=local,rtt50,rtt200,throttled rounds=5 turns=120 down=0`, medians of
5, tree 55298006b48d, Linux Chromium on a fleet runner (cmux-ci runs 45005743114 for the terminal, 45006868481 for
the chat). One 120-turn chat, nothing streaming, one page: this is the quiet case, not duress.

| Link | Chat first content | Chat settled | Chat attach answered | Chat bytes | Terminal first content = settled | Terminal bytes |
|---|---|---|---|---|---|---|
| local | 60 ms | 458 ms | 405 ms | 75,703 | 0.9 ms | 39,620 |
| rtt50 | 59 ms | 590 ms | 478 ms | 75,703 | 151 ms | 40,118 |
| rtt200 | 61 ms | 1103 ms | 766 ms | 75,703 | 601 ms | 40,118 |
| throttled | 61 ms | 1505 ms | 650 ms | 75,703 | 776 ms | 39,620 |

The chat's first content comes from its saved copy, so it does not move with the link; no layout shift in any
round. What the link moves is the time until the chat is live: 0.46 s on a local link, where the terminal takes
1 ms, and about 2x the terminal on the slower links.

iOS has no web agent pane: its chat is native. Rows 14 to 16 are here because the same question applies.

## Things that unload themselves

| What | Where | Trigger | What the person sees |
|---|---|---|---|
| Hidden chat page released | `HiddenChatPages.swift` | 60 s hidden and idle (30 s under memory warning) | a rebuild on next show |
| Hidden Chromium page frozen | `browser.freezeHiddenTabs` | 30 s hidden | thaw on show |
| Hidden pane's stream shed | `AcpmuxPaneSocket+Hidden.swift` | hidden | `_acpmux/lagged` resync on show |
| Chat view rebuilt | `App.tsx` `chatViewMount.key += 1` | leaving the chat for New Tab, History, Contexts or Setup | draft and picker state start over |
| New Tab screen rebuilt | `App.tsx` `key={newTabGeneration}` | every Cmd-T adoption | |
| Mode chip changes or leaves | `ComposerPickers.tsx` (`highest`, `modeless`, borrowed start mode, saved copy) | acpmux's answer or the harness list arriving | "bypass permissions appears then disappears" (cause not yet reproduced) |
| iOS older turns spilled | `ChatTranscriptList.relieveMemoryPressure` | memory warning | re-read on scroll |

## Not read yet

`workers/`, the `agent-chat/` sidecar, the Mac's Cloud relay, the sidebar chat-history and session-info hosts.
