# Terminal verify round 8 (fresh adversarial verifier, 2026-10-15 02:20 PT onward)

**Verdict: REJECT.** The multi-second black pages of round 6 are gone (0 black runs longer than one frame in 123 jumps, 18 prunes and 5 drop runs), V5-2, V6-1 and V5-4 hold, and the t1 divergence did not reproduce in 12 minutes of real Codex. But the reading position is still lost after a drop while output arrives (225-388 rows, 3 of 3, both transports), a one-frame black comes with about 40 % of jumps at the cap, closing a tab leaves its Mac session running, and every timing row is invalid (laptop load 8-95).

Criteria: `ACCEPTANCE.md` on `origin/feat-cnx-ios-termqa` (b64ef74d), verbatim. Claims from
`qa-round-8.md` were read as claims only. Evidence is in `verify8v/`. The raw videos stay on the
laptop in `~/cnx-ios-e2e/termqa-raw/tv8v/`; `verify8v/raw-videos.txt` lists each one's sha256
prefix and duration. Events, with the laptop load on every line, are in `verify8v/events.jsonl`.
The tools I wrote are `verify/termqa/v8v*.py` on this branch.

## Build, rig, load

- **Phone build:** `feat-cnx-ios-termqa` at `b64ef74d`, built by me in
  `worktrees/feat-cnx-ios-termverify8`. Demo config, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, CnxFFI
  from the demo-build cache key `5d1dacc3d0a79f7c` (the key `demo-build.sh` computes for this SHA;
  the generated `CnxFFI.swift` is byte-equal to the committed copy).
  - Installed on `cnx-termqa-1` (C906E217-…). The installed `CnxApp` sha256 is
    `45a3d5ea865fdd5e80bebcf8b4e2b66d073f38a52602891dab0787d5048be3ae`, the same as the build output
    and the copy in `~/cnx-ios-e2e/termverify8/CnxApp.app`.
  - Launched with `-CnxFrameLog`.
- **Mac:** `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2 (daemon `e1edf234`). The Mac side was used
  only for:
  - oracle reads: `terminal list`, `terminal … screen read`, and the hostd log;
  - kills of the rig's own hostd (`pkill -9 -f …cnx-e2e-604fc689.app/…/cnx-hostd`).
- **Stimulus:** every command and prompt was entered on the phone with composer paste + Send, the
  key bar, or axe taps and swipes. That includes the GEN loops, the reverse-video bar, `seq`,
  `codex` and the Codex prompts.
- **Paths:** `G-D` (hostd `kind=WireGuard path=Direct`) and `W-T` (`kind=WebRtc path=Turn`,
  Relay only on). Transport was switched in Settings on the phone. One G-D reattach reported
  `kind=WireGuard path=Relay` (`gd-drop-read2a`): Relay only is on, and WireGuard honours it only
  sometimes. W-D, G-T, G-R and netsim were not run.
- **Load:** the laptop 1-min load was 8-95 during the captures (each run's load is in its
  `*-result.json` and in `events.jsonl`). **Every timing row is INVALID.** Only correctness,
  order, content and zero-count rows are judged.
- **How black is measured:** `v8v_black.py` reads every *source* frame of the recording (no
  resampling) and reports each black band (lit < 0.4 %, ACCEPTANCE section 0) with how long it
  stayed on screen (next frame's pts minus its pts). The app's own frame-log `blank` flag is
  summarised by `v8v_fl.py`. Where the two disagree, the video wins (see "The `blank` flag" below).

## Claim 1: no black pages

### 1b. Following at the history cap, hands off (V6-2, T-FOLLOW-04)

A GEN loop (`for i in $(seq 1 60000); do echo GEN-$i; sleep 0.01; done`, typed on the phone) ran
in `e2e-t2` at the cap (17739 rows, pruned to 16853 every ~21 s). 150 s each, no touch.

| Run | Path | Prunes while following | Video black (source frames) | Black > 1 frame | Frame log `blank` |
| --- | --- | --- | --- | --- | --- |
| `gd-hold1` | G-D | 8 | **1** at 111.357 s, 20 ms (one frame), 46 ms after the prune at 02:29:32.099 | 0 | 1 frame, at the same moment |
| `wt-hold1` | W-T | 10 | **1** at 91.508 s, 20 ms (one frame) | 0 | 752 frames, 19 runs of 2-3 frames (not visible in the video) |

- Round 6 had 5 of 5 prunes black for 1-11.5 s. **The multi-second black is fixed** on both
  transports: 18 prunes, 0 black runs longer than one frame.
- A one-frame full black still appears right after a prune (`verify8v/gd-hold1-111.34s-oneframe-black.jpg`:
  the frames before, at and after). ACCEPTANCE T-FOLLOW-04 allows 0 black frames, so the row
  stays **FAIL**. Under the brief's "> 1 frame" rule this case passes.
- Counts: `verify8v/{gd,wt}-hold1-{black,framelog,result}.json`. Prunes: `v8v_prunes.py` on the
  `pin:` row counts in the app log (the hold tool's own prune regex finds 0, because a prune while
  following logs no line).

### 1a. Jump to bottom (V6-3, T-SCROLL-09)

- `gd-jump1`, `gd-jump2` (G-D, GEN at ~100 rows/s at the cap): 32 jumps, half from deep history
  (6 flings, then 1.5 s settle) and half right after 2 flings (mid-fling).
- `wt-fling1` (W-T, GEN at ~250 rows/s at the cap): 65 flings from the live bottom, each followed
  by Jump to bottom 0.5 s later (65 jumps).
- `wt-cxjump1` (W-T, a fresh Codex tab created from + on the phone, Codex streaming 900 lines):
  see below.

| Run | Jumps | Video black runs (all one source frame) | Longest | Black > 1 frame |
| --- | --- | --- | --- | --- |
| gd-jump1 | 16 | 5 (16.18, 22.15, 33.20, 53.77, 82.01 s) | 21.7 ms | 0 |
| gd-jump2 | 16 | 6 (4.93, 9.48, 23.68, 63.10, 67.91, 128.05 s) | 18.3 ms | 0 |
| wt-fling1 | 65 | **37** | 18.3 ms | 0 |

- Round 6's 3-5.6 s black pages are gone: 0 of 113 jumps black for more than one frame.
- **But a one-frame full-black frame comes with the jump about every second time at fast output.**
  In `wt-fling1` 37 one-frame blacks in 65 jumps; the sheet `verify8v/wt-fling1-171.66s-oneframe-black.jpg`
  shows the page at the reading position, one black frame with the Jump button still up, then the
  live bottom. Several `gd-jump` blacks sit 0.1-0.5 s before the logged tap return (the tap lands
  before `axe` returns).
- T-SCROLL-09 says the first frame after the tap is the start of the animation or the bottom, with
  0 foreign frames. A black frame is neither: **FAIL (noticeable, systematic)**. Under the brief's
  "> 1 frame" rule it passes.
- **Fresh Codex tab** (`wt-cxjump1`, W-T): + → New Terminal, `codex …` and a 900-line prompt, all
  typed on the phone. 10 jumps while Codex streamed: **0 black frames** (source-frame scan,
  460 s). Two `a fling reached the bottom` lines came at 03:20:02/12 while the transcript was
  still shorter than the page (`offset -62, bottom -62`); that is a legitimate end, not a snap.
- **Total: 123 jumps, 0 black for more than one frame; 48 one-frame blacks, all at the cap.**

### 1c. Two quick drops (V6-4, T-LIFE-08)

`v8v_drop.py`: a GEN loop typed on the phone streams through the whole run; two hostd kills 3.4 s
apart (`read2`, `follow2`) or one (`read1`).

| Run | Path | Mode | Video black | Frame log blank > 1 frame | Replays | `[unknown surface]` on screen |
| --- | --- | --- | --- | --- | --- | --- |
| gd-drop-read2a | G-D | reading, 2 kills | 0 | 0 | 1 `reattach` | 0 (4 log-only attach retries) |
| gd-drop-read1 | G-D | reading, 1 kill | 0 | 0 | 1 | 0 |
| gd-drop-follow2 | G-D | following, 2 kills | 0 | 2 runs of 2 (not visible) | 2 (one per link-up) | 0 |
| wt-drop-read2 | W-T | reading, 2 kills | 0 | 0 | 1 | 0 |
| wt-drop-follow2 | W-T | following, 2 kills | 0 | 4 runs of 2-3 (not visible) | 1 | 0 |

- **V6-4 is fixed in these runs: 0 black frames after two quick drops on both transports**
  (round 6: black for 60 s+ on W-T). T-LIFE-08: **PASS (n = 5)**.
- `LinkError(code: "attach", message: "unknown surface 17")` appears 3-7 times per drop in the app
  log (attach retries while the Mac restarts); none reached the screen (screenshots
  `*-after.jpg`).

### 1d. A fling just before a tap

- `gd-jump*` odd trips tap Jump 0.2 s after the last of 2 flings: 16 such taps, 0 black runs over
  one frame; 2 one-frame blacks.
- `wt-fling1`: each Jump tap 0.5 s after a fling: 65 taps, 37 one-frame blacks, none longer.

### The `blank` flag

The frame log's per-frame `blank` (rows the presented frame does not cover) fired 752 times in
`wt-hold1` (19 runs of 2-3 frames) and 101 times in `gd-jump2`, while the video in the same windows
shows full rows (`verify8v/` sheets for `wt-drop-follow2` 20.6 s and `wt-hold1` 102.9 s). It also
fired 2-frame runs during the key-bar ^C / keyboard show at the end of the runs. Either the flag
over-reports (for example a sliver of an uncovered row at the edge), or the uncovered rows are not
visible. It is not usable as acceptance evidence as it stands; the video verdicts above are.

## Claim 2: no fling snaps to the bottom at a prune (V5-2, T-SCROLL-04)

- Flings toward older history during output at the cap: gd-jump1 64, gd-jump2 64 (~100 rows/s),
  wt-fling1 65 from the live bottom (~250 rows/s, the page pruned 39 times during the run and
  28 times while reading). **About 193 flings.**
- `a fling reached the bottom`: **0** in the cap runs. After each of the 65 `wt-fling1` flings the
  Jump button was present 0.5 s later (no snap). `verify8v/wt-fling1-result.json`.
- **PASS.**

## Claim 3: reading position after drops at the cap (V2-3, T-LIFE-09, T-LIFE-15)

Top visible row id (OCR) just before the first kill and 12 s after the reattach, with output
arriving through the drop:

| Run | Path | Before | After | Off by | App log |
| --- | --- | --- | --- | --- | --- |
| gd-drop-read1 (1 kill, no prune) | G-D | GEN-3060 | GEN-3285 | **225 rows lower** | `reading mark row 15301 of 17439` → `restored row 15301 -> 15526 of 17664` |
| gd-drop-read2a (2 kills, a prune) | G-D | GEN-6802 | GEN-7158 | **356 rows lower** | `16065 of 17685` → `15534 of 17154` |
| wt-drop-read2 (2 kills, a prune) | W-T | GEN-1405 | GEN-1793 | **~388 rows lower** | `15277 of 17585` → `14778 of 17086` |

- In each case the phone moved the mark by the change in total rows (+225, −531, −499), which
  counts the rows that arrived during the drop as a shift of the anchor. The page lands that many
  rows lower. The single-drop case did not even involve a prune: total grew 17439 → 17664, the
  anchor row (15301) did not move on the Mac, and the phone moved it to 15526.
- This is the limit `qa-round-8.md` itself states for the V2-3 fix ("more than about 110 rows during
  the drop pushes the old end out of the active area"), hit by an ordinary 100 rows/s stream.
- T-LIFE-09 (reading: same top row id ± 0): **FAIL, disruptive, 3 of 3 on both transports.**
  T-LIFE-15: **FAIL** for the same reason on W-T.
- Following after drops (`follow2`, both paths): back at the live bottom (GEN advancing, Jump
  hidden) 12 s after; following resumes: PASS (timing invalid).

## Claim 4: bottom pin after the draft shrinks (V6-1)

`v8v_pin.py` (W-T, tab e2e-t2): `seq 1 300; printf '\e[7m%*s\e[0m' $COLUMNS ''; read x` typed on the
phone, so a reverse-video bar is the last row. A 6-line draft is pasted into the composer
(not sent), then shrunk by holding delete. Pixels by `v6pin.py` on each screenshot (bar bottom vs
the first non-background row under it); the app's `pin:` log was not used.

| Step | Keyboard | Composer field h (pt) | Bar bottom (pt) | First row below (pt) | Gap (pt) | Bar h (pt) |
| --- | --- | --- | --- | --- | --- | --- |
| 1 line | up | 36 | 458 | 458 | **0.0** | 16 |
| 6 lines | up | 136 | 358 | 358 | **0.0** | 16 |
| shrunk to 5 | up | 124 | 370 | 370 | **0.0** | 16 |
| shrunk to 5 | down | 124 | 648 | 648 | **0.0** | 16 |
| shrunk to 5, +5 s | down | 124 | 648 | 648 | **0.0** | 16 |
| shrunk to 2 | up | 58 | 436 | 436 | **0.0** | 16 |
| shrunk to 2 | down | 58 | 714 | 714 | **0.0** | 16 |
| shrunk to 2, +5 s | down | 58 | 714 | 714 | **0.0** | 16 |

- The bar's bottom tracks the composer card in every shrink, keyboard up and down: gap 0 pt,
  bar a full 16 pt row (no overlap). The shrinks were 6 → 5 → 2 lines (delete-hold steps are
  coarse), which covers round 6's failing 6 → 5 case and a large shrink. **V6-1 / T-SIZE-07:
  PASS.** Shots: `verify8v/wt-pin-*.jpg`, numbers `wt-pin-pin.json`.
- `pin.sh` (Demo terminal, not the real link, growth only): the app's log reports gap 0.0 at
  1-6 lines (`verify8v/pinsh-demo.txt`). It has no bar, so no pixel check; informative only.

## Claim 5: `clear`

- On the rig's zsh, `clear` (typed on the phone, e2e-t2) also clears the scrollback (E3). The Mac
  then has one row (the bar/prompt) at row 0. The phone shows that row at the top of the page and
  blank black down to the composer (`verify8v/wt-clear-e3-kbup.jpg`, `wt-clear-e3-kbdown.jpg`:
  ~380 pt of blank between the last row and the composer).
- This matches the Mac's screen and T-REND-09 (no blank rows above row 0). It does not match the
  claim as briefed ("the prompt sits directly above the composer, with no blank page"); with no
  history above, the prompt cannot sit on the composer without blank rows above it. **Verdict:
  claim as briefed FAIL; ACCEPTANCE rows T-REND-09/T-REND-10 PASS for this case.** The case the
  implementer fixed (`clear` that keeps history) was not run separately.

## Claim 6: a new tab does not make the open tab replay (V5-4)

- Grid → + → New Terminal (`newtab1`, W-T), with e2e-t1 the last open tab. App log: only
  `surface 24: mirror reset cause=attach size=53x42` (the new surface). No reset or
  `resized-event` on any other surface. **PASS (n = 1).** `verify8v/newtab1.log.gz`.
- `+ → New Terminal` → `codex …` started a working Codex (`newtab-codex-start.jpg`): T-TABS-06
  correctness PASS.
- The Mac still lists e2e-t1 at 39 rows while every other tab is 42 (`terminal list`); the
  "53x42 asked, 39 overruled" state of round 6 persists for t1.

## Claim 7: no 370 ms freeze every 3 s while following

Frame log while following a stream, hands off (`v8v_fl.py`):

| Run | Frames | Frames > 100 ms | Longest 5 (ms) | Spacing of the > 100 ms frames |
| --- | --- | --- | --- | --- |
| gd-hold1 | 9030 | 10 | 214, 164, 158, 157, 156 | **every 15.1-15.5 s** (5.3, 20.8, 35.9, 51.1 … 142.0 s) |
| wt-hold1 | 8971 | 11 | 162, 156, 155, 152, 150 | **every 10.6-15.5 s**, mostly 15.1-15.2 s |

- The 370 ms frame every 3 s is gone. **Claim PASS.**
- **New (noticeable, timing INVALID under load 15-95):** a 150-214 ms frame every ~15.1 s while
  output streams. The period equals `TerminalFrameSaveSchedule`'s maximum wait: `saveFrameSoon`
  waits for output to pause, at most 15 s, then renders `controller?.snapshot(hidingCursor:)` on
  the main thread. Under continuous output the save always fires at the 15 s cap. The frame log's
  `work_ms` for those frames is 0-0.6 ms, so the save is outside the measured work, and T-SCROLL-06 /
  load cell (9) numbers from the frame log understate it. It needs a valid-load rerun, but the
  period is load-independent evidence of the cause.

## Claim 8: grid cards, D11, V5-5

- **V5-6 / T-TABS-01, active card:** the active card shows the live bottom with the prompt and
  cursor (`grid-open-1.jpg`, e2e-t2; `grid-while-streaming.jpg`, e2e-t2 at GEN-387 while the loop
  streamed; `v55-grid-before-close`, the Codex tab's bottom). **PASS** for the active card.
- **Inactive card stale (T-TABS-01, noticeable):** at the first grid open after my install and
  launch, the e2e-t1 card showed old Codex output (forest items 86-107) while the Mac's t1 showed
  rivers item 700 and the prompt (`grid-open-1.jpg`, `mac-t1-screen-0317.txt`). Opening t1 showed the
  right screen (`t1-open-8s.jpg`). After a relaunch the cards were right (`d5-grid-after-relaunch.jpg`).
  The stale card is a saved frame from an earlier session that the grid showed as current.
- **D5 / T-TABS-02:** relaunch, grid: all 4 cards show content. **PASS.**
- **D11 / T-LIFE-06 (saved frame after a kill):** `simctl terminate` + launch (`d11-relaunch.mp4`).
  The saved dark frame is under the system launch cross-fade (`d11-handoff-light-skeleton.jpg`),
  then a dimmed saved frame with "Connecting…", then live, with 0 black source frames.
  - No cursor block in the saved frame. **But the character under the cursor is gone too:** the
    saved frame reads `› sk Codex to do anything` where the live frame reads `› Ask …` with the
    cursor on `A` (polish: hiding the cursor also hides its cell's glyph).
  - **PASS with that polish item.** Timing not judged (load).
- **V5-5 (closing a tab ends its Mac session): FAIL.** + → New Terminal created
  `term_7b24c2dea0cf7caeaa3f49e8b403e768` on the Mac. Closing its card on the phone (the card's ×,
  no confirmation shown, an idle shell) removed it from the grid (4 tabs), but the Mac still listed
  it as `running` 10 s later (03:30:24) and 50 s later (03:31:13, after an app relaunch in
  between). It was gone at the next check, 04:01:31 (`events.jsonl` `v55_close`, `v55_recheck`).
  So the Mac session ends late (somewhere between 50 s and 31 min), not at the close.
  T-TABS-08 ("the Mac's tab closes too ≤ 2 s"): **FAIL.**

## Claim 9: text selection (G-14, T-SEL-01)

On e2e-t1 (real Codex transcript, W-T then G-D):

- **Long-press selects a word:** long-press on `Science` → Copy → pasteboard `Science`. **PASS.**
- **Handles extend the selection:** long-press `Satellites` (row 684), then a drag from the word's
  end into row 685 → Copy → `Satellites map seasonal flood extents.\n  685. Laser scans reveal channel
  geometry.` That equals the Mac's two rows. **PASS (1 of 1).**
- **Select All + Copy across scrollback:** 35,262 bytes, 1,118 lines, from `Earlier messages are
  available — press ctrl + t to` / `34. Karst streams…` to the composer prompt. The Mac's
  `history read` for t1 starts with the same rows. **PASS.** `verify8v/sel-select-all-pasteboard.txt`.
- **Tap clears:** after a tap on the page the edit menu is gone and the text is not dimmed
  (`sel3-after-tap-clear*.jpg`). **PASS.**
- **New (noticeable): the selection is nearly invisible.** Selected text is drawn dimmer (grey on
  black) with no highlight colour, and the handles are not visible. Where the handles sit they
  black out parts of neighbouring glyphs: `683. Drones` shows as `Ͻrones` and `scans` loses a
  letter while a selection is up (`sel-word-then-handle.png`, `sel-longpress-crop.png`). A user
  cannot see what is selected or where to grab.
- T-SEL-01 asks for 10 of 10 exact selections; this run has 3. T-SEL-02 (selection holds while
  output streams) was not run. **T-SEL-01: not enough samples; functional checks pass.**

## Claim 10: regression re-checks (passed in round 6)

| Item | Verdict | Evidence |
| --- | --- | --- |
| Reconnect after a hostd kill | **PASS (correctness)**; timing INVALID | 7 kills; hostd `link up` 0.9-1.1 s after each restart (`*-result.json` `hostd`) |
| One replay per reattach (T-SIZE-02) | **PASS** | 1 `mirror reset cause=reattach` per link-up in every drop run and in the transport switch; 0 `resized-event` |
| D5 (T-TABS-02) | **PASS** | `d5-grid-after-relaunch.jpg`: 4 cards with content after a relaunch |
| V3-2 (output keeps arriving after a drop) | **PASS (tail)** | After every follow drop GEN kept advancing on the phone (`after` → `after_plus3s` ids grow); M-INTEG not run |
| V3-3 (drop mid-fling keeps the place) | **NOT RUN** | The simulator stopped taking input before this run (see Not done) |
| V3-4 / T-TABS-14 | **cnx-owned PASS; row FAIL (kit, unchanged)** | Grid AX (`ax-grid-open.txt`): 0 Return, 0 Scroll to bottom, 0 composer inside cards. The page still exposes the kit's `Close e2e-t2` at (372, 0) (button list in this round's logs) |
| V2-1 / T-TABS-03 grid trips while streaming | **NOT JUDGED** | 2 attempts; the first trip's tap timed out (simulator input), the recordings are unfinalized |
| Transport switch (T-LIFE-16) | **PASS (correctness)** | W-T → G-D on Settings with t1 open: 1 `reattach`, 0 black source frames, phone tail = Mac tail (`switch-wt-to-gd.log.gz`, `events.jsonl` `switch`). The app's status says `WireGuard TURN` while hostd logs `path=Direct` (label/path disagree with Relay only on) |
| Jump to bottom mid-fling | **Lands: PASS; one-frame black: FAIL** | Claim 1a |
| Pin at rest | **PASS** | Claim 4: gap 0.0 pt at rest, keyboard up and down |

## Claim 11: round-6 failing rows, and the e2e-t1 divergence (V6-5)

- **V6-5 (t1 ≠ Mac): not reproduced.** `gd-t1-codex`: a 1500-item Codex prompt typed on the
  phone in e2e-t1 (G-D), followed hands-off for **12.3 min** (03:34:54-03:47:08) with a phone/Mac
  comparison every ~41 s (`gd-t1-codex-compare.jsonl`). The phone's highest item was within
  1-5 of the Mac's at every sample where OCR read one (83/86, 348/350, 439/440, 528/529, 711/713,
  808/810, 913/914, 1005/1007, 1094/1095, 1293/1296, 1565/1570). No freeze, no old output.
  - motion.py on the first 120 s (60 fps): 0 reversals, 0 flashes, 0 black; recording INVALID
    by the 34 ms rule (26.5 %).
  - Every tab's bottom matched the Mac at the end (`events.jsonl` `tab_compare`: lighthouse,
    mountains, t2; t1 matched during the follow).
  - Only t1 was followed for 10+ min. The new Codex tab streamed 9 min (`wt-cxjump1`, with
    jumps) and ended equal to the Mac. The two idle tabs were spot-checked.
- Round-6 rows re-judged:

| Round-6 row | Round 8 | Evidence |
| --- | --- | --- |
| Bottom pin (V6-1 shrink gap) | **PASS** | Claim 4 |
| T-SCROLL-09 / V5-1 (V6-3) | **FAIL (one-frame black, systematic)**; multi-second black fixed | Claim 1a |
| Following black after a prune (V6-2) | **FAIL (one frame)**; multi-second black fixed | Claim 1b |
| V5-2 fling snap | **PASS** | Claim 2 |
| V2-3 / T-LIFE-09 | **FAIL (225-388 rows off, 3 of 3)** | Claim 3 |
| T-LIFE-08 two quick drops (V6-4) | **PASS** (5 runs, both transports) | Claim 1c |
| Jump mid-fling | **Lands PASS; one-frame black FAIL** | Claim 1d |
| Scroll while streaming (frame log) | **INVALID (load)**; new 15 s periodic frame | Claim 7 |
| D7 (one-row jumps following Codex) | **PASS in 120 s at 60 fps (0 reversals, 0 flashes)**; INVALID by the 34 ms rule | Claim 11 |
| V5-6 / T-TABS-01 | **Active PASS; inactive stale once (FAIL)** | Claim 8 |
| V6-5 t1 ≠ Mac | **Not reproduced (12.3 min)** | above |
| Reconnect "about 2 s" (T-LIFE-12) | **INVALID (load)** | |
| T-LIFE-15 (relay) | **FAIL** (T-LIFE-09 on W-T) | Claim 3 |
| T-ADV-01 | **FAIL** | All of the above; about 100 min of scripted and free play |

## Verdict per ACCEPTANCE ID touched

| ID | Verdict | Numbers |
| --- | --- | --- |
| T-FOLLOW-04 | **FAIL** | 2 one-frame blacks in 300 s following at the cap (18 prunes); 0 longer |
| T-FOLLOW-02/03 | PASS (Codex 120 s), INVALID recording | 0 reversals, 0 flashes |
| T-SCROLL-02 | **FAIL** | 48 one-frame black frames across 123 jumps at the cap |
| T-SCROLL-04 | **PASS** | 0 reading → following without a user action in ~193 flings at the cap |
| T-SCROLL-09 | **FAIL** | 48 one-frame blacks during 113 jump trips at the cap (most at the tap, some mid-fling); 0 in 10 Codex-tab jumps |
| T-SIZE-02 | PASS | 1 replay per attach (12 reattaches, 1 switch) |
| T-SIZE-07 (shrink) | PASS | gap 0.0 pt, 8 measurements |
| T-REND-09/10 after `clear` (E3) | PASS | prompt at row 0, as the Mac |
| T-LIFE-06 | PASS (polish: cursor glyph hidden) | saved frame first, 0 black |
| T-LIFE-08 | PASS | 0 black, 0 error text, 5 drop runs |
| T-LIFE-09 | **FAIL, disruptive** | 225 / 356 / ~388 rows off |
| T-LIFE-10 | PASS (tail only) | |
| T-LIFE-15 | **FAIL** | T-LIFE-09 on W-T |
| T-LIFE-16 | PASS | 1 replay, 0 black, tail equal |
| T-TABS-01 | **FAIL** (inactive stale once) / active PASS | |
| T-TABS-02 | PASS | |
| T-TABS-06 | PASS (correctness) | |
| T-TABS-08 | **FAIL** | Mac session still running 50 s after the close |
| T-TABS-14 | FAIL (kit), cnx PASS | |
| T-SEL-01 | functional PASS, 3 of 10 samples | Copy exact ×2, Select All = Mac history |
| T-SEL-02 | NOT RUN | |
| All timing rows | INVALID | laptop load 8-95 |

## New defects

1. **N8-1 (disruptive): reading position lost after a drop when output keeps arriving.** The
   restore shifts the anchor by the change in total rows, so it lands lower by the number of
   rows that arrived during the drop. 3 of 3 (G-D ×2, W-T ×1), 225-388 rows, even with no prune.
   Repro: in e2e-t2, type the GEN loop, fling up 5 times, kill hostd once; the top row moves from
   GEN-3060 to GEN-3285 (`gd-drop-read1`). This is V2-3's residual, not fixed.
2. **N8-2 (noticeable, systematic): one black frame on Jump to bottom and after a prune at the
   cap.** 48 of 123 jumps at the cap, 2 of 18 prunes while following. Each is one source frame
   (5-22 ms). Round 6's multi-second black pages are fixed.
3. **N8-3 (noticeable): a 150-214 ms frame every ~15.1 s while output streams** (the cold-frame
   save at its 15 s maximum wait, rendered on the main thread). Not counted in the frame log's
   `work_ms`. Timing rows INVALID under load; the period identifies the cause.
4. **N8-4 (noticeable): closing a tab on the phone leaves its Mac session running** for at least
   50 s (V5-5 claim fails).
5. **N8-5 (noticeable): selection is nearly invisible.** Dimmed text, no highlight colour, no
   visible handles; the handles black out parts of nearby glyphs.
6. **N8-6 (noticeable): a stale inactive grid card** (e2e-t1 showed old output at the first grid
   open after launch while the Mac showed the end of a later turn).
7. **N8-7 (tooling): the frame log's `blank` flag over-reports** (752 flagged frames in a run whose
   video shows none). It cannot serve as acceptance evidence until it matches the screen.
8. **Polish:** the saved relaunch frame hides the glyph under the cursor (`› sk Codex`); the app's
   status reads `WireGuard TURN` while hostd reports `path=Direct`.

## Not done

- W-D, G-T, G-R, netsim; M-INTEG; a Claude Code session; T-SEL-02; 10 selections.
- V3-3 (drop mid-fling) and V2-1 grid trips while streaming: from 03:50 the simulator stopped
  taking input. Every `axe` tap (simulator and automatic styles), `axe touch` and `axe swipe`
  timed out (20-25 s), while the app kept drawing at ~58 fps (frame log) and AX reads worked.
  Laptop load was 25-62 at the time (another agent's build). I did not restart the simulator or
  front anything.
- 10+ min of following for every tab: only t1 (12.3 min); the new Codex tab streamed 9 min with
  jumps; the other two tabs were idle and spot-checked.
- Every timing threshold: INVALID (load 8-95 through the round).

## Rig left

- `cnx-termqa-1` runs my `b64ef74d` build (sha256 `45a3d5ea…e3ae`), launched with `-CnxFrameLog`,
  paired on WireGuard (hostd `path=Direct`; Relay only still on).
- `~/cnx-ios-e2e/termqa-state.json` `app_path` points to `~/cnx-ios-e2e/termverify8/CnxApp.app`.
- e2e-t2 still runs a GEN loop I typed (`seq 1 60000`, ~40-100 rows/s). It ends on its own; I could
  not send ^C after the input stopped responding. The Codex tabs (e2e-t1, "Print 1–900 mountain…")
  are idle at their prompts.
- The Mac side is unchanged except for the hostd restarts; its hostd is up.
