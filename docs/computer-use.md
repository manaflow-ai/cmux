# cmux Computer Use

cmux bundles `cmux-cua` from the `manaflow-ai/cmux-cua` fork of trycua/cua
and exposes it as an MCP server named `cmux-cua`.

Claude Code and Codex CLI sessions launched by cmux receive the server
automatically at session start (injection is implemented in
`cmux-claude-wrapper` and `cmux-codex-wrapper`); no user MCP configuration is
required for them. The Claude wrapper retains cmux's broad native tool surface.
The Codex wrapper launches the tag-installed helper executable as its
authenticated MCP broker and adds `--codex-computer-use-compat`, which
presents the exact Codex Computer Use server identity, ten-tool order, schemas,
annotations, app-oriented arguments, screenshot/tree result shape, and
approval flow while still running on cmux's own engine. Other agents are not
currently supported:
the socket proxy requires the per-launch credential that cmux injects into its
own terminal process tree. Do not configure the bundled cmux-cua engine with
`--embedded`; that would grant Accessibility and Screen Recording to the main
terminal host and bypass the separately permissioned **cmux Computer Use**
helper.

Codex's built-in `@computer` entry is an OpenAI-bundled plugin. cmux does not
replace that plugin: it supplies its own local MCP server and the
`$cmux-cua` skill. Neither wrapper installs global skills or adds automatic skill
directories by default. Use your agent's normal skill installer for a persistent
user-owned installation. Codex 0.153 treats `skills.config` paths as enable/disable
rules, not discovery roots; cmux does not inject an ineffective session fallback.

Alternatively, `CMUX_COMPUTER_USE_INSTALL_GLOBAL_SKILL=1` is a per-launch
preference for an app-managed global link: `~/.agents/skills/cmux-cua` for Codex
or `~/.claude/skills/cmux-cua` for Claude. Export the flag for future launches
to retain these links; they are user-global and may also appear outside cmux.
With the flag unset or `=0`, a cmux agent launch removes only verified
app-managed links. A same-name project or user-owned skill takes precedence:
the wrapper does not create a competing global link or hide the existing skill.

Migration of `cmux-cua`, `cmux-computer-use`, and `codex-cua` links requires an
existing cmux bundle with a verified bundle ID, known install/build root, and
root/current-user ownership. Real skill directories, unrelated symlinks, and
project skills remain untouched. Unknown or dangling targets lack that proof
and require manual review; `CMUX_CUA_DIAGNOSTICS=1` reports preserved paths
blocking explicit install and verified managed links retired by the per-launch
policy. Historical app-created and manually-created symlinks with identical
verified targets cannot be distinguished retroactively; recognized app-bundle
links are treated as cmux-managed, while unknown and dangling links remain
preserved. No plugin manifest or temporary projection is shipped. Final picker
rendering and selection are owned by the agent client.

While Codex runs inside a cmux terminal, its CLI also Apple-Events its own
"Codex Computer Use" (`com.openai.sky.CUAService`) helper. macOS attributes
that request to the enclosing terminal app, so a consent dialog naming the
cmux build and "Codex Computer Use" can appear. It is not cmux's helper or
cmux-cua engine sending anything (the same TCC entry appears for Ghostty and every
terminal Codex has run in); allowing or denying it only affects Codex's own
computer-use path.

The user grants Accessibility and Screen Recording to the helper once. A
cmux-launched agent then connects through the authenticated, variant-scoped
socket and can perceive the desktop through screenshots and accessibility
trees and act with click, type, scroll, hotkey, drag, app, window, cursor, and
diagnostic tools.
cmux's injection disables the upstream cmux-cua engine's telemetry and self-update
checks; cmux manages application updates through Sparkle.

Onboarding is opened only by a deliberate user action in Settings → Computer
Use (the **Grant…** or **Open System Settings** permission controls). Launch or
resume, MCP/skill discovery, helper status checks, protected tool calls, and
prompt or UI text never present it and never establish consent. This keeps a
model's decision to select a tool separate from the user's decision to grant
Accessibility and Screen Recording. A first-time natural-language request
therefore requires the one-time Settings setup action; cmux has no trusted
structured invocation signal from the agent picker to safely infer consent.

The Settings action uses the same onboarding flow: its first **Allow** action
goes directly to the matching permanent System Settings pane instead of
raising a second native TCC prompt first. If the helper is absent from the
permission list, the compact companion supplies a draggable **cmux Computer
Use** app tile; add it, turn it on, and let onboarding advance after the helper
reports the grant. The companion is a nonactivating panel: dragging its tile or
pressing Back never activates cmux, so the main terminal window cannot rise
over the System Settings pane mid-drag. On macOS Tahoe, turning Screen
Recording on is followed by the system's separate direct-capture consent —
an alert saying the helper "is attempting to bypass the system private window
picker". This is expected; onboarding says so in place, and allowing it is
required before setup can complete. Agents must not call a standalone helper's
permission prompt while onboarding is active, because that creates unrelated
permission dialogs under the wrong process identity.

The host keeps the helper's readiness phase authoritative. An already attached
but unconfigured proxy can still wait for its external readiness milestone and
then return the pinned helper's setup-required response, **“Computer Use
onboarding is still in progress. Finish setup in cmux, then retry.”** That
response is bounded by the helper's current 55-second poll and is intentionally
documented here rather than bypassing permission readiness or silently opening
the window. Existing users who completed setup retain their helper readiness;
revoked permissions remain quiet until the user deliberately re-enters Settings.

Risk gating is handled by the MCP client harness. Claude Code and Codex show
their normal tool approval UI for actions, and `cmux-cua` advertises the
profile-specific annotations. Codex app approval is brokered through its
negotiated MCP elicitation capability and authenticated to the signed Codex
parent; a raw socket client cannot reuse that approval session. The retired
cmux Node MCP elicitation layer is intentionally gone.

## Agent-specific tool contracts

Codex receives exactly these tools, in this order:

`list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `set_value`,
`select_text`, `scroll`, `drag`, `press_key`, and `type_text`.

This profile intentionally has no cmux-only lifecycle, cursor, recording,
diagnostic, browser/CDP, or `perform_actions` tools. `get_app_state` accepts an
app name, path, or unambiguous bundle identifier and returns the Codex-shaped
logical-window screenshot plus accessibility tree. Its string
`element_index` values are valid only for the current app snapshot. Mutating
actions return a compact acknowledgement; perception is explicit through
`get_app_state`, so one host turn can perform several safe actions and then
take one authoritative screenshot/tree refresh.

Claude Code continues to receive the broader native cmux contract. It uses
pid/window addressing, `get_window_state`, stable snapshot tokens, explicit
cursor and diagnostic controls, and proxy-only `perform_actions`. Keeping the
profiles separate prevents a cmux extension from silently changing Codex's
built-in Computer Use schema.

`cmux-cua` is the one bundled command-line executable and MCP server. MCP is
its machine-readable stdio protocol—not a separate user-installed service—and
no Node, Sky, or legacy bridge is involved.

Set `CMUX_COMPUTER_USE_MCP_DISABLED=1` before launching an agent to disable
automatic computer-use MCP injection. There is no ambient executable override:
both wrappers fail closed unless the app-bundled `cmux-cua` client and the
tag-scoped cmux helper are present.

## Building the bundled cmux-cua engine

Every cmux app build runs `scripts/build-cmux-cua.sh`, which compiles the
pinned `manaflow-ai/cmux-cua` commit with Cargo and bundles the resulting
MCP proxy as `Contents/Resources/bin/cmux-cua`. The same
engine is packaged as the `cmux Computer Use.app` executable (`cmux-cua`) so Activity
Monitor and permission UI show the product name instead of an implementation
name. This requires a Rust
toolchain on the build machine:

- local dev: install via [rustup](https://rustup.rs) (or
  `brew install rustup && rustup-init`); `rustup` also lets the script add the
  `aarch64-apple-darwin`/`x86_64-apple-darwin` targets it needs
- CI: `scripts/install-rust-ci.sh`

The pinned source is cached under `~/Library/Caches/cmux/cmux-cua`; after
the first successful build no network access is needed until the pinned
commit changes. Set `CMUX_CUA_SRC=/path/to/cmux-cua` to build from a local
checkout (it must still be at the pinned commit).
