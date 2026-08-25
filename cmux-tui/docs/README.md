# cmux-tui docs

`cmux-tui` is a terminal multiplexer backed by Ghostty's VT engine. PTY output becomes styled terminal state that the TUI, public resource streams, and other frontends can render consistently.

## Contents

- [Getting started](getting-started.md): build prerequisites, local and headless runs, sockets, detach and attach, session isolation for products built on cmux-tui.
- [Concepts](concepts.md): session tree, focus, collapse behavior, tab naming, smart split, terminals, and browsers.
- [Keyboard](keyboard.md): prefix model, modeless Alt layer, default bindings, and `cmux-tui.json` key remapping.
- [Mouse](mouse.md): clickable UI, drag reorder, resize, scrollbars, menus, selection, pointer shape, and dialogs.
- [Configuration](configuration.md): full `cmux-tui.json` reference with defaults and a worked example.
- [Remote daemon](remote.md): authenticated clients, SSH, WebSocket, Iroh, relays, RPC, and port forwarding. The exact agent RPC wire schema is in the [remote RPC contract](../spec/remote-rpc.md).
- [Machines](machines.md): optional dual rails, static Unix/SSH targets, relay, `npx cmux` remote setup, and outbound `npx cmux machine-agent` registration.
- [Raw control protocol](protocol.md): private protocol-v12 JSON-lines commands and compatibility rules.
- [Public resource protocol](../spec/resource-api-v2.md): stable opaque IDs, requests, mutations, streams, and errors.
- [Public CLI](../spec/cli.md): noun-first commands and selectors.
- [SDK contract](../spec/bindings.md): handwritten facades and generated raw layers.
- [Browser panes](browser-panes.md): CDP-backed browser tabs, rendering, input, profiles, and current limitations.
