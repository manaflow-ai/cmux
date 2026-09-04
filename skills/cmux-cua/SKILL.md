---
name: cmux-cua
description: "Drive real macOS apps from a cmux agent session via the bundled computer-use engine (accessibility tree + screenshot perception, click/type/scroll/drag, branded agent cursor). Use when an agent should see and operate GUI apps on the local Mac, when computer-use tools are missing or failing, or when explaining how to grant permissions, brand the cursor, or focus the driving session."
---

# cmux-cua

cmux bundles a local computer-use engine (packaged as `cmux Computer Use` with
the MCP proxy named `cmux-cua`, from a pinned build of
the `manaflow-ai/cmux-cua` fork) and attaches it as an MCP tool server named
`cmux-cua` to every agent session cmux launches (Claude Code, Codex).
The agent can then perceive and operate real macOS apps: read the accessibility
tree, take screenshots, and click / type / scroll / drag.

Everything runs locally through the bundled **cmux Computer Use** helper. The
helper has its own TCC identity, so Accessibility and Screen Recording never
belong to the main cmux app and granting Screen Recording never requires
restarting cmux. Upstream telemetry and update checks are disabled at runtime.

## How it attaches

- The `cmux-claude-wrapper` and `cmux-codex-wrapper` inject `cmux-cua` as an
  MCP proxy using `mcp --socket <cmux-owned socket>` plus cursor-branding and
  state-dir env. Codex launches the exact tag-installed helper executable as
  its authenticated approval broker; Claude uses the bundled native-profile
  proxy client. The Codex wrapper additionally passes
  `--codex-computer-use-compat`; the Claude wrapper deliberately does not.
  No user setup per session — start `claude` or `codex` inside cmux and the
  corresponding tool profile is there.
- `ComputerUseRuntimeService` is the only helper lifecycle owner. It installs
  the nested helper under the tag-scoped
  `~/Library/Application Support/cmux/cmux-cua/helper/<scope>/` directory
  and launches that explicit app URL through LaunchServices.
- The native daemon uses the tag-scoped
  `/tmp/cmux-cua-<uid>/<scope>/cmux-cua.sock`; the Codex compatibility daemon uses
  `cmux-cua-codex.sock` beside it. Both fit Darwin's Unix-socket path limit and share
  the tag-scoped cmux Application Support state directory.
- The wrappers keep the signed, app-bundled skill discoverable in both agent
  pickers: each repairs the link in its agent's own root before launching —
  `~/.claude/skills/cmux-cua` for Claude, `~/.agents/skills/cmux-cua` for
  Codex (migrating any older cmux-owned `cmux-computer-use` link) — so the
  picker shows one plain `cmux-cua` entry. Codex falls back to an
  invocation-scoped `skills.config` entry only when that repair fails; there
  is deliberately no Claude plugin fallback and no plugin manifest in this
  directory, because a manifest makes Codex namespace the skill
  (`cmux-cua:cmux-cua`) and Claude display it plugin-qualified. A user-owned
  directory or unrelated symlink at that path is never replaced. Set
  `CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL=0` when a strictly session-local
  launch is required.
- While Computer Use is enabled, the helper daemon starts quietly at cmux
  startup with its internal permission gate disabled. Starting cmux or an agent
  never requests access or shows onboarding.
- Wrappers are pure forced proxies. They never copy or launch the helper and
  never fall back to in-process computer use. cmux owns the onboarding window
  and opens the permanent macOS permission panes directly; it does not ask the
  helper to raise an intermediate native prompt. The proxy keeps its
  external-flow flag on so the first driving call waits for both helper grants
  before it is forwarded.
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
or agent startup. Settings → Computer Use always shows the two authoritative
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
The consent follows the helper's code signature, so every rebuilt (ad-hoc
signed) dev helper re-triggers it: cmux invalidates its cached
direct-capture-ready flag whenever it replaces the installed helper build,
which re-presents onboarding so the alert always lands with its explanation.
Do not invoke `check_permissions {prompt:true}` or any standalone helper while
this flow is active: that creates the stray native permission dialogs this
onboarding deliberately avoids. The main cmux process never calls a TCC API or
executes the cmux-cua binary.

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
cursor. It is configured by env the wrapper injects
(`CMUX_CUA_CURSOR_GRADIENT` / `_BLOOM` / `_LABEL`) and is auto-active while
the helper daemon is driving. It remains visible across normal reasoning gaps
and is removed when the driving session ends or the proxy control connection
closes. Each later action reasserts the cursor directly above the driven
target. If no cursor appears during an action, confirm the MCP config uses the
helper socket, has a stable `CMUX_CUA_DEFAULT_SESSION`, and uses the pinned
  cmux-cua build.

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
Settings → Computer Use.

## Troubleshooting

- **Agent has no computer-use tools** — Settings → Computer Use must be on;
  start a *new* session (tools attach at launch).
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
  lipos, and codesigns the binary plus the nested helper into the app bundle.
- The helper daemon's `CMUX_CUA_EXTERNAL_PERMISSION_FLOW=1` prevents
  agent-supplied `check_permissions {prompt:true}` from bypassing cmux
  onboarding. The wrappers set `CMUX_CUA_MCP_FORCE_PROXY=1` and preserve
  the external-flow contract in the proxy process so protected calls wait for
  cmux's post-verification readiness signal.
  There is no ambient executable override. Both profiles resolve the app-bundled
  `cmux-cua` executable and the tag-scoped helper only; missing ownership fails
  closed instead of running a user-supplied executable.
- If the cmux-owned daemon is unavailable, do **not** invoke `cmux-cua`
  directly through Bash and do not start its default socket. Tell the user to
  open Settings → Computer Use or restart the tagged cmux build, then retry the
  MCP tool after the helper runtime is healthy.
- Never hand-edit `docs/.../cmux-cua/mcp-tools.mdx` in the fork — it is
  generated from the Rust tool descriptions.
- cmux-side UX lives in `Sources/App/ComputerUse*.swift`,
  `Packages/macOS/CmuxSettingsUI/.../Sections/ComputerUseSection.swift`, and the
  two wrappers under `Resources/bin/`.
