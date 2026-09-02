# Plugin Contract

This document specifies the mux-side sidebar and journal plugin contracts.

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
The manager inspects at most 256 entries in one install root, including hidden
transaction leftovers and registry metadata. A larger root fails closed and
must be cleaned up before `list`, `use`, `update`, or `remove` can continue.
Git sources are passed to `git` as process arguments. HTTP and HTTPS sources
with embedded user information, query strings, or fragments are rejected so
tokens do not enter the process table. Use a Git credential helper or an SSH
key for private repositories; SSH user names, SCP-like sources, and local paths
remain supported. Git metadata stdout is capped at 16 KiB before parsing;
overflow is treated as unavailable.

## Agent Plugins

An agent plugin is a server-side background executable. It does not run in a
sidebar PTY and it does not add agent code to cmux core. Core owns process
supervision, environment setup, journal admission, and roster reduction. The
plugin owns process-group discovery, screen sampling, manifest rules, and
agent-specific interpretation.

Core still accepts the old `detected` source and `ScreenDetect` native event
only when replaying journals written before this boundary existed. Current core
code never creates those records. New detection implementations must use the
generic `plugin.<id>.agent.*` journal envelope.

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

`id` is the stable producer identity and is required. It must match
`[a-z0-9][a-z0-9_-]*` (maximum 64 bytes). `command[0]` and `cwd` must be absolute.
The built-in `cmux_agent` hook producer ID is reserved and cannot be used by a
userland plugin. Core ignores an agent plugin entry without an explicit ID and
never invents a namespace for it.
`revision` is optional for hand-written configuration, but the plugin manager
writes a content-derived value. A changed revision restarts the child even
when the command path is unchanged. Invalid replacement configuration disables
the previous child instead of leaving stale detection active.

The supervisor passes `CMUX_TUI_SOCKET`, `CMUX_MUX_SOCKET`,
`CMUX_TUI_SESSION_ID`, and the required `CMUX_PLUGIN_ID`, plus
`CMUX_PLUGIN_REVISION`,
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

The reference Linux backend streams `/proc` regular files through a 128 KiB
bound before parsing. Oversized process files fail closed, so a malformed
process cannot force an unbounded allocation in the detector.

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
The reference loader also caps an active set at 256 manifests, a source
directory at 512 entries, and each manifest at 256 KiB before parsing.

The herdr source and Apache-2.0 license attribution are listed in
`cmux-tui/ATTRIBUTIONS.md` and the plugin package `ATTRIBUTIONS.md`. Twenty
manifest files are unchanged at the manifest snapshot commit. `grok.toml`
carries one local precedence correction, documented in both attribution files
and its manifest README. Files adapted from herdr carry the upstream path and
their source-reference commit in their header.

The reference package builds with Cargo `--locked`, so installation uses the
checked-in dependency graph. Other plugins may choose another build tool, but
should provide an equivalent lock or integrity check when their tool supports
one.

### Herdr capability coverage

The reference package covers the agent-detection capabilities that can be
shared without importing herdr's application into cmux:

| Herdr capability | Userland package behavior |
| --- | --- |
| Screen manifests | 21 manifests are bundled and replaceable. Herdr lists 23 agent kinds, but OMP and Mastracode have no screen manifest at the manifest snapshot revision. |
| Identity aliases and wrappers | Manifest aliases, shell/runtime arguments, package launchers, process groups, and a public-process fallback are supported. Attached runtime eval/module flags stop path scans, and flags after the first positional script do not hide its identity. Direct shell scripts and escaped shell command words are decoded; shell command flags follow each runtime's grammar, including fish's separate and inline `--command` forms. Value-taking, no-exec, exit-only, and unknown shell modes fail closed. Visible executable and wrapper evidence is checked before the optional `CMUX_AGENT` or `HERDR_AGENT` process hint, so ordinary scans do not read process environments. Linux can opt into bounded child-group inference with `CMUX_AGENT_PROCESS_DETECTION=child-groups` when a controlling-terminal group is unavailable. |
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
| Remote persistence and session restore | cmux journal and session persistence | The plugin has no private durable state to merge with host snapshots. |
| Plugin panes, actions, and link handlers | Sidebar and resource plugin contracts | These are separate plugin kinds. Do not couple them to agent detection. |
| Windows foreground process-group inspection | Not supported by this reference package | The Rust SDK transport and native process backend are Unix-only. A Windows package must add both before publication. |
| OMP and Mastracode screen manifests | Not present at the manifest snapshot revision | Herdr lists these process kinds but ships no screen manifests. Hooks can still cover them. We do not invent state rules. |
| Agent inventory and point lookup (`agent.list`, `agent.get`) | `agent.list` and typed SDK agent handles return the generic `AgentSnapshot`; there is no separate `agent.get` wire operation | Keep lookup terminal-scoped and catalog-independent. A client can refresh a selected opaque agent id. |
| Agent screen and history reads (`agent.read`) | `terminal.screen.read`, `terminal.output_read`, and `terminal.history.read` provide the same data sources to any plugin | Keep reads terminal primitives. Do not add an agent-specific read endpoint. |
| Explain (`agent.explain`) | The reference plugin exposes `explain` with rule evidence, source, version, and fallback reasons; the host does not evaluate vendor rules | Keep explain beside the replaceable manifest engine. Core receives normalized facts only. |
| Input (`agent.send`, `agent.send_keys`) | `terminal.input.keys` and `terminal.input.write` are generic host operations | A detector has no input permission. An action plugin must request input explicitly and own its policy. |
| Focus (`agent.focus`) and rename (`agent.rename`) | `terminal.input.focus` and `pane.rename` are generic host operations | Keep focus and naming in the host. Detection must not mutate presentation. |
| Start (`agent.start`) | `pane.run`, `pane.create`, and `tab.create_terminal` can start a command, but no agent catalog or launcher is in core | Let a separate launcher plugin choose commands. A detector must not execute an agent. |
| Prompt plus wait (`agent.prompt`) | A client can compose `terminal.input.write` or `terminal.input.keys` with `terminal.wait`; there is no atomic agent prompt operation. Herdr's latest delayed-prompt fix (`8633a398e653eee47b375c963996c78a8a14aa48`) sequences text and Enter inside its PTY actor. | Keep the detector input-free. If cmux needs atomic text-plus-Enter submission, add a generic terminal-input transaction in a separate host contract, not an agent-specific method. |
| Semantic wait (`agent.wait`) | `terminal.wait` handles screen patterns, `terminal.wait_exit` handles process exit, and `session.journal.subscribe` exposes state events; no agent-specific wait helper exists | Filter the generic journal in userland. This keeps wait semantics replaceable and avoids a core agent catalog. |
| Declarative agent view (`agent.view.set`, `agent.view.clear`) | `frontend_projection.put` is generic; native agents-view filters and sort grammar remain host-owned | Keep client-owned presentation state, including the seen bit, out of shared journal state. |
| Lifecycle report (`pane.report_agent`) | `agent.report` and the `cmux.agent-plugin.v1` journal envelope accept generic state facts | Use one reducer with hook, plugin, legacy replay, and socket precedence. |
| Native session report (`pane.report_agent_session`) | Native hook integrations can retain opaque session references; the userland screen plugin does not report or resume them | Do not let an untrusted screen guess authorize a resume command. Add a generic opaque reference only with an explicit host resume contract. |
| Presentation metadata (`pane.report_metadata`) and state labels/tokens | Generic journal `native` and `extra` data can be retained, but it does not override host lifecycle or labels | Keep display metadata in host projections. Do not let plugin payloads change semantic state by side effect. |
| Child-agent topology and rollups | A screen plugin reports one terminal observation. Core has no vendor child graph or rollup policy | Require explicit parent references and a generic graph contract before adding topology. |
| Remote client endpoint compatibility | Herdr's audited agent-surface revision `8633a398e653eee47b375c963996c78a8a14aa48` changes its transport endpoint generation, not the userland detector contract | Define and test SDK endpoint-generation compatibility before a standalone binary promises daemon upgrades. Do not import herdr's transport implementation into the detector. |

This inventory was rechecked against herdr's agent-surface revision
`8633a398e653eee47b375c963996c78a8a14aa48`. The only `src/detect` change
after the manifest snapshot is the exact Pi bundled CLI path correction from
`b1ff4582e9688f52ffb943cfa8bee4871ae122e4`; the userland process adapter
ports it and rejects non-entrypoint lookalikes. It also ported the
first-acquisition OSC retention fix from `82e6a80eb3ae39fb3d3ebd4d1fed19389767e605` inside the
userland tracker. The foreground group-leader CWD fix from
`3a3792622e59c7f2dc20f9c0236167161e4a5035` is already covered by cmux's
generic `foreground_cwd` resource, which reads the controlling foreground
group leader and exposes no herdr policy. Later upstream changes cover
Windows launch, process environment and job handling, and native input
identity. The shell-render refactor `207be3c771d281baae6e5fa0fb74be9a056e97a2`
is application/client architecture, not detector behavior, and is not copied.
The reference package has no Windows SDK transport or native process backend
and does not own launch, input, or remote paste handling, so those changes
remain outside this plugin. Review them before publishing Windows support.

The latest audited Windows commits, `0032c3b42751b6da9c5b1a91546b3c1a425d67f1`
and `18e69891dca486d669a584facd80644bb51f54a2`, fix remote multiline paste
and OpenSSH mouse input. The independent multi-client tab-view change
`6c0bb273d5d5405a00985621b17e36f8b4d64609` and the reliable delayed-prompt
change `8633a398e653eee47b375c963996c78a8a14aa48` are application/client and
PTY input architecture, not detector policy. The malformed Windows process
environment fix `5616196942cbe752cc0659b9bd0fb616b2a6ed5c` is portable-pty
behavior. These changes are outside the userland detector. Before publishing
a standalone binary, define and test SDK endpoint-generation compatibility
across host versions. The herdr repository tip checked on 2026-09-02 is
`d08e44686d8b19bd9555cc99ec9068d9fde05f16`; its post-audit changes only cover
client terminal geometry and detach handling, so the agent-surface revision is
the reproducible capability-audit pin.

Linux child-group inference remains an explicit fallback because it cannot
distinguish foreground from background children without a controlling
terminal. Generic OSC metadata has no agent-specific reset operation. The
scanner preserves OSC evidence on the first agent acquisition, then anchors
the stream revision at each replacement or confirmed exit and ignores retained
title and progress until that revision advances. On older hosts without a
revision, it keeps the compatibility path because the plugin cannot prove
whether retained metadata predates the edge. If a host supplied a revision for
the fence and later omits it, the plugin fails closed until a newer revision is
reported. A local screen hash can schedule a read, but it is never a generation
fence.
Network updates are explicit; the scanner never fetches data during startup. A
different userland plugin can replace the
reference package and emit the same generic journal envelope.
