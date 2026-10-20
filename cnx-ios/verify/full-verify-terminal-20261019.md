# Full verify: terminal and Safari-like tabs, build 3e6a2b56eff (cmux INTERNAL 1.2.0)

Verifier: a fresh adversarial session that implemented nothing. Prior rounds' verdicts were not used. Date: 2026-10-19 (US Pacific).
Gate: `cnx-ios/verify/design/terminal/ACCEPTANCE.md` (162 criteria).

## Verdict

**The gate is not green: 6 PASS, 19 FAIL, 137 BLOCKED (of 162).** Seven defects in the phone app are disruptive under §15. Separately, the Mac rig app crashed once.

The large BLOCKED count has four causes:
- Measurement tools the gate requires do not exist: G-01 through G-19, including the echo probe, the phone text export, the sizing log, netsim, render-suite and red-SHA runs.
- No real agent produced output (below).
- Only `W-D` was run; WireGuard was not.
- Device-only rows were not run.

A BLOCKED row is not a pass.

## Rig

| Part | Value |
| --- | --- |
| Phone | Demo simulator build of 3e6a2b56eff (`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, `DEBUG CNX_DEMO`), iPhone 17 Pro, iOS 26.5, simulator `fvterm-3e6a` (deleted after), on the laptop |
| Mac | Fleet build `cnx-e2e-90375ce5` (job b65d313ac0f91b52bbb59726, 90375ce5e11). It differs from 3e6a2b56eff only in `RootView.swift` (iOS), `testflight-build.sh` and the TestFlight workflow, so Mac-side code is identical. It ran hidden on **mini-cmux11s-mac-mini** (`~/cnx-ios-e2e/fvterm`), settings via `open --env` (`verify/parity/rmac.py`); Info.plist was never edited and the app was never re-signed |
| Link | Dev Worker; WebRTC direct (`W-D`), as the hostd log shows (`kind=WebRtc path=Direct`). WireGuard (`G-D`) and relay paths were **not run** |
| Stimulus | Phone UI only: composer typing and Send, composer Paste + Send, key bar, joystick, taps, drags, grid. Mac-side use was limited to read-only oracle reads (screen, terminal list, hostd log, ps), fault injection (kill -9 cnx-hostd; kill of a tab's terminal host for Restart Shell) and staging fixtures over ssh |
| Load | `termqa/fixtures/stream20.py` (20 stamped rows/s with a 2-line live area redrawn under them, like Codex's), 4.5 min to 60 min runs, plus `seq`, `top` and shell commands |
| Analysis | `termqa/motion.py` (60 fps resample, shift, reversals, flashes, black), `termqa/rows.py` (OCR row ids, drift, foreign, lag), `scripts/pin.py` (pixel scan of the composer card's top edge vs the lowest lit text row) and `scripts/fv.py` mem/CPU sampler (`footprint`, ps cputime deltas, Mac RSS over ssh). Frames were split with ffmpeg and checked by eye where a number flagged something |

**Real agents: BLOCKED.**
- Codex: mini-cmux11s has no Codex login.
- Claude Code: 2.1.301 was started from the phone in a terminal tab with the team subrouter route typed on its command line. It answered every one of 4 prompts with `502 upstream … attempt 10/10` (`agent-session.jsonl`).
- Substitute: the heaviest realistic one was `stream20`, a Codex-shaped live area (erase + redraw under streaming rows), over the same real terminal path.
- Side effect: Claude Code auto-updated itself on the mini during the run.

**Recording validity:** every simulator recording fails §1.4's "< 2 % of source gaps over 34 ms" rule. `simctl recordVideo` writes frames only when the screen changes, giving 5-42 effective fps. Defects below were confirmed frame by frame. Clean numbers are reported, but strictly they are `invalid` under §1.4.

**Contamination:** the hostd log shows a second phone (`5a8031ef…`, probably another verifier on the shared dev account) linking to this rig Mac over WireGuard TURN at 03:27:48 UTC. It did not touch this run's terminals.

## Defects

| ID | Severity | Defect | Rows |
| --- | --- | --- | --- |
| D1 | disruptive | **Torn frames while following.** Under a Codex-shaped live area, the phone presents a frame with the new row appended but the live area not yet redrawn: the page jumps 1 row (16 pt) for one frame, then back. 46 times in 66 s with the keyboard up (`s2b-follow-kbup.motion.json`), 11 in 15 s with the keyboard down after Jump to bottom (`s3b-jump.motion.json`). A 4-min keyboard-down run (s1) had 0. The bytes of one PTY write are drawn in two frames. | T-FOLLOW-02/03/04, T-SCROLL-03, T-REG-1259-b, T-REG-1337-a |
| D2 | disruptive | **Reattach and reconnect.** (a) A Worker signaling socket reset (seen twice, 02:11:09 and 03:36:54 UTC) makes the phone build a second link while the first is still up. The terminal reattaches and repaints: over `top` it went blank (cursor only) for 11 frames at 60 fps, then showed a half-painted screen. The old link died later by `keepalive timed out`. (b) After `kill -9 cnx-hostd`, hostd was back in 1.0 s and on signaling in 1.6 s. The phone's first offer then timed out (`answer failed … timeout`) and the link came up **26.7 s after the kill**, with the tab on "Reattaching…" the whole time. | T-LIFE-12, T-LIFE-17 |
| D3 | disruptive (confirm on device) | **AutoFill pill over the terminal.** With the composer focused (keyboard up), the system AutoFill pill floats over the left 20-140 pt of the last two terminal rows, in 67 of 67 sampled seconds of the keyboard-up run. The shell composer should not offer AutoFill (M2). | T-INPUT-13, T-REND-10, T-FOLLOW-01 |
| D4 | disruptive | **No offline state when the Mac app is gone.** After the Mac app died, the phone showed "Reattaching…" for 20 min and never "offline". | T-LIFE-13 |
| D5 | disruptive | **Input sent while the Mac is down is queued silently and runs much later.** The composer cleared as if sent, with no pending or refused cue. A stream command sent at 19:19:46 ran at 19:35:09 (15.4 min later), when the Mac app came back. | T-INPUT-17 |
| D6 | disruptive | **Grid card frozen.** While the grid is open the card does not update: its last row stayed at 78 while the Mac went 143 → 201, and at 331 while the Mac went 405 → 476. | T-TABS-01, T-REG-1350-a |
| D7 | disruptive (≥2× miss) / noticeable | **Timing and accessibility in tabs.** New Terminal takes 5.59 s from + to a prompt (threshold 1.5 s). The first grid→card switch took 0.76 s (threshold p95 0.15 s); 5 later ones were 0.05-0.07 s. A close confirmation appears 2.1-2.4 s after the tap. An idle close removes the card after 4.4 s. On the zoomed terminal page the AX tree exposes hidden grid controls ('Close e2e-t1', 'Done', 'New', 'More'). The grid's + lost its accessibility label between visits. | T-TABS-05/06/14, T-LIFE-03 |
| M1 | Mac side (outside this lane) | The DEBUG rig Mac app crashed at 19:15:42 while idle: the `MainThreadWatchdog.checkHang` assertion fired with the main thread in `CGFontCacheReset` (`mac-crash-191542.ips`). It caused D4 and D5. | — |

### Steps to reproduce

- **D1:**
  1. Open a terminal tab and tap the composer, so the keyboard is up.
  2. Send `python3 stream20.py 300 20` (`termqa/fixtures`).
  3. Record the simulator.
  4. Run `motion.py VIDEO --bottom 0.52`, or step frames at 60 fps around a flagged time. The frame that shows a new `#000NNNN` row has no `• working…` / `status` lines under it, and the next frame has them.
- **D2a:** keep a terminal open on a busy TUI (`top`) and wait for a Worker socket reset (`signaling ended; reconnecting` in `cnx-hostd.log`). The phone logs a new `link up` while the old session is still up, and the terminal repaints from blank.
- **D2b:**
  1. Run stream20 in a tab.
  2. On the Mac, run `pkill -9 -f '<app>/Contents/Resources/bin/cnx-hostd'`.
  3. Time the tab pill from "Reattaching…" back to its title against hostd's `link up`.
- **D3:** in any terminal tab, tap the composer. The AutoFill pill appears just above the composer, over the last terminal rows.
- **D4 / D5:**
  1. Quit or crash the Mac app.
  2. On the phone, compose `echo X` and Send. The composer clears, with no cue.
  3. Relaunch the Mac app minutes later. The command runs then.
- **D6:**
  1. Run stream20 in a tab.
  2. Open the grid and leave it open.
  3. OCR the card twice, 2 s apart. The rows are the same and older than the Mac's.

## What held up (fresh evidence)

- **Bottom pinned to the composer, on the cursor row:**
  - The lowest text row's bottom edge sits **0.67 pt** above the composer card's top edge in every analysed frame. Keyboard down: 2449 frames of a 4-min stream. Keyboard up: 328 frames.
  - The pinned row is the cursor (prompt or live) row, not the row above (`s1-follow-kbdown.pin.json`, `s2b-follow-kbup.pin.json`, `shots/s1-follow-end.jpg`).
  - The bottom rows are behind the AutoFill pill only when the keyboard is up (D3).
- **Smooth reading while streaming:** after the finger lifted and deceleration ended, 0 px drift for 63 s under stream20, with the Jump button shown throughout.
- **Jump to bottom mid-deceleration:** tapped while the page still moved 3-4 pt per frame, the page reached the live bottom in 1-2 frames (≤ 33 ms) and followed.
- **No black screens:** 0 black frames across follow, read, grid, relaunch and hostd-kill recordings. The one black run was the D2a reattach.
- **App kill and relaunch:** the dimmed saved frame comes first ("Connecting to cmux11's Mac mini…"), then live 0.65 s later. The saved frame was from an earlier state.
- **Close asks the Mac:** 3/3 for a running program, with the Mac's process name ("Still running: python3.14."). Cancel keeps the tab. An idle shell closes without asking.
- **Restart Shell:**
  - A tab whose terminal host kept failing showed "The shell ended." with "Restart Shell Here".
  - The tap brought a live shell in about 0.1-0.3 s, and input reached the Mac (`restart-shell.mp4` at 115 s, `shots/restart-shell-113.5s.jpg`).
  - `exit` in a shell closes the tab instead; that matches the Mac.
- **TUI mode (`top`):** 10 vertical drags caused 0 px of page scroll. 4 keyboard shows and 4 hides caused 0 black frames. Quitting returned the prompt to the composer with the pre-TUI scrollback intact.
- **Joystick and keys:** a flick sends exactly 1 arrow (5/5). A hold repeats (8 columns in 1.2 s). Nothing repeats after release. The key-bar gaps are an even 6.0 pt. ^C stops a flood.
- **Selection:** long-press then Copy put the exact text on the pasteboard in 10/10.
- **Memory and CPU over 60 minutes** (stream20 for 57.6 min, then idle; 136 samples; `mem60-summary.json`):

  | Measure | Value |
  | --- | --- |
  | Phone footprint | 116 MB at start, 140 MB peak, 131 MB at end |
  | Growth after minute 10 | 1 MB; slope 0.27 MB / 10 min |
  | CPU | 12.3 % average while streaming (flat, -0.04 %/10 min); 2.5 % idle following |
  | Mac | cnx-hostd 28 → 37 MB; daemon (cmux-tui) 88 → 208 MB |

  An earlier 40-min process grew 68 → 128 MB while it gained 5,400 rows of scrollback.

## Timing rows, measured

| Row | Threshold | Measured | Verdict |
| --- | --- | --- | --- |
| T-FOLLOW-06 lag (stream20) | p95 ≤ 250 ms | p95 ≈ +0.06 s (offset-corrected) | stream20 part met; stream1m not run |
| T-SCROLL-09 jump to bottom | ≤ 400 ms | 17-33 ms (2/2, one mid-deceleration) | PASS |
| T-LIFE-03 warm switch | p50 ≤ 100 ms, p95 ≤ 150 ms | 0.76, 0.06, 0.07, 0.06, 0.05, 0.06 s | FAIL |
| T-LIFE-06 relaunch → live | p95 ≤ 2.5 s | 0.65 s after the first app frame | PASS (n=1) |
| T-LIFE-12 reconnect after hostd restart | link up ≤ 1.5 s | 25.1 s (WebRTC); 0.6 s after the Mac app relaunch | FAIL |
| T-LIFE-13 Mac quit | offline label ≤ 5 s; reattach ≤ 3 s | never offline in 20 min; reattach 2.3 s | FAIL |
| T-TABS-06 new terminal | prompt ≤ 1.5 s | 5.59 s from + | FAIL |
| T-TABS-08 close | Mac list ≤ 2 s | ask 2.1-2.4 s; idle card gone 4.4 s | not scored (Codex part blocked) |
| T-AGENT-10/11 (substitute load) | ≤ 30 MB growth, ≤ 2 MB/10 min; idle CPU ≤ 3 %, streaming ≤ 35 % | 1 MB, 0.27 MB/10 min; 2.5 %, 12.3 % | BLOCKED (no real agent) |

## Evidence

- Committed: `cnx-ios/verify/fullverify-terminal-20261019/`:
  - analyser json (`*.motion.json`, `*.rows.json`, `*.pin.json`);
  - scenario logs (`s23b-log.json`, `tabs-ab.json`, `life-c.json`, `life-de.json`, `keys.json`, `joystick-hold.json`, `tui-top.json`, `selection10.json`, `agent-session.jsonl`);
  - memory and CPU series (`mem.jsonl`, `mem60.jsonl`, `mem60-summary.json`);
  - the touch log (`touch.jsonl`) and recording start times (`recs.jsonl`);
  - frame strips (`shots/`), the Mac crash report and the rig scripts (`scripts/`).
- Raw videos stay on the laptop in `~/cnx-ios-e2e/fvterm-raw/` (about 2 GB), too large to commit:
  - `s1-follow-kbdown.mp4` (s2-follow-kbup.mp4 and s3-read-stream.mp4 were recorded while the Mac app was dead, so they are not used for verdicts);
  - `s2b-follow-kbup.mp4`, `s3b-read-stream.mp4`;
  - `tabs-a-grid.mp4`, `life-c-newtab.mp4`, `life-d-relaunch.mp4`, `life-e-hostd-kill.mp4`;
  - `tui-top.mp4`, `tui-quit.mp4`, `restart-shell.mp4`, `life13-mac-relaunch.mp4`;
  - `agent-follow-*.mp4`, `agent-read-*.mp4`.

## All 162 criteria

| ID | Verdict | Numbers and evidence |
| --- | --- | --- |
| T-REND-01 | BLOCKED | blocked (needs tool): G-09 phone text export and G-13 render-suite do not exist |
| T-REND-02 | BLOCKED | blocked (needs tool): G-13 render-suite |
| T-REND-03 | BLOCKED | blocked (needs tool): G-13 render-suite |
| T-REND-04 | BLOCKED | blocked (needs tool): G-13 render-suite |
| T-REND-05 | BLOCKED | cursor-vs-Mac pixel check not built; not measured |
| T-REND-06 | BLOCKED | `top` exit restored the shell screen and seq 1-300 scrollback (shots/tui-quit.jpg); entry was not recorded and no M-ROWS id count |
| T-REND-07 | BLOCKED | per-TUI cell diff not built; Codex and Claude produced no output (see T-AGENT) |
| T-REND-08 | BLOCKED | `top`: 0 black frames over 4 keyboard shows and 4 hides (tui-top.motion.json, 30-67 s); the Codex half is blocked. A separate black run over `top` came from a reattach (T-LIFE-17) |
| T-REND-09 | PASS | new and short sessions show the prompt on row 0 under the status bar, with no blank rows above (shots/newtab.jpg, fv-open) |
| T-REND-10 | FAIL | keyboard down: last row 0.67 pt above the composer in 2449/2449 frames (s1-follow-kbdown.pin.json). Keyboard up: the row is pinned at 0.67 pt (328/328), but an iOS **AutoFill** pill sits over the left part of the last two terminal rows in 67/67 sampled seconds (D3) |
| T-REND-11 | BLOCKED | light mode and AX5 not run |
| T-FOLLOW-01 | FAIL | the cursor row is pinned to the composer: gap 0.67 pt in every frame, keyboard down (2449 frames) and up (328 frames). Keyboard up, the AutoFill pill covers the newest rows' left 20-140 pt in every sampled frame (D3) |
| T-FOLLOW-02 | FAIL | keyboard down, stream20 4 min: 0 down moves, 0 reversals (s1). Keyboard up, stream20 66 s: 297 spontaneous reversals, from 1-row one-frame jumps (s2b-follow-kbup.motion.json; D1) |
| T-FOLLOW-03 | FAIL | 46 one-frame 1-row (16 pt) jumps in 66 s keyboard up (s2b), 11 in 15 s keyboard down after Jump to bottom (s3b-jump.motion.json). In each, the new row is drawn without the 2-line live area; the next frame restores it (shots/kbup-follow-tornframe-2.34s.png; D1) |
| T-FOLLOW-04 | FAIL | 0 black frames (s1, s2b, s3b), 0 M-ROWS foreign frames; the 46 + 11 torn-frame flashes above fail the M-MOTION flash part. Real Codex not run |
| T-FOLLOW-05 | PASS | while reading: button visible in 22/22 AX polls over 60 s; following: not visible (kb-up and after-jump polls). Poll period 2 s, so the 300 ms fade window is not resolved |
| T-FOLLOW-06 | BLOCKED | stream20 keyboard up: lag p50 -0.05 s, p95 -0.00 s, so about +0.01 to +0.06 s after the +0.064 s mini clock offset (s2b-follow-kbup.rows.json). stream1m not run |
| T-SCROLL-01 | BLOCKED | stream20: 0 px read-row drift for 63 s after deceleration ended (full-res motion 5.4-69 s: 0 moves; rows.py 0 drift after 5.3 s; s3b-hold.*). stream1m and real Codex not run |
| T-SCROLL-02 | BLOCKED | s3b reading hold: 0 foreign, 0 black; under the 5 min per path minimum |
| T-SCROLL-03 | FAIL | a page at rest never moved while reading (0 moves in 63 s), but following produces spontaneous reversals with no finger (297 in s2b, 252 in s3b-jump; D1) |
| T-SCROLL-04 | PASS | reading stayed reading for 63 s while stream20 appended: 0 page moves, Jump button 22/22 polls (s3b-hold). AX + motion, not M-FRAMELOG |
| T-SCROLL-05 | BLOCKED | blocked (needs tool): S-FLING finger tracking |
| T-SCROLL-06 | BLOCKED | blocked (needs tool): M-FRAMELOG (G-04) |
| T-SCROLL-07 | BLOCKED | blocked (needs tool): S-FLING |
| T-SCROLL-08 | BLOCKED | flings toward a streaming bottom not run |
| T-SCROLL-09 | PASS | Jump to bottom tapped while deceleration was still running (3-4 pt/frame at 94.98 s): page at the live bottom 17-33 ms after the tap, in one step, then following (s3b-jump.motion.json, 93.2-97 s). The first jump (87.43 s) did the same. 0 foreign frames |
| T-SCROLL-10 | BLOCKED | hist10k top reach not run |
| T-SCROLL-11 | BLOCKED | blocked (needs tool): S-SWEEP |
| T-SCROLL-12 | BLOCKED | `top`: 0 px page scroll over 10 vertical drags (tui-top.motion.json). vim, less, htop, Codex, Claude and mouse reporting not run |
| T-SCROLL-13 | BLOCKED | after `top` quit, the prompt is on the composer with history above (shots/tui-quit.jpg). The 300 ms timing was not measured |
| T-SCROLL-14 | BLOCKED | M-SIZELOG not collected |
| T-SCROLL-15 | BLOCKED | not run |
| T-SCROLL-16 | BLOCKED | not run |
| T-SCROLL-17 | BLOCKED | not run |
| T-SCROLL-18 | BLOCKED | not run |
| T-INPUT-01 | BLOCKED | blocked (needs tool): real-link echo probe G-08 |
| T-INPUT-02 | BLOCKED | blocked (needs tool): real-link echo probe G-08 |
| T-INPUT-03 | BLOCKED | blocked (needs tool): real-link echo probe G-08 |
| T-INPUT-04 | BLOCKED | blocked (needs tool): S-TYPE-INTEG |
| T-INPUT-05 | BLOCKED | ^C from the key bar stopped a stream20 flood (keys.json); timings not measured |
| T-INPUT-06 | BLOCKED | single-line composer pastes + Send arrived (10+ commands); 50-line and 10 KB pastes not run |
| T-INPUT-07 | BLOCKED | the rig's term_keys step failed on its own locator (an off-screen grid Done matched); the 60-key table was not run |
| T-INPUT-08 | BLOCKED | not run |
| T-INPUT-09 | BLOCKED | flick = exactly 1 arrow in 5/5 (20 required); a 1.2 s hold repeats (8 columns); 0 repeats after release in 3/3 (keys.json, joystick-hold.json). Rate and first-repeat delay not timed |
| T-INPUT-10 | BLOCKED | ^C visible at rest; key gaps 6.0 pt at rest (esc/ctrl/^C/tab/⇧tab/↑ AX frames). Gaps after 10 swipes and the 30-tap hit test not run |
| T-INPUT-11 | BLOCKED | blocked (needs tool): G-18 HID |
| T-INPUT-12 | BLOCKED | IME not run |
| T-INPUT-13 | FAIL | the shell composer offers AutoFill: the system AutoFill pill shows over the terminal whenever the composer has focus (67/67 sampled seconds; D3). Autocorrect and capitalisation were not separately measured |
| T-INPUT-14 | BLOCKED | attachments not run |
| T-INPUT-15 | BLOCKED | not measured |
| T-INPUT-16 | BLOCKED | not run |
| T-INPUT-17 | FAIL | with the Mac app dead (crash at 19:15:42), a command composed and sent at 19:19:46 showed no pending or refused state (the composer cleared as if sent). It **ran on the Mac at 19:35:09, 15.4 min later**, after the Mac app relaunch; 4 later probe echoes cannot be traced (probe-send.json, life13-mac-relaunch.json; D5) |
| T-SEL-01 | BLOCKED | long-press + Copy put the exact word on the pasteboard in 10/10 single-row selections (selection10.json); handles across rows and into scrollback not exercised |
| T-SEL-02 | BLOCKED | not run |
| T-SEL-03 | BLOCKED | not run |
| T-SEL-04 | BLOCKED | not run |
| T-SEL-05 | BLOCKED | not run |
| T-SEL-06 | BLOCKED | not run |
| T-SIZE-01 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-02 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-03 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-04 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-05 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-06 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected; 0 black frames over 4 keyboard shows and 4 hides over `top` |
| T-SIZE-07 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-08 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-SIZE-09 | BLOCKED | M-SIZELOG (terminal-sizing log) not collected |
| T-LIFE-01 | BLOCKED | cold open of an existing never-opened tab not timed |
| T-LIFE-02 | BLOCKED | not measured |
| T-LIFE-03 | FAIL | grid → card, first frame of the full terminal after the tap returned: 0.76, 0.06, 0.07, 0.06, 0.05, 0.06 s (n=6; tabs-a-grid.motion.json). p95 = 0.76 s > 150 ms. Tap-return timing undercounts |
| T-LIFE-04 | BLOCKED | not run |
| T-LIFE-05 | BLOCKED | not run |
| T-LIFE-06 | PASS | terminate + launch mid-stream: the app's first frame is the dimmed saved frame with 'Connecting to cmux11's Mac mini…'; live 0.65 s later; no blank frame (life-d-relaunch.motion.json, shots/relaunch-7.5s.jpg). Note: the saved frame was from an earlier state, not the pre-kill frame. Simulator launch overhead 3.9 s is excluded |
| T-LIFE-07 | BLOCKED | blocked (needs tool): G-15 |
| T-LIFE-08 | PASS | kill -9 cnx-hostd mid-stream: 0 black frames over 27 s, no error text, held frame kept (life-e-hostd-kill.motion.json; n=1) |
| T-LIFE-09 | BLOCKED | the reconnect took longer than the recording (T-LIFE-12) |
| T-LIFE-10 | BLOCKED | blocked (needs tool): M-INTEG |
| T-LIFE-11 | BLOCKED | no working agent |
| T-LIFE-12 | FAIL | hostd killed 03:29:01.0, restarted 03:29:02.0, signaling up 03:29:02.66; the phone's first offer timed out ('answer failed … timeout') and the link came up at 03:29:27.76, **25.1 s after hostd was listening**. The tab read 'Reattaching…' throughout (life-de.json; D2) |
| T-LIFE-13 | FAIL | the Mac app died (DEBUG watchdog assert, mac-crash-191542.ips); the phone showed 'Reattaching…' for 20 min, never offline (shots/mac-crashed-phone.jpg). After the relaunch the tab was live 2.3 s after the app was up (pass part). D4 |
| T-LIFE-14 | BLOCKED | not run |
| T-LIFE-15 | BLOCKED | relay paths not run |
| T-LIFE-16 | BLOCKED | not run |
| T-LIFE-17 | FAIL | two Worker socket resets (02:11:09, 03:36:54.8): each time the phone built a **second link** while the first was still up (old link died later by 'keepalive timed out') and the terminal reattached. Over `top` this blanked the terminal (cursor only) for 11 frames at 60 fps, then painted a partial screen (tui-top 13.40-13.57 s, shots/tui-reattach-blank-13.25s.jpg; D2) |
| T-TABS-01 | FAIL | while the grid is open the card never updates: card last row 78 while the Mac went 143→201 over 2.4 s; 331 while the Mac went 405→476 (tabs-ab.json). The card is a snapshot, more than 2 s old and frozen |
| T-TABS-02 | BLOCKED | not measured |
| T-TABS-03 | BLOCKED | 6 shrink/expand cycles while streaming: 0 black frames (tabs-a-grid.motion.json); reflow and position error not measured |
| T-TABS-04 | BLOCKED | label OCR band not run |
| T-TABS-05 | FAIL | inherits T-LIFE-03 (p95 0.76 s) |
| T-TABS-06 | FAIL | New Terminal from +: prompt visible 5.59 s after the + tap, about 4.5 s after the 'New Terminal' pick (life-c.json); threshold p95 ≤ 1.5 s. The + button also lost its accessibility label between grid opens (None vs 'New Tab') |
| T-TABS-07 | BLOCKED | refused create not reproduced |
| T-TABS-08 | BLOCKED | a running program (python3 stream20): confirmation 3/3 ('Close “e2e-t1”?' / 'Still running: python3.14.'), Cancel kept the tab 3/3; the ask appears 2.1-2.4 s after the tap. An idle shell closed with no ask (1/1); its card was gone 4.4 s after the tap. Codex part blocked |
| T-TABS-09 | BLOCKED | not run |
| T-TABS-10 | BLOCKED | not run |
| T-TABS-11 | BLOCKED | not run |
| T-TABS-12 | BLOCKED | Feed needs a working agent |
| T-TABS-13 | BLOCKED | not run |
| T-TABS-14 | FAIL | on the zoomed terminal page the AX tree exposes 'Close e2e-t1' (372,0), the grid's 'Done' and 'New' (y 2536, off screen) and 'More' (y 1814), all hidden controls (D7) |
| T-AGENT-01 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-02 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-03 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-04 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-05 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-06 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-07 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-08 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-09 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-AGENT-10 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl); substitute 60-min stream20 load: footprint 116→140 MB peak, growth after 10 min 1 MB, slope 0.27 MB/10 min (mem60-summary.json) |
| T-AGENT-11 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl); substitute: 12.3 % avg while streaming (slope -0.04 %/10 min), 2.5 % idle following (mem60-summary.json) |
| T-AGENT-12 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl); substitute: cnx-hostd RSS 28→37 MB, daemon 88→208 MB over 68 min; 2 'keepalive timed out' link downs from the duplicate-link reattaches (D2) |
| T-AGENT-13 | BLOCKED | no working real agent: Codex has no login on mini-cmux11s; Claude Code 2.1.301 started from the phone via the team subrouter answered 4/4 prompts with '502 upstream … attempt 10/10' (agent-session.jsonl) |
| T-LOAD-01 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-02 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-03 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-04 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-05 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-06 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-07 | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-CAP-a | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-CAP-b | BLOCKED | load matrix not run (only stream20) |
| T-LOAD-NET | BLOCKED | blocked (needs tool): netsim G-11 |
| T-LOAD-MEM | BLOCKED | blocked (needs tool): G-16 |
| T-LOAD-THERM | BLOCKED | device only |
| T-DEV-01 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-02 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-03 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-04 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-05 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-06 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-07 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-08 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-09 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-10 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-DEV-11 | BLOCKED | needs device (no real-phone verification was asked for) |
| T-REG-1259-a | BLOCKED | red-on-old-SHA runs not done (G-17) |
| T-REG-1259-b | FAIL | the mechanism reproduces on the new SHA with a substitute load: keyboard up, following stream20 (a Codex-like live area), the live area shifts by a row for one frame, 46 times in 66 s (D1). Green on the new SHA not met |
| T-REG-1259-c | BLOCKED | red-on-old-SHA runs not done (G-17) |
| T-REG-1259-d | BLOCKED | red-on-old-SHA runs not done (G-17) |
| T-REG-1259-e | BLOCKED | red-on-old-SHA runs not done (G-17) |
| T-REG-1259-f | BLOCKED | red-on-old-SHA runs not done (G-17) |
| T-REG-1337-a | FAIL | its criterion (T-SCROLL-03/T-FOLLOW-02, 0 reversals without a finger) fails on the new SHA: 297 spontaneous 1-row reversals in 66 s |
| T-REG-1337-b | BLOCKED | red runs not done (G-17) |
| T-REG-1337-c | BLOCKED | red runs not done (G-17) |
| T-REG-1337-d | BLOCKED | red runs not done (G-17) |
| T-REG-1337-e | BLOCKED | red runs not done (G-17) |
| T-REG-1350-a | FAIL | its criterion T-TABS-01 fails on the new SHA: the grid card is stale and frozen while the grid is open |
| T-REG-1350-b | BLOCKED | red runs not done (G-17) |
| T-REG-1350-c | BLOCKED | red runs not done (G-17) |
| T-REG-D1 | BLOCKED | red runs not done (G-17) |
| T-REG-D2 | BLOCKED | red runs not done (G-17) |
| T-REG-D3 | BLOCKED | red runs not done (G-17); new SHA: hostd kill showed 0 blank frames and no error text (1/1) |
| T-REG-D4 | BLOCKED | red runs not done (G-17) |
| T-REG-D5 | BLOCKED | red runs not done (G-17) |
| T-REG-R32 | BLOCKED | red runs not done (G-17); new SHA: 0 black frames over 4+4 keyboard changes over `top` |
| T-REG-R34 | BLOCKED | red runs not done (G-17) |
| T-REG-R35 | BLOCKED | red runs not done (G-17) |
| T-REG-R41 | BLOCKED | red runs not done (G-17) |
| T-REG-R42 | BLOCKED | red runs not done (G-17) |
| T-REG-B1 | BLOCKED | red runs not done (G-17) |
| T-REG-OPEN | BLOCKED | 20 of 20 consecutive scroll_while_streaming runs not done |
| T-ADV-01 | BLOCKED | S-AGENT-CODEX unavailable; about 3 h of mixed real-link use on stream20 instead, findings D1-D7 |
| T-ADV-02 | BLOCKED | stream1m gesture spam not run |

Counts: PASS 6, FAIL 19, BLOCKED 137, total 162.
