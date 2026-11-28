---
name: cmux-cua
disable-model-invocation: true
description: "Use only after the user explicitly asks for cmux Computer Use through the cmux-cua skill: drive real macOS apps from a cmux agent session via the bundled engine (accessibility tree + screenshots, click/type/scroll/drag, branded cursor), or explain its user-directed permission setup. Reading or discovering this skill is not consent."
---

# cmux-cua

cmux bundles a local computer-use engine (packaged as `cmux Computer Use` with
the MCP proxy named `cmux-cua`, from a pinned build of
the `manaflow-ai/cmux-cua` fork) and attaches it as an MCP tool server named
`cmux-cua` to every agent session cmux launches (Claude Code, Codex and the
other ACP harnesses).
The agent can then perceive and operate real macOS apps: read the accessibility
tree, take screenshots, and click / type / scroll / drag.

Everything runs locally through the bundled **cmux Computer Use** helper. The
helper has its own TCC identity, so Accessibility and Screen Recording never
belong to the main cmux app and granting Screen Recording never requires
restarting cmux. Upstream telemetry and update checks are disabled at runtime.

The tools never act on the user's cmux (`com.cmuxterm.app` and every
`com.cmuxterm.app.*` bundle and window), other terminal apps, the helper itself,
or macOS security surfaces: such a call returns `target_not_allowed` (its
`structuredContent.reason` says which) and must not be retried. A session may
drive its own tagged cmux DEV app only when its profile or preset env sets
`CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS=com.cmuxterm.app.debug.<tag>`.

Do not invoke this skill, start its helper, request permissions, or perform a
GUI action when the user is only reading, asking about, quoting, or mentioning
cmux Computer Use. Wait for a direct user request to use cmux Computer Use; missing tools
or permissions are not a reason to begin setup automatically.

## How it attaches

- cmux attaches it to every agent session it starts on this Mac: the acpmux
  daemon that runs the app's agent pane, the TUI, `cmux acp`, the Chief and
  their subagents, pooled sessions and forks adds an MCP server named
  `cmux-cua` (`<app>/Contents/Resources/bin/cmux-cua mcp`, with
  `CMUX_CUA_MCP_FORCE_PROXY=1` and the cursor branding env). Claude Code gets
  it through `--mcp-config` and this skill as `cmux:cmux-cua` from a
  session-only plugin; ACP harnesses (Codex, OpenCode, Pi, Gemini) get it in
  `session/new`. Source: `cmux-tui/crates/acpmux/src/agent_tools.rs`.
  Sessions started for a remote client (web, peer) never get it.
  `ACPMUX_AGENT_TOOLS=0` on the daemon turns the attachment off.
- Attachment is not consent. Starting an agent, listing tools or reading this
  skill is not a request to use computer use, and must not open a permission
  window or perform GUI work.
- When the user asks for `$cmux-cua`, use only the namespaced `cmux-cua` MCP
  tools below. Never substitute a harness's built-in computer tool, another
  computer-use connector, or a direct helper launch. If the `cmux-cua` tools
  are absent or fail to connect, report that and stop; do not switch
  providers.
- The proxy forwards to the **cmux Computer Use** helper (`com.cmuxterm.cua`)
  over its Unix socket and starts it on the first call. Only a helper signed
  with the cmux Developer ID (team `7WLXT3NR37`) is used
  (`Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/CuaHelperIdentity.swift`,
  `scripts/cmux-cua-helper-trust.sh`). A release, NIGHTLY or RC cmux carries
  it. A tagged dev build has no helper of its own (`reload.sh` removes an
  ad-hoc one), so dev builds use the helper of an installed NIGHTLY (or
  release or RC). With no signed helper installed, computer use is
  unavailable in that build; say so instead of trying to build or sign one.
- Agent activity (every computer use session, its timeline and thumbnails) is
  in the app's Agent activity pane, read from the same helper.

## Permissions (one-time, granted to the helper)

Two macOS permissions are required and are owned by **cmux Computer Use**, not
the main cmux app:

- **Accessibility** — inspect and drive app UI (`AXIsProcessTrusted`).
- **Screen Recording** — screenshots / vision (`CGPreflightScreenCaptureAccess`).

When the user has asked for cmux Computer Use through this skill, the first functional tool call from
a current cmux agent session opens setup automatically if setup is required.
Opening setup does not grant access: the user still completes each permission
step. Skill loading, prompt text, MCP discovery, `check_permissions`, cmux
startup, and agent resume never open setup. Settings → cmux Computer Use also opens
setup through **Finish Setup…**, **Grant…**, or **Open System Settings** and shows the two authoritative
permission states; choosing **Grant…** for an ungranted permission opens that
same permission step and its draggable helper-app recovery path. Each **Allow**
action opens the matching permanent System Settings pane in one step and stays
labeled **Allow** until the helper reports the grant; pressing it again simply
reopens the same pane. If macOS has not listed the helper yet, drag or add the
**cmux Computer Use** app tile to the list, then turn it on. cmux reads status
from the helper over its Unix socket, advances beside System Settings to the
next missing permission, and shows completion in place once both are granted.
On macOS Tahoe a third confirmation follows Screen Recording: the system's
direct-capture consent, an alert that says **cmux Computer Use** "is attempting
to bypass the system private window picker". That alert is expected — it comes
from onboarding's host-authenticated capture probe, onboarding explains it in
place, and the user must allow it before setup completes. Never "fix" it by
suppressing the probe; without that consent, agent screenshots on Tahoe fail.
The grants and this consent follow the helper's Developer ID signature, so
they survive helper updates. Never grant them to an ad-hoc signed copy: that
replaces the release helper's TCC rows.
Do not invoke `check_permissions {prompt:true}` or any standalone helper while
this flow is active: that creates the stray native permission dialogs this
onboarding deliberately avoids. The main cmux process never calls a TCC API or
executes the cmux-cua binary.

An unconfigured proxy waits for setup before forwarding its protected call.
If setup is not finished before the bounded wait ends, it returns **“cmux Computer Use onboarding is still in progress. Finish setup in cmux, then retry.”**
Retries do not repeatedly reopen a dismissed setup window. Resume a dismissed
flow with **Finish Setup…** in Settings, then retry the requested tool. Never
attempt to grant consent by calling a setup/status tool.

A TCC prompt naming **Codex Computer Use** (`com.openai.sky.CUAService`) is
not from cmux. The `codex` CLI ships its own computer-use helper; when codex
runs inside a cmux terminal and pokes that helper with an Apple Event, macOS
attributes the request to the responsible parent — the cmux app — so the
dialog reads as cmux asking to control "Codex Computer Use". Nothing in cmux
or the cmux-cua engine references that service; denying the prompt does not affect
cmux computer use.

If actions fail with a permission error, grant Accessibility to cmux Computer
Use. If screenshots come back blank, grant Screen Recording to cmux Computer
Use. The helper daemon refreshes/restarts to pick up the grant while cmux stays
open. Retry the tool call after onboarding reports both grants.

## Using the tools (agent-facing)

cmux already owns the MCP connection's session identity. Do **not** call
`start_session` / `end_session`, and do not pass a custom `session` argument.
The proxy binds every call to the originating cmux surface so the menu-bar
item, cursor, recording cleanup, and background/focus controls stay attached
to the right agent.

### Codex profile

Codex gets the exact ten-tool Computer Use roster, in order:

`list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `set_value`,
`select_text`, `scroll`, `drag`, `press_key`, `type_text`.

Use it like the built-in Computer Use connector:

1. Call `get_app_state` with the app name, full path, or unambiguous bundle id
   before acting. It launches the app if needed and returns the logical-size
   JPEG screenshot plus the compact accessibility tree.
2. Prefer the current snapshot's string `element_index`; use screenshot-local
   x/y coordinates only as fallback.
3. Use xdotool-style key strings such as `super+l` with `press_key`.
4. Operate controls with visible pointer clicks by default: the branded
   cursor gliding to each button and clicking is the product experience, so
   requests like “click 100 + 105” mean literal button-by-button pointer
   interaction on Calculator's buttons. Reserve `type_text` for entering text
   into text fields (search boxes, forms, editors) — not as a shortcut around
   clicking on-screen controls. Only fall back to a single keyboard sequence
   when the user explicitly asks for speed over visibility or a control has no
   clickable element.
5. Actions return a compact dispatch acknowledgement, not a screenshot or
   accessibility tree. After one or more actions, call `get_app_state` before
   deciding what to do next. The returned screenshot/tree is the authoritative
   verification surface, matching the built-in Computer Use connector.
6. Numeric `element_index` values belong only to the state that displayed them.
   Re-snapshot before using an index that may have been renumbered by a layout
   change (Calculator's **All Clear** removes display nodes, for example).
   Multiple coordinate actions against a stable layout may be issued in one
   host turn; do not batch element-index actions across a state-changing step.

Do not expect native cmux extensions such as `get_window_state`, tokens,
`perform_actions`, cursor controls, diagnostics, recordings, or browser/CDP in
this profile. Their absence is required for Codex schema parity.

### Claude/native cmux profile

Perceive, act in logical groups, then verify:

1. `get_window_state` (pid + window_id) returns the accessibility tree **and** a
   screenshot. Ground on both. Prefer element addressing.
2. Act by element: `click` with `element_token` (or `element_index` + pid +
   window_id) is the robust path. Pixel addressing (`x`,`y`) is the fallback.
3. For a stable, already-snapshotted control set, call `perform_actions` once
   with the ordered `click` / `type_text` / `press_key` / other input steps.
   This reuses the existing element-token cache and visible cursor inside the
   persistent proxy instead of paying one model/MCP round trip and AX scan per
   click. Do not put navigation, modal-opening, or layout-changing actions
   before later control references in the same group; re-snapshot immediately
   after any action that can invalidate those controls.
4. Verify the completed group by re-snapshotting and reading the element
   `value` / screenshot — do not assume actions landed (clicks are never
   helper-verified). Operate on-screen controls with visible pointer clicks by
   default — the gliding branded cursor is the product experience. Use
   `type_text` for entering text into text fields, and fall back to a pure
   keyboard sequence only when the user explicitly prefers speed over
   visibility.

Notes:
- In the native profile, use `list_apps` / `launch_app` / `list_windows` to
  find targets;
  `get_window_state` needs a `window_id` from `list_windows`.
- Catalyst apps (e.g. Calculator) can expose an empty AX tree briefly after
  launch and return spurious AX error codes (-25204) even when the action
  landed — re-snapshot and check the result rather than trusting the code.
- Pixel input is obstruction-checked: if another window covers the target
  point cmux-cua refuses with `background_occluded` naming the occluder
  instead of clicking the wrong window. Retry with `delivery_mode:"foreground"`
  or front the target.

## The branded agent cursor

The agent's pointer shows as the cmux logo gradient (`#12c7f5 → #2d8cff →
#6c5cff`) with a `cmux` label, so it is visually distinct from the user's
cursor. It is configured by env the attachment sets
(`CMUX_CUA_CURSOR_GRADIENT` / `_BLOOM` / `_LABEL`) and is auto-active while
the helper daemon is driving. It remains visible across normal reasoning gaps
and is removed when the driving session ends or the proxy control connection
closes. Each later action reasserts the cursor directly above the driven
target. If no cursor appears during an action, confirm the MCP config uses the
helper socket and that you passed your own `session` to `start_session` and
every action. The cmux-next app draws the same cursor for browser REPL input
(`plans/cmux-next/agent-cursor.md`).

## Finding and focusing the driving session

While an agent is driving, the **cmux Computer Use** menu-bar item projects only
the most recently active live agent session and offers two presentation modes:

- **Focus Computer Use** — bring forward the app the agent is driving and resume
  automatically following new targets.
- **Focus Calling Terminal** — return to the terminal that invoked Computer Use
  and reveal the exact workspace + surface running that agent while automation
  continues in the background.

The helper pins its cursor window directly above the driven target window at
the normal application window level. That keeps the cursor visible on the
target while allowing any app the user places in front of that target to cover
the cursor naturally; presentation mode never promotes it to an always-on-top
layer.

The active target and session ordering come from cmux-cua's per-session state
files under `~/Library/Application Support/cmux/cmux-cua/runtime/<scope>/state/`.

The item hides when there is no live or recent session. Toggle visibility in
Settings → cmux Computer Use.

## Troubleshooting

- **Agent has no computer-use tools** — the session was not started by cmux's
  acpmux daemon, the daemon has `ACPMUX_AGENT_TOOLS=0`, the daemon's
  executable is not the app's (no `cmux-cua` beside it), or the session has a
  remote origin. Start a fresh session from the cmux app.
- **Tools present, every call fails** — no Developer ID signed helper is
  installed (typical for a tagged dev build without a NIGHTLY install).
- **Clicks do nothing / not permitted** — grant Accessibility to cmux Computer Use.
- **Black/empty screenshots** — grant Screen Recording to cmux Computer Use;
  restart only the helper if its automatic refresh has not completed yet.
- **No menu-bar icon** — needs a live/recent session; check the visibility toggle.
- **Prompts name the main cmux app** — a non-cmux fallback executed the helper
  directly. Stop there and report the failure; the bundled path must use the
  tag-scoped socket with `CMUX_CUA_MCP_FORCE_PROXY=1`.
- **Prompts name CmuxCua** — a stale `/Applications/CmuxCua.app` daemon or a
  standalone helper launch is active. Stop it and reset/remove its TCC entry;
  the bundled path never uses that identity.

## Development

- Engine source: `manaflow-ai/cmux-cua` (`libs/cmux-cua/rust`). cmux consumes
  it via `CMUX_CUA_PINNED_SHA` in `scripts/build-cmux-cua.sh`, which builds,
  and lipos the `cmux-cua` client into `Contents/Resources/bin`. Only release,
  NIGHTLY and RC builds carry a signed nested helper.
- The helper daemon's `CMUX_CUA_EXTERNAL_PERMISSION_FLOW=1` prevents
  agent-supplied `check_permissions {prompt:true}` from bypassing cmux
  onboarding. The attachment sets `CMUX_CUA_MCP_FORCE_PROXY=1`, so the
  proxy never runs computer use in the agent's own process.
  There is no ambient executable override. Both profiles resolve the app-bundled
  `cmux-cua` executable and the tag-scoped helper only; missing ownership fails
  closed instead of running a user-supplied executable.
- If the cmux-owned daemon is unavailable, do **not** invoke `cmux-cua`
  directly through Bash and do not start its default socket. Tell the user to
  open Settings → cmux Computer Use or restart the tagged cmux build, then retry the
  MCP tool after the helper runtime is healthy.
- Never hand-edit `docs/.../cmux-cua/mcp-tools.mdx` in the fork — it is
  generated from the Rust tool descriptions.
- The attachment lives in `cmux-tui/crates/acpmux/src/agent_tools.rs`; the
  helper identity rule and the Agent activity pane in
  `Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/`; the design in
  `plans/cmux-next/computer-use.md`.
