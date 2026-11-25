# Media tools

- `tour.py`, `record-window.swift`: drive the app and record its window (ScreenCaptureKit).
- `crop-video.swift`: a fixed crop and scale of a video with AVFoundation, for Macs without ffmpeg.
- `reel.py`: a nightly reel of pull request clips (ffmpeg).
- `cmux-follow-cut` (Rust, `cmux-tui/crates/cmux-follow-cam`): a vertical cut (9:16, 4:5 or 1:1) of a
  landscape recording whose crop follows the typing and cuts at scene changes, moved by the same follow
  camera as the iPhone viewer. It finds where pixels change on its own; a signal trace (`--trace`,
  `cmux_follow_cam::Event` JSON lines) adds the caret, pointer and window. Needs ffmpeg with libx264.

  ```bash
  cargo run --release --manifest-path cmux-tui/Cargo.toml -p cmux-follow-cam --bin cmux-follow-cut -- \
    recording.mp4 vertical.mp4 --aspect 9:16 --width 1080 [--trace signals.jsonl] [--path-out path.jsonl]
  ```
