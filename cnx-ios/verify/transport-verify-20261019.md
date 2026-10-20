# Transport verification, 2026-10-19 (fresh verifier)

Status: IN PROGRESS. Partial results are pushed as they land.

Under test: `origin/feat-cnx-ios` at `90375ce5e11c` (WireGuard path order
direct UDP, TURN over UDP, TURN over TLS on 443; TeamHub relay retired;
WireGuard roaming; browser video on the WebRTC track or the WireGuard RTP
lane; dev Worker API 0.9.0).

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
  `~/cnx-tv/cnx-ios/verify/evidence/2026-10-19/transport-verify/`.

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
