# Motion receipt contract

Use `motion-record.py` to capture a tagged app, then use `motion-receipt.py` to
make the reviewable MP4. The MP4 must show the real UI for the entire clip:

1. A short hold of the first captured frame labeled `BEFORE`.
2. Every recorded transition frame at the recorder cadence.
3. A readable hold of the last captured frame labeled `AFTER` (1.8s by default).

The video has only a compact bottom-right phase marker (`BEFORE`, `MOTION`, or
`AFTER` plus its boundary time). Do not burn cards, state IDs, or full-frame
debug colors into the app pixels. Full state IDs and the exact recorder
timestamps belong in `receipt.json` and the PR comment. The marker must persist
through the whole AFTER hold so a player that pauses on the final frame still
shows which state is being reviewed.

Before publishing, inspect at least three extracted frames: the before hold,
the middle of the real transition, and the after hold, plus one frame from the
last second. The after frame must be the final real UI frame, not a card or a
blank fallback. For pane actions, require the new pane's `debug.surfaces` text
to be connected and non-empty (seed a deterministic `pane-ready` line when
needed). Reject the receipt if the first and last frames are identical, if
either is suspiciously small, if frame timestamps are missing or compressed,
or if the metadata does not prove a state change. Publish the MP4 and its GIF
only after those checks pass.

Example:

```sh
python3 scripts/cmux-next/motion-record.py \
  --socket /tmp/cmux-debug-TAG.sock --out "$OUT" \
  --surface panes --only split-right --seconds 3.4
python3 scripts/cmux-next/media/motion-receipt.py \
  --frames "$OUT/panes/split-right" \
  --metadata "$OUT/pane-event.json" \
  --out "$OUT/pane-split.mp4" --head "$HEAD"
```
