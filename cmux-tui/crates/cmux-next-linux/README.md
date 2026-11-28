# cmux-next-linux (developer preview)

cmux NEXT's agent chat in a Linux desktop window (cmux#330). One binary starts a private
`acpmux daemon`, the webviews dev server for the agent pane, and a WebKitGTK window (wry + tao)
on the pane. Closing the window stops both processes it started.

```sh
sudo apt-get install libwebkit2gtk-4.1-dev libgtk-3-dev   # build deps
cd cmux-tui/crates/cmux-next-linux && cargo build
(cd ../../../webviews && bun install --frozen-lockfile)
target/debug/cmux-next-linux --webviews ../../../webviews --acpmux "$(command -v acpmux)" --cwd ~/src/project
target/debug/cmux-next-linux --dry-run   # print the commands and URL only
```

## What it is, what it is not

- It is the same pane the macOS app shows, connected the way
  `webviews/scripts/agent-pane/dev-slot.sh` connects a browser tab: the dev host
  (`webviews/src/dev-host/host.ts`) with the loopback endpoint and token in the URL fragment.
- It is **not** the production bridge. The daemon runs as a development launch
  (`--dev --allow-dev-origin <pane origin>`), and trust prompts are the dev host's stubs, so it
  does not have production permission parity. Use it on your own machine.
- The crate has its own `[workspace]` (like cmux-rd-host and coord-sim, so `cmux-tui`'s builds never see it) because it links GTK. Without
  the default `window` feature it builds without GTK and prints the URL instead
  (`cargo test --no-default-features` covers the launch plan).

## Next (tracked in the hq plan issue)

1. Production host in Rust: the protocol v2 `acpmux-bridge` handshake with a socket the host
   holds (as `AgentPaneTransport.swift` does on macOS), and no token in the page.
2. Built pane assets (no Vite or bun at run time) served from the binary.
3. Terminal and browser panes, the sidebar, and packaging (.deb, AppImage, Flatpak) on the
   existing Linux release legs.
