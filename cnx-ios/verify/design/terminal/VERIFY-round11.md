# Terminal verify round 11 (fresh adversarial verifier, 2026-10-15 06:42-09:25 PT)

**Verdict: REJECT.**

The round-11 claims mostly hold. Reading position after a drop held in 9 of 9 runs. Jumps were 0 black in 250. Inactive cards were fresh 5 of 5. D6 advanced on the first tap 10 of 10. The glyph under the cursor is kept.

These items fail:

- **W-D drop:** a drop whose reattach crosses a history prune shows a **250 ms full-black terminal**, 2 of 2.
- **Tab close (T-TABS-08):** closing a tab kills a running foreground program **without a confirmation**: `sleep`, `yes`, and 1 of 5 Codex tabs.
- **Last-row pin:** a full-width last row with the cursor in the wrap column is **hidden under the composer**, 2 of 2. Round 8 passed the same command.
- **Jump pill:** the Jump pill is still drawn on the first moved frame in 4 of 250 jumps.
- **Saved relaunch frame:** it still draws a grey cursor block. For about 80 ms that block sits half a cell left of the cursor.

## Sources and evidence

- **Criteria:** `ACCEPTANCE.md` on `origin/feat-cnx-ios-termqa` 319b2c60, verbatim.
- **Claims:** `qa-round-11.md` was read as claims only.
- **Evidence:** everything is in `verify11/`.
- **Events:** `verify11/events.jsonl` holds every capture, with the laptop load at its start and end. A `load_window` line gives the 1-minute load min and max, sampled every 2 s during each tool run.
- **Raw videos:** they stay on the laptop in `~/cnx-ios-e2e/termqa-raw/tv11/`. `verify11/raw-videos.txt` gives each one's sha256 prefix and duration.
- **Tools written this round:** all are in `verify/termqa/`.
  - `v11.py`: the `q11.py` wrapper, writing to `verify11/`, plus the load sampler.
  - `v11_jump.py` and `v11_jumpland.py`: OCR of the source frames around each pill-off frame.
  - `v11_close.py`, `v11_card.py`, `v11_hitch.py`, `v11_sel.py`, `v11_grid.py`.
  - `v11_rigsetup.py`: `rigsetup.py` with the normal-mode D6 probe waiting for the page.
  - `v6pin.py`: restored from termverify8.

## Build, rig, load

- **Phone build:** `origin/feat-cnx-ios-termqa` 319b2c603c35, built by this verifier.
  - Command: `cnx-ios/scripts/demo-build.sh --ref 319b2c603c35 --tag tq10 --skip-device --skip-mac`.
  - Settings: Demo, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, bundle `dev.cmux.cnx.tq10`.
  - CnxFFI had no cache hit (key 3459f1856b078e80), so the script built it on the laptop.
  - Zip sha256: `e76df0da5ecb99ce31814b9610e91bc263e5b90f03e3c59afaa760c5a025af4e`.
  - `CnxApp` sha256: `24f924aa8982c15de9106356d2cbf4f49228905f0d8cde05830690effcfe1375`.
  - The installed copy on `cnx-termqa-1` (C906E217-…) has the same hash. I checked it after the install and again after the erase and setup.
  - It is launched with `-CnxFrameLog YES`.
- **Mac:** `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2. The Mac side was used only for:
  - oracle reads: `terminal list`, `screen read`, `pgrep` of the test processes, and the hostd log;
  - hostd kills.
- **Stimulus:** every command, Codex prompt, `htop`/`vim` and selection was entered on the phone, through composer paste + Send, axe taps, swipes and long presses, or soft-keyboard typing.
- **Paths:**
  - `W-D`: hostd `kind=WebRtc path=Direct`.
  - `W-T`: `kind=WebRtc path=Turn`, Relay only on.
  - `G-D`: the phone reports "WireGuard direct · 1 ms". The rig's older hostd logs `kind=WireGuard path=Relay` for the same link, which is the label bug qa-round-11 7b describes. With Relay only on, the phone said "WireGuard TURN · 14 ms".
  - The rig's transport helper could not turn Relay only off, because its tap on the switch was ignored. An axe tap by the switch's accessibility id worked.
- **Load:** the laptop 1-minute load was 7.5-76 over the round, and is given per capture below. A timing row counts only where the sampled maximum was ≤ 12.
- **Simulator wedge:** at 08:58 the simulator stopped taking taps and `simctl` screenshots. At boot it then hung on "Waiting on System App". I killed its own `launchd_sim` and app, erased it, booted it headless, and set it up again through `rigsetup.py` (that is D6 sample 10). The new seed workspace is `ws_bcc39a1f…` (e2e-t1/e2e-t2).
- **Rig left as:** paired, G-D, the app running on e2e-t2 with the frame log, one booted simulator of mine. No load processes are left.

## Part A: code review (diff b64ef74d..319b2c60, terminal and adjacent paths)

Severity uses ACCEPTANCE §15. The line numbers are at 319b2c60. Findings 1 and 2 were confirmed live or in code by me; the rest come from a reading review.

| # | Finding | Where | Severity | Evidence |
| --- | --- | --- | --- | --- |
| A1 | The close confirmation is decided from the tab **title** only: an agent status, or the title's first word against a fixed list. Since 1c1692c8 the phone also sends `close-terminal` right after `close-surface`, so a missed confirmation now **kills the program at once**. A Codex tab whose title is its thread name ("Reply V11MARK-6607 \| cmux") was not recognised. Nor were `sleep`, `yes`, `git rebase`, `swift build`, `pytest`, `rsync`, or zsh with no title hook. | `CnxWorkspaces/TabCloseGuard.swift:19-25`, `CnxLive/LiveWorkspaceCreation.swift:352-363` | **disruptive** (an agent or user job stopped by the phone with no question) | live: B4 |
| A2 | Close Tab Group never asks: one destructive button sends `close-tab-group` for a group holding Codex/Claude tabs. `editGroup(.close)` clears only `surfaces[member.id]`. It leaves `browsers[...]` and `streamed.drop(tab:)` alone, which `close()` does clean. | `CnxWorkspaces/TabMoveAndGroupSheets.swift:41`, `WorkspaceTabsSource.swift:676-695` | **disruptive** | code |
| A3 | The scroll-gate `followFallback` CADisplayLink now returns early on every tick while the target is uncovered ("never, however long"). `deinit` invalidates only `outputLink`; `viewWillDisappear` and the weak-self closure do not stop it. A controller freed mid-wait leaves a display link firing forever. An offscreen page keeps calling `updateViewport(force:)` and `setNeedsTerminalDraw()` every 6 ticks. | `CnxTerminal/Screen/TerminalViewController.swift:1559-1628`, `:236-239` | noticeable (leak, CPU) | code |
| A4 | Each reading-mark restore reads the whole scrollback twice on the main thread (`screenRows()` → `ghostty_surface_read_text` under the surface lock), then runs an O(n) alignment. It happens at every reconnect with a reader, at about 17k rows here. | `TerminalViewController.swift:1020` | noticeable (main-thread stall at reattach) | code; not timed (load) |
| A5 | A late saved frame can overwrite a newer one, or bring back a closed tab's file: a detached render, then a second detached write, with no generation check against `cool()` or `frameStore.remove`. | `CnxTerminal/Screen/TerminalModel.swift:146-151`, `CnxShell/GhosttyTerminalTabContent.swift:165-170` | noticeable | code |
| A6 | The card `read-screen` refresh has no in-flight dedupe and no reply ordering: a slower old reply can overwrite a newer card text. `failed(id)` clears a newer request's timestamp. | `GhosttyTerminalTabContent.swift:284-296` | polish | code |
| A7 | Every `tree-changed` marks the arrangement stale. `list-workspaces`, including the one after a tab close, then waits for `list-personal` and `sidebar_layout.get`, which has a 10 s deadline. After a transient failure the arrangement is stored as empty. | `CnxLive/WorkspaceSync.swift:232-245` | noticeable | code |
| A8 | The post-prune restore path places the frame in a stale numbering. The blank watchdog repairs it only after its deadline: "blank page: rows 14805..<14860 not in the frame at 17033 … for 267 ms: placed by the report". | `TerminalViewController.swift:1005-1027` (restore) and `:1695-1718` (recovery) | **disruptive** | live: B1, B2 |
| A9 | Polish: `TerminalCursorErase` on a coloured cell (low confidence). Frames saved by older builds lose rows to the new `bottomTrim`. `TerminalScreenRows.text(from:to:)` indexes characters, not cells, so CJK and emoji columns copy wrong. The prune heuristic can fire on a reflow. A doc comment is misplaced (`TerminalViewController.swift:2150-2157`). | as named | polish | code |

These were checked and are not bugs:

- Wrong-tab close: the terminal is keyed by the closed tab's own surface. A refused `close-surface` throws before `close-terminal` is sent. Cancel returns before any backend call. Live, the seed terminals were kept in 10 of 10 closes.
- The selection-autoscroll link stops on end, cancel, clear and a TUI switch.
- The off-main still render touches no UIKit view.
- D6: one Button with the stable id `setup.pair-mac.cta`, its label accessible, both states advance.
- The reading mark normalises trailing blanks.

## Part B: live verification

### B1. T-LIFE-09 / T-LIFE-15: reading position after drops while GEN streams (~100 rows/s)

A GEN loop was typed on the phone. The page was flung into the history, then hostd was killed once (read1) or twice 3.4 s apart (read2). The top row ids were read by OCR before, at +12 s and at +15 s. The app log gives the mark.

| Run | Path | Kills | Prune crossed the drop | Top ids before → after | Mark log | Video black | Load (start/end) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| wt-read1-a | W-T | 1 | no (prunes before and after) | GEN-1781 → same | 15015 → 15015 | 0 | 12.0 / 12.2 |
| wt-read2-a | W-T | 2 | no | GEN-1670 → same | 14955 → 14955 ×2 | 0 | 12.7 / 12.0 |
| gd-read1-a | G-D | 1 | no | GEN-1873 → same | 15195 → 15195 | 0 | 10.9 / 11.2 |
| gd-read2-a | G-D | 2 | no | GEN-1691 → same | 15136 → 15136 ×2 | 0 | 11.5 / 13.2 |
| **wd-read1-a** | W-D | 1 | **yes** (887 rows) | GEN-1294 → GEN-1294/5 | 15692 → **14805** (prune-adjusted) | **1 run, 250 ms (3 source frames)** | 13.5 / 13.6 |
| **wd-read2-a** | W-D | 2 | **yes** | GEN-1527 → same | 15683 → **14796** | **1 run, 255 ms** | 14.3 / 14.7 |
| wd-noprune-read1 | W-D | 1 | no prune in the run | GEN-1 → same | 109 → 109 | 0 | max 23.2 |
| wd-noprune-read2 | W-D | 2 (one reattach logged) | none | GEN-1805 → same | 1910 → 1910 | 0 | max 14.0 |
| gd-noprune-read2 | G-D | 2 (one reattach logged) | none | GEN-1829 → same | 4622 → 4622 | 0 | max 21.3 |
| gd-fling2-a (V3-3) | G-D | 2, then a fling | no | #101-120 constant (rows.py, 10 fps, 18 s) | 421 → 421, 305 → 305 | 0 | max 16.2 |
| gd-follow2-a | G-D | 2, following | n/a | ids advance (GEN-1291 → 1460), no Jump button | n/a | 0 | 12.3 / 12.5 |

- **The position is kept** in 9 of 9 reading runs on W-T, G-D and W-D, single and double drops, with and without a prune, mid-fling included. The T-LIFE-09 position part: **PASS**.
- **New defect N1 (disruptive, T-LIFE-08 / T-FOLLOW-04):** when a prune lands between the drop and the restore (the mark moves by exactly the prune, 887 rows), the page is **fully black for 250 ms** about 1.8 s after the restore. It happened in 2 of 2 such runs.
  - Frame sheets: `verify11/wd-read1-a-14.35s-black-sheet.jpg` and `wd-read2-a-9.35s-black-sheet.jpg`. The second shows "Reattaching…".
  - The app's own log says "blank page … not in the frame at 17033 … for 267 ms: placed by the report".
  - The frame log flagged 16 blank frames in each run. The video and the flag agree.
  - It happened on W-D only because only those runs had a prune in the reconnect window. Nothing in it is transport specific (A8).
  - **T-LIFE-08 / T-LIFE-09 "with prunes": FAIL.**

### B2. Black frames: Jump to bottom, prunes while following, reattach

| Run | Path | Jumps | Prunes (while reading) | Video black (every source frame) | Snaps (`fling reached the bottom`, no Jump) | Load min/max |
| --- | --- | --- | --- | --- | --- | --- |
| wd-fling-a | W-D | 55 | 41 (18) | 0 | 0, 0 | 15.8 / 15.3 (ends) |
| wd-fling-b | W-D | 50 | 50 (23) | 0 | 0, 0 | 16.9 / 15.4 (ends) |
| gd-fling-a | G-D | 55 | 50 (23) | 0 | 0, 0 | 11.9 / 10.0 (ends) |
| gd-fling-b | G-D | 50 | 40 (18) | 0 | 0, 0 | 11.3 / 12.0 (ends) |
| gd-fling-c | G-D | 40 | 36 (16) | 0 | 0, 0 | **7.6-8.8 sampled** |

- **Jump to bottom: 250 jumps at the cap, 105 on W-D and 145 on G-D, with 0 black source frames.** The earlier W-T runs claimed 0 in 120; W-T was not rerun. **PASS.**
- **Prunes while following:** `gd-hold-a` (G-D, 150 s at the cap, hands off): 10 prunes, 0 black source frames, 0 flashes. **PASS.**
- **At reattach: FAIL.** See B1 N1: 2 of 13 drop runs showed a 250 ms black.
- **Fling snaps (V5-2):** 250 flings toward history at the cap, 0 snaps. **PASS.**

### B3. Jump to bottom: landing time and the pill

Method: source frames (passthrough, no resampling). The pill is lit-pixel tested in its label box. For each pill-off frame, OCR reads the GEN ids of the 4 frames before and the 4 after (`*-jumpocr.json`, `*-jumpland.json`).

- **Landing:** the first frame at the live bottom is 0-20 ms after the pill-off frame in 250 of 250 jumps. The app log's tap → frame-log `following` is 8-10 ms.
  - Only `gd-fling-c` had a load window ≤ 12 (sampled 7.6-8.8). There, the landing was ≤ 18 ms after pill-off in 40 of 40.
  - **T-SCROLL-09 ≤ 400 ms: PASS (valid window, G-D, n = 40).** The W-D timing is INVALID (load 15-17).
- **The first frame after the tap:** the jump goes reading → intermediate rows → bottom, monotonic in 241 of 250. The intermediate is the start of one motion, 1-2 frames.
  - 9 sequences showed a one-row OCR step back during the intermediate frames. They are within the "≤ 1 row" allowance, and are possibly OCR noise.
  - 0 foreign frames.
- **The pill is gone in the first frame after the tap: FAIL, 4 of 250** (wd-fling-b 1, gd-fling-b 1, gd-fling-c 2). Each time, the first frame that already shows the moved rows still has the full "Jump to bottom" pill. It is gone one frame (3-10 ms) later. Sheet: `verify11/wd-fling-b-128.53s-pill-on-jumped-frame.jpg` (14523 → 14737 with the pill on). Noticeable.

### B4. V5-5 / T-TABS-08: closing a tab ends the Mac session (10 samples)

Each sample: + → New Terminal on the phone, an optional program started from the composer, then the card's × in the grid. If a confirmation appeared, its "Close Tab" was tapped. The Mac's `terminal list` was polled, along with `pgrep` of the program.

| Sample | Program on the phone | Confirmation | Mac terminal gone | Program after | Seed tabs kept |
| --- | --- | --- | --- | --- | --- |
| 1 | `sleep 6135` (title "sleep 6135") | **none** | ≤ 2.24 s | **killed** | yes |
| 2-5 | `codex "V11MARK-… reply with one word"` (running, title "⠹ Reply …" or "renaming… ⠼") | **yes**: "Codex is still running on cmux's Mac mini (2). Closing the tab stops it there." | 0.43-1.19 s after confirming | killed | yes |
| 6 | `codex "V11MARK-6607 …"`, idle after its answer, title "Reply V11MARK-6607 \| cmux" | **none** | ≤ 2.24 s | **Codex killed** | yes |
| 7-9 | idle shell | none (correct) | ≤ 2.2 s | n/a | yes |
| 10 | `yes V11YES6691 > /dev/null` | **none** | ≤ 2.19 s | **killed** | yes |

- **V5-5 (the Mac session ends): PASS, 10 of 10.** The terminal is gone, the program is gone, and no other tab closed.
  - The idle-close timing is an upper bound only: the first poll came 1.2 s after the tap.
- **T-TABS-08: FAIL.**
  - The confirmation appeared in 4 of 5 Codex closes, and the threshold is 10 of 10.
  - It did not appear for 2 of 2 foreground programs. The criterion asks for one when "a tab running an agent or a foreground process" closes.
  - In each miss the program was stopped with no question (A1). Disruptive.
- Load during the closes: 7.5-12.5. Events: `v11_close` lines in `events.jsonl`.

### B5. T-TABS-01: inactive cards on the first grid open after launch (5 samples)

`v11_card.py`:

1. In e2e-t1, type `clear; sleep 15; seq 1 60; echo CARD-AFTER-<n>`.
2. Switch to e2e-t2 and terminate the app.
3. Wait until the Mac shows the marker, then relaunch.
4. Open the grid first.

- **Freshness:** the e2e-t1 card showed rows 31-60, the marker and the prompt **in the first screenshot** in 5 of 5. **PASS.**
- **Composer:** no composer is drawn inside any card in 5 of 5. **PASS.**
- **Bottom rows:** in 4 of 5 no rows are cut off. In **card-c** (`verify11/card-c-grid-0.jpg`), the e2e-t2 card in the first shot was shifted down about 3.5 rows. It had a black band at the top and its last 8 rows and prompt were cut off. That run took no later shots, so it may be a transition. In card-d and card-e, shots at 1-3 s are correct. **Noticeable, 1 of 5, unconfirmed as a steady state.**
- Load 11.4-14.0: no timing is claimed.

### B6. Frame-save and the longest frames while following

`gd-hold-a` (G-D, 150 s, GEN at the cap, load 12.0-13.6 sampled, so the timing is INVALID):

- 9000 frames, all in phase `following`.
- `frame-save` ran every 15.00-15.05 s (9 intervals), at most **2.88 ms** on the main thread. The claim was 17-28 ms.
- The frame after each save: 16.67 ms.
- Frames over 33.4 ms: 0. Over 100 ms: 0. Longest: 16.67 ms. `verify11/gd-hold-a-hitch.json`.
- Caveat: every `dt_ms` in this window is exactly 16.67, so the simulator's display link may not show real lateness. It is informative only.

### B7. The saved relaunch frame keeps the glyph under the cursor

On the phone: `clear; printf 'XQZW-glyph\r'; read x`, 16 s for a save, then terminate and launch (`d11-relaunch.mp4`, `d11-relaunch-row-frames.jpg`, `d11-relaunch-phases.jpg`).

- **The X under the cursor is kept** in every frame of the dimmed saved frame ("Connecting to cmux's Mac mini (2)…"), about 0.5 s of it. **Claim PASS.**
- But the saved frame **still draws a cursor block**: a grey cell behind the X. T-LIFE-06 / R3-4 require "saved frame with no cursor block". **FAIL.**
- In frames 139-145 (about 80 ms) that grey block is **misplaced half a cell to the left**, partly in the margin. It is a stray block (T-REND-05). Noticeable.
- Before the saved frame, the relaunch shows the **white system launch screen for about 0.9 s** (frames 33-97). Round 8 saw the same cross-fade. Noticeable, carried over.
- The title pill is light grey over the dark page while it connects. T-TABS-09 (no light-pill frames) needs a check.

### B8. G-14 selection (T-SEL-01), all typed on the phone

| Sample | Case | Result |
| --- | --- | --- |
| 1 | `g14.py scroll`: long press near the bottom, start handle held at the top edge for 3 s, Copy | exact, `#0000574..#0000595`, autoscrolled **9 rows** above the first visible row (the tool's own > 20-row bar fails; ACCEPTANCE has no rate) |
| 2-5 | words (`v11_sel words`): mike, hotel, victor, charlie | exact 4 of 4 |
| (extra) | a long press on the space between two words (row 188) | empty selection, Copy still offered and copies "" (polish) |
| 6-7 | across rows: end handle dragged 3 rows | exact `#188..#191` and `#194..#197` |
| 8 | clear that keeps history (`printf '\e[H\e[2J'`), pull into the history, select 3 rows | exact `#217..#220` |
| 9 | vim (`g14.py tui`) | PASS, 5 rows exact |
| 10 | htop (`/opt/homebrew/bin/htop`) | long press selects a word ("S" of the S column), handles shown, copy matches the Mac's screen; `q` left htop |

- **10 of 10 exact.** The selection colour is visible: iOS blue highlight and handles, about 750 blue px around "india" in `verify11/g14-scroll-selected.jpg`. **PASS**, with these notes:
  - Autoscroll is slow (about 3 rows/s while held at the edge). That is polish.
  - On the rig's zsh, plain `clear` also clears the scrollback (E3). That is correct, and it is not the keep-history case.
  - I first saw an empty copy with the keyboard up. It was my harness's fault (the rows had moved under the keyboard), and it was retracted: with the keyboard up, 2 of 2 long presses selected exactly.

### B9. D6: the onboarding Continue advances on the first tap (10 samples, loaded)

10 fresh installs (uninstall + keychain reset) with sign-in and the team step, then the "Connect your Mac" button:

- 5 samples with `--immediate`: tap the moment the page is in the tree.
- 5 in normal mode: tap once the button is still.

The laptop 1-minute load at the samples was **70.7, 57.9, 50.3, 51.1, 44.7, 44.5, 38.9, 35.6, 31.6, 24.0 … 17.8**. Other work on the laptop caused it; I did not add synthetic load. My in-simulator CPU burners did not start.

- **10 of 10 advanced on the first tap**, 0.75-1.16 s after the tap. **PASS.**
- "Heavy output" does not apply here: no terminal exists before pairing, and Mac-side output is forbidden as a stimulus.
- Events: `d6` lines. Videos `d6-1..10.mp4` are in the raw folder.

### B10. Regression re-checks

| Item | Verdict | Evidence |
| --- | --- | --- |
| One replay per reattach (T-SIZE-02) | **PASS**: 1 `mirror reset cause=reattach` per surface per link-up | Both open tabs (surfaces 34/37, later 65/68) replay once each; every drop log; `transport-switch-gd.log` |
| Two quick drops (V6-4, T-LIFE-08) | **FAIL**: W-D `wd-read2-a` showed 255 ms black (N1); W-T, G-D (×2) and W-D no-prune had 0 black | B1 |
| Fling snaps (V5-2) | **PASS** | B2 |
| Pin after a draft shrink (V6-1, T-SIZE-07) | **FAIL (new defect N3)**: the command is round 8's `seq 1 300; printf '\e[7m%*s\e[0m' $COLUMNS ''; read x`. The full-width reverse bar (the last row, cursor in the wrap column) is **not visible**: row 300 sits on the composer and the bar is under it, at every draft size and with the keyboard up and down. The app logs `pin: … gap 0.0 pt`. Reproduced again with `REVERSE-BAR` (`pin-bar-check.jpg`). A full bar followed by a short bar is shown correctly (`pin-bar-variant.jpg`), and an empty `cat` cursor row is shown. Round 8 passed the identical command. | `verify11/gd-pin-*.jpg`, `pin-bar-*.jpg`, `gd-pin.log` |
| A new tab does not replay the open one (V5-4) | **PASS, 10 of 10**: only the new surface's `cause=attach` | `verify11/newtab-closes.log` |
| D5 (T-TABS-02) | **PASS**: content in every card after 5 relaunches | B5 shots |
| V3-2 (output keeps arriving after a drop) | **PASS** | `gd-follow2-a`: ids advance after the reattach |
| V3-3 (drop mid-fling keeps the place) | **PASS (n = 1)** | `gd-fling2-a`, rows.py: #101-120 for 18 s through both drops |
| V3-4 / T-TABS-14 | **cnx-owned PASS; row FAIL (kit, unchanged)** | Grid AX (`gd-grid-b-grid-ax.txt`): only the cards' own Close buttons, no Return, Scroll to bottom or composer. The zoomed page still exposes the kit's `Close e2e-t2` at (372, 0), plus the grid's offscreen `Done`/`New`/`More` at y 1814-2536. The rig's `back_to_list` tried to tap that off-screen `Done`. |
| V2-1 / T-TABS-03 grid trips while streaming | **PASS for black frames**: 10 trips, 0 black source frames, 1.99 % gaps over 34 ms | `gd-grid-b`; motion and reflow were not judged |
| Transport switch (T-LIFE-16) | **PASS (log)**: one reattach per surface, 0 `blank page` lines; the switch worked 4 times | `transport-switch-gd.log` |
| Reconnect (T-LIFE-12) | correctness **PASS** (every drop reattached); timing not measured | B1 |

## Verdicts per ACCEPTANCE ID touched this round

| ID | Path(s) | Verdict | Numbers |
| --- | --- | --- | --- |
| T-LIFE-08 | W-D, W-T, G-D | **fail** | 2 of 13 drop runs 250-255 ms black (both with a prune crossing the drop) |
| T-LIFE-09 | W-D, W-T, G-D | **pass** (position) | 9 of 9 same top id, 2 of them prune-adjusted |
| T-LIFE-15 | W-T | pass (position), T-LIFE-08 part not separately failing | 2 of 2 |
| T-LIFE-16 | G-D | pass (log) | 1 reattach per surface |
| T-LIFE-06 / T-REG-R34 | G-D | **fail** | cursor block in the saved frame; misplaced for about 80 ms; glyph kept |
| T-REND-05 | G-D | **fail** | a stray half-cell-offset block on relaunch |
| T-SCROLL-09 | W-D, G-D | **fail** (the first-frame part) / pass (≤ 400 ms) | pill on the first moved frame 4 of 250; landing ≤ 20 ms (valid window n = 40) |
| T-FOLLOW-04 (prunes) | G-D | pass | 10 prunes, 0 black in 150 s |
| T-FOLLOW-01 / T-SIZE-07 / T-REND-10 | G-D | **fail** | full-width last row with the cursor at the wrap hidden under the composer, 2 of 2 |
| T-SCROLL-04 / V5-2 | W-D, G-D | pass | 250 flings, 0 snaps |
| T-TABS-01 | G-D | pass (freshness) / noticeable (1 of 5 cut card) | 5 of 5 fresh |
| T-TABS-02 (D5) | G-D | pass | 5 relaunches |
| T-TABS-08 | W-D, G-D | **fail** | Codex confirmation 4 of 5; foreground programs 0 of 2; idle 3 of 3 correct |
| T-TABS-14 | G-D | fail (kit, unchanged) | `Close e2e-t2` exposed on the zoomed page |
| T-SEL-01 | G-D | pass | 10 of 10 exact |
| T-SEL-02 | — | not run | |
| T-SIZE-02 | all | pass | 1 replay per surface per link-up |
| D6 (qa-round-1) | W-D | pass | 10 of 10 first tap at load 18-71 |
| frame-save (qa11 item 5) | G-D | pass, INVALID timing | 2.88 ms max every 15 s, 0 frames over 33 ms |

Every other ACCEPTANCE row was not exercised this round and keeps its prior state. The terminal stays at most simulator-pending; the §12 device rows are blocked (needs device).

## New defects

- **N1 (disruptive):** a 250 ms full-black terminal after a reading-mark restore that crossed a history prune.
  - Seen in 2 of 2 such runs (W-D). Source: A8.
  - Repro: `v8v_drop read1|read2` at the cap, where a prune lands between the kill and the reattach.
- **N2 (disruptive):** a tab close kills a foreground program or an idle Codex with no confirmation (A1, B4).
- **N3 (disruptive):** a full-width last row with the cursor in the pending-wrap column is hidden under the composer, while the app logs gap 0. Round 8's pin command now fails.
- **N4 (noticeable):** the Jump pill is still drawn on the first moved frame, 4 of 250.
- **N5 (noticeable):** the saved relaunch frame keeps a grey cursor block, which is misplaced half a cell left for about 80 ms.
- **N6 (noticeable, unconfirmed):** the active tab's grid card was cut by about 8 rows in 1 of 5 first-open shots.
- **N7 (polish):** Copy is offered for an empty selection (a long press on a space). Selection autoscroll runs at about 3 rows/s at the edge.
- **Tooling:**
  - The rig's `transport` helper cannot turn Relay only off: its tap on the switch's right edge is ignored, while an axe tap by the switch's id works.
  - `back_to_list` picks the grid's off-screen `Done` while a page is zoomed.

## Not done

- 60-minute agent sessions, T-ADV free play, netsim and relay paths other than W-T.
- T-SEL-02.
- Timing rows under a valid load window, except the G-D jump landing.
- W-T jumps (the implementer's claim was not rerun).
- Codex-running cards for T-TABS-01. Codex ran fine on the mini this round, despite the brief's note about its login.
