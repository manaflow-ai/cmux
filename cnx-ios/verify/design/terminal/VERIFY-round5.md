# Terminal verify round 5 (fresh adversarial verifier, 2026-10-14 21:09-22:52 PT)

**Verdict: REJECT.** Several claims hold: reconnect, one replay per reattach, the
"unknown surface" fix, D5, V3-2, V3-3, and our own hidden controls. Grid trips
(V2-1) still pass. Three claims fail:

- **V2-3 still fails on both transports.** The reading position moves about 900 rows
  when a drop happens while the Mac's history is evicting rows at the top.
- **The page went black on a reattach.** The terminal was black for one source frame
  shown for about 220 ms, during the reattach after the second of two quick drops
  (T-LIFE-08). The same black-frame glitch also shows on a Jump-to-bottom tap.
- **New disruptive defect (V5-2).** While output streams, an upward fling ended with
  the page jumping to the live bottom.

Criteria: `ACCEPTANCE.md` on `origin/feat-cnx-ios-termqa` (verbatim, unchanged).

## Build, rig and load

- Phone: simulator `cnx-termqa-1` (C906E217-BD51-4BC7-82D8-584AB67695B7), bundle
  `dev.cmux.cnx`. The installed binary's sha256 is `10e5721c5f7e…4a75`, as required.
  It is identical to `cnx-ios/build/dd/…/CnxApp` (20:11) in the termqa worktree, which
  sits at `671704a1`. The only changes after `c622a001` are docs and `killtest.py`, so I
  did not rebuild.
- Mac: `cnx-e2e-604fc689` on mini-cmuxs-mac-mini-2. `cmux-tui.version` and
  `acpmux.version` both read commit `e1edf234`. `cnx-hostd.version` has key
  `fd86929d78f0e4da`, commit 604fc689, sha256 `91b00f39…`.
- Stimulus: everything was typed or pasted on the phone through the composer, or done
  with taps and swipes through `axe` on this simulator. That includes the Codex prompts,
  `seq`, the generator loops and the `sleep … python3` probe. The Mac side was used only
  for oracle reads (`terminal … screen read`, the hostd log) and for fault injection
  (`pkill -9 -f …/cnx-hostd`, 17 times). Real Codex `gpt-6-astra max`.
- Paths: G-T = WireGuard + Relay only, which reported `relay`/`turn`. W-T = WebRTC + Relay
  only, which reported `webRTC … turn` (21:35:46-22:04). Switching used Settings →
  Transport on the phone.
- **Load:** the laptop's 15-min load was 12.1-31 for every capture (1-min 6.5-57).
  `events.jsonl` has the load at every `rec_start`, `rec_stop` and `kill`. **Every timing
  row is INVALID this round.** Only correctness is judged. Every recording also fails the
  §1.4 34 ms-gap rule: 2-77 % of source gaps are over 34 ms (`*-motion.json` → `source`).
- Artifacts: `verify5/`. It holds screenshots, contact sheets and extracted frames, the
  summaries from motion.py (30 fps resample, band 70 pt-0.8; trimmed to summary plus
  black/flash frames), filtered app logs, `events.jsonl` (every phase, kill, drop report
  and compare), `touch-*.jsonl` (M-TOUCH) and `raw-videos.txt` (sha256 prefixes). The raw
  mp4s stay in `~/cnx-ios-e2e/termqa-raw/tv5/` on the laptop (632 MB).

## Drops (17 kills, `events.jsonl` kind `drop_report`)

| Time | Gap to previous kill | Path | State | hostd `starting` | `link up` after kill | Replays on t1 | `unknown surface` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 21:13:22 | - | G-T | following, after creating and closing a tab | 1.13 s | 3.96 s | 1 | 0 |
| 21:18:15 | 292 s | G-T | reading row 803/1129 (s1) | 1.10 | 2.01 | 1 | 0 |
| 21:20:37 | 142 s | G-T | reading mid-stream (s2) | 1.34 | 2.21 | 1 | 0 |
| 21:21:46 | 69 s | G-T | mid-fling, streaming (s3) | 0.95 | 2.07 | 1 | 0 |
| 21:25:31 | 226 s | G-T | fling at the reattach (s3b) | 1.07 | 2.55 | 1 | 0 |
| 21:30:47 | 316 s | G-T | reading at the top of history (s4) | 1.33 | 2.48 | 1 | 0 |
| 21:30:51 | **3.4 s** | G-T | same, second drop | 2.03 | 2.87 | 1 | 0 |
| 21:43:47 | - | W-T | following Codex (s6) | 1.25 | 2.43 | 1 | 0 |
| 21:43:58 | **11 s** | W-T | following, then 4 grid trips | 1.27 | 2.29 | 1 | 0 |
| 21:46:02 | 124 s | W-T | reading mid-stream (s7) | 1.28 | 3.02 | 1 | 0 |
| 21:46:27 | **25 s** | W-T | same | 1.04 | 2.03 | 1 | 0 |
| 21:56:10 | - | W-T | t2 shallow read (s8) | 1.08 | 2.47 | 1 | 0 |
| 21:57:13 | 63 s | W-T | t2 mid (s8) | 1.17 | 2.42 | 1 | 0 |
| 21:58:54 | 100 s | W-T | t2 deep (s8) | 1.35 | 2.38 | 1 | 0 |
| 22:00:41 | 108 s | W-T | t2 read while history evicts (s9-wt) | 1.31 | 2.41 | 1 | 0 |
| 22:06:44 | - | G-T | same (s9-gt) | 1.01 | 2.15 | 1 | 0 |
| 22:49:52 | - | G-T | Codex working, then 6 grid trips (s11) | 1.35 | 2.19 | 1 | 0 |

- `link up` is from hostd's log on the mini; the mini's clock is NTP-synced. The phone's
  `link connected(` agreed to 0.04 s wherever it was logged.
- **Reconnect:** 2.01-3.96 s after the kill, median 2.4 s. With kills under 60 s apart:
  2.87, 2.29 and 2.03 s. Under 3 s in 16 of 17; the first drop took 3.96 s. "Within about
  2 s" holds only as a median of about 2.4 s. hostd itself starts 0.95-2.03 s after the
  kill, and `link up` comes 0.3-2.8 s after that. Timing is INVALID (load).
- **Replays:** each drop and each transport switch logs exactly one
  `mirror reset cause=reattach` per surface. There are 0 `cause=resized-event` after a
  reattach (`grep resized-event verify5/*.log`). The only `resized-event` came when the
  phone created a new tab (V5-4).
- **`unknown surface`:** 0 occurrences in 17 reattaches and 2 transport switches. The
  check came after a + → New Terminal and a Close at 21:12:47-21:13:04 (`k01-idle-drop.log`).

## Verdicts per ACCEPTANCE ID touched

| ID | Verdict | Evidence and numbers |
| --- | --- | --- |
| T-LIFE-08 (no blank on drop) | **FAIL** | `s4-deep-2drops-gt`, second of two drops 3.4 s apart, reading at the top of history (G-T). One source frame at 33.66 s has the terminal band fully black (`lit` 0.0), and the next source frame is at 33.88 s, so it was **shown for about 220 ms**. The composer moves up 13 pt in that frame and Jump to bottom vanishes, then both come back (`verify5/s4-drop2-black-frame.jpg`, `s4-motion.json`). In the other 16 drops: 0 black frames and no error text. Persistent black (V3-1): 0 of 17. |
| V3-1 (no black page after a drop while reading) | **PASS for the persistent form; the single black frame above fails T-LIFE-08** | 12 read-drops at depths from 1 screen to the top of history: the page was never left black. Every post-drop OCR at +10 s and +18 s shows rows (`s1/s2/s4/s7/s8/s9-*-post*.jpg`). |
| T-LIFE-09 / V2-3 (resume at the same row) | **FAIL (both transports)** | Kept in 12 of 14 read-drops, where the top row id or text was identical by OCR before and after. That includes s2, where the totals differed (`1209 of 1347` → `1209 of 1363`); there the stream only appended at the bottom. **Lost in 2 of 2 when the Mac's history evicts rows at the top while reading.** Repro: run `seq -f HIST-%06g 1 30000` in t2 (both sides hold about 17.3k rows at the cap), then start `for i in $(seq 1 4000); do echo GEN-$i; sleep 0.01; done`, fling 12×, settle and drop. **W-T** (`s9-evict-readdrop-wt`): top HIST-029100 → HIST-029987, about **887 rows lower**; log `reading mark row 15047 of 17322: kept`, then `restored row 15047 -> 15047 of 17493` (`verify5/s9-wt-pre-post.jpg`). **G-T** (`s9-evict-readdrop-gt`): HIST-029783 → GEN-668, about 900 rows lower; `15140 of 17318` → `15140 of 17414` (`verify5/s9-gt-pre-post.jpg`). The mark is restored by row index, not by content, so the page now shows different rows. Following drops (s6 ×2, s11): the page was at the live bottom after link up (compares in `events.jsonl`). |
| T-LIFE-10 / V3-2 (no lost or frozen output after a drop) | **PASS (tail check); M-INTEG not run** | Drops while reading mid-stream (s2 G-T, s7 W-T ×2): output kept arriving. After Jump to bottom the phone's tail matched the Mac's to within 0-3 items of the Codex stream (OCR then the Mac read, about 1 s apart). s7 ended on `500.` / `Worked for 8m 12s` on both sides (`verify5/s7-check-now.jpg`). M-INTEG (G-09 CRC export) was not run. |
| V3-3 (drop mid-fling keeps the place) | **PASS (2 of 2)** | `s3-flingdrop-gt`: fling from the live bottom (item 377) with the kill sent at the same moment. The fling decelerated to item 265 while showing "Reattaching…", and the page stayed at 265 after the replay (`reading mark row 1506 of 1723: kept` → `1506`; `verify5/s3-sheet-4.5-9.5s.jpg`). `s3b`: fling sent about 1.6 s after the kill, so it landed in the reattach window: mark kept and the page stayed put (`s3b-sheet-5-10s.jpg`). |
| T-LIFE-15 (relay paths) | **FAIL** | Through T-LIFE-09 on W-T and G-T. G-R not run. |
| T-LIFE-16 (transport switch) | **PASS (correctness)** | WG→WebRTC at 21:35:16 and back at 22:04:02. Each logged one `mirror reset cause=reattach` per surface. The reading mark was kept (`113 → 113 of 1723`), and the page's top rows matched after reopening (`s5-t1-after-switch.jpg`). 0 black frames (`s5-transport-to-webrtc-motion.json`). M-INTEG not run. |
| T-LIFE-12 (reconnect time) | **INVALID** | Load. Numbers are in the drop table above. |
| T-SIZE-02 / T-REG-D4 (one replay per attach) | **PASS (19 of 19 reattaches; the row needs 30)** | 17 drops and 2 transport switches, 1 replay each, 0 `resized-event` after a reattach. Red side not re-run. Separate finding V5-4: an extra replay of the open tab when a new tab is created. |
| T-SCROLL-11 (no blank region) | **PASS (limited)** | After each of the 5 t2 restores and 5 t1 restores, a pull of 200 pt showed contiguous rows (`s8-*-pulled.jpg`). No full S-SWEEP was run. |
| T-SCROLL-04 (no surprise resume-following) | **FAIL (new, V5-2)** | `s9-evict-readdrop-gt` 7.0-7.4 s (22:06:13): an **upward** fling was decelerating through HIST-0297xx, with no finger down (touches at 5.70 s and 8.40 s). The page went black for one frame, then jumped about 600 rows to the live bottom (GEN-568…, cursor block). The log says `scroll: a fling reached the bottom -> following` (`verify5/s9-gt-fling-to-bottom-5.0-7.7s.jpg`, `s9-gt-jump-window.log`). Seen 1 time in about 85 flings, while output streamed at about 100 lines/s. |
| T-SCROLL-09 (Jump to bottom: 0 foreign frames) | **FAIL (new, V5-1)** | `s2-midstream-readdrop-gt` 33.48 s: tapping Jump to bottom shows one fully black terminal frame (about 28 ms), and the composer drops 13 pt, then the page lands at the bottom (`verify5/s2-jump-black-frame-1005.jpg`). |
| T-FOLLOW-05 (Jump iff not following) | **PASS** | After every read-drop the button was shown at +10 s and +18 s (14 of 14). After every Jump tap it was gone once the page reached the bottom. |
| T-FOLLOW-03/04 (following, no one-frame jump or foreign frame) | **Observation, not attributed** | `s11` 126.90 s (G-T, following Codex): one frame shows row `95.` and the next frame drops it, so the content steps up one row and back (`verify5/s11-flash-126.9s.jpg`). This may be Codex redrawing its own live area. T-FOLLOW-02's M-MAC diff is needed to decide. Not counted as a defect. |
| T-TABS-03 / T-REG V2-1 (grid trips while streaming) | **PASS (correctness)** | `s6`: 4 trips 2.6 s after a drop, W-T, Codex streaming. Phone bottom = Mac bottom at +4 s and +10 s, with the phone 0-3 items behind (`s6-after-grid.jpg`); the recording of this run was not finalized (rig). `s11`: drop, then 6 trips with grid holds of 0.6-1.6 s while Codex streamed 300 lines, G-T. 0 black frames, and phone bottom = Mac bottom in 3 compares (`s11-bottom-*.jpg`, `s11-gt-drop-grid-working-motion.json`). No stale rows above the prompt. |
| T-TABS-01 (card shows the page's content) | **FAIL** | Cards of other tabs update live while the grid is open (D5 below). But the **active tab's card shows the top two thirds of the page**. It ended at item 298 while the page's live bottom was `300.` / `done 5:30 PM` / `› Ask Codex to do anything` / status line, so the newest 7 rows were missing (`verify5/s01-card1z.png`, `s01-grid.jpg`). The same happened after relaunch: the card ended at 497 while the page showed 500 and the prompt (`d5b-grid-sequence.jpg`). This is the T-REG-1350-a symptom: the card does not show Codex's prompt. |
| T-TABS-02 / T-REG-D5 (D5) | **PASS** | t2's command was typed on the phone, then the app was terminated and relaunched. t2 was not opened in the new launch, and the grid was opened 3.4 s after launch. The t2 card showed the Mac's current screen (D5MARK-1..30 and the pending command) in its first grid frame, ≤ 0.9 s into the recording (`d5b-grid-sequence.jpg`). With the grid left open, the Mac printed `D5T 1792039949.66`, and the card changed at video 38.1 s = 949.0 laptop time. The lag is within the mini/laptop clock skew of about 1 s. The first run (`d5-relaunch-grid`) showed a black card that was correct, because the Mac's screen was cleared, and it updated to the marks once they printed (card change at 46.3 s). |
| T-TABS-14 / V3-4 (hidden controls) | **cnx-owned: PASS. Row as a whole: FAIL (kit, U8)** | Grid open: 0 composer, Return or Scroll to bottom elements inside the cards (`verify5/ax-grid-open.txt`). With the page settled or the keyboard up, the kit's `Close e2e-t1` at (372, 0) is exposed. With the keyboard up, Back, Page Menu, Reload and Tabs at y 792 are exposed under the keyboard (top 583) (`ax-page-settled.txt`, `ax-page-keyboard.txt`). These are filed upstream as U8. Also kit-side: the visible close button on the non-active `e2e-t2` card is absent from the AX tree in 2 of 3 dumps. |
| "unknown surface" on reattach | **PASS** | 0 in 19 reattaches, including after creating and closing a tab (`k01-idle-drop.log`). V5-5 below covers the closed tab's leftover surface. |
| T-REG-D3 | **FAIL** | Through T-LIFE-08 (the 220 ms black frame). The error text part is fixed. |
| T-REG-1350-a | **FAIL** | Through T-TABS-01 (the active card crops the prompt). |
| Other T-REG rows (red-on-old-SHA) | **BLOCKED** | The G-17 red-run tooling is absent, and old SHAs were not rebuilt. |
| T-ADV-01 | **FAIL** | V5-1, V5-2, the V2-3 eviction case, V5-4, V5-6. About 100 minutes of mixed play on the rig, Codex running in 5 turns. |
| Rotation (T-SIZE-04) | **N/A here** | The app is portrait-only (qa-round-5). |

## New defects

**V2-3 (still disruptive): a drop while the Mac evicts history loses the reading place.**
Repro (both transports): in a tab with history at the cap (`seq -f HIST-%06g 1 30000`,
about 17.3k rows on each side), start a streaming loop
(`for i in $(seq 1 4000); do echo GEN-$i; sleep 0.01; done`). Fling up about 12 times,
settle, then `pkill -9 cnx-hostd`. The page comes back about 900 rows lower.
`reading mark restored row N -> N of M`: the row index is reused, but rows were evicted at
the top, so a different text sits at that index. Artifacts: `s9-wt-pre-post.jpg`,
`s9-gt-pre-post.jpg`, `s9-wt.log`, `s9-gt.log`.

**V5-1 (disruptive at a reattach, noticeable at a Jump tap): one fully black terminal
frame with a composer bounce.**
- The terminal band goes black for exactly one source frame. In that frame the composer
  and Jump button move about 13 pt (the Jump button vanishes), then they animate back.
- Seen at the reattach of the second of two quick drops (s4, about 220 ms on screen), on a
  Jump to bottom tap (s2, about 28 ms), and at V5-2's jump (s9-gt).
- The signature suggests the whole page, terminal and composer bar, is laid out again for
  a frame. Artifacts: `s4-drop2-black-frame.jpg`, `s2-jump-black-frame-1005.jpg`,
  `s9gt` in `s9-gt-fling-to-bottom-5.0-7.7s.jpg`.

**V5-2 (disruptive): an upward fling during fast output ends at the live bottom.** In t2, while
reading during the `GEN` loop (about 100 lines/s), a fling toward older history was
decelerating when the page snapped to the live bottom. The log says
`a fling reached the bottom -> following`. Seen 1 time in about 85 flings. Artifact:
`s9-gt-fling-to-bottom-5.0-7.7s.jpg`, log 22:06:13.237.

**V5-4 (minor): creating a tab replays the open tab.** + → New Terminal at 21:12:47 logged
`surface 16: mirror reset cause=resized-event (rows 39, last size asked 53x42)` for
e2e-t1, which is not the new tab (`k01-idle-drop.log`). Every reattach also logs
`reattach at the Mac's 53x39 (asked 53x42 was overruled)`: the Mac keeps 39 rows while the
phone asks for 42.

**V5-5 (minor): a closed tab's surface stays alive.** After closing tab `~` (surface 20) at
21:13:04, the next drop logged `surface 20: link dropped, waiting to reattach`
(`k01-idle-drop.log`). It did not reattach or error.

**V5-6 (noticeable): the active tab's grid card crops away the live bottom** (T-TABS-01,
T-REG-1350-a). The card is a top-aligned crop of the page, so the newest rows and the agent
prompt are not on the card. This is related to the kit's U4 thumbnail request. Today the
user sees an older region than the page.

Rig defects (not app defects): `journey.link_status()` returns `''`, so
`settings_transport()` reports a failure even though the link connected (the app log shows
`link connected(…webRTC…turn…)`). The `s6` recording never finalized, so s6 is judged from
screenshots and compares only.

## User-reported defects being fixed next (state on this build only)

- **The last row is not flush with the composer.** Measured at the bottom while Codex was
  working: last lit text pixel at 726.3 pt, composer card top at 737.0 pt, a **10.7 pt gap**
  (0.67 of a 16 pt row) (`gap-t1-working.jpg`). It may relate to the 42-vs-39 row overrule
  above. Still present.
- **Scroll jank while output streams.** Present. The app's own meter during the s9-gt
  flings: `scroll pacing: 327 frames, longest 50.2 ms, 10 over 17 ms`, and
  `190 frames, longest 37.2 ms, 8 over 17 ms` (`s9-gt-jump-window.log`). Laptop load was
  about 15, so these numbers are indicative only.
- **Jump to bottom fails mid-fling.** Not tested in isolation this round. The one Jump tap
  after a fling-drop (s3) worked. V5-1's black frame happens on a Jump tap.

## Not done

- M-INTEG (G-09), M-FRAMELOG, the G-R path, netsim, and red runs on old SHAs.
- Every timing row: INVALID by load.
- rows.py was not run: the Codex and HIST fixtures were judged by OCR of the top rows
  before and after each drop (`events.jsonl` `pre`/`post`/`s8_result`/`s9_result`), plus
  motion.py on every recording.

The rig was left running and paired on WireGuard (G-T): `e2e-t1` open at the bottom, Codex
idle, hostd up, and this build installed on the simulator.
