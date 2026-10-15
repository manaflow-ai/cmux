# Terminal verify round 6 (fresh adversarial verifier, 2026-10-15 00:45-02:02 PT)

**Verdict: REJECT.**

Two claims hold: the bottom pin at rest and while following, and drops in most cases.
The black-frame fix does not hold. On this build the terminal goes **black for seconds**,
and three patterns cause it:

1. Jump to bottom from history (V5-1 is worse than in round 5).
2. Any history prune while following at the cap. The page goes black, hands off, for up
   to 11.5 s, until the next touch.
3. A two-quick-drops reattach. The page stayed black for about 60 s, until a fling.

V5-2 also reproduced: 1 of about 300 flings toward older history snapped to the live
bottom, and the snap came with a 1.1 s black frame. The V2-3 eviction case still lost
the reading position in 1 drop (116 rows lower). There is one new bottom-pin defect: a
6-11 pt gap after the composer draft shrinks.

Criteria: `ACCEPTANCE.md` on `origin/feat-cnx-ios-termqa`, verbatim. Artifacts are in `verify6/`.
The raw mp4s stay on the laptop in `~/cnx-ios-e2e/termqa-raw/tv6/` (1.0 GB). Their sha256 prefixes
and durations are in `verify6/raw-videos.txt`. Events, with the laptop load on every line, are
in `verify6/events.jsonl`. The tools I wrote are `verify/termqa/v6*.py` on this branch.

## Build, rig, load

- **Phone build:** `feat-cnx-ios-termqa` at `3a634b2a`. I built it myself in a separate worktree
  (Demo config, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`, CnxFFI `d84db41cfd5ce9a9`) and installed it
  on `cnx-termqa-1` (C906E217-…). It was launched with `-CnxFrameLog`. The installed `CnxApp`
  sha256 is `e6c1e5f86b6addf98f08930558e17e84e9a34ca0ef3f86941118f6ec572c5455`, the same as the
  build output.
  - The termqa worktree's HEAD had moved to `9b8deeb8`, a merge another session made at 00:45, so I
    did not build there.
- **Mac:** `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2 (daemon `e1edf234`). The Mac side was used
  only for:
  - oracle reads: `terminal … screen read`, `terminal list`, and the hostd log;
  - kills of the rig's own hostd: 17 `pkill -9 -f …cnx-e2e-604fc689.app/…/cnx-hostd`.
- **Stimulus:** every command and prompt was entered on the phone, with composer paste + Send, the
  key bar ^C, or axe taps and swipes. That includes the HIST and GEN loops, the reverse-video bar
  fixtures and the Codex prompts.
- **Paths:**
  - **G-D**: WireGuard, hostd `kind=WireGuard path=Direct`.
  - **W-T**: WebRTC, `kind=WebRtc path=Turn`. I switched transport in Settings on the phone.
  - "Relay only" was **on** throughout, yet WireGuard reported `path=Direct`. Either WireGuard
    ignores Relay only, or the label is wrong. This is worth a look, but it is not judged here.
  - No W-D, G-T or G-R runs.
- **Load:** the laptop 1-min load was **17-353**, and the 15-min load was **36-101**, for every
  capture.
  - **Every timing row is INVALID.** Only correctness is judged.
  - Most recordings also fail §1.4's 34 ms-gap rule. Only fl-gd-1 and fl-gd-2 are valid (1.9 % and
    1.3 %). The black runs below are seconds long, far beyond any frame-gap effect.

## Verdicts per ID touched

| ID / claim | Verdict | Evidence |
| --- | --- | --- |
| **Bottom pin** (user report): flush, 0 gap, 0 overlap, ±1 pt | **FAIL (one case)** | See below. |
| **T-SCROLL-09 / V5-1**: Jump to bottom with no black frame | **FAIL** | See below. |
| **New: following goes black after a prune** (T-FOLLOW-04, T-SCROLL-02) | **FAIL, disruptive** | See below. |
| **V5-2 / T-SCROLL-04**: no fling toward older history snaps to the bottom | **FAIL (1 of ~300)** | See below. |
| **V2-3 eviction / T-LIFE-09** (claimed fixed, rig 2 of 2) | **FAIL (1 of 10 read-drops at the cap)** | See below. |
| **T-LIFE-08**: no blank on a drop. Two quick drops (s4 re-run) | **FAIL on W-T, pass on G-D** | See below. |
| **Jump to bottom mid-fling** (user report, 100/300/600 ms) | **Lands: 18 of 18. Black: FAIL** | See below. |
| **Scroll while streaming** (G-04 frame log) | **INVALID for thresholds (load); correctness FAIL via the black runs** | See below. |
| **D7**: no one-row jump while following real Codex for 60 s | **INVALID / not shown** | See below. |
| **V5-6 / T-TABS-01**: cards | **Inactive: PASS. Active: kit crop, as stated (row still FAIL)** | See below. |
| **New: t1 phone ≠ Mac** (T-FOLLOW-01/06, T-REND-01) | **FAIL (observed; cause not isolated)** | See below. |
| Reconnect "about 2 s" (T-LIFE-12) | **INVALID (load); regressed against the claim** | See below. |
| One replay per reattach (T-SIZE-02) | **PASS (21 reattaches + 2 switches)** | See below. |
| No `unknown surface` | **PASS** | 0 in every log of this round (`grep -c "unknown surface" verify6/*.log`). |
| D5 / T-TABS-02 | **PASS** | See below. |
| V3-2 / T-LIFE-10 (output keeps arriving after a drop; tail check) | **PASS (tail); M-INTEG not run** | See below. |
| V3-3 (drop mid-fling keeps the place) | **PASS (1 of 1, W-T)** | See below. |
| V3-4 / T-TABS-14 | **cnx-owned PASS; row FAIL (kit U8, unchanged)** | See below. |
| V2-1 / T-TABS-03: grid trips while streaming | **PASS (correctness)** | See below. |
| T-LIFE-16: transport switch | **PASS (correctness)** | See below. |
| T-LIFE-15 (relay) | **FAIL** | W-T fails T-LIFE-08 (the two-quick-drops black). T-LIFE-09 failed on G-D, not W-T; W-T kept 4 of 4. |
| T-TABS-06: new terminal | **PASS (correctness)** | `+ → New Terminal`: the composer appeared 2.8 s after the tap (load 70; timing invalid). `cd … && codex` typed there started Codex (`verify6/newtab-codex.jpg`). |
| T-ADV-01 | **FAIL** | All of the above. About 75 min of play. |

### Bottom pin

- Measure: `v6pin.py`. The last row is a reverse-video bar typed on the phone, so it fills its whole
  cell. The check is the bar's bottom edge against the first non-background pixel row below it, and
  against the AX composer card top.
- **At rest (`pin-rest-gd2.json`) and while following (`pin-follow-gd.json`, 241 frames from 6
  recordings): gap 0.0 pt and bar height 16.0 pt (one full row, so no overlap).**
  - This holds with the keyboard down and a 1-line composer, the keyboard up with 1, 3 and 6 lines,
    and the keyboard down with 6 lines.
- **New defect V6-1 (noticeable):** when the draft *shrinks*, the last row stays where the taller
  composer was.
  - Long-press delete shrank the draft from 6 lines to 5.
  - Gap: **6.0 pt** (`pin-rest-gd2-kbdown-cleared.jpg`, still there 20 s later in
    `pin-rest-gd2-cleared-later.jpg`); **11.0 pt** with the keyboard up and the same after hiding it
    (`shrB1-b/c`, crop in `shrB1-c-kbdown-crop.png`); **6.0 pt** in all 40 frames while following
    (`pin-follow-gd-kbdown-cleared`).
  - Reproduced in 3 of 4 shrinks. It clears on the next composer height change.
  - The app's own `pin:` log says `gap 0.0 … composer 92 pt` while the card is visibly shorter, so
    the page holds a stale composer height (`pin-shrink.log`).

### T-SCROLL-09 / V5-1: black frames on Jump to bottom

- Tested from deep history while GEN streamed at about 50-100 rows/s with the history at the cap.
- **3 of 20 jumps showed the terminal fully black for 3.0-4.0 s**, and black stayed until the next
  touch:
  - fl-gd-1 at 159.2-163.2 s and 192.9-195.9 s;
  - fl-gd-2 at 31.6-35.1 s.
  - Sheets: `fl-gd-1-jump-158.8s.jpg`, `fl-gd-2-jump-31.0s.jpg`. Motion: `fl-*-motion.json` (valid
    recordings).
- **It also happens with no prune.** In a fresh Codex tab (about 600 rows, no cap), the jump at 79.1 s
  went black for **5.6 s** (80.6-86.2 s), until the next fling (`cx-wt-jump-black-79.8s.jpg`).

### New: following goes black after a prune

- At the cap, **every prune while following was followed by a black terminal: 5 of 5** in the
  hands-off run `jb-hold-gd`.
- Black runs:

  | Start (s) | End (s) | Length |
  | --- | --- | --- |
  | 11.3 | 14.7 | 3.4 s |
  | 28.8 | 29.8 | 1.0 s |
  | 46.0 | 57.5 | **11.5 s** |
  | 64.2 | 72.1 | 7.9 s |
  | 82.8 | 84.1 (end of recording) | 1.3 s |

- Each run starts about 0.4 s after the page's rows drop 17740 → 16854.
- In two cases nothing touched the page, and it stayed black until the next fling
  (`jb-hold-gd-44-59s.jpg`, `jb-hold-gd.log`).
- Same on W-T: `dr-wt-follow` was black from 12.0 s to the end, and still black at +50 s (OCR 0 rows),
  after the prune at 01:40:02.9.
- The composer, chrome and scroll indicator stay drawn. Only the terminal surface is black.

### V5-2 / T-SCROLL-04: fling snaps to the bottom

- In `fl-gd-2`, the first fling after a Jump to bottom started from the live bottom toward older
  history.
- It logged `scroll: a fling reached the bottom -> following` at 01:12:38.761. That is the same
  millisecond the page's rows dropped 17726 → 16853 (a prune).
- The terminal was black for 1.1 s (68.0-69.1 s), and the page went to following, then back to
  reading on the next fling (`fl-gd-2-v52-67.4s.jpg`).
- Flings toward older history, all during streaming at the cap:

  | Run | Flings |
  | --- | --- |
  | fl-gd-1 | 100 |
  | fl-gd-2 | 100 |
  | fl-wt-1 | 50 |
  | ev-wt-2/4 | 20 |
  | ev-gd-1/2/3 | 30 |
  | mf-gd-1 | 48 (setup flings) |
  | **Total** | **about 348** |

- `history pruned … while reading` appeared 14 times.

### V2-3 eviction / T-LIFE-09: reading position after a drop

- Repro: `fl-gd-2` trip 9 (G-D). Reading at top row GEN-18084. Drop after 01:14:29.
- The log shows `reading mark row 15037 of 17633: kept`, then `restored row 15037 -> 14266 of 16862`.
- The page came back at **GEN-18200, 116 rows lower**. The phone shifted the mark by the full
  771-row difference in totals, which is not the true top shift.
- Kept, top row identical, in 9 other read-drops at the cap: `fl-wt-1`, `ev-wt-2`, `ev-wt-4`,
  `ev-gd-1/2/3`, `dr-wt-midfling`, and `dr-gd-twoquick` ×2.
- `dr-wt-twoquick` shifted its mark by 529 rows (17472 → 16943). The page was black there, so the
  result is unreadable.

### T-LIFE-08: two quick drops

- **W-T (`dr-wt-twoquick`):** two drops 3.6 s apart while reading.
  - Surface 17 (the open tab) got `attach … LinkError(closed / no-link)` ×4. It reattached only
    after the second link up.
  - The page was then **black from 11.2 s to the end of the recording**, and still black at +60 s:
    OCR 0 rows, before and after a small drag (`dr-wt-twoquick-after.jpg`, `…-after-60s`).
  - Only a fling brought it back.
  - This is the persistent V3-1 black page again.
- **G-D (`dr-gd-twoquick`):** 0 black frames, and the top row was kept (`9231 -> 9231`).
- Single drops: following W-T went black (the prune, above). Following G-D was clean.

### Jump to bottom mid-fling (user report)

- `mf-gd-1`: 12 taps sent 0.1, 0.3 and 0.6 s after the swipe command returned (4 each).
  `cx-wt-scroll`: 6 more taps on real Codex.
- **18 of 18 reached the bottom.** The button was gone 2.5 s later, and the log shows
  `settled -> following`.
- But **3 of 12 in `mf-gd-1` were black for 3.5-3.7 s**:
  - 7.6-11.3 s (0.1 s delay), 16.9-20.5 s (0.3 s), 92.2-95.8 s (0.1 s);
  - plus 0.5 s and 1.4 s runs;
  - sheet: `mf-gd-1-rep0-0.1s.jpg`.
- Caveat: the app logged `decelerating false` at every jump. I cannot prove from the log that a tap
  landed mid-deceleration. The video shows the fling still moving within about 0.1-0.2 s of the tap
  command.

### Scroll while streaming (G-04 frame log)

- Source: the in-app frame log `-CnxFrameLog`, surface e2e-t2, GEN at 50-100 rows/s with prunes
  (`verify6/framesum`-style output in `framelog-summary.json`). The raw ndjson is in tv6.
- Frame interval (dt) and main-thread work per frame, in ms:

  | Run | Phase | n | dt p50 | dt p95 | dt p99 | dt max | Frames > 33.4 ms | Work p50 | Work p95 | Work p99 | Work max |
  | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
  | G-D, 200 flings | interacting+streaming | 15616 | 16.7 | 16.7 | 19.6 | 84.5 | 91 | 0.04 | 0.58 | 0.95 | 2.24 |
  | G-D, 200 flings | following+streaming | 10532 | 16.7 | 16.7 | 18.0 | 65.9 | 60 | 0.72 | 1.55 | 2.17 | **12.53** |
  | G-D, 200 flings | reading+streaming | 2749 | 16.7 | 16.7 | 16.7 | 62.2 | – | 0.05 | 0.13 | 1.24 | 2.86 |
  | W-T | interacting+streaming | 2771 | 16.7 | 16.7 | 21.8 | 69.5 | – | 0.04 | 0.59 | 0.89 | 1.91 |

- Laptop 15-min load at the time: 46-60. **INVALID for thresholds.**
- The work numbers would meet T-SCROLL-06 (p99 ≤ 4, max ≤ 12) while interacting.
- The frame log keeps ticking at 16.7 ms while the surface shows black. Its numbers say nothing about
  the black-page defects.
- Not run: a `yes | head` flood with the frame log. The real-Codex window `cx-wt-scroll` is in the
  ndjson but was not summarized separately.
- Device smoothness: T-DEV, pending.

### D7

- `cx-wt-follow` (new tab, real Codex, W-T, 75 s hands-off, 60 fps).
- Codex only started streaming at 63.8 s. The Mac's model link fell back ("Falling back from
  WebSockets to HTTPS"), so only about 12 s of following was recorded.
- motion.py reports 3 one-frame jumps of 1, 2 and 3 rows at 74.8, 74.9 and 75.75 s (conf 1.0). I
  could not confirm them by eye in the split frames (`d7-flash-75.75.jpg`).
- The recording fails the 34 ms rule (18.8 %).
- Not enough streaming time to judge. Re-run when the Mac's Codex streams steadily.

### V5-6 / T-TABS-01: cards

- `grid-v56.jpg`: the t2 card shows its newest rows, GEN-59978..60000, the prompt and the composer.
  This matches the Mac.
- The active t1 card shows the page's top crop (items 400-410), as qa-round-6 states (kit U4).
  T-TABS-01 / T-REG-1350-a stay FAIL for the active card.

### New: t1 phone ≠ Mac

- After launch, t1's page (surface 16, which reattaches at the Mac's 53x39, "asked 53x42 was
  overruled") showed an older Codex list (desert items 381-416) with no prompt.
- The Mac's screen showed the forest turn. When I typed a rivers prompt on the phone, it reached the
  Mac, but the phone never showed it.
- Over the next minutes the phone page advanced through old desert items at about 2 per second, then
  rivers items, ending about 500 items behind the Mac.
- It then **froze at item 206 for 65 s** while the Mac had finished at item 700:
  - `d7-t1-follow-gt` shows 0 moves;
  - `events.jsonl` `t1_lag` and `t1_compare*`;
  - `t1-*.jpg`.
- A relaunch fixed it: the t1 card then matched the Mac (`d5-pair.jpg`).
- Load was extreme (1-min 100-177) during this. The t2 and new-tab pages kept up in the same
  minutes, so this is not general starvation. Cause not isolated. It may be tied to the 39-vs-42-row
  overrule (V5-4/D4).

### Reconnect time (T-LIFE-12)

- Hostd `link up` came 2.5-4.5 s after each kill, median about 3.2 s, over 13 kills.
- Hostd itself restarts 1.5-2.4 s after the kill.

### One replay per reattach (T-SIZE-02)

- 21 reattaches and 2 transport switches.
- Each logs exactly one `mirror reset cause=reattach` per surface. 0 `resized-event`.
- t1 still logs `reattach at the Mac's 53x39 (asked 53x42 was overruled)` (V5-4).

### D5 / T-TABS-02

- Terminate and relaunch, then open the grid 3.5 s later. Both cards show content at +1 s
  (`d5-pair.jpg`).

### V3-2 / T-LIFE-10

- After drops, output kept arriving on t2: GEN advanced, and a Jump landed at the live bottom.
- The new Codex tab's tail was 50 items behind the Mac 4 s after opening, under load 70
  (`final_compare_codex`).

### V3-3

- `dr-wt-midfling`: kill sent with the fling. The fling decelerated from GEN-5773 to GEN-5655, and
  the page stayed there after the reattach (`15598 -> 15598`). 0 black frames.

### V3-4 / T-TABS-14

- Grid open: 0 composer, Return or Scroll to bottom elements inside the cards (`ax-grid-open.txt`).
- Page settled: the kit's `Close …` at (372, 0), `Page Menu` and `Reload` are exposed
  (`ax-page-settled.txt`), as in round 5.

### V2-1 / T-TABS-03

- 4 grid trips while real Codex streamed (W-T): 0 black frames, 0 foreign frames
  (`grid-trips-wt-motion.json`).
- The phone tail was 30 items behind the Mac at compare (timing invalid). Correct rows, no garble.

### T-LIFE-16

- WireGuard → WebRTC and back.
- One `mirror reset cause=reattach` per surface each way. 0 unknown. Reading marks kept.
- The old link was dropped only by the 45 s keepalive timeout after the switch (hostd
  `keepalive timed out`). Minor.

## New defects

1. **V6-2 (disruptive): following at the history cap goes black after every prune.**
   - Repro: in a tab at the cap (about 17.7k rows), run `for i in $(seq 1 60000); do echo GEN-$i;
     sleep 0.01; done` and leave the page at the live bottom.
   - Each prune (rows 17740 → 16854, about every 18 s) blacks out the terminal for 1-11.5 s, and it
     often stays black until a touch.
   - `jb-hold-gd` 5 of 5; `dr-wt-follow`. Both transports.
2. **V6-3 (disruptive): Jump to bottom shows a black terminal for 3-5.6 s.**
   - Seen on 3 of 20 jumps at the cap, 3 of 12 mid-fling jumps, and 1 of 6 in a 600-row Codex tab
     with no prune.
   - This is V5-1, worse than the 28 ms of round 5.
3. **V6-4 (disruptive): persistent black page after two quick drops on W-T.** The page was still
   black at +60 s; a fling restored it (`dr-wt-twoquick`).
4. **V5-2 (still open):** a fling that starts from the live bottom at the moment of a prune snaps
   back to following, with a 1.1 s black frame.
5. **V2-3 (still open):** a drop while the Mac prunes can restore the mark by the totals difference.
   The page lands 116 rows off.
6. **V6-1 (noticeable): a 6-11 pt gap under the last row after the composer draft shrinks.**
7. **V6-5 (disruptive, cause open): t1's page diverged from the Mac.** It showed old Codex output,
   then froze 500 items behind the Mac until a relaunch.

## Not done

- W-D, G-T, G-R and netsim.
- M-INTEG, M-ROWS (rows.py) and a `yes | head` flood frame-log window.
- A Claude Code session.
- 60 s of steady Codex streaming for D7: the Mac's model link was degraded.
- The 20-minute free play counted toward T-ADV is about 75 min of mixed scripted and unscripted runs.

## Rig left

- `cnx-termqa-1` runs `3a634b2a` (sha256 above), launched with `-CnxFrameLog`. It is paired on
  WireGuard (G-D, Relay only still on), in workspace e2e-143502.
- A third tab `proj` (`term_80dfe927…`) that I created runs Codex in `~/cnx-ios-e2e/termqa/proj`.
- `~/cnx-ios-e2e/termqa-state.json` `app_path` points to my build in
  `cmuxterm-hq-worktrees/feat-cnx-ios-termverify6`. The Mac side is unchanged and its hostd is up.
- The mini's disk was not written beyond the logs.
