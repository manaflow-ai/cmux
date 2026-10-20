# Transport verification, 2026-10-19 (fresh verifier)

Status: done. Overall FAIL (two transition defects, below). Video paths are on the mini (see Evidence).

Under test: `origin/feat-cnx-ios` at `90375ce5e11c` (WireGuard path order
direct UDP, TURN over UDP, TURN over TLS on 443; TeamHub relay retired;
WireGuard roaming; browser video on the WebRTC track or the WireGuard RTP
lane; dev Worker API 0.9.0).

## Summary

Overall: **FAIL**. Every path connects, labels itself right on both ends,
carries the terminal and streams the browser on the right carrier, and roaming
and 3 % loss hold up. A transport switch or a cnx-hostd restart while a
browser tab is open leaves that tab frozen on the channel (defect 7, high).

| Check | Result | Key numbers | Evidence (on mini-cmuxs-mac-mini-3, `~/cnx-tv-evidence-20261019/`) |
| --- | --- | --- | --- |
| WireGuard direct: status, Mac label, terminal, browser | PASS | "WireGuard direct" / `Direct`; RTT 0 to 2 ms; echo 8 / 18 ms; `wg-rtp`, glass to glass p50 50 / p90 73 ms, 34.9 fps, 0 stalls | `wg-direct/{terminal,keystroke_echo_idle,browser-ui}.mp4`, `wg-direct/bench/screen.mp4` |
| WireGuard TURN over UDP | PASS | "WireGuard relay (TURN)" / `Turn`; RTT 14 to 16 ms (25 to 44 at load 169); echo 62 / 1243 ms (load); `wg-rtp`, g2g 52 / 101 ms, 33.9 fps, 2 stalls | `wg-turn/...` |
| WireGuard TURN over TLS (Block UDP) | PASS | "WireGuard relay (TURN over TLS)" / `TurnTls`; RTT 15 to 18 ms; echo 33 / 48 ms; `wg-rtp`, g2g 35 / 60 ms, 35.4 fps, 0 stalls | `wg-tls/...` |
| WebRTC direct | PASS | "WebRTC direct" / `Direct`; RTT 0 to 12 ms; echo 24 / 33 ms; `track`, g2g 35 / 60 ms, 35.7 fps, 0 stalls | `rtc-direct/...` |
| WebRTC TURN | PASS | "WebRTC relay (TURN)" / `Turn`; RTT 15 to 21 ms; echo 32 / 47 ms; `track`, g2g 52 / 102 ms, 27.2 fps, 8 stalls (load 604) | `rtc-turn/...` |
| WebRTC + Block UDP | PASS (ignored, as documented); label defect 4 | connects "WebRTC direct" in 8 s | `rtc-blockudp/terminal.mp4` |
| Transport switch while a tab streams | FAIL | tab returns on `channel`, 4 fps, frozen | `t-switch/transition.mp4` |
| Kill cnx-hostd while a tab streams | FAIL (link and terminal recover in about 1 s; browser does not) | tab on `channel`, 1 fps | `t-kill/transition.mp4` |
| Roam on WireGuard (DEBUG probe) | PASS | stall 20.7 ms, first packet 4 ms, `wg-rtp` 38 to 46 fps throughout | `t-roam/transition.mp4` |
| Retired relay | PASS | 0 `relay_retired` on phone and Mac; no binary signaling frame in the client | logs |
| 3 % loss, WireGuard RTP | PASS | g2g 37 / 85 ms, 29.7 fps, 3 stalls > 100 ms, 524 to 663 NACKs | `loss-wg/bench/screen.mp4` |
| 3 % loss, WebRTC track | PASS | g2g 59 / 96 ms, 28.1 fps, 2 stalls, 522 to 678 NACKs | `loss-rtc/bench/screen.mp4` |

Glass to glass and fps come from `verify/scripts/browser-track-bench.py`'s
analysis (12 s, or 20 s under loss, of `bench.html?scroll=6`, OCR of every
frame). "Page tap to phone frame" (`mac_input_to_frame_ms`) p50: WireGuard
direct 117, TURN 87, TLS 65, WebRTC direct 77, TURN 130, loss WireGuard 67,
loss WebRTC 83 ms. Single maxima of 2 to 3 s are one OCR sample each.
All numbers are on one mini shared with CI and another agent's rig (load in
each row); they are not comparable to the quiet-host runs in
`browser-video-track.md`.

Defects, by severity:

- High: 7 (visible browser tab loses the media lane and freezes after a
  redial); 5 (dev Worker 0.10.0 deployed mid-run; a connected 90375ce5 Mac
  stayed on its retired team hub and looked offline to its phone until
  cnx-hostd was killed).
- Medium: 1 (DEBUG rig app aborts in `MainThreadWatchdog` under host load,
  taking cnx-hostd down); 2 (after the Mac app restarts, the open terminal
  stays "Reattaching…" and prints `[unknown surface 15]`).
- Low: 4 ("WebRTC, UDP blocked" label though WebRTC ignores Block UDP).
- Rig only: 3 and 6 (other agents' phones on the shared dev account dial
  the rig Mac and evict its browser tabs); 8 (simulator render server spins
  after repeated recordings on a loaded host).

Not covered: browser over WebRTC + Block UDP (input timed out; the link
itself was checked); WireGuard direct terminal stream timing (the first run
timed from the start of typing, 110.8 s; the TURN and TLS rows give 11 to
13 s); typed-echo on WebRTC TURN at load 604 is an upper bound.

## Rig

- Mac: fleet build of `90375ce5e11c` (job `b65d313ac0f91b52bbb59726`, tag
  `cnx-e2e-90375ce5`). Its bundled `cnx-hostd.version` names commit
  `90375ce5e11c240c9acdd97ce61085019c8e3890` (key `7d66d8c1edf18a4d`). An
  unmodified copy runs hidden (`open -g -j -n`) on `mini-cmuxs-mac-mini-3`;
  every rig setting goes in through `open --env`; the bundle and its
  Info.plist are never edited or re-signed.
- Phone: the Demo configuration of `90375ce5e11c`, built on the same mini
  (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`), in one headless iPhone 17 Pro
  simulator (iOS 26.5) on the same mini.
- Backend: the dev Worker (API 0.9.0) and Cloudflare TURN.
- Driver: `verify/e2e/transport_verify.py` (this branch). Every phone action
  is a tap or typed text in the app's UI: Settings > Transport for the
  transport and the Developer toggles, the terminal composer for commands,
  the browser's address bar for pages, the toolbar for Back and Forward.
- Evidence (videos, screenshots, logs; git-ignored): on the mini under
  `~/cnx-tv-evidence-20261019/` (moved there from the run's worktree at cleanup; `results.json`, `run.log`, `shots/`, per-row `*.mp4`, `bench/result.json`).

## Rig notes and load

- `open --env` reached the rig app's process for every key (checked with
  `ps eww`): `CMUX_NEXT_CONFIG_FILE`, `CMUX_AUTH_CREDENTIALS_FILE`,
  `CMUX_NEXT_IPHONE_PAIRING_SEED`, `CMUX_SHELL_INTEGRATION_DIR`,
  `CMUX_BUNDLED_CLI_PATH` (the last two override the fleet paths baked into
  `LSEnvironment`). No Keychain prompt; cnx-hostd started at once.
- Both allowed minis were heavily loaded by CI during the run
  (mini-cmuxs-mac-mini-3: 1-minute load 8 to 320; mini-cmux11s-mac-mini: 50 to
  350 at the same time). The laptop stayed at 12 to 27 (nothing of this run
  runs on it). Each row below carries the mini's load at its start. At loads
  over about 150 the simulator's input injection (`axe tap`) timed out after
  25 s, and once (18:24) the simulator's render server spun at 100 % CPU and
  the device would not shut down; it was killed, deleted, and the run went on
  in a new simulator (signed in again through the UI). Rows recorded in
  those windows were rerun.

## Partial results (pushed 19:40 PDT; rerun rows follow below as they land)

Load is the mini's 1-minute load average at the start of the row. RTT is the
link RTT the phone's link line shows, 10 samples over 20 s. Echo is
keystroke-to-echo on the phone's soft keyboard, from the simulator recording
(12 keys). "Stream" is a Codex-like output typed on the phone (`for i in
$(seq 400);do echo TAG-$i tok tok;sleep .01;done;echo TAG-END`): seconds from
the tap on Send to `TAG-END` on the Mac's terminal / on the phone's screen.
The simulator and the rig Mac share one host, so "direct" is loopback.

| Row | Load | Phone link line | Mac (cnx-hostd) | RTT ms (median) | Echo ms median / p95 | Stream Mac / phone (s) | Browser | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WireGuard direct | 94 | "WireGuard direct" | `Direct` | 0 (0 to 2) | 8 / 18 | 110.8 / 113.0 (first run timed from the start of typing) | overlay `wg-rtp`, 40 to 45 fps, latency 19 to 29 ms; bench page typed and loaded, touch scroll, tap counted by the page, example.com typed and rendered, Back and Forward | PASS (browser leg by screenshot, the script's page needle was stale) |
| WireGuard TURN over UDP | 169 | "WireGuard relay (TURN)" | `Turn` | 25 to 44 under load (14 to 16 at an earlier load of 130) | 62 / 1243 (load) | 12.5 / 13.0 | overlay `wg-rtp`, 44 to 48 fps, latency 64 ms; navigate 0.7 s, Back 1.0 s, Forward 0.7 s, tap counted | PASS (numbers inflated by load) |
| WireGuard TURN over TLS (Block UDP) | 130 | "WireGuard relay (TURN over TLS)" | `TurnTls` | 18 (15 to 18) | 33 / 48 | 10.8 / 11.2 | 34 to 41 fps, latency 35 ms; navigate 0.9 s, Back 1.0 s, Forward 0.5 s, tap counted; carrier label misread by OCR (see bench) | PASS |
| WebRTC direct | 119 | "WebRTC direct" | `Direct` | 0 | not valid (0 / 0: the analysis saw no key-down) | 10.6 / 11.0 | FAIL in this run: the tab showed `channel`, 1 fps, latency 402 ms; the rig Mac app crashed 3 min later (below) | RERUN |
| WebRTC TURN | 549 | "WebRTC relay (TURN)" | `Turn` | 20 (17 to 24) | not run (Mac app crash, simulator input timed out) | not run | not run | RERUN |
| WebRTC + Block UDP | 541 | never Connected in 60 s | `Direct` | | | | | RERUN |

Scrollback: every terminal row reached the top of the terminal's history by
touch (screenshots `wg-direct-scrollback.png`, `wg-turn-scrollback.png`); the
script's own line-200 check overshot with fast flicks and is not counted.

Retired relay: no `relay_retired` line in the phone's log or cnx-hostd's log
for any row so far. The dev Worker cannot show it: `TeamHub` answers a binary
frame with an `error` frame to the sender and logs nothing
(`backend/src/team-hub.ts` `relayError`), and invocation logs are off. In the
client code the signaling writer has no binary frame at all (`SendQueue::pop`
maps only `Signal::Text` and `Signal::Ping`), and the reader ignores binary.

### Found so far

1. **Rig Mac app (DEBUG) aborts under host load: `MainThreadWatchdog`**.
   Three crash reports on mini-3 (`cmux DEV-2026-10-19-181005.ips`,
   `-192635.ips`, `-193343.ips`), all `EXC_BREAKPOINT` in
   `MainThreadWatchdog.checkHang` (`assertionFailure`) on the
   watchdog thread; main thread in `SidebarMapping.sections` /
   `MainThreadWatchdog.recordStall`. Load was 170 to 700. Each abort takes
   cnx-hostd down ("control input ended; exiting"), so the phone's link drops
   until the app is started again. Severity: medium for dogfood rigs (DEBUG
   only; Release builds do not assert). Repro: run the rig app on a Mac with
   a 1-minute load over about 200 for 10 minutes.
2. **After the Mac app restarts, the phone's open terminal stays
   "Reattaching…" and prints `[unknown surface 15]` into the terminal**
   (`shots/wg-turn-stream-end.png`, 18:17). The daemon (cmux-tui) kept
   running; the app and cnx-hostd restarted (18:14) and the link came back on
   TURN, but the typed `echo` never reached the Mac. Severity: medium. Repro:
   phone on a terminal tab, quit/crash the Mac app (not the daemon),
   relaunch it, type in the phone's composer.
3. **A second phone identity on the rig Mac.** cnx-hostd shows links from two
   phones (`2e42deec…` and `ff8d711c…`) after 18:52, and browser channels
   refused with `replaced: another viewer opened this tab`, plus
   `stopping the least recently used host tab` evicting the tab under test.
   Another agent's simulator (`iPhone 17` on the same mini, same dev
   account) is the likely second phone; not yet confirmed. Severity: rig
   contamination; any phone signed in to the dev account can dial the rig
   Mac and evict its browser tabs.
4. Settings shows "WebRTC, UDP blocked" on the Transport row when Block UDP
   is on with WebRTC (`SettingsScreen.swift:167`), but WebRTC ignores the
   switch (`dial/webrtc.rs` never reads `block_udp`, PROTOCOL.md "Transport
   switch"). Severity: low (DEBUG-only label). Live behavior still to
   confirm (the row above was lost to load).

### Found after the restart (20:14 onward)

5. **The dev Worker moved to API 0.10.0 mid-run (per-user hub, deployed
   03:17:33 UTC from another session), and the rig Mac stayed on its retired
   team hub.** `/v1/health` reported `0.9.0` at 19:39 PDT and `0.10.0` at
   20:20. After the deploy, the phone (90375ce5) showed "cmux's Mac mini is
   offline" (`/v1/me/macs` polled every 4.5 s, all 200) while cnx-hostd
   (90375ce5) kept its signaling socket `ESTABLISHED` and logged nothing for
   5 min: no `signaling ended`, no reconnect. PROTOCOL on
   `feat-cnx-ios-userhub` (388f0f9b) says the Worker retires a team hub the
   first time `GET /v1/me/macs` serves that team and closes its sockets with
   1012; that did not happen here within 5 min of continuous `/v1/me/macs`
   polling. Killing cnx-hostd (`kill -9`, the app restarted it) brought the
   Mac back in 1 s. Severity: high for the 0.10.0 rollout (every
   connected Mac looks offline to its phones until something drops its
   socket). Repro: Mac and phone of build 90375ce5 connected on dev 0.9.0,
   deploy 0.10.0, watch the phone's Workspaces header and cnx-hostd's log.
   Consequence for this report: the task's premise "Worker is API 0.9.0 on
   dev" no longer holds for rows recorded after 20:17 PDT.
6. **Other agents' phones dial this rig Mac.** With every rig signed in to the
   shared dev account (DEBUG "42" credential), after the restart cnx-hostd
   took links from three more phones (`8f5a4013…` WebRTC, `f4ad4f2f…`
   WireGuard TURN, and earlier `ff8d711c…`), and browser channels were
   refused `replaced: another viewer opened this tab`. This is how the
   0.10.0 per-user hub is designed (one user, all their Macs and phones), so
   it is a rig problem, not a product defect: concurrent rigs on one account
   disturb each other. The script now reads cnx-hostd's path only for its own
   phone's sessions (the 20:24 WebRTC-direct row logged `Turn` from another
   phone's WireGuard link).

## Results after the restart (20:14 to 21:33 PDT)

The WebRTC rows were rerun after the simulator's render server was restarted
(it spun at 100 % and blocked input and recording three times; see Rig notes).

| Row | Load | Phone link line | Mac (own phone's session) | RTT ms | Echo ms median / p95 | Stream Mac / phone (s) | Browser | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| WebRTC direct | 516 (spike) | "WebRTC direct" | `Direct` | 0 to 12 | 24 / 33 | 6.1 / 6.9 | overlay `track`, 41 to 42 fps, latency 21 ms; bench page typed and loaded, tap counted, example.com 0.4 s, Back 0.5 s, Forward 0.4 s (`rtc-direct/browser-ui.mp4`) | PASS |
| WebRTC TURN | 604 | "WebRTC relay (TURN)" | `Turn` | 16 (15 to 21) | 32 / 47 | 12.3 / 12.7 | overlay `track`, 41 to 43 fps, latency 33 ms; navigate 0.5 s, Back 0.6 s, Forward 0.5 s, tap counted | PASS |
| WebRTC + Block UDP | 347 | "WebRTC direct" (connected in 8.0 s) | `Direct` | 0 to 6 | 17 / 28 | 12.3 / 12.8 | not run (simulator input timed out) | PASS for "Block UDP is ignored on WebRTC": it connected direct over UDP, as PROTOCOL says. The Settings row still reads "WebRTC, UDP blocked" (finding 4). |

### Transitions (all recorded; `t-*/transition.mp4`)

| Transition | Load | What happened | Result |
| --- | --- | --- | --- |
| Switch WebRTC to WireGuard while the bench tab streams (Back to the list, Settings > Transport > WireGuard, reopen the tab; inside a workspace the tab bar is hidden, so this is the only UI path) | 84 | WireGuard direct came up and the terminal worked after it. The reopened tab came back on `channel` at 4 fps / 7 kbps with a fixed "latency 36 ms" for 28 s: effectively frozen. cnx-hostd: the phone opened three `browser` channels at once on the new link, each claimed the media lane, two answered "another tab took the media lane; video returns to the channel", and the lane ended on a tab that was not on screen (lane report: 3 frames in 35 s). | FAIL (defect 7) |
| Kill cnx-hostd (SIGKILL) on WireGuard direct while the tab streams | 52 | The app restarted cnx-hostd and the link came back (WireGuard direct). The phone reopened five `browser` channels, three of them for tabs of workspaces closed earlier (`s133`, `s138`, `s143`); the lane went to one of those, and cnx-hostd's host limit stopped the visible tab's host ("stopping the least recently used host tab new-02d10d85-t1"). The visible tab showed `channel`, 1 fps, 2 kbps, latency 88 ms for the rest of the 30 s. Terminal correct after (`echo` reached the Mac). | FAIL (defect 7) |
| Roam on WireGuard (DEBUG `CNX_NETWORK_PROBE=roam`, delay 40 s, bench tab streaming) | 224 | `network_probe`: stall 20.7 ms, `roam_first_packet` 4.0 ms, `roam_direct` 5.7 ms, new TURN allocation 219.8 ms, link not closed, path `direct`. The overlay stayed `wg-rtp` at 38 to 46 fps across the roam; cnx-hostd's lane report went from 29 to 1926 frames per 5 s window with no loss. Terminal correct after. The probe relaunches the app (launch argument), so the roam happened on a fresh link. | PASS |

### 3 % loss (hostd `video-drop-permille` = 30, 20 s recorded)

| Carrier | Load | Overlay | cnx-hostd lane report | Result |
| --- | --- | --- | --- | --- |
| WireGuard RTP (`wg-rtp`, direct) | 170 | 51 fps at start, 26 fps after 20 s, latency 23 ms | loss 1.2 to 5.7 %, 524 to 663 NACKs, 7 keyframe requests, target 7.9 to 10.5 Mbit/s, not congested | PASS (stream stayed live; fps dips) |
| WebRTC track (`track`, direct) | 290 | 51 to 55 fps, latency 21 to 33 ms | loss 2.5 to 3.9 %, 522 to 678 NACKs, 6 keyframe requests | PASS |

### Retired relay

- No `relay_retired` line in cnx-hostd's log (0 in 1900+ lines) or in the
  phone's log for any row, on any path, including TURN over TLS.
- Code: the signaling writer of `cnx-link` has no binary frame
  (`send_queue.rs` maps only `Signal::Text` and `Signal::Ping`), so nothing in
  this build can send a relay frame.
- The dev Worker logs nothing for `relay_retired` (it only answers the
  sender), so "the Worker never logs it" cannot be checked from the Worker;
  the client-side checks above stand in for it. PASS.

### Defects added

7. **After a redial, the visible browser tab loses the media lane and freezes
   (high).** On a new link (transport switch, or cnx-hostd restart) the phone
   reopens a `browser` channel for every browser tab it still holds, including
   tabs of workspaces already closed on the Mac. Each open claims the one
   media lane; the last claim wins, and it is not the tab on screen. The
   visible tab falls back to the channel and, when cnx-hostd's host limit
   evicts its host, stays at 1 to 4 fps with no recovery. Repro: open two
   browser workspaces from the phone, close one on the Mac, keep the other
   on screen, kill cnx-hostd (or switch transport and reopen the tab); the
   overlay reads `channel` and the page stops moving. Evidence:
   `t-switch/transition.mp4`, `t-kill/transition.mp4`, cnx-hostd log
   04:17:39 and 04:20:11 UTC.
8. **The simulator's render server spins at 100 % after about 20 to 30 min of
   repeated `simctl io recordVideo` on a loaded host, then input and
   recording fail** (rig, not product). Killing the render server and
   rebooting the simulator fixed it each time; the app's sign-in survived.

## Load next to each check

mini-cmuxs-mac-mini-3 1-minute load at each row's start is in the tables
(range 52 to 1018). Another agent's rig (`cnx-e2e-ce1d3585`, with its own
simulator) ran on the same mini from about 20:30, and swap was 18 of 19 GB
used. The laptop ran none of this (its load stayed 12 to 27). Latency
numbers taken at loads over 300 are upper bounds.
