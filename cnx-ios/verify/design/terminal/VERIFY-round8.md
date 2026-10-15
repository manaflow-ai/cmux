# Terminal verify round 8 (fresh adversarial verifier, 2026-10-15 02:20 PT onward)

**Verdict: REJECT** (details below; partial results were committed as they landed).

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
