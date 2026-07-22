# cmux cua computer use

cmux bundles `cua-driver` from the `manaflow-ai/cmux-cua` fork of trycua/cua
and exposes it as an MCP server named `cmux-computer-use` for compatibility
with existing cmux-launched agents.

Claude Code and Codex CLI sessions launched by cmux receive the server
automatically at session start (injection is implemented in
`cmux-claude-wrapper` and `cmux-codex-wrapper`); no user MCP configuration is
required for them. Other agents are not currently supported: the socket proxy
requires the per-launch credential that cmux injects into its own terminal
process tree. Do not configure the bundled driver with `--embedded`; that would
grant Accessibility and Screen Recording to the main terminal host and bypass
the separately permissioned **cmux Computer Use** helper.

The user grants Accessibility and Screen Recording to the helper once. A
cmux-launched agent then connects through the authenticated, variant-scoped
socket and can perceive the desktop through screenshots and accessibility
trees and act with click, type, scroll, hotkey, drag, app, window, cursor, and
diagnostic tools.
cmux's injection disables the upstream driver's telemetry and self-update
checks; cmux manages application updates through Sparkle.

Risk gating is handled by the MCP client harness. Claude Code and Codex show
their normal tool approval UI for actions, and `cua-driver` advertises tool
annotations such as read-only and destructive. The retired cmux Node MCP
elicitation layer is intentionally gone: keeping the approval decision in the
client avoids a second, cmux-specific approval queue and matches the
Codex/ChatGPT desktop app model more closely.

Set `CMUX_COMPUTER_USE_MCP_DISABLED=1` before launching an agent to disable
automatic computer-use MCP injection. Development builds may set
`CMUX_CUA_DRIVER=/absolute/path/to/cua-driver`; cmux only uses that override
when the bundled driver is absent and the override path is executable with
trusted ancestors.

## Building the bundled driver

Every cmux app build runs `scripts/build-cua-driver.sh`, which compiles the
pinned `manaflow-ai/cmux-cua` commit with Cargo and bundles the resulting
binary as `Contents/Resources/bin/cmux-cua-driver`. This requires a Rust
toolchain on the build machine:

- local dev: install via [rustup](https://rustup.rs) (or
  `brew install rustup && rustup-init`); `rustup` also lets the script add the
  `aarch64-apple-darwin`/`x86_64-apple-darwin` targets it needs
- CI: `scripts/install-rust-ci.sh`

The pinned source is cached under `~/Library/Caches/cmux/cua-driver`; after
the first successful build no network access is needed until the pinned
commit changes. Set `CMUX_CUA_SRC=/path/to/cmux-cua` to build from a local
checkout (it must still be at the pinned commit).
