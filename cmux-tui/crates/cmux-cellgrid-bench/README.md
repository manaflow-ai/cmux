# cmux-cellgrid-bench

Measures one terminal pane streamed three ways on the same recorded workload, for
HQ#7146 G5 ("terminal cell grid instead of video"):

| Path | What it is in cmux today |
|---|---|
| `vt` | the PTY bytes as they arrive: the live frames of the `terminal_bytes` channel (`CmuxTerminalStream`, cmux-tui `snapshot_attach.rs`), which the iPhone and Mac viewers feed to their own libghostty |
| `render-delta` | the daemon's render attach (`cmux-tui-core/src/server/render_messages.rs`): dirty rows as styled-run JSON at the 8 ms frame cadence (`frame_producer.rs`), which the web frontend draws |
| `rowdiff` | a candidate cell wire: rows diffed against what the viewer holds, plus a scroll op |
| `h264-KBPS[-refreshMS]` | the pane's pixels through cmux-encode's OpenH264 (cmux.rd's Linux encoder settings: screen content, real time, frame skip), captured on a 60 Hz grid; `refresh500ms` also re-encodes every 500 ms while idle, as WebRTC's `ScreenStream` does |

## Run

```sh
python3 -I scripts/record.py vim-typing /tmp/vim-typing.cgt --file some.rs   # flood | vim-idle | vim-typing | palette
ZIG=/opt/zig-0.16.0/zig cargo build --release                               # its own workspace; Linux host
target/release/cmux-cellgrid-bench /tmp/vim-typing.cgt --json out.json [--window 2:7] [--link-mbps 20]
```

`record.py` runs a real program in a 120x40 PTY and records every read of its
output, and every key it types, with a timestamp. The bench replays that trace in
recorded time through ghostty-vt (the host), then through each path to a viewer.

## What each number is

- `kbps`, `kbps_deflate`: bytes sent in the window, and the same messages through
  one deflate stream with a sync flush per message (what a compressed channel carries).
- `key_to_view_ms`: from the first output after a typed key (the program's echo)
  to the viewer holding it, per key; `key_stages_p50_ms` splits it into:
  - `wait`: pacing before the path sends: the cell cadence, or the next 60 Hz capture;
  - `host`: building the message, or I420 conversion plus encode;
  - `network`: the message's bytes at `--link-mbps` (no RTT: it is the same for every path);
  - `viewer`: parsing and applying it (VT parse plus grid read, JSON apply, or H.264 decode).

  The program's own echo time, drawing pixels on the viewer and display refresh are
  the same for every path and left out. For video the host's screen capture is left out too, which favours video.
- `mismatched_rows`: viewer rows that differ from the host's after each message (0 is lossless).
- `quality`: the viewer's picture against the host's own pixels, sampled every
  `--quality-every` captures. The host and the cell viewer draw with the same rasterizer
  (`src/raster.rs`, DejaVu Sans Mono at 26 px: 13 pt at 2x), so a cell path is exact when
  its pixels match. `exact_text_cells_pct`: cells with any glyph pixel whose pixels all match;
  `near_text_cells_pct`: none off by more than 8 in a channel; `text_de2000_*`: CIEDE2000
  on fully covered glyph pixels, the text colour itself (2.3 is about one just-noticeable difference).
- `chroma_420_floor`: the I420 round trip with no codec, the colour floor 4:2:0 alone sets.

Not covered: images (kitty graphics ride `terminal_bytes` and render-graphics; Ghostty has
no sixel), attach keyframes (GHOSTSNP READY), and real networks (see HQ#7146 G2).
