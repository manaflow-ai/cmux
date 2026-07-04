# cmux-mux docs

`cmux-mux` is the Rust TUI multiplexer in `mux/`: a tmux-style session tree that speaks Ghostty's VT engine for PTY state and can replay that same VT state to attach clients. The bundled TUI is one frontend over the mux core; the control socket gives other frontends the same tree, input, sizing, and VT replay surface.

## Contents

- [Getting started](getting-started.md)
- [Concepts](concepts.md)
- [Keyboard](keyboard.md)
- [Mouse](mouse.md)
- [Configuration](configuration.md)
- [Control socket protocol](protocol.md)
- [Browser panes](browser-panes.md)
