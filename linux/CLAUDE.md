# cmux-linux

Rust + GTK4/libadwaita port of cmux (terminal multiplexer for AI coding agents).

## Build

```bash
cargo check          # Type check
cargo test           # Run tests
cargo build          # Debug build
cargo build --release # Release build
```

## Architecture

- `ghostty-sys/` — Raw FFI bindings to libghostty C API (`ghostty.h`)
- `ghostty-gtk/` — Safe Rust wrapper: GhosttyApp, GhosttyGlSurface, key mapping
- `cmux/` — Main application (GTK4/libadwaita)
  - `model/` — TabManager, Workspace, Panel, LayoutNode
  - `ui/` — Window, Sidebar, SplitView, TerminalPanel
  - `socket/` — Unix socket server, v2 JSON protocol, auth
  - `session/` — Session persistence (XDG, JSON compatible with macOS cmux)
  - `notifications.rs` — Notification store + desktop notifications
- `cmux-cli/` — CLI client (`cmux workspace list`, `cmux surface send-text`, etc.)

## Ghostty Integration

The `link-ghostty` feature enables actual FFI linking to libghostty.
Without it (default), the crates compile in stub mode for development.

To build with ghostty:
1. Initialize the ghostty submodule
2. Build with `cargo build --features ghostty-sys/link-ghostty`

## Socket Protocol

Unix socket at `$XDG_RUNTIME_DIR/cmux.sock` (falls back to `/tmp/cmux.sock`).
Line-delimited JSON v2 protocol. Compatible with macOS cmux socket API.

## Reference

- macOS cmux source: `~/cmux/`
- ghostty C API: `~/cmux/ghostty.h`
- GTK4 patterns: `~/koe/src/ui/`
