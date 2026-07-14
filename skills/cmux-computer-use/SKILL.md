---
name: cmux-computer-use
description: "Drive real macOS apps from a cmux agent session via the bundled computer-use engine (accessibility tree + screenshot perception, click/type/scroll/drag, branded agent cursor). Use when an agent should see and operate GUI apps on the local Mac, when computer-use tools are missing or failing, or when explaining how to grant permissions, brand the cursor, or focus the driving session."
---

# cmux Computer Use

cmux bundles a local computer-use engine (`cmux-cua-driver`, a pinned build of
the `manaflow-ai/cmux-cua` fork) and attaches it as an MCP tool server named
`cmux-computer-use` to every agent session cmux launches (Claude Code, Codex).
The agent can then perceive and operate real macOS apps: read the accessibility
tree, take screenshots, and click / type / scroll / drag.

Everything runs locally under **cmux's own TCC identity** — the driver runs
in-process in embedded mode, so macOS attributes Accessibility and Screen
Recording to the cmux app, not to a third party. Upstream telemetry and update
checks are disabled at runtime.

## How it attaches

- The `cmux-claude-wrapper` / `cmux-codex-wrapper` inject the driver as an MCP
  server with `--embedded` plus the cursor-branding and state-dir env. No user
  setup per session — start `claude` or `codex` inside cmux and the tools are there.
- Kill switch: set `CMUX_COMPUTER_USE_MCP_DISABLED=1`, or toggle it off in
  Settings → Computer Use (persists to `~/.config/cmux/cmux.json` and is
  exported to spawned terminals).
- Attaches only on cmux-launched, live-socket sessions (same authority bar as
  cmux hooks); hooks-disabled and stale-socket sessions do not attach.

## Permissions (one-time, granted to cmux)

Two macOS permissions are required and are requested **in-process by the cmux
app** so the system prompt names cmux:

- **Accessibility** — inspect and drive app UI (`AXIsProcessTrusted`).
- **Screen Recording** — screenshots / vision (`CGPreflightScreenCaptureAccess`).

First-run onboarding walks the user through both. Re-run any time from
**Settings → Computer Use → Run Onboarding Again**. If actions fail with a
permission error, grant Accessibility; if screenshots come back blank, grant
Screen Recording (macOS requires an app relaunch after granting it).

## Using the tools (agent-facing)

Perceive, then act, then verify:

1. `get_window_state` (pid + window_id) returns the accessibility tree **and** a
   screenshot. Ground on both. Prefer element addressing.
2. Act by element: `click` with `element_token` (or `element_index` + pid +
   window_id) is the robust path. Pixel addressing (`x`,`y`) is the fallback.
3. Verify by re-snapshotting and reading the element `value` / screenshot — do
   not assume an action landed (clicks are never driver-verified).

Notes:
- `list_apps` / `launch_app` / `list_windows` to find targets;
  `get_window_state` needs a `window_id` from `list_windows`.
- Catalyst apps (e.g. Calculator) can expose an empty AX tree briefly after
  launch and return spurious AX error codes (-25204) even when the action
  landed — re-snapshot and check the result rather than trusting the code.
- Pixel input is obstruction-checked: if another window covers the target
  point the driver refuses with `background_occluded` naming the occluder
  instead of clicking the wrong window. Retry with `delivery_mode:"foreground"`
  or front the target.

## The branded agent cursor

The agent's pointer shows as the cmux logo gradient (`#12c7f5 → #2d8cff →
#6c5cff`) with a `cmux` label, so it is visually distinct from the user's
cursor. It is configured by env the wrapper injects
(`CUA_DRIVER_CURSOR_GRADIENT` / `_BLOOM` / `_LABEL`) and is auto-active during
embedded computer use. If no cursor appears, confirm the session is embedded
and that the driver build is the pinned one (older builds only showed a cursor
when the agent passed an explicit `session`).

## Finding and focusing the driving session

While an agent is driving, the **Computer Use menu-bar item** lists live agent
sessions:

- **Focus terminal** — reveal the workspace + surface running that agent (shared
  reveal path with notifications).
- **Focus target** — bring forward the app the agent is driving, read from the
  driver's per-session state files under
  `~/Library/Application Support/cmux/computer-use/state/`.

The item hides when there is no live or recent session. Toggle visibility in
Settings → Computer Use.

## Troubleshooting

- **Agent has no computer-use tools** — Settings → Computer Use must be on;
  start a *new* session (tools attach at launch).
- **Clicks do nothing / not permitted** — grant Accessibility, restart the session.
- **Black/empty screenshots** — grant Screen Recording, relaunch the app.
- **No menu-bar icon** — needs a live/recent session; check the visibility toggle.
- **Prompts name a third party instead of cmux** — a stale standalone
  `CuaDriver.app` daemon or a non-embedded `cua-driver mcp` run contaminated the
  TCC list; our embedded path attributes to cmux. Remove the stale entry in
  System Settings → Privacy.

## Development

- Engine source: `manaflow-ai/cmux-cua` (`libs/cua-driver/rust`). cmux consumes
  it via `CMUX_CUA_PINNED_SHA` in `scripts/build-cua-driver.sh`, which builds,
  lipos, and codesigns the binary into the app bundle.
- Never hand-edit `docs/.../cua-driver/mcp-tools.mdx` in the fork — it is
  generated from the Rust tool descriptions.
- cmux-side UX lives in `Sources/App/ComputerUse*.swift`,
  `Packages/macOS/CmuxSettingsUI/.../Sections/ComputerUseSection.swift`, and the
  two wrappers under `Resources/bin/`.
