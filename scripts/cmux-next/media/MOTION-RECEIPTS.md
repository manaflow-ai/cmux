# Motion receipt contract

Use `motion-record.py` to capture a tagged app, then use `motion-receipt.py` to
make the reviewable MP4. The MP4 must show the real UI for the entire clip:

1. A short hold of the first captured frame labeled `BEFORE`.
2. Every recorded transition frame at the recorder cadence.
3. A readable hold of the last captured frame labeled `AFTER` (1.8s by default).

The video is intentionally clean: do not burn labels, cards, state IDs, or
debug colors into the app pixels. The phase labels, timing, and full state IDs
belong in `receipt.json` and the PR comment. This keeps the motion itself
reviewable instead of turning the clip into a debug slide.

Before publishing, inspect at least three extracted frames: the before hold,
the middle of the real transition, and the after hold. The after frame must be
the final real UI frame, not a card or a blank fallback. Reject the receipt if
the first and last frames are identical, if either is suspiciously small, or if
the metadata does not prove a state change. Publish the MP4 and its GIF only
after those checks pass.

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
