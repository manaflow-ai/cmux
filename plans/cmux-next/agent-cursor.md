# cmux next: the agent cursor and automation parity (R130)

Design, 2026-10-04. Owner: the agent automation lead. Inputs: R130 (Lawrence, verbatim in requests.md), automation-lease.md (lease states, pause on user input), the coordinator split of 2026-10-04 (hq-07 ports the browser REPL S0-S6; this lane owns the cursor module, the overlay consumer, the parity table and the cmux Computer Use first-party app), the R84 overlay work (`OverlayPlane`, `WindowOverlayLayer`: overlays in layout-root coordinates, moved into a click-through child panel above Chromium page windows), and the cmux-cua cursor (`cursor-overlay` crate: palette, Bezier path planner, spring, dwell, click pulse, label).

## 1. One renderer

Today the cmux-cua cursor is drawn by the helper: Rust plans a Bezier path and rasterizes every frame on the CPU (`render_frame`, a motion tick loop). Browser use has no cursor. R130 asks for one cursor everywhere, drawn the most resource-efficient way.

Design: a Swift package `CmuxAgentCursor` (CoreAnimation only):

- One `CALayer` tree per cursor: arrow shape (`CAShapeLayer` from the same SVG path as cmux-cua's builtin shape), label pill (`CATextLayer`), click ripple (`CAShapeLayer`, scale + opacity), focus rect.
- Motion: the path planner runs once per action (the same Bezier and spring parameters as `cursor-overlay::PathPlanner`, ported to Swift with shared golden vectors) and becomes one `CAKeyframeAnimation` on `position` with the planned path and timing. The render server interpolates; the app does no per-frame work. Click, drag and scroll are `CAAnimationGroup`s queued after the move.
- Idle: no timers, no display link, no animations attached. Idle hide is one `CABasicAnimation` on opacity with a begin time, not a timer.
- Color: one function of the session id (the same function the activity pane, lease badge and cmux-cua use), so cursor, badge and timeline match.

Where it runs:

- In the cmux app: one cursor layer per live lease, hosted in the window's `OverlayPlane` (layout-root coordinates), so R84's `WindowOverlayLayer` keeps it above Chromium page windows and the sidebar occluder rule applies. Never HTML in the page.
- In the cmux Computer Use helper (desktop targets outside cmux windows): the helper hosts the same package in its click-through overlay panel. Decision needed (section 6): the package lives in the cmux-cua repo and the helper links it through its existing Swift bridge; the cmux app depends on it at the cmux-cua pin.

## 2. The input event (contract with hq-07 and the CUA host)

Every driver (browser host CDP and WebKit drivers, CUA host) publishes one event per agent input, before it dispatches the input:

```
automation.input {
  v: 1,
  session_id,                       // lease session
  target_id,                        // browser tab id, or "cua:<pid>:<window_id>" for desktop windows
  seq,                              // per session, gap-free
  kind: move | click | double_click | right_click | drag | type | key | scroll,
  space: viewport | window,         // viewport = CSS px of the top-level document viewport (after scroll, iframe offsets resolved); window = window-local points of the target window (desktop)
  point?: {x, y},                   // where the input lands
  rect?: {x, y, w, h},              // target element rect in the same space, when known
  to?: {x, y},                      // drag end, scroll delta for scroll
  t_ms                              // host monotonic time
}
```

Coordinates are never screen points: the layout can move between the event and the frame. The app maps `viewport -> pane -> window` through the live layout model when it starts and retargets the animation (a pane move during the animation retargets once, from the presentation layer's current position). Desktop events map `window -> screen` in the helper.

## 3. Geometry through tabs, panes, workspaces, Spaces, niri columns

- Target tab visible: map and animate.
- Target tab hidden (background tab, other workspace, column scrolled out of view): animate to the tab chip or the column edge and show a small off-screen indicator with the session color; never draw over a pane that is not the target.
- Window on another Space or minimized: no cursor in the app; the titlebar lease indicator still counts it.
- Lease `paused` or `user_driving`: the cursor fades to an outline and stops at its last point; new input events are refused by the host anyway.

## 4. Resource budget

Idle: 0 percent CPU, no wakeups from this module (verified with the wakeups bench and `powermetrics` on cmux-lawrence-2). Per action: CPU only for one path plan and one animation commit; frames on the render server. Report CPU and energy for a scripted 60 s session (one action per second) against the current cmux-cua CPU renderer.

## 5. Parity table (ranked gaps land in this order)

Base: hq-07's classic REPL (156 differential cases, docs/browser-repl on main). Columns: cmux-next today, classic REPL, ChatGPT agent / Codex Computer Use (Sky), `aside repl`. "port" = done by hq-07's S0-S6; "this lane" = automation lead.

| Capability | cmux-next today | classic REPL | ChatGPT / Sky | aside | Owner |
| --- | --- | --- | --- | --- | --- |
| Persistent JS REPL, Playwright page/locators | headless only | yes | no (tool calls) | yes | port |
| Snapshot with stable refs, frames, shadow roots, diffs, budgets | headless only | yes | screenshots + AX (Sky) | yes | port |
| Annotated screenshot | no | yes | no | yes | port |
| Tabs: list, attach active, open, close, hibernated/crashed states | partial | yes | yes | yes | port |
| Trusted input with real user activation | no | partial (WebKit false) | yes | yes | port S3 |
| Background operation, never steals focus | untested | yes | yes (Sky AX path) | no (own browser) | port + bench |
| Smart waits (interactive, DOM stable) | headless only | yes | implicit | yes | port |
| Downloads, cookie-bearing fetch, private fs | no | yes | partial | yes | port |
| Secrets fill-only, masked; domain policy | host yes | yes | no | no | port |
| Site tools (Gmail, Slack, Notion, GitHub, Linear, ...) | no | yes | connectors | skills | port |
| Record / trace | no | yes | no | no | port |
| Visible agent cursor with click feedback | no | no | yes (virtual browser) | no | this lane |
| Lease badge, pause on user input, take over, hand back | contract only | no | yes (takeover) | no | this lane + v3 |
| Confirmation before high-risk writes | no | drafts until confirm | yes | no | port + this lane |
| Desktop apps: AX snapshot, click, type, scroll, drag | engine only, slow clicks | n/a | yes (Sky) | no | this lane |
| Desktop: screenshots | blocked (TCC) | n/a | yes | n/a | this lane |
| Multi-agent isolation (sessions, cursors) | per-session cursor color | named sessions | one agent | sessions | this lane |
| Agent activity timeline | prototype | no | task log | no | this lane |
| Latency: snapshot p50 | 55-103 ms (desktop AX) | faster than Playwright MCP | unmeasured | unmeasured | bench |
| Latency: click p50 | 1.5 s (desktop) | unmeasured | unmeasured | unmeasured | this lane (engine PR) |

Rank for this lane: (1) desktop click latency and reliability (engine PR), (2) screenshots, (3) the cursor module and overlay consumer, (4) lease UX, (5) cmux Computer Use as a first-party app, (6) baseline columns measured by the bench (`codex-cua`, `aside repl`).

## 6. Decisions needed

1. Where `CmuxAgentCursor` lives. Recommended: the cmux-cua repo (the helper must draw desktop cursors with the app closed, and it is built from that repo); the cmux app consumes it at the cmux-cua pin. Alternative: the cmux repo, with the helper build pulling the package from cmux; this inverts the dependency and couples helper releases to app builds.
2. Event coordinate space for the browser: viewport CSS px (recommended; the app knows the pane's page zoom and scroll does not need tracking) versus document coordinates.

## 7. Steps

| Step | Content | Verification |
| --- | --- | --- |
| k1 | `automation.input` schema + vectors (schemas/automation-input), agreed with hq-07 | review |
| k2 | `CmuxAgentCursor` package: layers, path planner port with golden vectors from `cursor-overlay`, animation builder | unit tests (path vectors, animation keyframes), snapshot images on the fleet |
| k3 | app consumer: lease + input event stream to `OverlayPlane`, viewport -> pane -> window mapping, hidden-tab indicator, pause rendering | module tests with a fake layout; live run on cmux-lawrence-2 |
| k4 | helper consumer: cmux-cua draws with the package; remove the CPU renderer on macOS | cmux-cua macOS CI + live run |
| k5 | 60 s CPU/energy session, idle wakeups | powermetrics numbers in this note |
| k6 | cmux Computer Use first-party app (apps platform package, catalog ops, palette commands) under the apps supervisor | apps lead review, live run |
