# Browser element picker

Hold Option and click an element in the built-in browser to capture its locator
and text. The pick gesture suppresses the page's normal click action. It adds a
`[picked]` summary to the originating workspace's visible terminal through the
normal queued text-input path. It does not submit Enter or change terminal focus.
Selected page content remains untrusted input, including printable shell syntax.

The picker pauses while Design Mode or React Grab is active. Only the top-level
page is supported. Open Shadow DOM can be resolved through host selectors;
closed Shadow DOM exposes its host rather than inaccessible descendants.

## Socket methods

Use the regular v2 browser target parameters (`workspace_id`, `surface_id`,
`pane_id`, or `tab_id`). Dock browser surfaces use the same browser resolver.

- `browser.picked` reads the latest authenticated native selection. With no pick,
  it returns `picked: false` and `element: null`.
- `browser.picked.clear` clears the selection and cancels pending waits.
- `browser.picked.wait` waits for a new pick after the request begins. Existing
  selections are preserved. Concurrent waiters can observe the same new pick;
  reading or waiting never consumes it. `timeout_ms` defaults to 30000 and is
  bounded to 1–300000 milliseconds. Timeout returns `timeout`; navigation,
  workspace transfer, WebView replacement, WebContent process termination, surface closure, or explicit clear
  returns `cancelled`.

A successful response includes normal workspace/surface references plus:

```json
{
  "picked": true,
  "element": {
    "xpath": "/html[1]/body[1]/button[1]",
    "selector": "*:nth-child(1) > *:nth-child(2) > *:nth-child(1)",
    "shadow_hosts": [],
    "text": "Save",
    "tag": "button",
    "timestamp_ms": 1780000000000
  }
}
```

For a Shadow DOM pick, `xpath` is `null`. Starting at `document`, resolve each
`shadow_hosts` selector and enter that host's open `shadowRoot`, then resolve
`selector` in the final root. HTML/SVG picks outside Shadow DOM have a document
XPath that can be evaluated against `document`. Locators are snapshots and can
become stale after DOM changes. Oversized locators are rejected rather than
truncated; text is capped at 200 characters.

## Trust boundary

The picker script and message bridge live in a dedicated WebKit content world.
Page scripts cannot forge native picked state by assigning globals or dispatching
synthetic clicks. Native acceptance requires a recent one-shot Option click in
the associated WebView, its main frame, and the current document generation.
Native state is cleared on navigation, workspace transfer, replacement and close.
Control characters and directional formatting controls are filtered before input
or socket delivery. These filters limit terminal control effects; they do not
make arbitrary page text safe to execute as a shell command.

The new socket methods are not allowlisted for remote CLI relay access.
