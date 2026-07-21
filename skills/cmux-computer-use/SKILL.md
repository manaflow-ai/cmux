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

Everything runs locally through the bundled **cmux Computer Use** helper. The
helper has its own TCC identity, so Accessibility and Screen Recording never
belong to the main cmux app and granting Screen Recording never requires
restarting cmux. Upstream telemetry and update checks are disabled at runtime.

## How it attaches

- The `cmux-claude-wrapper` / `cmux-codex-wrapper` inject the driver as an MCP
  proxy using `mcp --socket <cmux-owned socket>` plus the cursor-branding and
  state-dir env. No user setup per session — start `claude` or `codex` inside
  cmux and the tools are there.
- `ComputerUseRuntimeService` is the only helper lifecycle owner. It installs
  the nested helper under the tag-scoped
  `~/Library/Application Support/cmux/computer-use/helper/<scope>/` directory
  and launches that explicit app URL through LaunchServices.
- The daemon socket is tag-scoped under
  `/tmp/cmux-cua-<uid>/<scope>/cua.sock` so it always fits Darwin's Unix-socket
  path limit. Session state stays under the tag-scoped cmux Application Support
  runtime directory.
- While Computer Use is enabled, the helper daemon starts quietly at cmux
  startup with its internal permission gate disabled. Starting cmux or an agent
  never requests access or shows onboarding.
- Wrappers are pure forced proxies. They never copy or launch the helper and
  never fall back to in-process computer use.
- Kill switch: set `CMUX_COMPUTER_USE_MCP_DISABLED=1`, or toggle it off in
  Settings → Computer Use (persists to `~/.config/cmux/cmux.json` and is
  exported to spawned terminals).
- Attaches only on cmux-launched, live-socket sessions (same authority bar as
  cmux hooks); hooks-disabled and stale-socket sessions do not attach.

## Permissions (one-time, granted to the helper)

Two macOS permissions are required and are owned by **cmux Computer Use**, not
the main cmux app:

- **Accessibility** — inspect and drive app UI (`AXIsProcessTrusted`).
- **Screen Recording** — screenshots / vision (`CGPreflightScreenCaptureAccess`).

Onboarding appears on the first real Computer Use tool invocation, not on cmux
or agent startup. Re-run it any time from **Settings → Computer Use → Run
Onboarding Again**. Each permission step exposes the real helper app as a file
drag source for the matching System Settings list and reads status from the
running helper over its Unix socket. The main cmux process never calls a TCC API
or executes the driver binary.

If actions fail with a permission error, grant Accessibility to cmux Computer
Use. If screenshots come back blank, grant Screen Recording to cmux Computer
Use. The helper daemon refreshes/restarts to pick up the grant while cmux stays
open. Retry the tool call after onboarding reports both grants.

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
(`CUA_DRIVER_CURSOR_GRADIENT` / `_BLOOM` / `_LABEL`) and is auto-active while
the helper daemon is driving. If no cursor appears, confirm the MCP config uses
the helper socket, has a stable `CUA_DRIVER_DEFAULT_SESSION`, and uses the pinned
driver build.

## Finding and focusing the driving session

While an agent is driving, the **Computer Use menu-bar item** lists live agent
sessions:

- **View Computer Use** — bring forward the app the agent is driving and resume
  following newly driven targets, read from the driver's per-session state files
  under `~/Library/Application Support/cmux/computer-use/runtime/<scope>/state/`.
- **Continue in Background** — reveal the exact workspace + surface running that
  agent (through the shared terminal-focus path) and stop automatically fronting
  later targets. The agent keeps working through the driver's background-first
  delivery; an explicit foreground fallback briefly acts and restores the terminal.

The menu shows a checkmark for the active view/background mode. Background mode
resets after all live sessions end. The item hides when there is no live or recent
session. Toggle visibility in Settings → Computer Use.

## Troubleshooting

- **Agent has no computer-use tools** — Settings → Computer Use must be on;
  start a *new* session (tools attach at launch).
- **Clicks do nothing / not permitted** — grant Accessibility to cmux Computer Use.
- **Black/empty screenshots** — grant Screen Recording to cmux Computer Use;
  restart only the helper if its automatic refresh has not completed yet.
- **No menu-bar icon** — needs a live/recent session; check the visibility toggle.
- **Prompts name the main cmux app** — a non-cmux fallback executed the driver
  directly. Stop there and report the failure; the bundled path must use the
  tag-scoped socket with `CUA_DRIVER_RS_MCP_FORCE_PROXY=1`.
- **Prompts name CuaDriver** — a stale `/Applications/CuaDriver.app` daemon or a
  standalone driver launch is active. Stop it and reset/remove its TCC entry;
  the bundled path never uses that identity.

## Development

- Engine source: `manaflow-ai/cmux-cua` (`libs/cua-driver/rust`). cmux consumes
  it via `CMUX_CUA_PINNED_SHA` in `scripts/build-cua-driver.sh`, which builds,
  lipos, and codesigns the binary plus the nested helper into the app bundle.
- `CUA_DRIVER_RS_EXTERNAL_PERMISSION_FLOW=1` prevents agent-supplied
  `check_permissions {prompt:true}` from bypassing cmux onboarding. The wrappers
  set `CUA_DRIVER_RS_MCP_FORCE_PROXY=1`; `CMUX_CUA_DRIVER` may replace only the
  proxy executable and never enables embedded mode.
- If the cmux-owned daemon is unavailable, do **not** invoke `cua-driver`
  directly through Bash and do not start its default socket. Tell the user to
  open Settings → Computer Use or restart the tagged cmux build, then retry the
  MCP tool after the helper runtime is healthy.
- Never hand-edit `docs/.../cua-driver/mcp-tools.mdx` in the fork — it is
  generated from the Rust tool descriptions.
- cmux-side UX lives in `Sources/App/ComputerUse*.swift`,
  `Packages/macOS/CmuxSettingsUI/.../Sections/ComputerUseSection.swift`, and the
  two wrappers under `Resources/bin/`.
