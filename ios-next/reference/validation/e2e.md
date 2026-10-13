# End-to-end validation against the real Mac host (slot `e2e`)

Date: 2026-10-09, 13:29 to 14:31 PDT. Worktree HEAD `321b59e3392`.

- App: the `Drawer` and `Tabs` schemes, built and run with `remote-ios.sh --slot e2e` on
  the headless iPhone 17 Pro simulator on `aziz-other-macbook`. Sign-in used the test login
  (`CMUX_NEXT_TEST_LOGIN_EMAIL` / `CMUX_NEXT_TEST_LOGIN_SECRET`) as `aziz-verify@test.cmux.dev`.
  `Tabs` ran in dark mode (`CMUX_NEXT_APPEARANCE=dark`).
- Host: `cmux15` (`mini-cmux15`), `~/cmux-next-host` in normal mode. Codex was available and
  Claude was not. The host drives Chrome for Testing 155 over CDP.
- Backend: `https://cmux-next-mobile.debussy.workers.dev`.

Evidence (contact sheets, all ≤400 KB) is in `reference/validation/e2e/`. Each sheet is
a row of screenshots, left to right in the order listed.

## Test conditions (read before the numbers)

- Other agents shared this host and account throughout. The log shows 4–6 concurrent iOS
  and probe clients. Another session restarted the host at 20:47 UTC. Other clients typed
  into the same terminals ("echo cmux-probe-…", "echo soak-152", "hiiii") and sent Chief
  "are u coddx". Terminals and conversations are shared per account, so this is expected,
  but it disturbed some terminal checks.
- The simulator host was heavily loaded (load average 98–150). Its own network was jittery:
  ping to 1.1.1.1 ranged 17–575 ms, and its Tailscale path to cmux15 went through
  DERP(sfo) at 28–576 ms. All latency figures below include that noise. Treat them as
  upper bounds, not product numbers.
- After the 20:47 restart, the host launches Chrome on a random CDP port (60102 here),
  not 9222. CDP checks used `curl http://127.0.0.1:60102/json` on the mini.
- I restarted the host once on purpose (check 4). It is now running in normal mode as
  pid 34650, started with the `nohup … cmux-next-host.mjs run >> ~/.cmux-next-host/host.log`
  command from `host/scripts/install-remote.sh`.

## Results

| # | Check | Drawer | Tabs | Evidence |
| --- | --- | --- | --- | --- |
| 1a | Test login lands in the shell with cmux15 online | PASS | PASS | `01-signin-settings.png` (1–2), `08-tabs-scheme.png` (1) |
| 1b | Settings shows the Mac (Online · macOS 27.0.0) and the path | PASS | PASS | `01-signin-settings.png` (3), `08-tabs-scheme.png` (7) |
| 1c | Path label is "Direct" with Force relay off | FAIL (always "Relayed via TURN"; see bug 9) | FAIL (same) | `01-signin-settings.png` (3–4) |
| 1d | Force relay on gives "Relayed via TURN", relay/relay candidates, and a reconnect | PASS | n/a | `01-signin-settings.png` (5), `07-relay.png` (1) |
| 2a | Chief conversation exists (pinned) | PASS | PASS | `01-signin-settings.png` (1) |
| 2b | Message to Chief shows the typing indicator, then a real codex reply (~10 s) | PASS | PASS ("pong") | `03-chief-typing-1fps.png`, `02-chief.png` (1, 5) |
| 2c | "Start a codex agent…" starts a session, which appears in Home and Agents | PASS | n/a | `02-chief.png` (2–4) |
| 2d | The agent thread renders the finished agent reply | PASS, with raw Markdown (bug 11) and no working indicator for 77 s (bug 12) | n/a | `02-chief.png` (3–4) |
| 3a | New codex session in ~ streams text and a tool row; turn ends; `~/hello.txt` = `hi` on the Mac | PASS | n/a | `04-agents.png` (1–2) |
| 3b | Tool row expands to its output | FAIL (shows `[terminal output]`; bug 8) | n/a | `04-agents.png` (3) |
| 3c | Second prompt (Read-only mode) shows the approval card; Allow once completes the edit, and the "Edited 1 file +1" diff matches `hi\nthere` on the Mac | PASS | n/a | `04-agents.png` (4–5) |
| 3d | Session list status goes from spinner (running) to unread dot (done), and the title is updated | PASS (relative times are stale; bug 14) | n/a | `04-agents.png` (6–7) |
| 4a | Create a terminal; `uname -a; ls` | PASS | PASS | `05-terminal.png` (1), `08-tabs-scheme.png` (5) |
| 4b | `top` renders and `q` quits | PASS (first row hidden under the bar; bug 13) | n/a | `05-terminal.png` (2) |
| 4c | Key bar: Ctrl+C and ← arrows | PASS (`^C`; arrows moved the cursor, as `abcuname…` shows) | PASS | `05-terminal.png` (3), `08-tabs-scheme.png` (5) |
| 4d | Larger Text resizes the PTY (`stty size` 42x50 → 36x43) | PASS | n/a | `05-terminal.png` (4) |
| 4e | Link drop (Settings > Reconnect) reconnects and re-attaches the same PTY with its scrollback | PASS (~1 s) | n/a | `05-terminal.png` (7) |
| 4f | Host process killed and restarted: the app shows Reconnecting, then reconnects | PASS (re-hello 3.5 s after host start) | n/a | `05-terminal.png` (5) |
| 4g | Re-attach after a host restart | FAIL (PTYs die with the host; raw "terminal t_… not found" toast and a blank screen; bug 10) | n/a | `05-terminal.png` (6) |
| 5a | Tab list matches Chrome (Gmail, about:blank) | PASS | PASS | drawer in `06-browser.png` (8) |
| 5b | Open the Terminal_emulator URL from the address bar; Chrome's URL changes (CDP) | PASS | n/a | `06-browser.png` (2) |
| 5c | Readable mobile layout | FAIL (desktop layout at 1120 CSS px, scale 0.359; bug 5) | FAIL | `06-browser.png` (2) |
| 5d | Touch scroll updates frames and collapses the toolbar | PARTIAL (toolbar collapses; content jumps at 3–6 updates/s; bug 4) | n/a | `09-browser-scroll-direct-10fps.png` |
| 5e | Tapping a link opens the tapped link | FAIL (tapped "Ethernet"; Chrome went to `#Synchronous_terminals`; bug 3) | n/a | `06-browser.png` (3–4) |
| 5f | Back works (Chrome back to the article, scrollY restored) | PASS | n/a | CDP: `…/Terminal_emulator sy=716` |
| 5g | Tab overview opens; new tab creates a Chrome target | PASS (target `4BB26D32` appeared) | n/a | `06-browser.png` (5–6) |
| 5h | Closing a tab closes the Chrome target | FAIL (app shows 2 tabs, Chrome keeps 3, and the closed tab returns after a reconnect; bug 2) | n/a | `06-browser.png` (7–8) |
| 6a | Force relay: terminal command | PASS (`relay-ok`, `cmux15.local`) | n/a | `07-relay.png` (2) |
| 6b | Force relay: browser scroll | PARTIAL (works; ~3.5 updates/s) | n/a | `10-browser-scroll-relay-10fps.png` |
| T | Tabs: bottom accessory pill inside a Home thread | FAIL (opens Agents with the tab bar hidden, leaving no way to switch tabs; bug 1) | | `08-tabs-scheme.png` (2–3) |

## Measured latencies

All figures were measured on the loaded simulator host described above.

| Metric | Direct mode (Force relay off) | Force relay | How measured |
| --- | --- | --- | --- |
| ICE connecting → connected | 0.65–2.4 s (median ~0.9 s over 12 links) | 0.94 s | host.log `peer state` timestamps |
| Cold launch (`simctl launch` returns) → host `hello`, including test login and ICE | ~3.7 s (Tabs, fresh install) | n/a | local clock vs host.log |
| Settings > Reconnect: link close → `hello` | 0.95 s | 1.8 s (relay toggle) | host.log |
| Host restart → app re-`hello` | 3.5 s | n/a | host.log |
| App-reported RTT (Settings, `currentRoundTripTime`) | 40–1469 ms, typically 56–490 ms | 23–82 ms, outliers of 595 and 631 ms | Settings samples |
| Terminal keystroke echo (key-bar ← touch-down → cursor move in the recording) | 317 ms, 367 ms | 150 ms, 333 ms | `simctl recordVideo` at 60 fps, region diff. Low confidence: the recorder drops frames under load. |
| Browser frame updates while scrolling | ≈5 updates/s (9 over 1.8 s; brief 20/s bursts; gaps up to 267 ms) | ≈3.5 updates/s (8 over 2.3 s; gaps of 250 ms or more) | content-change count in the recording |
| Chief reply (send → bubble) | ~10 s (codex turn); "pong" in Tabs arrived within the 14 s screenshot wait | not measured | recording |
| Agent turn | 5 s (create hello.txt), 41 s (edit, including the approval wait) | n/a | "Worked for" label |

## Bugs, prioritized

The suspected file:line references are guesses from reading the source, not confirmed
root causes. I made no code changes; none of these is a safe one-line fix without a
redeploy or a design call.

### High

1. **Tabs: tab bar stays hidden; the user is stuck.** Repro: Tabs scheme, Home, open Chief,
   then tap the bottom `cmux15 · Relayed…` accessory. The app switches to Agents with no tab
   bar, and only a relaunch recovers it. Cause: the conversations nav delegate hides the
   UITabBarController's bar on push (`CNConversationsUI/ConvNavigation.swift:134-138`). The
   accessory's `openAgents` (`CNAppShell/TabsShell.swift:34-35`, `selection = .agents`)
   changes tabs while the bar is hidden, and nothing un-hides it. Evidence:
   `08-tabs-scheme.png` (2–3).
2. **Browser: closing a tab does not close it on the Mac.** The app removes the tab locally,
   but `curl …/json` still lists all 3 page targets. After the next reconnect the drawer
   lists the "closed" `about:blank` again. `BrowserModel.close` (`CNBrowserUI/BrowserModel.swift:347-350`)
   removes the tab first and swallows the RPC error with `try?`. The host `closeTab`
   (`host/src/providers/browser/index.ts:335-339`) calls `this.get(tabId)` before
   `Target.closeTarget`; that call probably throws for a tab id the host no longer tracks.
   The host does not log RPC errors. Evidence: `06-browser.png` (6–8).
3. **Browser: taps land on the wrong element.** After scrolling, I tapped the "Ethernet"
   link at (157, 456) pt, and Chrome navigated to `#Synchronous_terminals` (a table-of-contents
   entry). The frame on screen did not match Chrome's viewport: there is a gray band under the
   status bar, the frame looks upscaled and blurry, and CDP reported scrollY 4925 after the
   tap. Likely cause: the phone→page coordinate mapping uses a stale or transformed frame
   after the toolbar collapses. Evidence: `06-browser.png` (3–4).
4. **Browser: scrolling does not follow the finger.** Content stays still during the drag,
   then jumps 2–4 times; there is no local offset prediction. This is ≈5 updates/s direct
   and ≈3.5/s relayed. Evidence: `09-…`, `10-browser-scroll-*-10fps.png`.

### Medium

5. **Browser serves desktop sites.** The host sets `mobile: true` metrics
   (`host/src/providers/browser/index.ts:407`) but keeps the Mac Chrome user agent, so
   Wikipedia sends the desktop page (`innerWidth` 1120, visual scale 0.359), and the text
   is unreadable on the phone. Suggested fix: add `Emulation.setUserAgentOverride` with an
   iPhone user agent next to the metrics override.
6. **Browser page view has no way to reach the shell in Drawer.** The page view has no
   hamburger. In the tab overview the hamburger does nothing (tapped twice). Only the
   left-edge swipe opens the drawer. Evidence: `06-browser.png` (5).
7. **Drawer browser rows open the wrong tab.** Tapping "Terminal emulator – Wikipedia" in
   the drawer opened the about:blank Start Page.
8. **Agent tool rows show `[terminal output]` instead of the output.** In
   `host/src/providers/agents.ts:1022`, the placeholder is pushed into `texts`, so
   `item.output` is set and the `rawOutput` fallback at line 1026 never runs. codex-acp
   sends `terminal` content even though `clientCapabilities.terminal` is false (line 478).
   Fix: drop the placeholder so `rawOutput` (stdout) is used. I did not apply this; it
   needs a host redeploy. Evidence: `04-agents.png` (3).
9. **The app and the host disagree on the selected path.** With Force relay off, the app
   showed "Relayed via TURN" (local `relay`, remote `prflx`/`srflx`), while host.log showed
   `host/UDP -> host (fd7a:…)` for the same session (`s_18553025…`, `s_2df892b5…`). One
   side reads the wrong pair: the app at `CNTransportWebRTC/WebRTCConnector.swift:283`
   (`selectedCandidatePairId`), the host at `host/src/transport/webrtc.ts:290`
   (`getSelectedCandidatePair`). Because of this, "Direct" never appeared in this run.
10. **Terminal after a host restart.** The PTYs die with the host process. The app then
    shows the raw RPC text "terminal t_4c0ee7f0fe09f1c3 not found" (from
    `host/src/providers/terminal.ts:207`) over a blank grid, with no "session ended / new
    terminal" action. The list correctly shows "No Terminals". Evidence: `05-terminal.png` (6).
11. **Raw Markdown in Conversations and in previews.** Agent replies in the Messages-style
    thread show `**bold**` and backticks literally. The Agents list and drawer previews do
    too ("Updated `hello.txt` to: ```text hi there ```"). CNAgentUI renders the same text
    correctly. Evidence: `02-chief.png` (4), `04-agents.png` (7).
12. **No working indicator in an agent conversation thread.** The Chief thread shows typing
    dots, but the thread of a Chief-started codex agent stayed blank for the 77 s turn.

### Low

13. Terminal PTY rows are one too many with the key bar visible (42 rows in ~41.6 visible),
    so `top`'s first line sits under the nav bar. Evidence: `05-terminal.png` (2).
14. Agents list relative times go stale: "1m" for a 7-minute-old session and "4m" for a
    10-minute-old one, until a reload.
15. Unread dots are inconsistent. The drawer's Home section uses black dots while the Agents
    section uses gray dots for the same sessions. A session that finished while I was viewing
    it was marked unread.
16. Diff view: the green highlight on an added line spans only the text, not the row
    (`04-agents.png` (5)).
17. New terminals show zsh's inverse `%` partial-line marker on the first line, so the PTY
    is spawned at one size and resized after the first layout (`07-relay.png` (2)).
18. Settings > Terminal font size stays at 13 pt after the terminal menu's Larger Text
    (grid at 15 pt). It is unclear whether this is per-terminal by design.
19. The Reconnecting state shows two indicators at once: a header pill and a toast
    (`05-terminal.png` (5)).
20. Browser overview: the active tab card has no close button (`06-browser.png` (6)).
21. Tabs/dark: in Chief, the subtitle "Chief" overlaps the header name pill; the accessory
    text has low contrast over light web content (`08-tabs-scheme.png` (6)).

## Not covered

- An interactive sign-in UI flow (the test login skips it) and the email-code path.
- Real-device or cellular latency. The numbers above are from a loaded simulator over a
  DERP-relayed Tailscale path.
- Claude harness sessions (Claude is not logged in on cmux15).
