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
| 5 | Mac, New Tab spare | `AgentTabs.makeSpare`, `NewTabSparePool` | after first frame; refill 250 ms after an open | yes, parked | n/a | page only: 42 MB JS heap, 1839 DOM nodes parked; taking a chat 91 ms quiet, 328 ms at CPU 4x | | code |
| 6 | Mac, chat view under New Tab | `App.tsx` `<Activity mode="hidden">` (`premountsChatView`) | New Tab shown | yes, hidden React tree | n/a | not measured | | code |
| 7 | Mac, hidden chat released and reopened | `CmuxNextHibernation/HiddenChatPages.swift` (60 s idle, 2 kept warm) → `AgentPageHibernation.releasePage` | show after release | n/a | saved frame, except under Chromium where hidden capture is skipped | page only, see Hidden reopen: quiet 65 ms first content, 333 ms live; 6 pages at CPU 4x 1111 ms first content, 5249 ms live; a warm spare instead 122 ms and 446 ms | 6 pages at CPU 4x live 6416 ms to 3334 ms in one run; quiet restart live 2425 ms to 489 ms | run (page), code (native) |
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

## Hidden reopen: a released chat page shown again

`MODE=reopen-all ROUNDS=5 TURNS=120 bun bench/first-load-after-restart.bench.ts`, medians of 5, cmux-ci run
45005754456, Linux Chromium. `copy` is the page's saved copy, `no copy` a page with nothing saved, `spare` a warm
parked page that takes the chat.

| Load | Path | First content | Live | Socket open | Attach answered | Bytes |
|---|---|---|---|---|---|---|
| quiet, 1 page | copy | 65 ms | 333 ms | 173 ms | 264 ms | 75,703 |
| quiet, 1 page | no copy | 234 ms | 234 ms | 134 ms | 161 ms | 78,726 |
| quiet, 1 page | spare | 122 ms | 122 ms | none | none | 0 |
| 6 pages, CPU 4x | copy | 1111 ms | 5249 ms | 1629 ms | 3139 ms | 460,108 |
| 6 pages, CPU 4x | no copy | 2219 ms | 2219 ms | 1000 ms | 1462 ms | 472,356 |
| 6 pages, CPU 4x | spare | 446 ms | 446 ms | none | none | 0 |

Two gaps. Under load a rebuilt page is live 5 to 12 times later than a warm page that takes the chat (2219 or
5249 ms against 446 ms): every release of a hidden chat buys that. And the saved copy, which halves the time to
first content, more than doubles the time to live under load (5249 ms against 2219 ms; its socket opens 629 ms
later and its attach answers 1677 ms later).

Cause of the second gap (trace run 45010103014, profile run 45017801378): the swap from the copy to the live page
waited for the chat's saved draft to be read (`_acpmux/draft_get`, or its 2 s limit in `draftSettleHold.ts`) even
when the copy's prompt was empty, and under load that read answers about 2 s after the kept tail is drawn. Dropping
the kept tail (`NO_TAIL=1`) changed nothing (6256 ms). Fix: a copy whose prompt is empty waits for nothing
(`chatSnapshot/live.ts` `chatSnapshotShowsDraft`); a copy that shows a draft waits as before.

| Case (medians of 5) | Before | After | No copy, same run | Run |
|---|---|---|---|---|
| 6 pages, CPU 4x, copy, live | 6416 ms | 3334 ms (rounds 2370 to 4968) | 2523 ms | 45021058139 |
| 6 pages, CPU 4x, copy, first content | 1304 ms | 1342 ms | | 45021058139 |
| quiet, 1 page, copy, live | 353 ms | 302 ms | 256 ms | 45021426347 |
| quiet restart (`MODE=down`, daemon up), live | 2425 ms | 489 ms | | 45021426347 |

No blank or shifted frame in any round. Still open: under load the copy is live about 0.8 s after a page with no
copy. With a copy up, the page does about 7.0 s of work a round against 3.8 s: React render 2734 ms against 1122 ms,
`getPropertyValue` 679 ms against 54 ms (`gridScale`, `updateSeeThrough`, `readUIScale`), and a measure and layout
pass that repeats every 500 ms from 3.5 s to 7 s.

## Restart under duress, live content and offline

Same bench, `MODE=down`, the daemon down 3 s across the restart (so `live` cannot come before about 3.2 s).

| Case | First content | Live | Settled | Shift frames, max px | Bytes | Run |
|---|---|---|---|---|---|---|
| quiet: 1 page, 120 turns, local | 63 ms | 2387 ms | 2387 ms | 0 | 78,648 | 45005754456 |
| 6 pages, CPU 4x, rich content, a turn running, rtt200 (`MODE=nightly`) | 271 ms | 3629 ms | 4606 ms | 2, 44 px | 589,906 | 45005754456 |
| same, the saved copy refused (`refused-no-copy`) | 1787 ms | 1787 ms | 5222 ms | 1, 44 px | 592,995 | 45005754456 |
| offline duress: `SIM=long:400`, 1 page, local, not streaming (3 rounds) | 74 ms | 2431 ms | 2431 ms | 0 | 291,137 | 45007222053 |
| offline duress: `SIM=long:400 RUNNING=1 PAGES=6 CPU=4 LINK=rtt200`, streaming 60 records/s (3 rounds) | 351 ms | 5281 ms | 8618 ms, 1 round of 3 never settled | 5 to 7, 541 px | 3,123,404 | 45008421581 |

`SIM=` is new here: it feeds a chat-sim scenario (`scripts/chat-sim.ts --emit-ndjson`, `bench/simLogs.ts`) to the
page-load bench, so a load is measured while a chat streams with no agent. While the chat streams, the load takes
3.1 MB against 0.59 MB, shifts rows by up to 541 px and settles at 8.6 s. The round that never settled may be the
bench's own limit (it waits for one fixed reply to be in view while the stream moves on), not the page's.

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
