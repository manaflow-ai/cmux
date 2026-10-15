# Terminal QA round 10 (termqa implementer, 2026-10-15 09:50 PT onward)

Input: qa-round-9.md (`91accfc8`). The shared rig (`cnx-e2e-604fc689` on mini-2, simulator `cnx-termqa-1`)
belongs to a fresh verifier: not touched. Laptop load 20-30 at the start: no timing claims.

## Status

| Item | Status | Evidence |
| --- | --- | --- |
| G-14 TUI selection (vim, htop): a long press always selects | **implemented**: test `29260240` (red: type missing), fix `fd2e3c3a` (green: 15 of 15 with the selection and autoscroll suites, mini-cmux11s); iOS build green (`1769b3bf`, tag tq10). **Not run on the simulator yet** | below |
| Hidden laptop rig (real Codex) | **up**: Mac app hidden (0 on-screen windows, the front app unchanged, no Keychain or other prompt), rig set up with real onboarding, link `Online · Connected · WebRTC direct`; real `codex --yolo` (v0.162.1, the laptop's login) starts from the phone | Rig |
| G-17 T-REG-1337 with real Codex | **not reproducible with real Codex** (one valid run each): 2e1369f0, 224d15e9 and new are all green, 0 spontaneous moves, 0 flashes, 0 black, 0 Jump-to-bottom toggles over ~12 s at the bottom and ~12 s near it, Codex idle ("Worked for 2m 22s" on screen) | G-17 |
| G-17 1259, 1350-b with real Codex | not run yet | |
| CmuxTabsKit re-sync (coordinator) | **done** `87175151`: byte-identical to `506c1239` (includes `b962c111`); `check-tabskit-sync.sh` ok; CmuxTabsKit `swift test` 53 of 53 on mini-cmux11s; feat-cnx-ios `aa685b82` merged (`76c8bace`). Grid card and zoom re-check: after the rebuild | |
| G-14 autoscroll / full-scrollback copy on the simulator | not run yet | |
| D6 onboarding Continue | **not reproduced**: 10 of 10 fresh installs advanced on the first tap made the moment Continue is in the tree (7 at the page's push, 3 at the rig Mac's launch); the Not now→Continue swap could not be produced (the shared dev account always has an online Mac) | D6 |
| V6-5, D10, V2-6, 60-min sessions, D7 | not run yet | |

## Rig (hidden laptop rig, tag tq10)

- Mac: a fleet build of `e1edf234` (the rig app's daemon) with its own tag `tq10-e1edf234`
  (bundle `com.cmuxterm.app.debug.tq10.e1edf234`, own dev-backend stack). Fleet job
  `4faa3b2ec5167d9b355aae07`, in `~/cnx-ios-builds/20261015-e1edf23408-tq10`. The app is used as built:
  its Info.plist is never edited and it is never re-signed. `TQ_HOST=local` (`tq.LocalMac`) launches it
  with `open -g -j -n --env ...` for every setting (shell integration, bundled CLI, daemon socket, config
  file, credential file, pairing seed). `open --env` overrides LSEnvironment (checked with a test bundle).
- Phone: simulator `cnx-tq10` (070F8E62…), headless (`simctl boot`; Simulator.app never opened). New build:
  Demo `1769b3bf`, tag tq10, bundle `dev.cmux.cnx.tq10`.
- Select: `TQ_HOST=local TQ_RBASE=~/cnx-ios-e2e/tq10 TQ_STATE=~/cnx-ios-e2e/tq10-state.json
  TQ_RAW=~/cnx-ios-e2e/termqa-raw/tq10 TQ_BUNDLE=dev.cmux.cnx.tq10`.
- Codex: the laptop's existing login, used as is.
- `cnx-ios/scripts/demo-build.sh`: the simulator build is now `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`.

## G-14: TUI selection

`TerminalSelectionController` now takes any host view (the scroll view or the TUI host); edge autoscroll
runs only in a scroll view. The view controller keeps a second controller, `tuiSelection`, in `tuiHost`:
`TerminalTUISelectionGeometry` maps a point to a viewport cell (row 0 = the top row, clamped to the grid)
and back; the text comes from `viewportText`; Select All is the whole screen. The shell's selection is
cleared when a TUI starts, the TUI's when it ends; a tap clears either. The phone never forwards touches
as mouse events, so a long press always selects, like Shift-drag on the Mac when the app captures the
mouse (htop, vim `mouse=a`).

## D6

`rigsetup.py --immediate [--d6-only]` taps Continue the moment it is in the AX tree (polled every 50 ms
plus the tree read), mid-push included. Fresh install each time (uninstall, keychain reset, install, dev
sign-in, Personal on the team step). Recordings `termqa-raw/tq10/d6-setup-1.mp4`, `d6-imm-1..6.mp4`.

| Probe | Runs | First tap advanced | Page left after |
| --- | --- | --- | --- |
| Tap at the page's push (Mac online) | 7 | 7 | 0.70-0.86 s (includes the tree poll) |
| Tap as the rig Mac launches (0.22-0.31 s after `open`) | 3 | 3 | 0.92-1.09 s |
| Watch 25 s on the page (2 runs) | | | `Continue` and "…is online" from 0.27-0.53 s, no flip |

Code reading: `PairMacStep` swaps two views (`PrimaryCapsule("Continue")` / `TextCTA("Not now")`) in a
`ZStack` with an opacity transition on `onlineMac != nil`. If the account's online-Mac state flips while
a finger is down, the pressed button is replaced and the tap is lost; the round-1 report (three taps
ignored, a fourth 20 s later works) fits a Mac that was coming online. The rig cannot produce the flip
(another Mac of the shared dev account is always online, so Continue shows before the rig Mac
launches). Not fixed: no reproduction; a candidate fix is one button with a stable identity whose
label and style change.

## G-17 with real Codex

`reg.py --agent codex` now: stops a Codex left in the tab (Control C twice from the key bar, the composer
focused first), types `mkdir -p ~/cnx-ios-e2e/tq10/proj && cd … && codex --yolo` and the prompt on the
phone, and reads the Mac's screen only for timing: "streaming" once eight answer rows are on screen while
Codex works, "idle" once it worked and then shows no working indicator on two reads in a row. Codex
v0.162.1, GPT-6-Astra max (the laptop's login and its default model).

- The first real-Codex 1337 run on the new build (`03:18`) is **invalid** and was discarded
  (`termqa-raw/tq10/INVALID-new-1015-031821.json`): the idle check matched the prompt's own "400" before
  Codex began, so the scenario ran while Codex streamed. Fixed in `2027a77a`.
- The next run (`03:26`, 2e1369f0) read **red** (1337-a 14 spontaneous reversals, 1337-c) and is
  **also invalid** (`INVALID-2e1369f0-1015-032610.json`): its contact sheet
  (`artifacts/sheets/reg-1337-2e1369f0-032406-01.jpg`, 11.9-12.8 s) shows Codex still streaming rows
  213-254. This Codex (v0.162.1) prints no "Working"/"esc to interrupt" on screen, so the working check
  never fired. `d3c24e21` reads the state from the answer: streaming = the screen changes with numbered
  rows on it; idle = "Worked for …" or row 400 present and the screen unchanged across two reads 3 s
  apart. Lesson for the verifier: a real-Codex T-REG verdict needs a frame check that Codex was idle.

| Run (real Codex, idle) | Build | Load | At bottom (frames / spont. moves / reversals / flashes / black) | Near bottom | Verdict |
| --- | --- | --- | --- | --- | --- |
| `reg/1337/2e1369f0-1015-034843.json` | 2e1369f0 | 52 | 754 / 0 / 0 / 0 / 0 | 701 / 0 / 0 / 0 / 0 | green |
| `reg/1337/new-1015-035349.json` | new (`d3c24e21`) | 25 | 704 / 0 / 0 / 0 / 0 | 744 / 0 / 0 / 0 / 0 | green |
| `reg/1337/224d15e9-1015-035855.json` | 224d15e9 | 27 | 715 / 0 / 0 / 0 / 0 | 742 / 0 / 0 / 0 / 0 | green |

`compare-2e1369f0-new-*.json`: every 1337 row "not reproduced (green on old)". The 1 fps sheet of the
2e1369f0 run (`artifacts/sheets/reg-1337-2e1369f0-034444-01.jpg`) shows Codex idle at rows 366-400 with
"Worked for 2m 22s", the page at the bottom, then 3 rows up after the drag, still. With codexlike (round
9) and with real Codex (here) the 13:37 oscillation does not reproduce on either old SHA on this rig
(WebRTC direct, simulator). What the video had that this does not: a long session (hundreds of diff
rows), keyboard history, the device. Recorded as not reproducible with real Codex; T-SCROLL-03 and
T-FOLLOW-05 keep covering the behaviour.

## Next

(updated as the round goes)
