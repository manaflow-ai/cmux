# Terminal QA round 3 (termqa, 2026-10-14 16:15-16:30 PT): in progress

Input: VERIFY-round2.md (fresh verifier: gate not met; 3 disruptive, 3 noticeable).
Rig unchanged (simulator on the laptop, `cnx-e2e-604fc689` on `mini-cmuxs-mac-mini-2`,
WireGuard + Relay only, path `turn`), real Codex, phone input only.

## V2-1 (disruptive): Codex's live area garbled after grid round trips

- **Red on `eef46a7c`:** `tq.grid_garble("r5-grid-garble-old")` (one Codex answer of
  60 numbered paragraphs, three grid round trips while it streams, wait for "done").
  Phone's last rows: `… done 4:20 PM`, `columns more complicated.`, `handled according
  to terminal emulation rules.` (stale rows where the prompt and status line belong);
  Mac: `done 4:20 PM`, `› Ask Codex to do anything`, `gpt-6-astra max · …`.
  Video `~/cnx-ios-e2e/termqa-raw/r5-grid-garble-old.mp4`.
- **Cause found (log `mirror rows A -> B cause=layout`, added in this round):** the
  grid's zoom lays the page out at 893, 914, 939, 952, 963 pt; the mirror's row count
  (`surfaceRows`, page rows + margins) follows: 151 → 152 → 154 → 155 → 156 → 157.
  Ghostty resizes the mirror on each change, which moves its rows, while the Mac's
  rows map to the mirror's bottom rows by `offset = mirror rows − remote rows`
  (TerminalRowShift). Absolute-addressed writes from Codex then land on the wrong
  rows until the next replay.
- **Attempted fix (not kept):** rows from the screen's height (constant 151). The
  mirror no longer resized during the zoom, but in 2 of 2 runs the page then stayed
  on the start of Codex's answer (visible items 2-13 for 25 s, rows.py at 1 fps on
  `r5-grid-garble-fix1.mp4`) while the Mac streamed to 60, and caught up only after
  the answer finished (no Jump to bottom shown, so the scroll model still claimed
  following). Something else (viewport requests or `presentedTop` matching, which
  assume surface rows ≈ page rows) depends on the mirror following the page height.
  Reverted; only the log line stays.
- **Next:** keep the mirror height fixed AND fix what stalls following with a fixed
  mirror (check `updateViewport`'s margin math and `surfacePresented`'s candidates with
  `-CnxTermLog`/`-CnxPresentLog`), or on any mirror row change request a fresh replay
  (reset + reattach) instead of letting Ghostty move rows.

## Other verifier findings, status

| Verifier item | Status |
| --- | --- |
| V2-2 D7 one-frame jumps (14 → 9 per minute at 60 fps) | open |
| V2-3 link drop loses the reading position | open (reset() on reattach drops the anchor; keep the anchor row across a reattach when the history survives) |
| V2-4 D4 two replays per reattach | open, Mac side |
| V2-5 scrollback shrank after a drop (5,460 → 1,026 rows; matches the Mac's history) | open, cause not established |
| V2-6 RTT spikes 480-2,427 ms without a drop on G-T | open, transport |
