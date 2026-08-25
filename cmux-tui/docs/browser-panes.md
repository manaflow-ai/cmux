# Browser Panes

Browser panes are cmux-browser targets controlled with the Chrome DevTools Protocol. They live in the same canonical screen, column, split, pane, and tab tree as PTY tabs, but their rendering and input path are CDP-based instead of VT-based.

## Requirements

Browser panes require a live cmux-browser provider on the same machine. cmux-browser enables a dynamic loopback DevTools endpoint, registers that endpoint over the owner-only Unix control socket, and publishes each canonical browser tab's stable `tab_id` and current CDP `target_id`. cmux-tui does not discover or launch an isolated Chrome process. `CMUX_MUX_CDP_URL` is retained only as an explicit development override for legacy test harnesses.

Set `CMUX_MUX_CDP_DEBUG` to print browser runtime debug messages to stderr.

## Creating Panes

Use prefix `B`, or right-click a pane and choose `New browser tab`. The prompt starts with `https://`.

Bare domains get `https://` prepended. Inputs containing `://`, or starting with `about:`, `file:`, `data:`, `chrome:`, or `devtools:`, pass through unchanged.

Browser tabs are created inside an existing pane when one is active. If the session has no workspaces, creating a browser tab creates a workspace, screen, and pane around it.

## Rendering

The browser runtime attaches to the provider-owned target, enables the page domain, sets device metrics from the pane's cell size and detected cell pixels, and starts `Page.screencastFrame`. It never creates or closes the provider target.

The TUI draws the latest PNG frame with the kitty graphics protocol after each Ratatui frame. Pointer routing remains stale until the host replies to a graphics query ordered after that placement, so flushing bytes into the PTY cannot authorize clicks against an image the host has not processed. If a context menu or prompt overlaps the pane, the graphics placement is omitted for that frame so the terminal UI stays readable.

If the host terminal does not support kitty graphics, the pane displays `terminal has no kitty graphics support`. If the browser frame has not arrived yet, it displays a loading message.

## Input

Printable character keys and paste use CDP insert-text. Enter, Backspace, Tab, Esc, arrows, Home, End, PageUp, PageDown, and Delete use CDP key events with modifier bits for Alt, Control, Super, and Shift.

Left click, drag, release, and wheel events inside browser content are forwarded as CDP mouse input. Wheel deltas are scaled by the detected cell height.

Browser input, navigation, activation, and resize reconfiguration are accepted into a per-surface worker queue. Socket responses mean accepted, not completed; later CDP failures are reported through browser status events and status messages. Two consecutive CDP call timeouts mark only that surface failed with `browser is not responding`.

## Ownership and Lifecycle

The provider lease is connection-scoped process state. It is never written to SQLite or the journal. Multiple native cmux-browser windows from the same process may contribute targets, and multiple TUI or automation clients may attach to one target independently. Closing a TUI view or shutting down the mux does not close the browser, profile, or target.

If cmux-browser disconnects or replaces its DevTools target, cmux-tui retains the canonical browser surface, clears stale frame/input authority, and retries the latest provider lease with bounded backoff. Focus, selected tabs, and horizontal scroll remain frontend-local throughout.

## Vercel agent-browser

cmux-browser launches its bundled cmux-tui helper with the upstream `agent-browser.plugin.v1` provider adapter enabled. Each new terminal receives a distinct `AGENT_BROWSER_SESSION`, `AGENT_BROWSER_PROVIDER=cmux`, and a `browser.provider` plugin entry pointing back to the bundled helper. This prevents an agent command in another terminal from reusing the first terminal's page connection and makes the default path attach-only.

The plugin locates the calling terminal by `CMUX_TUI_TERMINAL_ID`, finds its canonical workspace without consulting active/focus flags, prefers a provider target in the same pane and screen, and returns a page-scoped DevTools URL. Use normal upstream commands:

```bash
agent-browser snapshot -i
agent-browser click @e1
agent-browser fill @e2 "hello"
```

Set `CMUX_TUI_BROWSER_TAB_ID=tab_...` for an exact browser tab. Direct-page mode deliberately rejects a bearer-authenticated endpoint because current upstream provider responses cannot forward WebSocket upgrade headers; the default cmux-browser endpoint is an ephemeral unauthenticated loopback socket protected by local process/user boundaries.

## Limitations

Attach clients can stream browser panes as of protocol v6. Older protocol servers show a placeholder for browser panes.

The provider must be local and explicitly registered. WebSocket control clients cannot register providers or read endpoint credentials. A workspace with no published browser target shows an attach error instead of falling back to another Chrome.
