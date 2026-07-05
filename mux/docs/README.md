# cmux-mux docs

`cmux-mux` is a tmux-style multiplexer that speaks Ghostty's VT engine on both ends: PTY output is parsed into Ghostty terminal state, and attach clients receive Ghostty VT replay plus live output so another frontend can reconstruct the same surface.

## Contents

- [Getting started](getting-started.md): build prerequisites, local and headless runs, sockets, detach and attach.
- [Concepts](concepts.md): session tree, focus, collapse behavior, tab naming, smart split, PTY and browser surfaces.
- [Keyboard](keyboard.md): prefix model, modeless Alt layer, default bindings, and `mux.json` key remapping.
- [Mouse](mouse.md): clickable UI, drag reorder, resize, scrollbars, menus, selection, pointer shape, and dialogs.
- [Configuration](configuration.md): full `mux.json` reference with defaults and a worked example.
- [Control socket protocol](protocol.md): JSON-lines framing, protocol v6 attach streams, events, and compatibility rules.
- [Browser panes](browser-panes.md): CDP-backed browser tabs, rendering, input, profiles, and current limitations.
