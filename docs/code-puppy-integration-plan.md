# Code Puppy integration contract

Code Puppy uses cmux's shared detection, hook status, Feed, session-index and
resume paths. The adapter is a managed Python callback plugin, not a PATH shim
and not a second session database. See [agent-hooks.md](agent-hooks.md#code-puppy-callback-plugin)
for installation and environment controls.

## Why native JSON hooks were replaced

Runtime fixtures exercised the native hook engine in Code Puppy source 0.0.643
and installed 0.1.69. Its JSON schema accepts cmux's nested groups, but the
payload does not provide the required behavior:

- Startup, tools and teardown use the placeholder `codepuppy-session`.
- Prompt/completion IDs are per-run UUIDs, not autosave names. Passing them to
  `--resume` can create an empty session instead of restoring the conversation.
- The default Code Puppy agent completes through `SubagentStop`, not `Stop`.
- Success/error fields supplied to completion callbacks are omitted from the
  native hook executor's stdin payload.
- The previous shell fallback printed `{}` into prompt/tool hook context even
  when cmux dispatch was disabled.

The former native-hooks-only plan was therefore not equivalent to issue
[#5587](https://github.com/manaflow-ai/cmux/issues/5587). The callback plugin
reads the canonical current autosave name in-process and carries the actual
completion outcome to existing cmux handlers. No Code Puppy modification is
required.

## Installation and ownership

`cmux hooks setup code-puppy`, `cmux hooks code-puppy install --yes` and the
explicit `pup` alias install:

- `~/.code_puppy/plugins/cmux-session/register_callbacks.py`;
- a cmux-owned record in `external_plugins.json` under Code Puppy's config root.

Current Code Puppy versions discover the plugin directory directly and ignore
XDG for plugin discovery; the JSON registry is cmux ownership metadata, not an
assumed native loader API.
Installation is idempotent. Uninstall removes only the owned module and
registration. Unknown modules, registry collisions, malformed files and
symlinks are rejected rather than overwritten. Unrelated plugins and hook
entries remain intact. Setup removes only cmux-owned legacy `hooks.json`
entries so the callback and native engines cannot double-report.

The producer is generated in `CMUXAgentLaunch`; target-specific CLI code only
resolves locations and applies installation edits. This keeps executable-path
escaping and registration ownership independently testable.

## Lifecycle and tool contract

| Code Puppy callback | Shared cmux event |
| --- | --- |
| Root `agent_run_start` | `session-start`, `prompt-submit` |
| `pre_tool_call` | `pre-tool-use`, Feed `PreToolUse` |
| `post_tool_call` | `post-tool-use`, Feed `PostToolUse` |
| Root `agent_run_end` | `stop`, with explicit success/error |
| `shutdown` | `session-end` |

Nested runs do not replace the root identity. Managed subagents do not publish
parent status. Calls retain the launching terminal's CLI/socket attribution,
carry the existing PID environment contract, capture subprocess output, and
have a bounded timeout. No callback returns extra model context. The plugin
is inert without `CMUX_SURFACE_ID` or with
`CMUX_CODE_PUPPY_HOOKS_DISABLED=1`.

Existing shared handlers own running/ready/error status, notifications, journal
admission and teardown. Code Puppy does not introduce a separate status store.
This integration reports tool telemetry; it does not claim interactive Feed
approval parity with agents that expose a blocking decision callback.

## Detection and restore

The shared registration owns launch/config aliases, process matchers, icon,
hook events and resume options. Direct detection accepts `code-puppy` and
`code_puppy`; Python console-script and `python -m code_puppy` entrypoints use
the existing alternate-argv path. Bare `pup` is deliberately not a process
matcher because the unrelated HTML parser has that executable name. `pup`
remains an explicit launch/config/hook alias. The icon uses `pawprint`, available
on supported macOS versions.

Vault preserves explicit `--resume` detection. Ordinary launches obtain their
resume identity from the plugin and the existing generic registry hook store
(`~/.cmuxterm/code-puppy-hook-sessions.json`). cmux rejects the startup
placeholder, traversal and non-durable run IDs. An autosave file must exist
before a binding is persisted; completion/subsequent hooks retry after saving.
Old bare autosave suffixes are accepted only when the corresponding persisted
file proves the full name. No latest-by-directory or timestamp guessing is
used to match panes.

Resume uses `code-puppy --resume <autosave-name>` through shared argv building
and launch sanitization. Supported model/agent options and working directory
are retained; prior resume targets and prompt-only invocations are not blindly
replayed.

## Paths and configuration

Code Puppy has **no `CODE_PUPPY_HOME`**. Its explicit-XDG convention is:

| Content | Explicit override | Default |
| --- | --- | --- |
| Config/ownership registry | `$XDG_CONFIG_HOME/code_puppy` | `~/.code_puppy` |
| Discovered plugins | none (hard-coded in tested releases) | `~/.code_puppy/plugins` |
| Autosaves | `$XDG_CACHE_HOME/code_puppy/autosaves` | `~/.code_puppy/autosaves` |

Restore captures `XDG_CACHE_HOME`. Global default-agent selection accepts the
Code Puppy aliases through the shared config type and agent registration.
Product names remain invariant across locales; surrounding CLI/UI labels are
localized.

## Verification scope

Package tests cover generation, ownership, canonical identity, shared resume
argv and environment capture. Runtime fixtures use Code Puppy's real callback
loader with a fake cmux executable; they do not establish live app behavior.
App/CLI tests cover installation migration, ordinary-launch hook-store restore,
Python-hosted detection and lifecycle/tool handling.

A package pass, Swift syntax parse or source-wiring check is not an app test
pass. Native compilation and focused app tests remain required when dependency
downloads permit them. Tagged dogfood must verify a plain launch, tool status,
completion/error, shutdown cleanup, same-session restore and multiple panes.
Never use the user's running production app for build or relaunch experiments.
