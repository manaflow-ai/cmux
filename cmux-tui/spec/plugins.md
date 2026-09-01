# Plugin Contract

This document specifies the mux-side sidebar plugin contract.

## Sidebar Plugins

A sidebar plugin is an executable terminal program. The mux server starts it inside a PTY and the TUI renders that PTY in the sidebar using the same Ghostty VT surface pipeline used by pane PTYs.

### Configuration

`~/.config/cmux/cmux-tui.json` (or legacy `mux.json` when the new file is absent):

```json
{
  "sidebar": {
    "plugin": {
      "command": ["/path/to/plugin-binary"],
      "cwd": "/optional"
    }
  }
}
```

When `sidebar.plugin` is absent, the built-in view selected by `sidebar.view` is used (`workspaces` by default, or `files`). When present, the plugin replaces either built-in view. In a local TUI session, `reload-config` applies this key through the existing config reload path. A headless server or attached-client setup may require restarting the server process so the server, not the attach client, picks up the plugin command.

The sidebar content PTY is sized to the sidebar content cells. The host TUI keeps one separator/focus-border column at the right edge. Resizes use normal PTY resizing (`TIOCSWINSZ` on Unix), so plugins observe the standard terminal resize behavior and `SIGWINCH`; there is no plugin-specific resize protocol.

### Environment

The child process receives:

| Variable | Value |
| --- | --- |
| `CMUX_TUI_SOCKET` | The server process control socket path for this cmux-tui session. |
| `CMUX_MUX_SOCKET` | Legacy alias for `CMUX_TUI_SOCKET`. |
| `CMUX_SIDEBAR` | `1`. |
| `TERM` | The same TERM configured for ordinary PTY surfaces. |

The plugin runs in the server process context. Attached TUI clients request and render the server-owned plugin surface; they do not spawn their own plugin process.

### Lifecycle

The mux starts the plugin when the plugin sidebar first becomes visible. Hiding the sidebar stops rendering but does not kill the plugin. The plugin is killed when the mux server exits or when config changes remove or replace the plugin command.

If the plugin exits or fails to start, the TUI renders a visible error message in the sidebar. The server records a bounded restart backoff and will not hot crash-loop. Focusing the sidebar requests a relaunch after the backoff has elapsed.

### Focus And Input

When a plugin is configured, `focus-sidebar` focuses its PTY. The default binding is `prefix S`.

While the sidebar is focused, key and paste input are forwarded as PTY bytes using the same key encoder and terminal-mode state as pane PTYs. The global prefix chord is the escape hatch back to cmux:

- `prefix prefix` sends a literal prefix key to the plugin and keeps sidebar focus.
- `prefix <command>` leaves sidebar focus and runs the normal cmux prefixed command.
- `prefix S` leaves sidebar focus when already focused.

Mouse input is not forwarded to sidebar plugins in this round. PTY pane mouse forwarding applies only to pane content; clicking inside the plugin sidebar focuses it.

### Manifest

Plugin directories use `cmux-plugin.toml` at the directory root:

```toml
[plugin]
name = "fzf"
kind = "sidebar"
version = "0.1.0"
description = "Fuzzy-find workspaces, screens, and panes"
platforms = ["macos", "linux", "windows"]

[run]
command = ["target/release/cmux-sidebar-fzf"]

[build]
command = ["cargo", "build", "--release"]
```

The host reads the already-installed command from the cmux-tui config. The plugin
manager installs sidebar plugins from git repositories and writes the resolved
command into that config file.

`plugin.platforms` is optional. When present, it is a non-empty list from
`macos`, `linux`, and `windows`, with no duplicates. The manager rejects an
install, use, or update when the current platform is not listed. `list` still
shows an incompatible installed plugin and reports `platform_supported=false`,
so a user can remove it or move the installation to a supported host.

## Install Layout

Installed plugins live under:

```text
~/.local/share/cmux/mux-plugins/<name>
```

When `$XDG_DATA_HOME` is set, the equivalent directory is:

```text
$XDG_DATA_HOME/cmux/mux-plugins/<name>
```

`<name>` is either `[plugin].name` from `cmux-plugin.toml` or the
`cmux sidebar plugin install --name <override>` value. Names must match
`[a-z0-9-_]+` and be at most 64 bytes; path traversal and mixed-case names are rejected. Install clones
to a temporary directory first, validates the manifest, runs `[build].command`
when present, verifies the resolved `[run].command[0]` exists and is
executable, then moves the directory into place. Existing installs are refused
unless `--force` is supplied.

Relative manifest run commands are resolved to absolute paths under the plugin
directory before `sidebar plugin use` writes the runnable command into the cmux-tui config.

## Agent Plugins

An agent plugin is a server-side background executable. It does not run in a
sidebar PTY and it does not add agent code to cmux core. Core owns process
supervision, environment setup, journal admission, and roster reduction. The
plugin owns process-group discovery, screen sampling, manifest rules, and
agent-specific interpretation.

### Configuration

The selected plugin is stored in `~/.config/cmux/cmux-tui.json`:

```json
{
  "agents": {
    "plugin": {
      "id": "agent_plugin_0123456789abcdef0123456789abcdef",
      "command": ["/absolute/path/to/cmux-agent-screen-detection"],
      "cwd": "/absolute/path/to/plugin",
      "revision": "sha256-..."
    }
  }
}
```

`id` is the stable producer identity and must match
`[a-z0-9][a-z0-9_-]*` (maximum 64 bytes). `command[0]` and `cwd` must be absolute.
The built-in `cmux_agent` hook producer ID is reserved and cannot be used by a
userland plugin.
`revision` is optional for hand-written configuration, but the plugin manager
writes a content-derived value. A changed revision restarts the child even
when the command path is unchanged. Invalid replacement configuration disables
the previous child instead of leaving stale detection active.

The supervisor passes `CMUX_TUI_SOCKET`, `CMUX_MUX_SOCKET`,
`CMUX_TUI_SESSION_ID`, `CMUX_PLUGIN_ID`, `CMUX_PLUGIN_REVISION`,
`CMUX_PLUGIN_GENERATION`, `CMUX_PLUGIN_PROTOCOL_VERSION=1`,
`CMUX_PLUGIN_KIND=journal`, `CMUX_JOURNAL_PLUGIN=1`, and the compatibility
hint `CMUX_AGENT_PLUGIN=1`. The socket is already bound before the child
starts. A plugin that emits restart-fenced observations should copy
`CMUX_PLUGIN_GENERATION` into its event's `normalized.plugin_generation` field.

### Lifecycle

Core starts one child after the resource socket is bound. An unexpected exit
creates a normal `agent.plugin.exited` journal event for that producer, then
restarts it with bounded exponential backoff. The reducer removes only entries
owned by the exited producer and, for a tagged child, by that exact exited
generation. Untagged compatibility rows use the exit timestamp as their limit,
and untagged observations stay fenced after an exit because they cannot prove
that they belong to a replacement. This prevents a crash from removing a
replacement process that has already reported. Config reload stops the old
child before starting the replacement.
On Unix the child starts in a dedicated process group and shutdown signals the
whole group. On Windows the child starts suspended, is assigned to a Job Object
with kill-on-close, and is resumed only after ownership is established. A Unix
plugin that calls `setsid` can leave that group; plugins must keep helper
processes in the inherited group or provide their own cleanup.
Generation fences protect the journal from late records, but Unix PID and
process-group identifier reuse remains a platform race. The detector treats a
foreground group as authoritative only when the host reports the current
group; a public-process fallback cannot prove replacement identity.

### Journal boundary

Agent plugins use the generic `session.journal.producer.put` and
`session.journal.append` operations. A producer manifest declares a namespace
of `plugin.<producer_id>`, event schemas, maximum sensitivity, and the
`journal.append.<namespace>` permission. Event payloads use the stable
`cmux.agent-plugin.v1` envelope when they are intended for the built-in agent
roster reducer:

```json
{
  "format": "cmux.agent-plugin.v1",
  "plugin": {"id": "agent_plugin_...", "version": 1},
  "adapter": {"id": "codex", "version": 1},
  "event": "state.changed",
  "normalized": {
    "state": "working",
    "source_session": "pid:123",
    "plugin_generation": "7",
    "observed_at_ms": "1730000000000"
  },
  "native": {}
}
```

The core reducer accepts this envelope without knowing the adapter catalog.
Its source order is hook, plugin, detected legacy replay, then socket. A fresh
hook blocks a plugin observation for 30 seconds. The plugin remains a normal
journal producer, so replay, remote clients, and durable projections use the
same event stream.

`session.journal.producer.list` returns userland producer manifests only. The
reserved cmux hook manifest is kept in the daemon's internal producer table,
but is omitted from this operation because its legacy `agent` namespace is not
a userland `plugin.<id>` namespace.

### Terminal metadata

The generic `terminal.screen.read` result may include `revision` and
`osc_progress`. Either field may be absent or null when the server cannot
provide it. `revision` is a coalesced PTY output counter. `osc_progress` is
bounded OSC 9 payload text captured by the terminal protocol layer. Core does
not interpret either field as an agent signal. A plugin may combine them with
the screen text, OSC title, and process metadata.

The process result includes the PTY foreground executable. Native process-group
inspection remains a plugin concern, so a plugin can add wrapped runtime
arguments and child processes without a daemon schema change. If the host does
not permit inspection, the plugin must use the one-process fallback.

### Manifests and updates

An agent plugin package declares `kind = "agent"` in `cmux-plugin.toml`:

```toml
[plugin]
name = "agent-screen-detection"
kind = "agent"
version = "0.1.0"
platforms = ["macos", "linux"]

[run]
command = ["target/release/cmux-agent-screen-detection"]

[build]
command = ["cargo", "build", "--release"]
```

The manager installs agent packages under
`~/.local/share/cmux/mux-plugins/agent/<name>` (or the equivalent
`$XDG_DATA_HOME` path), validates the manifest, runs its declared build, and
checks the executable before writing the selected config. Installation and
build execute third-party code with the user's permissions. Core does not
sandbox a plugin. Artifact replacement and selected-config replacement use a
local rollback guard, but they are separate filesystem transactions. A power
loss between those writes can leave an old artifact with new configuration (or
the reverse); startup validation disables an invalid selection and the next
explicit install or update repairs it.

The reference screen detector keeps the 21 herdr-derived manifests in the
plugin package. It loads bundled files first, then a bounded cache, then an
explicit local override directory. `cmux-agent-screen-detection update` is
the only network update path. The scanner never performs implicit network I/O,
so startup does not depend on a catalog, DNS, or a remote service. Update
failures are recorded per agent and never replace a valid cached manifest.

The herdr source and Apache-2.0 license attribution are listed in
`cmux-tui/ATTRIBUTIONS.md` and the plugin package `ATTRIBUTIONS.md`. The
vendored manifests are unchanged at the pinned commit. Files adapted from
herdr carry the upstream path and pinned commit in their header.

### Herdr capability coverage

The reference package covers the agent-detection capabilities that can be
shared without importing herdr's application into cmux:

| Herdr capability | Userland package behavior |
| --- | --- |
| Screen manifests | 21 manifests are bundled and replaceable. Herdr lists 23 agent kinds, but OMP and Mastracode have no screen manifest at the pinned revision. |
| Identity aliases and wrappers | Manifest aliases, shell/runtime arguments, package launchers, process groups, and a public-process fallback are supported. Linux can opt into bounded child-group inference with `CMUX_AGENT_PROCESS_DETECTION=child-groups` when a controlling-terminal group is unavailable. |
| Regions and gates | Recent-screen regions, prompt and viewer slices, OSC title/progress regions, `all`, `any`, `not`, literal, regex, and line-regex gates are supported with bounded complexity. |
| Rule priority and visibility | Numeric priority, idle fallback, blocker/working/idle visibility hints, and `skip_state_update` are preserved. |
| Stable polling and journal delivery | Quiescence debounce, a one-second maximum evaluation pacer, startup grace, six-miss identity hysteresis, same-name process-group replacement edges, activity expiry, pending idle, blocker refresh, and process-exit edges are supported. Each edge is committed only after journal admission. An uncertain transport result retains the exact envelope and idempotency key for bounded-backoff replay before a newer edge. Process hints and adaptive process-info cache intervals reduce process-tree work without delaying unknown-agent discovery. |
| Explain and update diagnostics | `explain`, `list`, `status`, and explicit HTTPS `update` commands expose matcher evidence, source precedence, versions, and per-agent failures. |

The following inventory records the agent-facing herdr capabilities that are
outside this package. This prevents a future change from silently moving
application policy into cmux core.

| Herdr capability | Status in cmux | Boundary decision |
| --- | --- | --- |
| Agent panel with filter and sort grammar | Native cmux agents view; the filter and sort contract is a separate host feature | Keep presentation in cmux. The detector emits facts only. |
| State-change sounds and desktop notifications | Native cmux notification path; no herdr sound asset is copied | Do not duplicate audio policy in a detector. |
| Agent launch, prompt, and resume | Native terminal and agent CLI paths | A detector observes a terminal. It must not gain input or process-launch authority. |
| Hook integrations and session identity | Existing cmux hook adapter | Keep hook authority in one reducer. A detector cannot safely replace a hook contract. |
| Agent socket API and wait operations | Generic cmux resource API and journal stream | Expose generic resources, not a herdr-specific API server. |
| Remote persistence and session restore | cmux journal and session persistence | The plugin has no private durable state to merge with host snapshots. |
| Plugin panes, actions, and link handlers | Sidebar and resource plugin contracts | These are separate plugin kinds. Do not couple them to agent detection. |
| Windows foreground process-group inspection | Not supported by this reference package | The Rust SDK transport and native process backend are Unix-only. A Windows package must add both before publication. |
| OMP and Mastracode screen manifests | Not present at the pinned herdr revision | Herdr lists these process kinds but ships no screen manifests. Hooks can still cover them. We do not invent state rules. |

Linux child-group inference remains an explicit fallback because it cannot
distinguish foreground from background children without a controlling
terminal. Generic OSC metadata has no agent-specific reset operation, so the
scanner's startup grace prevents stale screen classification while the daemon
retains generic terminal metadata. Network updates are explicit; the scanner
never fetches data during startup. A different userland plugin can replace the
reference package and emit the same generic journal envelope.
