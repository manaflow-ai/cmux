# cmux-tab-snapshots bench results

`tab-snapshots-2026-11-22.jsonl` is the output of

    cargo run -q -p cmux-tab-snapshots --example tab_snapshot_bench

with the default workload. The run is deterministic: the same build gives the same file.

## What is measured

- Bytes. Every frame comes from the crate's real producer, session, encoder and mirror. Byte counts are
  frame lengths plus 9 header bytes for each 16 KiB link write. The bench does not compress.
- Frame counts, blob counts, and the bytes saved by dedupe (one favicon shared by several tabs) and by the
  phone's cache (blobs listed in `have`).

## What is computed, not measured

All times. They come from a link model in virtual time: one round trip, the bandwidth in each direction,
frames sent one after another on each side. Nothing ran on a radio or on a phone. The model has no loss,
no congestion window, no TLS and no app processing time, so real times will be longer.

## What is assumed

- Links: wifi with an 8 ms round trip and 100 Mbit/s down, 40 Mbit/s up; lte with a 70 ms round trip and
  12 Mbit/s down, 5 Mbit/s up.
- Workload: 12 tabs. Every third tab is a terminal; the other 8 are browser tabs. There are 5 distinct
  favicons.
- Sizes: a thumbnail is 38,000 bytes of random data (516x688 JPEG), so it does not compress. A favicon is
  2,200 bytes. Terminals have no favicon. A terminal screen is a generated 120x40 text of about 2,100 bytes.
- `--thumbs DIR` and `--favicons DIR` replace the generated images with real files. `--tabs`,
  `--favicons-distinct` and `--terminal-every` change the workload.

## Line kinds

- `assumptions`: the workload and the link parameters.
- `per_tab_bytes`: what one tab costs, by part.
- A scenario line has `link`, `session` (`want`, the default, or `push_before_want`) and `scenario`. The
  scenarios are a cold open, a warm open with the cache persisted, one changed thumbnail, and a reconnect
  that resumes with three tabs changed. Times are `manifestMs` (rows arrive), `firstCardMs`,
  `firstScreenMs` (the first 6 cards are filled) and `allWantedMs`.
- `e_baseline_send_everything` sends every card in full with no cache, dedupe or deltas.
- `baseline_ratio`: the baseline's bytes down divided by each scenario's bytes down.
