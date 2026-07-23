# cmux-tui docs

`cmux-tui` is a tmux-style multiplexer that speaks Ghostty's VT engine on both ends: PTY output is parsed into Ghostty terminal state, and attach clients receive Ghostty VT replay plus live output so another frontend can reconstruct the same surface.

## Contents

- [Getting started](getting-started.md): build prerequisites, local and headless runs, sockets, detach and attach.
- [Concepts](concepts.md): session tree, focus, collapse behavior, tab naming, smart split, PTY and browser surfaces.
- [Keyboard](keyboard.md): prefix model, modeless Alt layer, default bindings, and `cmux-tui.json` key remapping.
- [Mouse](mouse.md): clickable UI, drag reorder, resize, scrollbars, menus, selection, pointer shape, and dialogs.
- [Configuration](configuration.md): full `cmux-tui.json` reference with defaults and a worked example.
- [Remote daemon](remote.md): authenticated clients, SSH, WebSocket, Iroh, relays, RPC, and port forwarding. The exact agent RPC wire schema is in the [remote RPC contract](../spec/remote-rpc.md).
- [Control socket protocol](protocol.md): JSON-lines framing, protocol v9 layouts and events, attach streams, and compatibility rules.
- [Browser panes](browser-panes.md): CDP-backed browser tabs, rendering, input, profiles, and current limitations.
