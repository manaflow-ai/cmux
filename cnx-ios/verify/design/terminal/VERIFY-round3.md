# Terminal verify round 3 (fresh adversarial verifier, 2026-10-14 17:00-17:40 PT)

**Verdict: REJECT.** V2-1 looks fixed (grid trips). D5 is not fixed: the card has
no spinner, but it is blank. V2-3 is fixed only when the phone's history matches
the Mac's. In 5 of 9 read-drops it failed, and 3 of those left a blank or dead
terminal. Three new disruptive defects (V3-1, V3-2, V3-3).

## Build and rig

- SHA `5212401851` (`git rev-parse` in the termqa worktree; tracked tree clean).
  I could not prove the app installed on the simulator was this SHA: its binary
  was 16:52, before `405bba87`/`595ad952` were committed. So I built from this
  worktree (Demo, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`,
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG CNX_DEMO`, DerivedData
  `/tmp/termverify3-dd`) and installed it on `cnx-termqa-1` (bundle `dev.cmux.cnx`,
  binary sha256 `930583596338…`). Launched 17:02.
- Mac: `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2, Codex `gpt-6-astra max` in
  `e2e-t1`. Path G-T (WireGuard, relay) except the WebRTC runs (W-T, relay only).
- Everything was typed or tapped on the phone through the app (paste into the
  composer, soft keyboard, the tab grid). The Mac CLI only read screens and
  injected `pkill -9 cnx-hostd` drops.
- Recordings: `~/cnx-ios-e2e/termqa-raw/tv3-*.mp4` (rig-local, laptop).
  Committed evidence is in `verify3/`: screenshots, contact sheets, motion.py
  summaries, filtered app logs, and `loads.jsonl` (load average at the start and
  end of every capture).
- **Load:** the 15-min load average was 18-24 (over 12) for every capture up to
  17:20 (a1, a2, d5, r1-deep, r1-shallow, r1-deep2, r2-fling). It peaked at 65/31/24
  during a2. From 17:21 it was 10-16; it dropped under 12 only for the last runs
  (r2-fling2, webrtc-read, webrtc-read2, wg-read3: 10.1-11.9). **Every timing
  criterion is INVALID this round.** Every recording also fails the §1.4
  34 ms-gap rule (12-75 % of gaps over 34 ms). Only correctness is judged.

## Verdicts per ACCEPTANCE ID touched

| ID | Verdict | Evidence and numbers |
| --- | --- | --- |
| T-TABS-03 (grid shrink/zoom while streaming) | **PASS (correctness); timing invalid** | `tv3-a1-grid-diffs` (9 trips while Codex streamed 3 unified diffs of a 240-line file, approvals answered on the phone; grid hold 0.2-2.5 s, page hold 0.3-4 s): motion.py 30 fps 0 black, 0 flashes (`verify3/a1-motion.json`). `tv3-a2-grid-kb` (12 trips, grid hold 0.1-3 s, 4 of them with the composer tapped 0.15 s into the zoom-in, while Codex streamed 150 paragraphs): 0 black, 0 flashes (`verify3/tv3-a2-grid-kb-motion.json`). Position error and cols-reflow were not measured (no per-frame card tracker). |
| T-SIZE-01 (no spurious resize: grid zoom) | **PASS** for the grid and keyboard-in-zoom | App log 17:02:17-17:16:08 covered all 21 trips (a1 + a2) and keyboard toggles: 0 `mirror rows` changes (151 throughout), 0 `resize`, 0 `mirror reset`. The only resize lines are at launch (`cause=first`). Rotation: BLOCKED (below). |
| T-FOLLOW-01/02 (after grid trips) | **PASS (correctness)** | a1 end: phone bottom = Mac bottom (`Worked for 5m 24s · done 5:08 PM`, `› Ask Codex…`, status line; `verify3/tv3-a1-grid-diffs-end.jpg`). a2: the prompt and status line stayed under the stream in every 1 fps frame (`verify3/tv3-a2-grid-kb-02.jpg`). rows.py 10 fps on a2 102-162 s: ids 2..150, 0 foreign, 1 backstep at 124.0 s. That backstep is in the grid card's tiny text during a trip, not the page (`verify3/a2-rows.json`). Lag at bottom not judged (load). |
| T-REG (V2-1 garble) | **PASS (green on 5212401851)** | No stale rows above the prompt in 21 trips, at the end of 2 turns, or in 22 mid-stream phone/Mac bottom comparisons (`tv3-a2-grid-kb-snaps`). Red side not re-run by me. |
| T-TABS-01 (card content) | **FAIL** | Opened tabs update live in the grid (a2 sheets). The never-opened `e2e-t2` card is blank (see T-TABS-02), so it does not show the page's content. |
| T-TABS-02 (D5) | **FAIL** | Launched 17:02; `e2e-t2` was not opened. Grid open 5 s, link up: the card is **black with only a cursor block** at the top-left (`verify3/tv3-d5-grid5s.jpg`). It stayed like that through 3+ minutes of grid trips in a1/a2 (`verify3/tv3-dbg1.jpg`). The Mac's t2 screen is full (40 coloured `color NN 漢字 emoji…` lines, `COLORS-DONE`, prompt; `cmux terminal … screen read`). After opening t2 once, its card shows the content (`tv3-d5-grid-after-t2.jpg`). The spinner is gone, but the card is blank, not "a snapshot ≤ 3 s, else a static **labeled** placeholder". The implementer's "green" shot `r6-tabs-grid-d5c.jpg` shows the same blank card. |
| T-TABS-06 (new terminal from +) | **PASS (correctness)** | + → New Terminal: shell prompt on the page at 3 s; the new card shows the prompt in the grid at 0.6 s and 3.6 s (`tv3-d5-newtab*`, rig shots). Timing invalid. |
| T-TABS-08 (close an idle shell) | **PASS (correctness)** | Close on the new idle tab: gone at 0.5 s, no confirmation, grid back to 2 tabs (`tv3-d5-close-*`, rig shots). Mac list not timed. |
| T-TABS-14 (hidden controls) | **FAIL** | AX dump with the grid open lists `Scroll to bottom`, `Return` (`terminal.composer.send`) and a `terminal.composer.field` inside the zoomed-out e2e-t1 card (16 pt frames at y 406-431). `Close e2e-t1` is still exposed while the page is settled. The Back, Page Menu, Reload and Tabs buttons are exposed under the open keyboard (y 792, keyboard top 566). The rig's `find(ident="terminal.composer.field")` picked the hidden card copy at (42, 431) and tapped the card. |
| T-LIFE-08 (no blank on drop) | **FAIL** | `tv3-r1-deep`: 9 black frames, 23.33-23.57 s (motion.py; `verify3/r1-deep-motion.json`, `tv3-r1-deep-drop.jpg`). `tv3-r3-webrtc-read`: 13 black frames, 11.63-12.03 s, with a cursor block only (`verify3/tv3-r3-webrtc-black.jpg`). Plus the persistent blank pages of V3-1 (≥ 18 s and > 60 s). Drops while following or reading on a matching history: 0 black (`two8`, `two15`, `r1-shallow`). |
| T-LIFE-09 (resume at the same anchored row) | **FAIL** (4 of 9 kept) | Kept (top rows identical by OCR, Jump shown): `r1-shallow` (841→841 of 1118), `r1-deep2` (113→113), `two8` (two drops 12 s apart, 388→388 both), `two15` (731→731). Lost: `r1-deep` (row 113 of 3602 → page at the top of the Mac's history, then black, then the live bottom with no Jump button), `webrtc-read` (row 801: item 1 → item 267-300, no Jump), `webrtc-read2` (837: item 34 → 267), `wg-read3` (835: item 32 → 267, **WireGuard**, so this is not transport-specific), `streamread2` (blank, V3-1). The log shows the cause pattern: `reading mark restored row 835 -> 935 of 1218`, then the page ends at the live bottom. It fails whenever the replay's row count differs from the phone's (1118 vs 1218 or 2154 or 3602). Drop during a fling: V3-3. |
| T-LIFE-10 (no lost content after a drop) | **FAIL** | V3-2: after a drop while reading during a Codex stream, the phone's output stopped at item 168 while the Mac reached 300. Input still reached the Mac (`› zq` appeared on the Mac, not on the phone). Only the next drop repaired it. |
| T-LIFE-15 / T-LIFE-16 (WebRTC and WireGuard) | **FAIL** on W-T (V2-3 2 of 2) and on G-T (see T-LIFE-09). The transport switch reattached once with no visible blank (17:31:51 log). |
| T-SCROLL-11 (no blank region) | **FAIL** | V3-1: the page rests on a blank document region after a drop; a pull shows rows above (`verify3/tv3-r2-stuck-pull.jpg`). |
| T-FOLLOW-05 (Jump shown iff not following) | **FAIL** | After V3-1 and the `webrtc-read*` restores, the page is not at the bottom (blank, or the bottom of an older replay) and Jump to bottom is not shown. In V3-2 the page at item 168 shows no Jump while the Mac is at 300. |
| T-SIZE-02 (one replay per attach) | **FAIL (unchanged D4/V2-4)** | Every drop: `mirror reset cause=reattach`, then `cause=resized-event (rows 39, last size asked 53x42)` (all logs in `verify3/*.log`). Every reattach also logs `attach surface 14: LinkError(code: "attach", message: "unknown surface 14")`. |
| T-ADV-01 (partial) | **FAIL** | Findings V3-1..V3-4. |
| Rotation during a trip (T-TABS-03 ×rotate, T-SIZE-04) | **BLOCKED** | The headless simulator has no rotation without Simulator.app's menu, and launching or driving Simulator.app would take focus on this Mac. Needs a headless rotate tool or a cmux mini. |

## New defects

**V3-1 (disruptive): blank terminal after a drop while reading; it stays blank
until the user scrolls.**
- Repro A (2 of 2 seen): read at the top of history (12-15 flings, then a slow
  drag to settle; log `settled -> reading(row 113…)`), then `pkill -9 cnx-hostd`.
  `tv3-r2-fling` 17:20:06: `reading mark restored row 113 -> 1149 of 2154`, then
  `mirror reset cause=resized-event`, then `reading mark row 1149 of 2154: none`.
  The page is black for over 60 s with no Jump button (`verify3/tv3-r2-fling-post.jpg`).
  A pull down shows item 112 above (`tv3-r2-stuck-pull.jpg`).
- Repro B: read about 2 screens up while Codex streams 300 lines, then drop
  (`tv3-r2-streamread2`, 17:28:29: `restored row 818 -> 1514 of 1849`). The terminal
  is black from about 5 s after the drop until the end of the recording (≥ 18 s;
  `verify3/tv3-r2-streamread2.jpg`).
- Likely cause: the mark is placed in the first (53x42) replay by the end-distance
  fallback. Then the D4 `resized-event` replay (53x39, fewer rows) resets the
  mirror. The new mark reads blank rows, becomes nil, and the offset is left past
  the content. motion.py misses this kind of persistent black, because the run's
  median `lit` is low.

**V3-2 (disruptive): after a drop while reading during a stream, phone output
stops; input still works.**
- `tv3-r2-streamread`: drop at 17:24:26 while reading during a 300-line Codex
  answer; reattach and `reading mark restored row 867 -> 849 of 1118`. After that
  the phone's last rows stay at item 168, with no Jump button
  (`verify3/tv3-r2-streamread-final2.jpg`), while the Mac reaches 300 and "done".
  Typing `zq` on the phone appeared on the Mac's prompt but never on the phone
  (`tv3-r2-stuck-typed.jpg`). A grid trip did not repair it. A second drop did.
  The app logged nothing after 17:24:28, and its main thread was idle (`sample`).
  Seen 1 of 2.

**V3-3 (disruptive): a drop during a fling, or after one, throws away the
reader's position.**
- `tv3-r2-fling2`: follow a 300-line stream, fling up, then drop mid-fling. The
  held frame shows items 127-160 ("Reattaching…"). After the replay the page is
  at a different, older answer at the top of history ("Earlier messages are
  available…", item 92 of the previous answer). No mark is taken, because the
  state was not `reading` at the reset (`TerminalViewController` creates a mark
  only for `.reading`, and `freezeLastFrame` skips while decelerating).

**V3-4 (noticeable): the hidden copies of controls in grid cards catch rig taps
(T-TABS-14).** Listed above. The rig's helper tapped the hidden composer in the
card, which opened the page. A VoiceOver user would hit the same controls.

## Notes on the implementer's claims

- "V2-3 green 2 of 2" holds only while the phone's history row count equals the
  replay's. Once the totals diverge (1118 vs 1218 here after about 20 minutes; 3602
  vs 2154 after a long session, which was the original V2-3 repro), 5 of 5 read-drops
  lose the position, 3 of them with a black or dead terminal.
- "D5 green: saved frame, no spinner": the saved frame is a blank screen with a
  cursor; the claim's own screenshot shows it.
- V2-1: I could not break it with 21 trips at varied timing, with diff streams,
  approvals mid-turn, and the keyboard raised during the zoom-in.

## Not done

- Rotation during a trip, and rotation generally: BLOCKED (focus rule; no headless rotate).
- Timing rows (T-LIFE-01/03/12, T-FOLLOW-06, T-TABS-01 ≤ 1 s): INVALID (load over 12; frame gaps).
- Red-on-old-SHA re-runs (T-REG): not re-run.

The rig was left running on WireGuard (Settings → Transport restored), with
`e2e-t1` open at the bottom and Codex idle. My build is installed on the
simulator (DerivedData `/tmp/termverify3-dd`).
