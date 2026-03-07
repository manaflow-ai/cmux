# cmux Linux MVP — Design Document

## Overview

A Ghostty-based Linux terminal with vertical tabs, split panes, and notification
rings. Built with Rust + GTK4. Target: Ubuntu 22.04+.

## Why Rust + GTK4

Multi-model consensus (Cerebras, Gemini, GPT-4o) confirmed Rust + GTK4 as the
strongest choice. Key reasons:

- **gtk-rs** is production-grade, used by Cosmic-DE and other shipping apps
- Zero-cost abstractions keep per-character latency sub-millisecond (proven by Alacritty)
- Rust's `unsafe` FFI to Ghostty's C API is well-supported; `cbindgen` can generate safe wrappers
- Zig GTK bindings are experimental/unstable — not ready for production
- Python too slow for terminal rendering; Qt adds unnecessary complexity
- Rust's borrow checker eliminates data races in background notification monitoring

Alternatives considered and rejected:

| Option | Reason rejected |
|---|---|
| Zig + GTK4 | Experimental bindings, no high-level UI crates, thin ecosystem |
| C++ + Qt | Meta-object system overhead, larger binary, more manual memory management |
| Python + GTK4 | 2-3x slower per-character rendering, no compile-time safety |
| Fork Wezterm | Divergent terminal engine (not Ghostty), large existing codebase to learn |

## Reference projects to study

- **Wezterm** — Rust terminal with tabs + splits + GPU (closest analog)
- **Alacritty** — Rust GPU terminal (performance reference)
- **Cosmic-Term** — Rust + cosmic/GTK4 terminal (System76)
- **Tilix** — GTK tiling terminal (split pane UX reference)

## Goals

1. Ghostty terminal embedding via its GTK backend (libghostty C API)
2. Left vertical tab sidebar with rename and drag-to-reorder
3. Horizontal/vertical split panes with resize and keyboard navigation
4. Notification rings — tabs light up when terminal work finishes
5. Session persistence — restore tabs, splits, and cwds on relaunch
6. Standard keybinds for all operations

## Non-goals (Round 2)

- Socket control / CLI interface
- In-app browser
- Port scanner
- Analytics / telemetry
- Auto-update

## Architecture

### Crate structure (portability-first)

Per multi-model recommendation, separate platform-agnostic core from UI:

```
cmux-linux/
  crates/
    cmux-core/          # Platform-agnostic data model + logic
      src/
        split_tree.rs   # SplitNode binary tree + operations
        split_nav.rs    # Directional pane navigation
        tab.rs          # Tab model
        workspace.rs    # Workspace (collection of tabs)
        notification.rs # Notification state machine
        session.rs      # Session serialization
        config.rs       # Config file parsing
    cmux-gtk/           # GTK4-specific UI
      src/
        main.rs         # GtkApplication entry point
        window.rs       # Main window layout
        sidebar.rs      # Tab sidebar widget
        tab_row.rs      # Individual tab row
        tab_drag.rs     # Drag-to-reorder
        split_view.rs   # Recursive split -> GtkPaned builder
        terminal.rs     # Ghostty surface wrapper
        style.css       # GTK4 CSS theme
  build.rs              # Link libghostty
```

This means `cmux-core` can later be shared with a macOS SwiftUI frontend or
even an eventual `cmux-appkit` crate.

### Window layout

```
┌─────────────────────────────────────────────┐
│                  GtkWindow                  │
│ ┌──────────┬────────────────────────────┐   │
│ │ Sidebar  │       Content Area         │   │
│ │          │                            │   │
│ │ [Tab 1]  │  ┌──────────┬───────────┐  │   │
│ │ [Tab 2*] │  │ Terminal │ Terminal  │  │   │
│ │ [Tab 3]  │  │  (pane)  │  (pane)   │  │   │
│ │          │  ├──────────┴───────────┤  │   │
│ │          │  │     Terminal         │  │   │
│ │          │  │      (pane)          │  │   │
│ │          │  └──────────────────────┘  │   │
│ └──────────┴────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

## Core Data Model (in cmux-core)

### Tab

```rust
struct Tab {
    id: TabId,
    title: String,           // user-renameable
    split_tree: SplitNode,   // tree of panes
    has_notification: bool,
    order: usize,            // position in sidebar
}
```

### SplitNode (binary tree)

```rust
enum SplitNode {
    Leaf {
        pane_id: PaneId,
    },
    Split {
        direction: Direction,  // Horizontal | Vertical
        ratio: f64,            // 0.0–1.0, position of divider
        first: Box<SplitNode>,
        second: Box<SplitNode>,
    },
}
```

### Pane

```rust
struct Pane {
    id: PaneId,
    cwd: PathBuf,
    pid: Option<u32>,        // shell process
    // ghostty surface handle (platform-specific, not in core)
}
```

### Workspace (top-level state)

```rust
struct Workspace {
    tabs: Vec<Tab>,
    active_tab: TabId,
    focused_pane: PaneId,
}
```

### Notification state machine

```rust
enum NotificationState {
    Idle,      // shell prompt, no child process
    Busy,      // foreground child process running
    Notified,  // child exited, user hasn't focused pane yet
}
```

Transitions:
- `Idle -> Busy`: shell spawns foreground child process
- `Busy -> Notified`: child exits AND pane is not focused
- `Busy -> Idle`: child exits AND pane is currently focused
- `Notified -> Idle`: user focuses the pane

## Ghostty Integration

### Risk: Ghostty's GTK backend is not designed as an embeddable library

Ghostty's GTK code (`ghostty_surface_*` C API) was built for Ghostty's own app.
Embedding it in a custom GTK4 app requires:

1. **Build libghostty as a shared library** — use `zig build -Demit-xcframework=true`
   equivalent for Linux (emit `.so`)
2. **FFI bindings** — generate Rust bindings from `ghostty.h` using `bindgen`
3. **Surface lifecycle** — manage `ghostty_surface_new()` / `ghostty_surface_free()`
   with proper ownership semantics (Rust `Drop` impl)
4. **Event forwarding** — GTK key/mouse events must be forwarded to Ghostty's
   input handling via `ghostty_surface_key()` etc.
5. **Pty ownership** — Ghostty manages its own pty; we track the shell PID
   externally for notification monitoring via `/proc/<pid>/stat`

### Mitigation

- Study Ghostty's `src/apprt/gtk/` for how it creates surfaces in GTK
- Start with a minimal "one terminal in a window" prototype (Commit 13–14)
  before building any split/tab UI on top
- If FFI proves too painful, fall back to VTE (libvte-2.91) as terminal widget
  and lose Ghostty-specific rendering, but gain a stable GTK4-native API

## Key Dependencies

```toml
[dependencies]
gtk4 = "0.9"              # GTK4 bindings
serde = { version = "1", features = ["derive"] }
serde_json = "1"          # Session serialization
toml = "0.8"              # Config file parsing
nix = { version = "0.29", features = ["process", "signal"] }
xdg = "2.5"              # XDG directory paths
uuid = { version = "1", features = ["v4"] }  # Tab/pane IDs

[build-dependencies]
bindgen = "0.70"          # Generate Ghostty FFI bindings
```

## Keybinds (defaults)

| Action | Keybind |
|---|---|
| New tab | Ctrl+Shift+T |
| Close tab | Ctrl+Shift+W |
| Next tab | Ctrl+Tab |
| Prev tab | Ctrl+Shift+Tab |
| Rename tab | F2 |
| Split horizontal | Ctrl+Shift+H |
| Split vertical | Ctrl+Shift+V |
| Close pane | Ctrl+Shift+X |
| Navigate pane (directional) | Ctrl+Alt+Arrow |
| Resize pane | Ctrl+Shift+Arrow |
| Toggle sidebar | Ctrl+Shift+B |

## Session persistence

Format: `~/.local/state/cmux/session.json`

```json
{
  "version": 1,
  "tabs": [
    {
      "id": "uuid",
      "title": "my-server",
      "order": 0,
      "split_tree": {
        "type": "split",
        "direction": "horizontal",
        "ratio": 0.5,
        "first": { "type": "leaf", "cwd": "/home/user/project" },
        "second": { "type": "leaf", "cwd": "/home/user" }
      }
    }
  ],
  "active_tab": "uuid"
}
```

Atomic write (tmp + rename) to prevent corruption on crash.

## Testing Strategy

- **cmux-core**: Pure Rust unit tests, no GTK dependency, run everywhere
  - Split tree operations (insert, remove, navigate, serialize)
  - Notification state machine transitions
  - Session serialization round-trips
  - Workspace operations (add/close/reorder/rename tabs)
  - Config parsing
- **cmux-gtk**: Integration tests requiring display server
  - Run headless via `xvfb-run cargo test`
  - Window creation, sidebar rendering, focus management
  - Tab drag-and-drop ordering
